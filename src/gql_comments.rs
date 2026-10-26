//! Thread comments from Reddit's Android GraphQL `PostComments` operation, converted to the JSON
//! API's comments Listing so `comments::parse_comments` renders them unchanged. Since 2026-10-23
//! Reddit 403s the thread JSON routes for app-only tokens; this operation still answers them.
//! Pure: builds the request body and converts the response, with no I/O (`thread::fetch` sends it
//! through `client::gql`).
//!
//! Ported from upstream redlib PR #603 (fxmfxmfx, unmerged), whose converter and RTJSON renderer
//! (here `rtjson.rs`) are adapted from polak14's implementation (AGPL-3.0-only):
//! https://github.com/polak14/redlib/commit/a63460b4ac29c27401e3e2aaab34b68dca02991e

use crate::rtjson::render;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use chrono::DateTime;
use serde_json::{json, Value};

const OPERATION: &str = "PostComments";
/// The Android app's persisted-query id for `PostComments`; gql-fed rejects raw query text, so this
/// hash is the whole query. When Reddit retires it, every thread renders post-only and
/// `thread::fetch` logs a "PersistedQueryNotFound"-style error: update this constant from
/// https://github.com/Amqx/reddit-gql/blob/main/src/operations.ts.
const POST_COMMENTS_HASH: &str = "314f29c2494fd78c7844ef2c6b09acb4bef5b37ab50b4ddc01691d6d5c8433f8";
const COMMENT_COUNT: u32 = 200;
const MAX_DEPTH: u32 = 10;
/// Longest base64 cursor accepted from a URL; Reddit's own are far shorter.
const MAX_CURSOR_LEN: usize = 8192;

/// JSON API sort names and their GraphQL `CommentSort` values. `best` is an alias of `confidence`.
const SORTS: [(&str, &str); 6] = [
	("confidence", "CONFIDENCE"),
	("top", "TOP"),
	("new", "NEW"),
	("controversial", "CONTROVERSIAL"),
	("old", "OLD"),
	("qa", "QA"),
];

/// One page of a thread's comments. Built by `thread::fetch`.
pub(crate) struct CommentsRequest {
	pub post_id: String,
	/// The linked comment of `/r/<sub>/comments/<id>/<title>/<comment_id>/`.
	pub comment_id: Option<String>,
	/// A JSON API sort name (`SORTS`, or `best`).
	pub sort: String,
	/// The base64 cursor of a "more" link (`encode_cursor`), as it appears in our URLs.
	pub cursor: Option<String>,
	/// `?context=N`: how many ancestors of `comment_id` to keep.
	pub context: usize,
}

/// Whether `sort` is one this operation serves. `thread::fetch` uses it to vet a post's `suggested_sort`.
pub(crate) fn is_supported_sort(sort: &str) -> bool {
	sort_type(sort).is_some()
}

fn sort_type(sort: &str) -> Option<&'static str> {
	let sort = if sort == "best" { "confidence" } else { sort };
	SORTS.iter().find(|(name, _)| *name == sort).map(|(_, gql)| *gql)
}

fn sort_name(gql: &str) -> Option<&'static str> {
	SORTS.iter().find(|(_, value)| *value == gql).map(|(name, _)| *name)
}

/// The POST body for gql-fed. Errs on an unsupported sort or a cursor that is not ours.
pub(crate) fn request_body(req: &CommentsRequest) -> Result<Value, String> {
	let sort = sort_type(&req.sort).ok_or_else(|| format!("unsupported comment sort {:?}", req.sort))?;
	let mut variables = json!({
		"id": format!("t3_{}", req.post_id),
		"sortType": sort,
		"count": COMMENT_COUNT,
		"maxDepth": MAX_DEPTH,
		"includeConsistencyToken": false,
		"includePremiumAvatarTreatment": false,
	});
	match (&req.cursor, &req.comment_id) {
		(Some(cursor), _) => variables["after"] = decode_cursor(cursor)?.into(),
		// Never alongside a cursor: the cursor already names its parent, and Reddit answers the
		// pair with DEPENDENCY_FAILURE. With context, Reddit also returns the comment's ancestors.
		(None, Some(comment_id)) => {
			variables["focusedCommentContext"] = json!({ "commentId": format!("t1_{comment_id}"), "isFocusedThreadOnly": req.context == 0 });
		}
		(None, None) => {}
	}
	Ok(json!({
		"operationName": OPERATION,
		"variables": variables,
		"extensions": { "persistedQuery": { "version": 1, "sha256Hash": POST_COMMENTS_HASH } },
	}))
}

/// Reddit's cursors carry `:`, `+` and `/`; URL-safe base64 keeps them intact in a query string.
fn encode_cursor(cursor: &str) -> String {
	URL_SAFE_NO_PAD.encode(cursor)
}

fn decode_cursor(cursor: &str) -> Result<String, String> {
	if cursor.len() > MAX_CURSOR_LEN {
		return Err("invalid comments cursor (too long)".to_string());
	}
	URL_SAFE_NO_PAD
		.decode(cursor)
		.ok()
		.and_then(|bytes| String::from_utf8(bytes).ok())
		.ok_or_else(|| "invalid comments cursor".to_string())
}

/// The JSON API comments Listing for a `PostComments` response: `children` nested by depth,
/// `after` the base64 cursor of the next top-level page (or null), `sort` the applied sort.
/// A `?context` link (comment_id, context > 0, no cursor) keeps only the linked comment's branch.
pub(crate) fn listing(response: &Value, req: &CommentsRequest) -> Result<Value, String> {
	let forest = &response["data"]["postInfoById"]["commentForest"];
	let trees = forest["trees"].as_array().ok_or("Reddit returned no comment forest")?;
	let after = trees
		.iter()
		.find(|tree| is_next_page(tree))
		.and_then(|tree| tree["more"]["cursor"].as_str())
		.map(encode_cursor);
	let mut children = nest(trees.iter().filter(|tree| !is_next_page(tree)).filter_map(|tree| item(tree, &req.post_id)).collect());
	if let Some(comment_id) = req.comment_id.as_deref().filter(|_| req.context > 0 && req.cursor.is_none()) {
		children = vec![focus(&children, comment_id, req.context)?];
	}
	let sort = forest["appliedSort"]
		.as_str()
		.and_then(sort_name)
		.or_else(|| sort_type(&req.sort).and_then(sort_name))
		.unwrap_or("confidence");
	Ok(json!({ "kind": "Listing", "data": { "children": children, "after": after, "sort": sort } }))
}

/// The forest's top-level "more" is the next page of the thread, not a reply placeholder.
fn is_next_page(tree: &Value) -> bool {
	tree["depth"] == 0 && tree["parentId"].is_null() && !tree["more"].is_null()
}

fn children_listing(children: Vec<Value>) -> Value {
	json!({ "kind": "Listing", "data": { "children": children } })
}

/// The linked comment's branch, trimmed to `context` ancestors above it.
fn focus(children: &[Value], comment_id: &str, context: usize) -> Result<Value, String> {
	let (mut depth, mut focused) = focused_branch(children, comment_id).ok_or_else(|| format!("focused comment {comment_id} is not in the response"))?;
	while depth > context {
		focused = focused["data"]["replies"]["data"]["children"][0].take();
		depth -= 1;
	}
	Ok(focused)
}

/// The ancestor chain of comment `id` without unrelated siblings, with its depth in that chain.
fn focused_branch(comments: &[Value], id: &str) -> Option<(usize, Value)> {
	for comment in comments {
		if comment["data"]["id"] == id {
			return Some((0, comment.clone()));
		}
		let Some(replies) = comment["data"]["replies"]["data"]["children"].as_array() else {
			continue;
		};
		if let Some((depth, child)) = focused_branch(replies, id) {
			let mut parent = comment.clone();
			parent["data"]["replies"] = children_listing(vec![child]);
			return Some((depth + 1, parent));
		}
	}
	None
}

/// Builds the reply tree from items in depth-first order. Goes by depth rather than parent ids,
/// as deleted comments have none.
fn nest(items: Vec<(u64, Value)>) -> Vec<Value> {
	let mut top = Vec::new();
	let mut open: Vec<(u64, Value)> = Vec::new();
	for (depth, item) in items {
		while open.last().is_some_and(|(open_depth, _)| *open_depth >= depth) {
			close(&mut open, &mut top);
		}
		open.push((depth, item));
	}
	while !open.is_empty() {
		close(&mut open, &mut top);
	}
	top
}

/// Attaches the innermost open item to its parent, or to the top level.
fn close(open: &mut Vec<(u64, Value)>, top: &mut Vec<Value>) {
	let Some((_, item)) = open.pop() else { return };
	let Some((_, parent)) = open.last_mut() else {
		top.push(item);
		return;
	};
	let replies = &mut parent["data"]["replies"];
	if !replies.is_object() {
		*replies = children_listing(Vec::new());
	}
	if let Some(children) = replies["data"]["children"].as_array_mut() {
		children.push(item);
	}
}

fn valid_id(id: &str) -> bool {
	!id.is_empty() && id.bytes().all(|b| b.is_ascii_alphanumeric())
}

/// One entry of the comment forest as a JSON API item (`t1` or `more`), with its depth.
fn item(tree: &Value, post_id: &str) -> Option<(u64, Value)> {
	let depth = tree["depth"].as_u64()?;
	let parent = tree["parentId"]
		.as_str()
		.filter(|p| p.starts_with("t1_"))
		.map_or_else(|| format!("t3_{post_id}"), str::to_string);
	if tree["more"].is_null() {
		comment_item(&tree["node"], &parent).map(|comment| (depth, comment))
	} else {
		Some((depth, more_item(&tree["more"], &parent)))
	}
}

/// A "more" placeholder. Its `id` is the base64 cursor, which `comments::build_comment` turns
/// into the link; a `deep_comment:` cursor has count 0 (a continuation, not a count).
fn more_item(more: &Value, parent: &str) -> Value {
	let cursor = more["cursor"].as_str().map(encode_cursor).unwrap_or_default();
	json!({ "kind": "more", "data": { "id": cursor, "count": more["count"].as_i64().unwrap_or_default(), "parent_id": parent } })
}

fn comment_item(node: &Value, parent: &str) -> Option<Value> {
	let fullname = node["id"].as_str().unwrap_or_default();
	let deleted = node["__typename"] == "DeletedComment";
	if !deleted && !fullname.strip_prefix("t1_").is_some_and(valid_id) {
		return None;
	}
	let (author, body, body_html) = content(node, deleted);
	let author_flair = &node["authorFlair"];
	let (flair_type, flair_richtext) = flair(author_flair);
	Some(json!({
		"kind": "t1",
		"data": {
			"id": fullname.strip_prefix("t1_").unwrap_or(fullname),
			"name": fullname,
			"author": author,
			"body": body,
			"body_html": format!("<div class=\"md\">{body_html}</div>"),
			"created_utc": timestamp(&node["createdAt"]).unwrap_or_default(),
			"edited": timestamp(&node["editedAt"]).map_or(Value::Bool(false), Value::from),
			"score": node["score"].as_i64().unwrap_or_default(),
			"score_hidden": node["isScoreHidden"] == true,
			"stickied": node["isStickied"] == true,
			"distinguished": node["distinguishedAs"].as_str().map(str::to_lowercase),
			"author_flair_type": flair_type,
			"author_flair_richtext": flair_richtext,
			"author_flair_text": author_flair["text"],
			"author_flair_background_color": author_flair["template"]["backgroundColor"],
			"author_flair_text_color": author_flair["textColor"].as_str().map(str::to_lowercase),
			"all_awardings": awards(&node["awardings"]),
			"parent_id": parent,
			"replies": "",
		}
	}))
}

/// Author, markdown body and body HTML, in the JSON API's spelling of deleted and removed
/// comments, which `comments::build_comment` recognises (removed ones link to the archive).
fn content(node: &Value, deleted: bool) -> (String, String, String) {
	let author = node["authorInfo"]["name"].as_str().unwrap_or("[unknown]");
	if deleted {
		return ("[deleted]".into(), "[deleted]".into(), "<p>[deleted]</p>".into());
	}
	if node["isAdminTakedown"] == true {
		return (author.into(), "[ Removed by Reddit ]".into(), String::new());
	}
	if node["isRemoved"] == true {
		return ("[deleted]".into(), "[removed]".into(), String::new());
	}
	let content = &node["content"];
	let markdown = content["markdown"].as_str().unwrap_or_default();
	// `richtext` is a JSON string holding `{"document": [...]}`; `html` arrives empty.
	let richtext: Value = content["richtext"].as_str().and_then(|r| serde_json::from_str(r).ok()).unwrap_or_default();
	let html = if richtext["document"].is_array() {
		render(&richtext["document"], &content["richtextMedia"])
	} else {
		format!("<p>{}</p>", htmlescape::encode_minimal(markdown))
	};
	(author.into(), markdown.into(), html)
}

/// The JSON API's `author_flair_type` and `author_flair_richtext` for a GraphQL `authorFlair`.
fn flair(flair: &Value) -> (&'static str, Value) {
	let richtext: Value = flair["richtext"].as_str().and_then(|r| serde_json::from_str(r).ok()).unwrap_or_default();
	let kind = if richtext.as_array().is_some_and(|r| !r.is_empty()) {
		"richtext"
	} else if flair["text"].as_str().is_some_and(|t| !t.is_empty()) {
		"text"
	} else {
		""
	};
	(kind, richtext)
}

/// `all_awardings` in the shape `model::Awards::parse` reads.
fn awards(awardings: &Value) -> Vec<Value> {
	awardings
		.as_array()
		.into_iter()
		.flatten()
		.map(|a| json!({ "name": a["award"]["name"], "count": a["total"], "resized_icons": [{ "url": a["award"]["static_icon_16"]["url"] }] }))
		.collect()
}

/// `2026-10-20T01:20:04.977000+0000` as Unix seconds.
fn timestamp(value: &Value) -> Option<f64> {
	DateTime::parse_from_str(value.as_str()?, "%Y-%m-%dT%H:%M:%S%.f%z").ok().map(|t| t.timestamp() as f64)
}

#[cfg(test)]
mod tests {
	use super::*;

	fn request(comment_id: Option<&str>, sort: &str, cursor: Option<&str>, context: usize) -> CommentsRequest {
		CommentsRequest {
			post_id: "p".into(),
			comment_id: comment_id.map(str::to_string),
			sort: sort.into(),
			cursor: cursor.map(str::to_string),
			context,
		}
	}

	fn forest(trees: Value) -> Value {
		json!({ "data": { "postInfoById": { "commentForest": { "appliedSort": "TOP", "trees": trees } } } })
	}

	fn comment(id: &str, depth: u64, parent: Option<&str>) -> Value {
		json!({ "depth": depth, "parentId": parent, "node": { "__typename": "Comment", "id": id, "authorInfo": { "name": "a" } } })
	}

	fn replies(item: &Value) -> &Vec<Value> {
		item["data"]["replies"]["data"]["children"].as_array().unwrap()
	}

	#[test]
	fn request_body_maps_sorts_and_uses_the_persisted_query() {
		for (sort, expected) in [
			("confidence", "CONFIDENCE"),
			("best", "CONFIDENCE"),
			("top", "TOP"),
			("new", "NEW"),
			("controversial", "CONTROVERSIAL"),
			("old", "OLD"),
			("qa", "QA"),
		] {
			let body = request_body(&request(None, sort, None, 0)).unwrap();
			assert_eq!(body["variables"]["sortType"], expected, "{sort}");
		}
		let body = request_body(&request(None, "top", None, 0)).unwrap();
		assert_eq!(body["operationName"], "PostComments");
		assert_eq!(body["extensions"]["persistedQuery"]["sha256Hash"], POST_COMMENTS_HASH);
		assert_eq!(body["variables"]["id"], "t3_p");
		assert_eq!(body["variables"]["count"], 200);
		assert_eq!(body["variables"]["maxDepth"], 10);
		assert!(body["variables"]["after"].is_null());
		assert!(body["variables"]["focusedCommentContext"].is_null());
		assert!(request_body(&request(None, "random", None, 0)).is_err());
		assert!(!is_supported_sort("live"));
	}

	#[test]
	fn a_cursor_is_never_combined_with_a_focused_comment() {
		let cursor = encode_cursor("opaque:+/= cursor");
		let vars = &request_body(&request(Some("def"), "new", Some(&cursor), 3)).unwrap()["variables"];
		assert_eq!(vars["after"], "opaque:+/= cursor");
		assert!(vars["focusedCommentContext"].is_null());

		let vars = &request_body(&request(Some("def"), "new", None, 3)).unwrap()["variables"];
		assert_eq!(vars["focusedCommentContext"], json!({"commentId": "t1_def", "isFocusedThreadOnly": false}));
		let vars = &request_body(&request(Some("def"), "new", None, 0)).unwrap()["variables"];
		assert_eq!(vars["focusedCommentContext"]["isFocusedThreadOnly"], true);
	}

	#[test]
	fn foreign_cursors_are_refused() {
		assert!(request_body(&request(None, "top", Some("%FF"), 0)).is_err());
		assert!(request_body(&request(None, "top", Some(&encode_cursor(&"x".repeat(7000))), 0)).is_err());
		// Valid base64 that is not UTF-8
		assert!(request_body(&request(None, "top", Some(&URL_SAFE_NO_PAD.encode([0xff, 0xfe])), 0)).is_err());
	}

	#[test]
	fn listing_needs_a_forest_and_reports_the_applied_sort() {
		assert!(listing(&json!({"data": {"postInfoById": null}}), &request(None, "top", None, 0)).is_err());
		let empty = listing(&forest(json!([])), &request(None, "new", None, 0)).unwrap();
		assert_eq!(empty["kind"], "Listing");
		assert_eq!(empty["data"]["children"], json!([]));
		assert!(empty["data"]["after"].is_null());
		// Reddit's appliedSort wins over the request's
		assert_eq!(empty["data"]["sort"], "top");
		let no_applied = json!({"data": {"postInfoById": {"commentForest": {"trees": []}}}});
		assert_eq!(listing(&no_applied, &request(None, "best", None, 0)).unwrap()["data"]["sort"], "confidence");
	}

	#[test]
	fn items_nest_by_depth_including_deleted_comments() {
		let trees = json!([
			comment("t1_a", 0, None),
			// Deleted comments have no id; their replies still nest by depth
			{ "depth": 1, "parentId": "t1_a", "node": { "__typename": "DeletedComment" } },
			comment("t1_c", 2, Some("t1_x")),
			{ "depth": 1, "parentId": "t1_a", "more": { "count": 5, "cursor": "c1" } },
			comment("t1_d", 0, None),
		]);
		let listing = listing(&forest(trees), &request(None, "top", None, 0)).unwrap();
		let top = listing["data"]["children"].as_array().unwrap();
		assert_eq!(top.len(), 2);
		assert_eq!(top[0]["data"]["parent_id"], "t3_p");
		let a = replies(&top[0]);
		assert_eq!(a.len(), 2);
		assert_eq!(a[0]["data"]["author"], "[deleted]");
		assert_eq!(a[0]["data"]["body"], "[deleted]");
		assert_eq!(replies(&a[0])[0]["data"]["id"], "c");
		assert_eq!(a[1]["kind"], "more");
		assert_eq!(a[1]["data"]["parent_id"], "t1_a");
		assert_eq!(a[1]["data"]["count"], 5);
		assert_eq!(a[1]["data"]["id"], encode_cursor("c1"));
		// No replies is the JSON API's empty string
		assert_eq!(top[1]["data"]["replies"], "");
	}

	#[test]
	fn the_next_page_is_separate_from_reply_placeholders() {
		let trees = json!([
			comment("t1_a", 0, None),
			{ "depth": 1, "parentId": "t1_a", "node": null, "more": { "count": 0, "cursor": "deep_comment:t1_a", "isTooDeepForCount": true } },
			{ "depth": 0, "parentId": null, "node": null, "more": { "count": 30, "cursor": "opaque:+/= cursor" } },
		]);
		let listing = listing(&forest(trees), &request(None, "top", None, 0)).unwrap();
		let top = listing["data"]["children"].as_array().unwrap();
		assert_eq!(top.len(), 1);
		let deep = &replies(&top[0])[0];
		assert_eq!(deep["data"]["count"], 0);
		assert_eq!(decode_cursor(deep["data"]["id"].as_str().unwrap()).unwrap(), "deep_comment:t1_a");
		// The next-page cursor round-trips into the request that follows it
		let after = listing["data"]["after"].as_str().unwrap();
		assert_eq!(request_body(&request(None, "top", Some(after), 0)).unwrap()["variables"]["after"], "opaque:+/= cursor");
	}

	#[test]
	fn context_keeps_the_linked_branch_without_siblings() {
		let trees = json!([
			comment("t1_a", 0, None),
			comment("t1_b", 1, Some("t1_a")),
			comment("t1_c", 2, Some("t1_b")),
			comment("t1_d", 3, Some("t1_c")),
			comment("t1_sibling", 1, Some("t1_a")),
			comment("t1_other", 0, None),
		]);
		let focused = |context| listing(&forest(trees.clone()), &request(Some("c"), "top", None, context)).unwrap();

		let wide = focused(9999);
		let top = wide["data"]["children"].as_array().unwrap();
		assert_eq!(top.len(), 1);
		assert_eq!(top[0]["data"]["id"], "a");
		assert_eq!(replies(&top[0]).len(), 1);
		let b = &replies(&top[0])[0];
		assert_eq!(b["data"]["id"], "b");
		// The linked comment keeps its own replies
		assert_eq!(replies(&replies(b)[0])[0]["data"]["id"], "d");

		// context=1 trims to one ancestor
		assert_eq!(focused(1)["data"]["children"][0]["data"]["id"], "b");

		// Without context, or with a cursor, Reddit's answer is already the right subtree
		assert_eq!(
			listing(&forest(trees.clone()), &request(Some("c"), "top", None, 0)).unwrap()["data"]["children"]
				.as_array()
				.unwrap()
				.len(),
			2
		);
		let cursor = encode_cursor("x");
		assert_eq!(
			listing(&forest(trees.clone()), &request(Some("c"), "top", Some(&cursor), 3)).unwrap()["data"]["children"]
				.as_array()
				.unwrap()
				.len(),
			2
		);
		assert!(listing(&forest(trees), &request(Some("missing"), "top", None, 3)).is_err());
	}

	fn full_comment() -> Value {
		json!({"depth": 0, "node": {
			"__typename": "Comment", "id": "t1_a", "authorInfo": {"name": "alice"},
			"content": {"markdown": "<script>x</script> & text", "html": ""},
			"createdAt": "2026-10-20T17:00:53.706000+0000", "editedAt": "2026-10-20T17:01:53.000000+0000",
			"score": 18, "isStickied": true, "isScoreHidden": true, "distinguishedAs": "MODERATOR",
			"authorFlair": {"text": "flair", "richtext": null, "textColor": "DARK", "template": {"backgroundColor": "#fff"}},
			"awardings": [{"total": 2, "award": {"name": "Bravo", "static_icon_16": {"url": "https://i.redd.it/b.png"}}}]
		}})
	}

	#[test]
	fn comments_keep_their_metadata() {
		let (depth, comment) = item(&full_comment(), "p").unwrap();
		assert_eq!(depth, 0);
		let data = &comment["data"];
		assert_eq!(
			(data["id"].as_str(), data["name"].as_str(), data["author"].as_str()),
			(Some("a"), Some("t1_a"), Some("alice"))
		);
		// No richtext: the markdown, escaped
		assert_eq!(data["body_html"], "<div class=\"md\"><p>&lt;script&gt;x&lt;/script&gt; &amp; text</p></div>");
		assert_eq!((data["created_utc"].as_f64(), data["edited"].as_f64()), (Some(1792515653.0), Some(1792515713.0)));
		assert_eq!(data["score"], 18);
		assert_eq!(data["distinguished"], "moderator");
		assert_eq!((data["stickied"].as_bool(), data["score_hidden"].as_bool()), (Some(true), Some(true)));
	}

	#[test]
	fn comments_keep_flair_and_awards() {
		let data = &item(&full_comment(), "p").unwrap().1["data"];
		assert_eq!(data["author_flair_type"], "text");
		assert_eq!(data["author_flair_text"], "flair");
		assert_eq!(data["author_flair_text_color"], "dark");
		assert_eq!(data["author_flair_background_color"], "#fff");
		assert_eq!(
			data["all_awardings"],
			json!([{"name": "Bravo", "count": 2, "resized_icons": [{"url": "https://i.redd.it/b.png"}]}])
		);
	}

	#[test]
	fn unedited_and_foreign_nodes() {
		let mut unedited = full_comment();
		unedited["node"]["editedAt"] = Value::Null;
		assert_eq!(item(&unedited, "p").unwrap().1["data"]["edited"], false);
		// An id that is not a comment's is dropped
		let mut foreign = full_comment();
		foreign["node"]["id"] = "t3_x".into();
		assert!(item(&foreign, "p").is_none());
	}

	#[test]
	fn deleted_removed_and_taken_down_use_the_json_api_spelling() {
		let tree = comment("t1_a", 0, None);
		let mut removed = tree.clone();
		removed["node"]["isRemoved"] = true.into();
		let data = &item(&removed, "p").unwrap().1["data"];
		assert_eq!((data["author"].as_str(), data["body"].as_str()), (Some("[deleted]"), Some("[removed]")));

		let mut takedown = tree.clone();
		takedown["node"]["isAdminTakedown"] = true.into();
		let data = &item(&takedown, "p").unwrap().1["data"];
		assert_eq!((data["author"].as_str(), data["body"].as_str()), (Some("a"), Some("[ Removed by Reddit ]")));

		let deleted = json!({"depth": 0, "node": {"__typename": "DeletedComment"}});
		let data = &item(&deleted, "p").unwrap().1["data"];
		assert_eq!(data["body_html"], "<div class=\"md\"><p>[deleted]</p></div>");
	}

	#[test]
	fn timestamps_parse_with_and_without_fractions() {
		assert_eq!(timestamp(&json!("2026-10-20T01:20:04.977000+0000")), Some(1792459204.0));
		assert_eq!(timestamp(&json!("2026-10-20T01:20:04+0000")), Some(1792459204.0));
		assert_eq!(timestamp(&json!("yesterday")), None);
		assert_eq!(timestamp(&Value::Null), None);
	}

	#[test]
	fn richtext_bodies_render_through_the_renderer() {
		let tree = json!({"depth": 0, "node": {
			"__typename": "Comment", "id": "t1_a", "authorInfo": {"name": "a"},
			"content": {"markdown": "hi", "html": "", "richtext": r#"{"document":[{"e":"par","c":[{"e":"text","t":"hi"}]}]}"#}
		}});
		assert_eq!(item(&tree, "p").unwrap().1["data"]["body_html"], "<div class=\"md\"><p>hi</p></div>");
	}
}
