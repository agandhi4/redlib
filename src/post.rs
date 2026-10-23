#![allow(clippy::cmp_owned)]
use crate::client::{canonical_path, json, thread_needs_login};
use crate::config::get_setting;
use crate::db;
use crate::model::{parse_post, Author, Awards, Comment, Flair, FlairPart, Post, Subreddit};
use crate::preferences::{get_filters, setting, Preferences};
use crate::rewrite::rewrite_emotes;
use crate::server::RequestExt;
use crate::subreddit::{can_access_quarantine, quarantine};
use crate::utils::{error, format_num, nsfw_landing, param, redirect, template, time, val};
use askama::Template;
use cached::{Cached, TimedSizedCache};
use hyper::{Body, Request, Response};
use regex::Regex;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::sync::{LazyLock, Mutex};

// STRUCTS
#[derive(Template)]
#[template(path = "post.html")]
struct PostTemplate {
	comments: Vec<Comment>,
	post: Post,
	sort: String,
	prefs: Preferences,
	single_thread: bool,
	url: String,
	url_without_query: String,
	comment_query: String,
	sub: Subreddit,
	/// Reddit refused the thread (`client::thread_needs_login`): the post renders alone with a notice.
	comments_unavailable: bool,
}

#[derive(Template)]
#[template(path = "saved.html")]
struct SavedTemplate {
	groups: Vec<db::SavedGroup>,
	prefs: Preferences,
	url: String,
}

static COMMENT_SEARCH_CAPTURE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\?q=(.*)&type=comment").unwrap());

// Rendered-HTML cache for post pages. The JSON cache (client.rs) already
// avoids re-fetching from Reddit, but parsing + rendering hundreds of
// comments costs ~250ms of NAS CPU per request — and the hover-prefetch
// flow renders every page twice (prefetch, then the real click). Keyed on
// URI + cookies because prefs shape the HTML. 20 entries × ~400KB ≈ 8MB.
static RENDERED_POST_CACHE: LazyLock<Mutex<TimedSizedCache<String, String>>> =
	LazyLock::new(|| Mutex::new(TimedSizedCache::with_size_and_lifespan(20, std::time::Duration::from_secs(30))));

fn html_response(html: String) -> Response<Body> {
	Response::builder().status(200).header("content-type", "text/html").body(html.into()).unwrap_or_default()
}

/// A post link with no subreddit (`/comments/<id>/…`, and the `/<id>` short link): resolve the
/// canonical `/r/<sub>/comments/<id>/<title>/` with the short-link HEAD on www.reddit.com (not
/// blocked, unlike the bare JSON route) and redirect, keeping a linked comment and the query, so
/// every post link lands in `item`. Used by the `/comments/:id…` routes and `/:id` in `main.rs`.
pub async fn canonical_redirect(req: Request<Body>) -> Result<Response<Body>, String> {
	let id = req.param("id").unwrap_or_default();
	let resolved = canonical_path(format!("/comments/{id}"), 3).await;
	match resolved.map(|path| path.and_then(|path| canonical_target(&path, req.param("comment_id").as_deref(), req.uri().query()))) {
		Ok(Some(target)) => Ok(redirect(&target)),
		Ok(None) => error(req, "Post ID is invalid. It may point to a post on a community that has been banned.").await,
		Err(e) => error(req, &e).await,
	}
}

/// Where `canonical_redirect` sends the reader, or None. A resolved path still lacking a
/// subreddit (Reddit answered 2xx, so `canonical_path` echoed the bare input) would redirect
/// back to the same route forever, so only `/r/`, `/u/` and `/user/` paths are followed.
fn canonical_target(path: &str, comment_id: Option<&str>, query: Option<&str>) -> Option<String> {
	if !["/r/", "/u/", "/user/"].iter().any(|prefix| path.starts_with(prefix)) {
		return None;
	}
	let mut target = path.to_string();
	if let Some(comment_id) = comment_id.filter(|c| !c.is_empty()) {
		if !target.ends_with('/') {
			target.push('/');
		}
		target.push_str(comment_id);
		target.push('/');
	}
	if let Some(query) = query.filter(|q| !q.is_empty()) {
		target.push('?');
		target.push_str(query);
	}
	Some(target)
}

pub async fn item(req: Request<Body>) -> Result<Response<Body>, String> {
	// Serve a recently rendered copy if one exists (see RENDERED_POST_CACHE)
	let cache_key = format!("{}|{}", req.uri(), req.headers().get("cookie").and_then(|c| c.to_str().ok()).unwrap_or_default());
	if let Some(html) = RENDERED_POST_CACHE.lock().unwrap().cache_get(&cache_key).cloned() {
		return Ok(html_response(html));
	}
	// Build Reddit API path
	let mut path: String = format!("{}.json?{}&raw_json=1", req.uri().path(), req.uri().query().unwrap_or_default());
	let sub = req.param("sub").unwrap_or_default();
	let quarantined = can_access_quarantine(&req, &sub);
	let url = req.uri().to_string();

	// Set sort to sort query parameter
	let sort = param(&path, "sort").unwrap_or_else(|| {
		// Grab default comment sort method from Cookies
		let default_sort = setting(&req, "comment_sort");

		// If there's no sort query but there's a default sort, set sort to default_sort
		if default_sort.is_empty() {
			String::new()
		} else {
			path = format!("{}.json?{}&sort={}&raw_json=1", req.uri().path(), req.uri().query().unwrap_or_default(), default_sort);
			default_sort
		}
	});

	// Log the post ID being fetched in debug mode
	#[cfg(debug_assertions)]
	req.param("id").unwrap_or_default();

	let single_thread = req.param("comment_id").is_some();
	let highlighted_comment = &req.param("comment_id").unwrap_or_default();

	// The thread JSON and the subreddit sidebar are independent Reddit calls; fetch them
	// concurrently so a cache-cold post page costs one round-trip, not two.
	let (response, sidebar) = tokio::join!(json(path, quarantined), crate::subreddit::subreddit(&sub, quarantined));
	let (post_json, comments_json) = match response {
		Ok(response) => (response.pointer("/0/data/children/0").cloned().unwrap_or_default(), response.get(1).cloned()),
		Err(msg) if thread_needs_login(&msg) => match post_without_comments(&req, quarantined).await {
			Ok(post_json) => (post_json, None),
			Err(msg) => return error(req, &msg).await,
		},
		Err(msg) if msg == "quarantined" || msg == "gated" => {
			let sub = req.param("sub").unwrap_or_default();
			return Ok(quarantine(&req, sub, &msg));
		}
		// If the Reddit API returns an error, exit and send error page to user
		Err(msg) => return error(req, &msg).await,
	};

	// Parse the JSON into Post and Comment structs
	let mut post = parse_post(&post_json).await;

	let req_url = req.uri().to_string();
	// Return landing page if this post if this Reddit deems this post
	// NSFW, but we have also disabled the display of NSFW content
	// or if the instance is SFW-only.
	if post.nsfw && crate::utils::should_be_nsfw_gated(&req, &req_url) {
		return Ok(nsfw_landing(req, req_url).await.unwrap_or_default());
	}

	let query_body = match COMMENT_SEARCH_CAPTURE.captures(&url) {
		Some(captures) => captures.get(1).unwrap().as_str().replace("%20", " ").replace('+', " "),
		None => String::new(),
	};

	let query_string = format!("q={query_body}&type=comment");
	let form = url::form_urlencoded::parse(query_string.as_bytes()).collect::<HashMap<_, _>>();
	let query = form.get("q").unwrap().clone().to_string();

	let filters = get_filters(&req);
	let comments = match (&comments_json, query.as_str()) {
		(None, _) => Vec::new(),
		(Some(json), "") => parse_comments(json, &post.permalink, &post.author.name, highlighted_comment, &filters, &req),
		(Some(json), _) => query_comments(json, &post.permalink, &post.author.name, highlighted_comment, &filters, &query, &req),
	};

	let sub_data = sidebar.unwrap_or_default();

	// Record visit and check saved status
	db::record_visit(&post.id, &post.title, &post.community, &post.permalink);
	db::cleanup_history();
	post.is_saved = db::is_saved(&post.id);

	// Use the Post and Comment structs to generate a website to show users
	let html = PostTemplate {
		comments,
		post,
		url_without_query: url.clone().trim_end_matches(&format!("?q={query}&type=comment")).to_string(),
		sort,
		prefs: Preferences::new(&req),
		single_thread,
		url: req_url,
		comment_query: query,
		sub: sub_data,
		comments_unavailable: comments_json.is_none(),
	}
	.render()
	.unwrap_or_default();
	RENDERED_POST_CACHE.lock().unwrap().cache_set(cache_key, html.clone());
	Ok(html_response(html))
}

/// The post alone, from `/by_id/` (still served to app-only tokens), for a thread Reddit refuses
/// (`client::thread_needs_login`). `item` then renders it with a note that comments need a login.
async fn post_without_comments(req: &Request<Body>, quarantined: bool) -> Result<Value, String> {
	let id = req.param("id").unwrap_or_default();
	let listing = json(format!("/by_id/t3_{id}.json?raw_json=1"), quarantined).await?;
	listing.pointer("/data/children/0").cloned().ok_or_else(|| "Post not found".to_string())
}

// COMMENTS

fn parse_comments(json: &serde_json::Value, post_link: &str, post_author: &str, highlighted_comment: &str, filters: &HashSet<String>, req: &Request<Body>) -> Vec<Comment> {
	// Parse the comment JSON into a Vector of Comments
	let comments = json["data"]["children"].as_array().map_or(Vec::new(), std::borrow::ToOwned::to_owned);

	// For each comment, retrieve the values to build a Comment object
	comments
		.into_iter()
		.map(|comment| {
			let data = &comment["data"];
			let replies: Vec<Comment> = if data["replies"].is_object() {
				parse_comments(&data["replies"], post_link, post_author, highlighted_comment, filters, req)
			} else {
				Vec::new()
			};
			build_comment(&comment, data, replies, post_link, post_author, highlighted_comment, filters, req)
		})
		.collect()
}

fn query_comments(
	json: &serde_json::Value,
	post_link: &str,
	post_author: &str,
	highlighted_comment: &str,
	filters: &HashSet<String>,
	query: &str,
	req: &Request<Body>,
) -> Vec<Comment> {
	let comments = json["data"]["children"].as_array().map_or(Vec::new(), std::borrow::ToOwned::to_owned);
	let mut results = Vec::new();

	for comment in comments {
		let data = &comment["data"];

		// If this comment contains replies, handle those too
		if data["replies"].is_object() {
			results.append(&mut query_comments(&data["replies"], post_link, post_author, highlighted_comment, filters, query, req));
		}

		let c = build_comment(&comment, data, Vec::new(), post_link, post_author, highlighted_comment, filters, req);
		if c.body.to_lowercase().contains(&query.to_lowercase()) {
			results.push(c);
		}
	}

	results
}
#[allow(clippy::too_many_arguments)]
fn build_comment(
	comment: &serde_json::Value,
	data: &serde_json::Value,
	replies: Vec<Comment>,
	post_link: &str,
	post_author: &str,
	highlighted_comment: &str,
	filters: &HashSet<String>,
	req: &Request<Body>,
) -> Comment {
	let id = val(comment, "id");

	let body = if (val(comment, "author") == "[deleted]" && val(comment, "body") == "[removed]") || val(comment, "body") == "[ Removed by Reddit ]" {
		format!(
			"<div class=\"md\"><p>[removed] — <a href=\"https://{}{post_link}{id}\">view removed comment</a></p></div>",
			get_setting("REDLIB_PUSHSHIFT_FRONTEND").unwrap_or_else(|| String::from(crate::config::DEFAULT_PUSHSHIFT_FRONTEND)),
		)
	} else {
		rewrite_emotes(&data["media_metadata"], val(comment, "body_html"))
	};
	let kind = comment["kind"].as_str().unwrap_or_default().to_string();

	let unix_time = data["created_utc"].as_f64().unwrap_or_default();
	let (rel_time, created) = time(unix_time);

	let edited = data["edited"].as_f64().map_or((String::new(), String::new()), time);

	let score = data["score"].as_i64().unwrap_or(0);

	// The JSON API only provides comments up to some threshold.
	// Further comments have to be loaded by subsequent requests.
	// The "kind" value will be "more" and the "count"
	// shows how many more (sub-)comments exist in the respective nesting level.
	// Note that in certain (seemingly random) cases, the count is simply wrong.
	let more_count = data["count"].as_i64().unwrap_or_default();

	let awards: Awards = Awards::parse(&data["all_awardings"]);

	let parent_kind_and_id = val(comment, "parent_id");
	let parent_info = parent_kind_and_id.split('_').collect::<Vec<&str>>();

	let highlighted = id == highlighted_comment;

	let author = Author {
		name: val(comment, "author"),
		flair: Flair {
			flair_parts: FlairPart::parse(
				data["author_flair_type"].as_str().unwrap_or_default(),
				data["author_flair_richtext"].as_array(),
				data["author_flair_text"].as_str(),
			),
			text: val(comment, "link_flair_text"),
			background_color: val(comment, "author_flair_background_color"),
			foreground_color: val(comment, "author_flair_text_color"),
		},
		distinguished: val(comment, "distinguished"),
	};
	let is_filtered = filters.contains(&["u_", author.name.as_str()].concat());

	// Many subreddits have a default comment posted about the sub's rules etc.
	// Many Redlib users do not wish to see this kind of comment by default.
	// Reddit does not tell us which users are "bots", so a good heuristic is to
	// collapse stickied moderator comments.
	let is_moderator_comment = data["distinguished"].as_str().unwrap_or_default() == "moderator";
	let is_stickied = data["stickied"].as_bool().unwrap_or_default();
	let collapsed = (is_moderator_comment && is_stickied) || is_filtered;

	Comment {
		id,
		kind,
		parent_id: parent_info[1].to_string(),
		parent_kind: parent_info[0].to_string(),
		post_link: post_link.to_string(),
		post_author: post_author.to_string(),
		body,
		author,
		score: if data["score_hidden"].as_bool().unwrap_or_default() {
			("\u{2022}".to_string(), "Hidden".to_string())
		} else {
			format_num(score)
		},
		rel_time,
		created,
		edited,
		replies,
		highlighted,
		awards,
		collapsed,
		is_filtered,
		more_count,
		prefs: Preferences::new(req),
	}
}

// SAVED ITEMS

/// Render the saved items page.
pub async fn saved(req: Request<Body>) -> Result<Response<Body>, String> {
	let groups = db::saved_items_grouped();
	Ok(template(&SavedTemplate {
		groups,
		prefs: Preferences::new(&req),
		url: "/saved".to_string(),
	}))
}

/// Save a post. Expects form-encoded post_id, title, subreddit, url, redirect.
pub async fn save(req: Request<Body>) -> Result<Response<Body>, String> {
	let body = hyper::body::to_bytes(req.into_body()).await.map_err(|e| e.to_string())?;
	let form: HashMap<String, String> = url::form_urlencoded::parse(&body).into_owned().collect();

	let post_id = form.get("post_id").cloned().unwrap_or_default();
	let title = form.get("title").cloned().unwrap_or_default();
	let subreddit = form.get("subreddit").cloned().unwrap_or_default();
	let url = form.get("url").cloned().unwrap_or_default();
	let redirect_url = form.get("redirect").cloned().unwrap_or_else(|| "/saved".to_string());

	if !post_id.is_empty() {
		db::save_item(&post_id, &title, &subreddit, &url);
	}

	Ok(redirect(&redirect_url))
}

/// Unsave a post. Expects form-encoded post_id, redirect.
pub async fn unsave(req: Request<Body>) -> Result<Response<Body>, String> {
	let body = hyper::body::to_bytes(req.into_body()).await.map_err(|e| e.to_string())?;
	let form: HashMap<String, String> = url::form_urlencoded::parse(&body).into_owned().collect();

	let post_id = form.get("post_id").cloned().unwrap_or_default();
	let redirect_url = form.get("redirect").cloned().unwrap_or_else(|| "/saved".to_string());

	if !post_id.is_empty() {
		db::unsave_item(&post_id);
	}

	Ok(redirect(&redirect_url))
}

#[cfg(test)]
mod tests {
	use super::*;

	const PERMALINK: &str = "/r/nyc/comments/1xadhhx/vandals_hit_nyc_subway/";

	#[test]
	fn canonical_target_keeps_a_linked_comment_and_the_query() {
		assert_eq!(canonical_target(PERMALINK, None, None).as_deref(), Some(PERMALINK));
		assert_eq!(
			canonical_target(PERMALINK, Some("kfbqlbc"), Some("context=3")).as_deref(),
			Some("/r/nyc/comments/1xadhhx/vandals_hit_nyc_subway/kfbqlbc/?context=3")
		);
		assert_eq!(
			canonical_target("/r/nyc/comments/1xadhhx/title", Some("kfbqlbc"), Some("")).as_deref(),
			Some("/r/nyc/comments/1xadhhx/title/kfbqlbc/")
		);
		assert_eq!(
			canonical_target("/user/spez/comments/abc123/t/", None, None).as_deref(),
			Some("/user/spez/comments/abc123/t/")
		);
	}

	#[test]
	fn canonical_target_refuses_a_path_that_would_redirect_to_itself() {
		// canonical_path echoes its input on a 2xx; following it would loop on /comments/:id.
		assert_eq!(canonical_target("/comments/1xadhhx", None, None), None);
		assert_eq!(canonical_target("/comments/1xadhhx/title/", Some("kfbqlbc"), None), None);
	}
}
