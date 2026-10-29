//! One thread page's Reddit data: the post from `/by_id/` and its comments from the Android
//! GraphQL query (`gql_comments`), since Reddit 403s the thread JSON routes for app-only tokens.
//! Used by `post::item`.

use crate::client::{distrust_listing, gql};
use crate::gql_comments::{is_supported_sort, listing, request_body, CommentsRequest};
use crate::sources::json;
use log::{debug, warn};
use serde_json::Value;
use std::time::Instant;

/// What `post::item` asked for, from its route and query.
pub struct ThreadQuery {
	pub post_id: String,
	pub comment_id: Option<String>,
	/// The `sort` query parameter, else the `comment_sort` setting. None defers to the post's
	/// `suggested_sort`, which costs fetching the post before the comments.
	pub sort: Option<String>,
	/// The base64 cursor of a "more" link.
	pub cursor: Option<String>,
	pub context: usize,
	pub quarantine: bool,
}

pub struct Thread {
	/// The `/by_id/` listing's child, as `model::parse_post` reads it.
	pub post: Value,
	/// The comments Listing (`gql_comments::listing`); None when Reddit did not return them, and
	/// the page renders the post alone.
	pub comments: Option<Value>,
	/// The sort the comments were served in (Reddit's applied sort when they came back).
	pub sort: String,
}

/// The post and its comments. Only the post's errors fail the page (including "quarantined" and
/// "gated", which `post::item` turns into the opt-in page); a comments failure is logged and
/// yields `comments: None`.
pub async fn fetch(query: ThreadQuery) -> Result<Thread, String> {
	let (post, comments, sort) = match query.sort.clone().filter(|sort| !sort.is_empty()) {
		// The sort is known: post and comments are independent, so one round-trip for both.
		Some(sort) => {
			let (post, comments) = tokio::join!(post(&query), comments(&query, sort.clone()));
			(post?, comments, sort)
		}
		None => {
			let post = post(&query).await?;
			let sort = post["data"]["suggested_sort"]
				.as_str()
				.filter(|sort| is_supported_sort(sort))
				.unwrap_or("confidence")
				.to_string();
			let comments = comments(&query, sort.clone()).await;
			(post, comments, sort)
		}
	};
	let sort = comments.as_ref().and_then(|listing| listing["data"]["sort"].as_str()).map_or(sort, str::to_string);
	Ok(Thread { post, comments, sort })
}

/// The post alone, from `/by_id/` (PostsByIds through `sources`, REST as its fallback).
async fn post(query: &ThreadQuery) -> Result<Value, String> {
	let path = format!("/by_id/t3_{}.json?raw_json=1", query.post_id);
	let listing = json(path.clone(), query.quarantine).await?;
	match listing["data"]["children"].as_array() {
		// No `children` at all is the degraded-token answer, not a missing post.
		None => Err(distrust_listing(&path, query.quarantine, &listing).await),
		Some(children) => children.first().cloned().ok_or_else(|| "Post not found".to_string()),
	}
}

/// The comments Listing in `sort`, or None (logged) when the request cannot be built, Reddit
/// fails it, or the response does not convert.
async fn comments(query: &ThreadQuery, sort: String) -> Option<Value> {
	let started = Instant::now();
	let req = CommentsRequest {
		post_id: query.post_id.clone(),
		comment_id: query.comment_id.clone(),
		sort,
		cursor: query.cursor.clone(),
		context: query.context,
	};
	let result = async {
		let response = gql(request_body(&req)?).await?;
		listing(&response, &req)
	};
	match result.await {
		Ok(listing) => {
			debug!(
				"[thread] t3_{}: {} top-level comments, sort {}, {}ms",
				req.post_id,
				listing["data"]["children"].as_array().map_or(0, Vec::len),
				listing["data"]["sort"],
				started.elapsed().as_millis()
			);
			Some(listing)
		}
		Err(e) => {
			warn!("[thread] t3_{}: comments unavailable, rendering the post alone: {e}", req.post_id);
			None
		}
	}
}
