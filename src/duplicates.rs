//! Handler for post duplicates.

use crate::client::json;
use crate::model::{filter_posts, parse_post, Post};
use crate::server::RequestExt;
use crate::subreddit::{can_access_quarantine, quarantine};
use crate::utils::{error, get_filters, nsfw_landing, template, Preferences};

use askama::Template;
use hyper::{Body, Request, Response};
use serde_json::Value;
use std::borrow::ToOwned;
use std::collections::HashSet;
use std::vec::Vec;

/// `DuplicatesParams` contains the parameters in the URL.
struct DuplicatesParams {
	before: String,
	after: String,
	sort: String,
}

/// `DuplicatesTemplate` defines an Askama template for rendering duplicate
/// posts.
#[derive(Template)]
#[template(path = "duplicates.html")]
struct DuplicatesTemplate {
	/// params contains the relevant request parameters.
	params: DuplicatesParams,

	/// post is the post whose ID is specified in the reqeust URL. Note that
	/// this is not necessarily the "original" post.
	post: Post,

	/// duplicates is the list of posts that, per Reddit, are duplicates of
	/// Post above.
	duplicates: Vec<Post>,

	/// prefs are the user preferences.
	prefs: Preferences,

	/// url is the request URL.
	url: String,

	/// num_posts_filtered counts how many posts were filtered from the
	/// duplicates list.
	num_posts_filtered: u64,

	/// all_posts_filtered is true if every duplicate was filtered. This is an
	/// edge case but can still happen.
	all_posts_filtered: bool,
}

/// Make the GET request to Reddit. It assumes `req` is the appropriate Reddit
/// REST endpoint for enumerating post duplicates.
pub async fn item(req: Request<Body>) -> Result<Response<Body>, String> {
	let path: String = format!("{}.json?{}&raw_json=1", req.uri().path(), req.uri().query().unwrap_or_default());
	let sub = req.param("sub").unwrap_or_default();
	let quarantined = can_access_quarantine(&req, &sub);

	let response = match json(path, quarantined).await {
		Ok(response) => response,
		Err(msg) if msg == "quarantined" || msg == "gated" => return Ok(quarantine(&req, sub, &msg)),
		Err(msg) => return error(req, &msg).await,
	};

	let post = parse_post(&response[0]["data"]["children"][0]).await;

	let req_url = req.uri().to_string();
	// Return landing page if this post if this Reddit deems this post
	// NSFW, but we have also disabled the display of NSFW content
	// or if the instance is SFW-only
	if post.nsfw && crate::utils::should_be_nsfw_gated(&req, &req_url) {
		return Ok(nsfw_landing(req, req_url).await.unwrap_or_default());
	}

	let filters = get_filters(&req);
	let (duplicates, num_posts_filtered, all_posts_filtered) = parse_duplicates(&response[1], &filters).await;

	let params = match paging_params(&req, &duplicates, &response[1]).await {
		Ok(params) => params,
		// Abort entirely if we couldn't get the previous batch.
		Err(msg) => return error(req, &msg).await,
	};

	Ok(template(&DuplicatesTemplate {
		params,
		post,
		duplicates,
		prefs: Preferences::new(&req),
		url: req_url,
		num_posts_filtered,
		all_posts_filtered,
	}))
}

/// The duplicates query string's paging state. Only the presence of `before=`/`after=`
/// matters (see `paging_params`); `sort=` is kept when it is `new` or `num_comments`, the
/// sorts the duplicates listing has. In practice there is only ever one of before/after.
#[derive(Debug, Default, PartialEq)]
struct QueryCursor {
	have_before: bool,
	have_after: bool,
	sort: String,
}

fn parse_cursor(query: &str) -> QueryCursor {
	let mut cursor = QueryCursor::default();
	for param in query.split('&') {
		let mut kv = param.split('=');
		// A parameter without `=` is ignored.
		let (Some(key), Some(value)) = (kv.next(), kv.next()) else {
			continue;
		};
		match (key, value) {
			("before", _) => cursor.have_before = true,
			("after", _) => cursor.have_after = true,
			("sort", "new" | "num_comments") => value.clone_into(&mut cursor.sort),
			_ => {}
		}
	}
	cursor
}

/// The "before=", "after=" and "sort=" values for the page's links. Err is a failed request
/// for the previous batch, which the caller renders as the error page.
///
/// FIXME: We have to perform a kludge to work around a Reddit API bug.
///
/// The JSON object in "data" will never contain a "before" value so it is impossible to use
/// it to determine our position in a listing. We'll make do by getting the ID of the first
/// post in the listing, setting that as our "before" value, and ask Reddit to give us a batch
/// of duplicate posts up to that post.
///
/// Likewise, if we provide a "before" request in the GET, the result won't have an "after"
/// in the JSON, in addition to missing the "before." So we will have to use the final post in
/// the list of duplicates.
///
/// With no duplicates all three stay empty, even when the query names a sort.
async fn paging_params(req: &Request<Body>, duplicates: &[Post], listing: &Value) -> Result<DuplicatesParams, String> {
	let (Some(first), Some(last)) = (duplicates.first(), duplicates.last()) else {
		return Ok(DuplicatesParams {
			before: String::new(),
			after: String::new(),
			sort: String::new(),
		});
	};

	let cursor = parse_cursor(req.uri().query().unwrap_or_default());
	// If we're in the middle of the batch (evidenced by an "after=" in the GET), then use the
	// first post as the "before" reference.
	let first_ref = format!("t3_{}", first.id);
	let mut before = if cursor.have_after { first_ref.clone() } else { String::new() };

	if !cursor.have_before {
		let after = listing["data"]["after"].as_str().unwrap_or_default().to_string();
		return Ok(DuplicatesParams { before, after, sort: cursor.sort });
	}

	// "before=" in the GET means "after" is null in the JSON: the next batch starts from one
	// after the last post in this one.
	let after = format!("t3_{}", last.id);

	// Here is where things get terrible. Notice that we haven't set `before`. In order to do
	// so, we will need to know if there is a batch that exists before this one, and doing so
	// requires actually fetching the previous batch. In other words, we have to do yet one
	// more GET to Reddit. There is no other way to determine whether or not to define
	// `before`.
	//
	// We'll mitigate that by requesting at most one duplicate.
	let probe_sort = if cursor.sort.is_empty() { "num_comments" } else { cursor.sort.as_str() };
	let probe_path = format!("{}.json?before=t3_{}&sort={probe_sort}&limit=1&raw_json=1", req.uri().path(), first.id);
	let previous = json(probe_path, true).await?;
	if !previous[1]["data"]["children"].as_array().unwrap_or(&Vec::new()).is_empty() {
		before = first_ref;
	}

	Ok(DuplicatesParams { before, after, sort: cursor.sort })
}

// DUPLICATES
async fn parse_duplicates(json: &Value, filters: &HashSet<String>) -> (Vec<Post>, u64, bool) {
	let post_duplicates: &Vec<Value> = &json["data"]["children"].as_array().map_or(Vec::new(), ToOwned::to_owned);
	let mut duplicates: Vec<Post> = Vec::new();

	// Process each post and place them in the Vec<Post>.
	for val in post_duplicates {
		let post: Post = parse_post(val).await;
		duplicates.push(post);
	}

	let (num_posts_filtered, all_posts_filtered) = filter_posts(&mut duplicates, filters);
	(duplicates, num_posts_filtered, all_posts_filtered)
}

#[cfg(test)]
mod tests {
	use super::*;

	fn cursor(have_before: bool, have_after: bool, sort: &str) -> QueryCursor {
		QueryCursor {
			have_before,
			have_after,
			sort: sort.to_string(),
		}
	}

	#[test]
	fn parse_cursor_reads_presence_and_known_sorts() {
		assert_eq!(parse_cursor(""), cursor(false, false, ""));
		assert_eq!(parse_cursor("after=t3_abc&sort=new"), cursor(false, true, "new"));
		assert_eq!(parse_cursor("before=&sort=num_comments"), cursor(true, false, "num_comments"));
	}

	#[test]
	fn parse_cursor_ignores_bare_keys_and_other_sorts() {
		// A bare key has no `=`; an unknown sort leaves an earlier known one in place.
		assert_eq!(parse_cursor("before&after"), cursor(false, false, ""));
		assert_eq!(parse_cursor("sort=new&sort=top"), cursor(false, false, "new"));
		assert_eq!(parse_cursor("sort=new=x"), cursor(false, false, "new"));
	}
}
