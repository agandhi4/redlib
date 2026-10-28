//! A thread's comments Listing (JSON API shape, as `gql_comments::listing` builds it) as the
//! `Comment` tree `templates/comment.html` renders. Used by `post::item`.

use crate::config::get_setting;
use crate::model::{Author, Awards, Comment, Flair, FlairPart};
use crate::preferences::Preferences;
use crate::rewrite::rewrite_emotes;
use crate::utils::{format_num, time, val};
use hyper::{Body, Request};
use serde_json::Value;
use std::collections::HashSet;

/// What every comment of one page shares.
pub struct CommentContext<'a> {
	pub post_link: &'a str,
	pub post_author: &'a str,
	pub highlighted_comment: &'a str,
	pub filters: &'a HashSet<String>,
	/// The page's comment sort, carried into "more" links so the next page keeps it.
	pub sort: &'a str,
	pub req: &'a Request<Body>,
}

pub fn parse_comments(json: &Value, ctx: &CommentContext) -> Vec<Comment> {
	// Parse the comment JSON into a Vector of Comments
	let comments = json["data"]["children"].as_array().map_or(Vec::new(), std::borrow::ToOwned::to_owned);

	// For each comment, retrieve the values to build a Comment object
	comments
		.into_iter()
		.map(|comment| {
			let data = &comment["data"];
			let replies: Vec<Comment> = if data["replies"].is_object() {
				parse_comments(&data["replies"], ctx)
			} else {
				Vec::new()
			};
			build_comment(&comment, replies, ctx)
		})
		.collect()
}

/// The comments whose body contains `query`, flattened.
pub fn query_comments(json: &Value, query: &str, ctx: &CommentContext) -> Vec<Comment> {
	let comments = json["data"]["children"].as_array().map_or(Vec::new(), std::borrow::ToOwned::to_owned);
	let mut results = Vec::new();

	for comment in comments {
		let data = &comment["data"];

		// If this comment contains replies, handle those too
		if data["replies"].is_object() {
			results.append(&mut query_comments(&data["replies"], query, ctx));
		}

		let c = build_comment(&comment, Vec::new(), ctx);
		if c.body.to_lowercase().contains(&query.to_lowercase()) {
			results.push(c);
		}
	}

	results
}

fn build_comment(comment: &Value, replies: Vec<Comment>, ctx: &CommentContext) -> Comment {
	let data = &comment["data"];
	let id = val(comment, "id");
	let post_link = ctx.post_link;

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

	// Comments are served up to some threshold; further ones are loaded by subsequent requests.
	// Those placeholders have kind "more", and "count" says how many more (sub-)comments exist
	// at that nesting level: 0 for a continuation of a thread too deep to count.
	let more_count = data["count"].as_i64().unwrap_or_default();

	let awards: Awards = Awards::parse(&data["all_awardings"]);

	let parent_kind_and_id = val(comment, "parent_id");
	let parent_info = parent_kind_and_id.split('_').collect::<Vec<&str>>();

	let highlighted = id == ctx.highlighted_comment;

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
	let is_filtered = ctx.filters.contains(&["u_", author.name.as_str()].concat());

	// Many subreddits have a default comment posted about the sub's rules etc.
	// Many Redlib users do not wish to see this kind of comment by default.
	// Reddit does not tell us which users are "bots", so a good heuristic is to
	// collapse stickied moderator comments.
	let is_moderator_comment = data["distinguished"].as_str().unwrap_or_default() == "moderator";
	let is_stickied = data["stickied"].as_bool().unwrap_or_default();
	let collapsed = (is_moderator_comment && is_stickied) || is_filtered || data["collapsed"] == true;
	let more_href = more_href(&kind, &id, parent_info[1], ctx);

	Comment {
		id,
		kind,
		parent_id: parent_info[1].to_string(),
		parent_kind: parent_info[0].to_string(),
		post_link: post_link.to_string(),
		post_author: ctx.post_author.to_string(),
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
		more_href,
		prefs: Preferences::new(ctx.req),
	}
}

/// A "more" placeholder's link. From GraphQL its id is the base64 cursor (`gql_comments`), which
/// `thread::fetch` continues from; without one, the parent comment's own page.
fn more_href(kind: &str, id: &str, parent_id: &str, ctx: &CommentContext) -> String {
	match (kind, id) {
		("more", "") => format!("{}{parent_id}", ctx.post_link),
		("more", cursor) => format!("{}{parent_id}/?sort={}&cursor={cursor}", ctx.post_link, ctx.sort),
		_ => String::new(),
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use serde_json::json;

	#[test]
	fn more_placeholders_link_to_their_cursor_in_the_page_sort() {
		let req = Request::builder().uri("/r/rust/comments/p/t/").body(Body::empty()).unwrap();
		let filters = HashSet::new();
		let ctx = CommentContext {
			post_link: "/r/rust/comments/p/t/",
			post_author: "op",
			highlighted_comment: "",
			filters: &filters,
			sort: "new",
			req: &req,
		};
		let listing = json!({"data": {"children": [{"kind": "t1", "data": {
			"id": "a", "author": "x", "body": "hi", "body_html": "<p>hi</p>", "parent_id": "t3_p",
			"replies": {"data": {"children": [
				{"kind": "more", "data": {"id": "Y3Vyc29y", "count": 4, "parent_id": "t1_a"}},
				{"kind": "more", "data": {"id": "", "count": 2, "parent_id": "t1_a"}},
			]}}
		}}]}});
		let comments = parse_comments(&listing, &ctx);
		assert_eq!(comments[0].more_href, "");
		assert_eq!(comments[0].replies[0].more_href, "/r/rust/comments/p/t/a/?sort=new&cursor=Y3Vyc29y");
		assert_eq!(comments[0].replies[0].more_count, 4);
		assert_eq!(comments[0].replies[1].more_href, "/r/rust/comments/p/t/a");
		assert_eq!(query_comments(&listing, "HI", &ctx).len(), 1);
	}
}
