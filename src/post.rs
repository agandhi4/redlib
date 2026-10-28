// askama's generated code for post.html compares against owned strings.
#![allow(clippy::cmp_owned)]
use crate::client::canonical_path;
use crate::comments::{parse_comments, query_comments, CommentContext};
use crate::db;
use crate::model::{parse_post, Comment, Post, Subreddit};
use crate::preferences::{get_filters, setting, Preferences};
use crate::server::RequestExt;
use crate::subreddit::{can_access_quarantine, quarantine};
use crate::thread::{self, ThreadQuery};
use crate::utils::{error, nsfw_landing, param, redirect, template};
use askama::Template;
use cached::{Cached, TimedSizedCache};
use hyper::{Body, Request, Response};
use regex::Regex;
use std::collections::HashMap;
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
	/// Reddit did not return the comments (`thread::fetch` logged why): the post renders alone
	/// with a notice linking to reddit.com.
	comments_unavailable: bool,
	/// The thread on reddit.com, including a linked comment, for that notice.
	reddit_url: String,
	/// The base64 cursor of the thread's next top-level page of comments, or empty.
	next_cursor: String,
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

/// A share link from the Reddit apps' Share button (`/r/<sub>/s/<id>`, `/u/<name>/s/<id>`, and
/// `/user/<name>/s/<id>`, upstream #560): Reddit's HEAD redirects it to the post, which
/// `canonical_path` follows. The share query (`share_id`, tracking) is dropped. Used by the
/// `…/s/:id` routes in `main.rs`.
pub async fn share_redirect(req: Request<Body>) -> Result<Response<Body>, String> {
	let id = req.param("id").unwrap_or_default();
	let owner = match (req.param("sub"), req.param("name")) {
		(Some(sub), _) => format!("r/{sub}"),
		(None, Some(name)) => format!("u/{name}"),
		(None, None) => String::new(),
	};
	if owner.is_empty() || !(8..12).contains(&id.len()) {
		return error(req, "Nothing here").await;
	}
	let resolved = canonical_path(format!("/{owner}/s/{id}"), 3).await;
	match resolved.map(|path| path.and_then(|path| canonical_target(&path, None, None))) {
		Ok(Some(target)) => Ok(redirect(&target)),
		Ok(None) => error(req, "Share link is invalid. It may point to a removed post or a banned community.").await,
		Err(e) => error(req, &e).await,
	}
}

/// Where a resolved post link sends the reader, or None. Only a post path (`/comments/` under
/// `/r/`, `/u/` or `/user/`) is followed: on a 2xx `canonical_path` echoes its input, and a bare
/// `/comments/<id>` or an unresolved share link would redirect back to its own route forever.
fn canonical_target(path: &str, comment_id: Option<&str>, query: Option<&str>) -> Option<String> {
	if !["/r/", "/u/", "/user/"].iter().any(|prefix| path.starts_with(prefix)) || !path.contains("/comments/") {
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
	let sub = req.param("sub").unwrap_or_default();
	let quarantined = can_access_quarantine(&req, &sub);
	let url = req.uri().to_string();
	let query = thread_query(&req, quarantined);

	let single_thread = req.param("comment_id").is_some();
	let highlighted_comment = &req.param("comment_id").unwrap_or_default();

	// The thread (post + comments) and the subreddit sidebar are independent Reddit calls; fetch
	// them concurrently so a cache-cold post page costs one round-trip, not two.
	let (thread, sidebar) = tokio::join!(thread::fetch(query), crate::subreddit::subreddit(&sub, quarantined));
	let thread = match thread {
		Ok(thread) => thread,
		Err(msg) if msg == "quarantined" || msg == "gated" => return Ok(quarantine(&req, sub, &msg)),
		// If the Reddit API returns an error, exit and send error page to user
		Err(msg) => return error(req, &msg).await,
	};

	// Parse the JSON into Post and Comment structs
	let mut post = parse_post(&thread.post).await;

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
	let ctx = CommentContext {
		post_link: &post.permalink,
		post_author: &post.author.name,
		highlighted_comment,
		filters: &filters,
		sort: &thread.sort,
		req: &req,
	};
	let comments = match (&thread.comments, query.as_str()) {
		(None, _) => Vec::new(),
		(Some(json), "") => parse_comments(json, &ctx),
		(Some(json), _) => query_comments(json, &query, &ctx),
	};
	let next_cursor = thread
		.comments
		.as_ref()
		.and_then(|listing| listing["data"]["after"].as_str())
		.unwrap_or_default()
		.to_string();

	let sub_data = sidebar.unwrap_or_default();

	// Record visit and check saved status
	db::record_visit(&post.id, &post.title, &post.community, &post.permalink);
	db::cleanup_history();
	post.is_saved = db::is_saved(&post.id);

	// The comment the reader followed stays in the link, for the comments-unavailable notice.
	let reddit_url = format!(
		"https://www.reddit.com{}",
		canonical_target(&post.permalink, Some(highlighted_comment.as_str()), None).unwrap_or_else(|| post.permalink.clone())
	);

	// Use the Post and Comment structs to generate a website to show users
	let html = PostTemplate {
		comments,
		post,
		url_without_query: url.clone().trim_end_matches(&format!("?q={query}&type=comment")).to_string(),
		sort: thread.sort,
		prefs: Preferences::new(&req),
		single_thread,
		url: req_url,
		comment_query: query,
		sub: sub_data,
		comments_unavailable: thread.comments.is_none(),
		reddit_url,
		next_cursor,
	}
	.render()
	.unwrap_or_default();
	RENDERED_POST_CACHE.lock().unwrap().cache_set(cache_key, html.clone());
	Ok(html_response(html))
}

/// What `thread::fetch` needs from a post route: ids, then `sort` from the query or else the
/// `comment_sort` setting (None defers to the post's suggested sort), a "more" cursor, `context`.
fn thread_query(req: &Request<Body>, quarantine: bool) -> ThreadQuery {
	let query = format!("?{}", req.uri().query().unwrap_or_default());
	let sort = param(&query, "sort")
		.filter(|sort| !sort.is_empty())
		.or_else(|| Some(setting(req, "comment_sort")).filter(|sort| !sort.is_empty()));
	ThreadQuery {
		post_id: req.param("id").unwrap_or_default(),
		comment_id: req.param("comment_id").filter(|id| !id.is_empty()),
		sort,
		cursor: param(&query, "cursor").filter(|cursor| !cursor.is_empty()),
		context: param(&query, "context").and_then(|context| context.parse().ok()).unwrap_or(0),
		quarantine,
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
		// A share link Reddit answered 2xx instead of redirecting.
		assert_eq!(canonical_target("/r/nyc/s/AbCdEfGh12", None, None), None);
		assert_eq!(canonical_target("/u/spez/s/AbCdEfGh12", None, None), None);
	}
}
