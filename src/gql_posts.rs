//! GraphQL posts (the `SubredditPost`/`ProfilePost` nodes every feed, search and PostsByIds
//! answer with) converted to the JSON API's `t3` things and Listings, so `model::parse_post`,
//! `Post::fetch` and `media::Media::parse` read them unchanged, as `gql_comments` does for
//! comments. Pure. Fields GraphQL has no equivalent for are left out, which the readers take as
//! the JSON API's default: `poll_data` (no poll), `num_duplicates` (0), `pinned` (false).
//! Used by `gql_plan`.

use crate::gql_fields::{after_param, awards, content_html, edited, flair, lowercase, timestamp};
use serde_json::{json, Map, Value};

/// v.redd.it's mp4 renditions, by height; the fallback is the largest one the video has.
const RENDITIONS: [i64; 7] = [1080, 720, 480, 360, 270, 240, 220];
/// The JSON API's image preview sizes, smallest first.
const STILL_SIZES: [&str; 6] = ["small", "medium", "large", "xlarge", "xxlarge", "xxxlarge"];

/// `{"kind":"Listing","data":{"children":…,"after":…}}`, `after` our `g_` form of `cursor`.
pub(crate) fn listing(children: Vec<Value>, cursor: Option<&str>) -> Value {
	json!({ "kind": "Listing", "data": { "children": children, "after": cursor.map(after_param) } })
}

/// A feed connection's nodes and its next cursor (None on the last page).
pub(crate) fn connection(conn: &Value) -> (Vec<&Value>, Option<&str>) {
	let nodes = conn["edges"].as_array().into_iter().flatten().map(|edge| &edge["node"]).collect();
	let page = &conn["pageInfo"];
	let cursor = page["endCursor"].as_str().filter(|c| !c.is_empty() && page["hasNextPage"] != false);
	(nodes, cursor)
}

/// Whether `node` is a post (feeds also carry ads and other cells).
pub(crate) fn is_post(node: &Value) -> bool {
	node["id"].as_str().is_some_and(|id| id.starts_with("t3_")) && node["__typename"] != "AdPost"
}

/// The `t3` thing for a post node.
pub(crate) fn post(node: &Value) -> Value {
	json!({ "kind": "t3", "data": post_data(node, true) })
}

fn post_data(node: &Value, with_crosspost: bool) -> Value {
	let mut data = Map::new();
	identity(node, &mut data);
	body(node, &mut data);
	stats(node, &mut data);
	flairs(node, &mut data);
	media(node, &mut data);
	let root = &node["crosspostRoot"]["post"];
	if with_crosspost && root.is_object() {
		data.insert("crosspost_parent".into(), root["id"].clone());
		data.insert("crosspost_parent_list".into(), json!([post_data(root, false)]));
	}
	Value::Object(data)
}

/// Ids, author, place and links.
fn identity(node: &Value, data: &mut Map<String, Value>) {
	let fullname = node["id"].as_str().unwrap_or_default();
	// A profile post lives in the user's `u_<name>` subreddit, as the JSON API names it.
	let subreddit = node["subreddit"]["name"].as_str().or_else(|| node["profile"]["name"].as_str()).unwrap_or_default();
	let is_self = node["isSelfPost"] == true;
	let url = node["url"].as_str().unwrap_or_default();
	let fields = json!({
		"id": fullname.strip_prefix("t3_").unwrap_or(fullname),
		"name": fullname,
		"title": node["title"],
		"author": node["authorInfo"]["name"].as_str().unwrap_or("[deleted]"),
		"subreddit": subreddit,
		"subreddit_name_prefixed": node["subreddit"]["prefixedName"],
		"permalink": node["permalink"],
		"url": url,
		"url_overridden_by_dest": (!is_self && !url.is_empty()).then_some(url),
		"domain": node["domain"],
		"is_self": is_self,
		"is_reddit_media_domain": matches!(node["domain"].as_str(), Some("i.redd.it" | "v.redd.it")),
		"websocket_url": node["liveCommentsWebsocket"],
	});
	extend(data, fields);
}

fn body(node: &Value, data: &mut Map<String, Value>) {
	let content = &node["content"];
	let markdown = content["markdown"].as_str().unwrap_or_default();
	let html = (!markdown.is_empty()).then(|| format!("<div class=\"md\">{}</div>", content_html(content)));
	extend(data, json!({ "selftext": markdown, "selftext_html": html }));
}

fn stats(node: &Value, data: &mut Map<String, Value>) {
	let fields = json!({
		"score": node["score"].as_i64().unwrap_or_default(),
		"hide_score": node["isScoreHidden"] == true,
		"upvote_ratio": node["upvoteRatio"],
		"num_comments": node["commentCount"].as_i64().unwrap_or_default(),
		"created_utc": timestamp(&node["createdAt"]).unwrap_or_default(),
		"edited": edited(&node["editedAt"]),
		"over_18": node["isNsfw"] == true,
		"spoiler": node["isSpoiler"] == true,
		"stickied": node["isStickied"] == true,
		"locked": node["isLocked"] == true,
		"distinguished": lowercase(&node["distinguishedAs"]),
		"removed_by_category": lowercase(&node["removedByCategory"]),
		// `BLANK` is Reddit's "no suggestion"
		"suggested_sort": lowercase(&node["suggestedCommentSort"]).as_str().filter(|sort| *sort != "blank"),
		"all_awardings": awards(&node["awardings"]),
	});
	extend(data, fields);
}

fn flairs(node: &Value, data: &mut Map<String, Value>) {
	for (prefix, flair_node) in [("author", &node["authorFlair"]), ("link", &node["flair"])] {
		let (kind, richtext) = flair(flair_node);
		extend(
			data,
			json!({
				format!("{prefix}_flair_type"): kind,
				format!("{prefix}_flair_richtext"): richtext,
				format!("{prefix}_flair_text"): flair_node["text"],
				format!("{prefix}_flair_background_color"): flair_node["template"]["backgroundColor"].as_str().unwrap_or_default(),
				format!("{prefix}_flair_text_color"): lowercase(&flair_node["textColor"]),
			}),
		);
	}
}

/// Thumbnail, preview, video and gallery, in the places `media::Media::parse` looks.
fn media(node: &Value, data: &mut Map<String, Value>) {
	let media = &node["media"];
	let thumbnail = &node["thumbnail"];
	extend(
		data,
		json!({
			"post_hint": post_hint(node),
			"thumbnail": thumbnail["url"].as_str().unwrap_or(if node["isSelfPost"] == true { "self" } else { "default" }),
			"thumbnail_width": thumbnail["dimensions"]["width"],
			"thumbnail_height": thumbnail["dimensions"]["height"],
		}),
	);
	let mut preview = preview(media);
	if let Some(video) = reddit_video(&media["streaming"]) {
		// Reddit-hosted video is `secure_media`; an embed Reddit transcoded (RedGIFs) is a preview.
		if media["typeHint"] == "VIDEO" {
			data.insert("secure_media".into(), json!({ "reddit_video": video }));
		} else if let Some(preview) = preview.as_mut() {
			preview["reddit_video_preview"] = video;
		}
	}
	if let Some(preview) = preview {
		data.insert("preview".into(), preview);
	}
	if let Some(items) = node["gallery"]["items"].as_array() {
		extend(data, gallery(items));
	}
}

/// The JSON API's `post_hint` (`IMAGE` → `image`, `HOSTED_VIDEO` → `hosted:video`).
fn post_hint(node: &Value) -> Value {
	node["postHint"].as_str().map_or(Value::Null, |hint| hint.to_lowercase().replacen('_', ":", 1).into())
}

/// `preview` with `images[0]`: the still's source and smaller sizes, and an animated image's mp4.
fn preview(media: &Value) -> Option<Value> {
	let still = &media["still"];
	let source = image(&still["source"])?;
	let resolutions: Vec<Value> = STILL_SIZES.iter().filter_map(|size| image(&still[*size])).collect();
	let mut first = json!({ "source": source, "resolutions": resolutions, "variants": {} });
	if let Some(mp4) = image(&media["animated"]["mp4_source"]) {
		first["variants"]["mp4"] = json!({ "source": mp4 });
	}
	Some(json!({ "images": [first], "enabled": true }))
}

/// A GraphQL `MediaSource` (`url`, `dimensions`) as the JSON API's `{url, width, height}`.
fn image(source: &Value) -> Option<Value> {
	let url = source["url"].as_str()?;
	Some(json!({ "url": url, "width": source["dimensions"]["width"], "height": source["dimensions"]["height"] }))
}

/// `reddit_video` from `media.streaming`. GraphQL has no mp4 `fallback_url`, so it is built from
/// the video's id and container (the `CMAF_96`/`DASH_96` scrubber names both) and the largest
/// rendition its size has; `hls_url` is exact.
fn reddit_video(streaming: &Value) -> Option<Value> {
	let hls = streaming["hlsUrl"].as_str()?;
	let (width, height) = (
		streaming["dimensions"]["width"].as_i64().unwrap_or_default(),
		streaming["dimensions"]["height"].as_i64().unwrap_or_default(),
	);
	let (id, container) = video_source(streaming["scrubberMediaUrl"].as_str().unwrap_or(hls))?;
	let short_side = width.min(height);
	let rendition = RENDITIONS.iter().find(|r| **r <= short_side).copied().unwrap_or(RENDITIONS[RENDITIONS.len() - 1]);
	Some(json!({
		"fallback_url": format!("https://v.redd.it/{id}/{container}_{rendition}.mp4?source=fallback"),
		"hls_url": hls,
		"dash_url": streaming["dashUrl"],
		"width": width,
		"height": height,
		"duration": streaming["duration"],
		"is_gif": streaming["isGif"] == true,
	}))
}

/// The id and container of a v.redd.it URL (`https://v.redd.it/<id>/CMAF_96.mp4`). A playlist
/// URL names no container; DASH is the older, still-served one.
fn video_source(url: &str) -> Option<(&str, &str)> {
	let path = url.strip_prefix("https://v.redd.it/")?;
	let (id, file) = path.split_once('/')?;
	let container = if file.starts_with("CMAF_") { "CMAF" } else { "DASH" };
	(!id.is_empty()).then_some((id, container))
}

/// `is_gallery`, `gallery_data` and `media_metadata` from `gallery.items`.
fn gallery(items: &[Value]) -> Value {
	let mut metadata = Map::new();
	let mut entries = Vec::new();
	for item in items {
		let media = &item["media"];
		let Some(id) = media["id"].as_str() else { continue };
		let mimetype = media["mimetype"].as_str().unwrap_or("image/jpeg");
		let mut source = json!({ "u": media["url"], "x": media["width"], "y": media["height"] });
		if mimetype == "image/gif" {
			source["gif"] = media["url"].clone();
		}
		metadata.insert(id.to_string(), json!({ "status": "valid", "e": "Image", "m": mimetype, "s": source }));
		entries.push(json!({ "media_id": id, "id": item["id"], "caption": item["caption"], "outbound_url": item["outboundUrl"] }));
	}
	json!({ "is_gallery": true, "gallery_data": { "items": entries }, "media_metadata": metadata })
}

fn extend(data: &mut Map<String, Value>, fields: Value) {
	if let Value::Object(fields) = fields {
		data.extend(fields);
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::media::Media;
	use crate::model::parse_post;

	fn base(extra: Value) -> Value {
		let mut node = json!({
			"__typename": "SubredditPost", "id": "t3_abc", "title": "A title", "permalink": "/r/sub/comments/abc/a_title/",
			"authorInfo": {"name": "alice"}, "subreddit": {"name": "sub", "prefixedName": "r/sub"},
			"createdAt": "2026-10-20T01:20:04.977000+0000", "score": 42, "commentCount": 7, "upvoteRatio": 0.93,
			"isSelfPost": false, "isNsfw": false, "isSpoiler": true, "isStickied": false, "isLocked": true,
			"domain": "example.com", "url": "https://example.com/x",
		});
		extend(node.as_object_mut().unwrap(), extra);
		node
	}

	fn source(url: &str, width: i64, height: i64) -> Value {
		json!({ "url": url, "dimensions": { "width": width, "height": height } })
	}

	#[tokio::test]
	async fn a_self_post_keeps_its_text_and_metadata() {
		let node = base(json!({
			"isSelfPost": true, "domain": "self.sub", "url": "https://www.reddit.com/r/sub/comments/abc/a_title/",
			"content": {"markdown": "Hello", "richtext": r#"{"document":[{"e":"par","c":[{"e":"text","t":"Hello"}]}]}"#},
			"distinguishedAs": "MODERATOR", "editedAt": "2026-10-20T01:21:04+0000", "suggestedCommentSort": "QA",
			"flair": {"type": "text", "text": "News", "textColor": "DARK", "template": {"backgroundColor": "#ff0"}},
		}));
		let thing = post(&node);
		let data = &thing["data"];
		assert_eq!((data["id"].as_str(), data["name"].as_str()), (Some("abc"), Some("t3_abc")));
		assert_eq!(data["selftext_html"], "<div class=\"md\"><p>Hello</p></div>");
		assert!(data["url_overridden_by_dest"].is_null());
		assert_eq!(data["thumbnail"], "self");
		assert_eq!((data["suggested_sort"].as_str(), data["distinguished"].as_str()), (Some("qa"), Some("moderator")));
		let post = parse_post(&thing).await;
		assert_eq!((post.post_type.as_str(), post.title.as_str(), post.community.as_str()), ("self", "A title", "sub"));
		assert_eq!((post.author.name.as_str(), post.score.0.as_str(), post.comments.0.as_str()), ("alice", "42", "7"));
		assert_eq!((post.upvote_ratio, post.created_ts, post.flags.spoiler), (93, 1792459204, true));
		assert_eq!(
			(post.flair.text.as_str(), post.flair.background_color.as_str(), post.flair.foreground_color.as_str()),
			("News", "#ff0", "black")
		);
	}

	#[tokio::test]
	async fn an_image_post_is_an_image_and_an_animated_one_a_gif() {
		let still = json!({ "source": source("https://preview.redd.it/i.jpeg?s=1", 2160, 3240), "small": source("https://preview.redd.it/i.jpeg?width=108", 108, 162) });
		let image = base(json!({ "postHint": "IMAGE", "domain": "i.redd.it", "url": "https://i.redd.it/i.jpeg", "media": {"typeHint": "IMAGE", "still": still} }));
		let (kind, media, _) = Media::parse(&post(&image)["data"]).await;
		assert_eq!((kind.as_str(), media.url.as_str(), media.width, media.height), ("image", "/img/i.jpeg", 2160, 3240));
		assert_eq!(post(&image)["data"]["preview"]["images"][0]["resolutions"][0]["width"], 108);

		let mut gif = image.clone();
		gif["media"]["animated"] = json!({ "mp4_source": source("https://preview.redd.it/g.gif?format=mp4&s=2", 720, 720) });
		let (kind, media, _) = Media::parse(&post(&gif)["data"]).await;
		assert_eq!((kind.as_str(), media.url.as_str()), ("gif", "/preview/pre/g.gif?format=mp4&s=2"));
	}

	fn streaming(scrubber: &str) -> Value {
		json!({
			"hlsUrl": "https://v.redd.it/vid1/HLSPlaylist.m3u8?a=1", "dashUrl": null, "isGif": false, "duration": 12,
			"dimensions": { "width": 480, "height": 658 }, "scrubberMediaUrl": scrubber,
		})
	}

	#[tokio::test]
	async fn a_hosted_video_gets_an_mp4_fallback_in_its_container() {
		let still = json!({ "source": source("https://external-preview.redd.it/p.png?s=3", 480, 658) });
		let media = json!({ "typeHint": "VIDEO", "still": still, "streaming": streaming("https://v.redd.it/vid1/CMAF_96.mp4") });
		let video = base(json!({ "postHint": "HOSTED_VIDEO", "domain": "v.redd.it", "url": "https://v.redd.it/vid1", "media": media }));
		let data = &post(&video)["data"];
		assert_eq!(data["post_hint"], "hosted:video");
		assert_eq!(data["secure_media"]["reddit_video"]["fallback_url"], "https://v.redd.it/vid1/CMAF_480.mp4?source=fallback");
		let (kind, media, _) = Media::parse(data).await;
		assert_eq!((kind.as_str(), media.url.as_str()), ("video", "/vid/vid1/cmaf/480.mp4"));
		assert_eq!(media.alt_url, "/hls/vid1/HLSPlaylist.m3u8?a=1");
		assert_eq!(media.poster, "/preview/external-pre/p.png?s=3");

		// An embed Reddit transcoded plays from its preview, in DASH when the scrubber says nothing.
		let mut embed = video.clone();
		embed["media"]["typeHint"] = "EMBED".into();
		embed["media"]["streaming"]["scrubberMediaUrl"] = Value::Null;
		let data = &post(&embed)["data"];
		assert!(data["secure_media"].is_null());
		assert_eq!(
			data["preview"]["reddit_video_preview"]["fallback_url"],
			"https://v.redd.it/vid1/DASH_480.mp4?source=fallback"
		);
		assert!(reddit_video(&json!({ "hlsUrl": "https://elsewhere/x.m3u8" })).is_none());
	}

	#[tokio::test]
	async fn a_gallery_lists_its_items() {
		let item = |id: &str, mimetype: &str| {
			json!({ "id": format!("i{id}"), "caption": "cap", "outboundUrl": null,
				"media": { "id": id, "url": format!("https://i.redd.it/{id}.jpg"), "width": 800, "height": 600, "mimetype": mimetype } })
		};
		let node = base(
			json!({ "domain": "reddit.com", "url": "https://www.reddit.com/gallery/abc", "gallery": { "items": [item("m1", "image/jpeg"), item("m2", "image/gif"), {"media": null}] } }),
		);
		let data = &post(&node)["data"];
		assert_eq!(data["media_metadata"]["m2"]["s"]["gif"], "https://i.redd.it/m2.jpg");
		let (kind, _, gallery) = Media::parse(data).await;
		assert_eq!((kind.as_str(), gallery.len()), ("gallery", 2));
		assert_eq!((gallery[0].url.as_str(), gallery[0].width, gallery[0].caption.as_str()), ("/img/m1.jpg", 800, "cap"));
	}

	#[tokio::test]
	async fn a_crosspost_carries_its_root() {
		let root = base(json!({ "id": "t3_root", "postHint": "HOSTED_VIDEO", "media": { "typeHint": "VIDEO", "streaming": streaming("https://v.redd.it/vid1/DASH_96.mp4") } }));
		let node = base(json!({ "crosspostRoot": { "post": root }, "domain": "reddit.com" }));
		let data = &post(&node)["data"];
		assert_eq!(data["crosspost_parent"], "t3_root");
		assert_eq!(data["crosspost_parent_list"][0]["id"], "root");
		let (kind, media, _) = Media::parse(data).await;
		assert_eq!((kind.as_str(), media.url.as_str()), ("video", "/vid/vid1/dash/480.mp4"));
	}

	#[test]
	fn profile_posts_live_in_their_user_subreddit_and_deleted_authors_read_deleted() {
		let node = json!({ "__typename": "ProfilePost", "id": "t3_p", "profile": {"name": "u_spez"}, "authorInfo": null });
		let data = &post(&node)["data"];
		assert_eq!((data["subreddit"].as_str(), data["author"].as_str()), (Some("u_spez"), Some("[deleted]")));
		assert_eq!(data["thumbnail"], "default");
	}

	#[test]
	fn connections_page_and_skip_non_posts() {
		let conn = json!({ "edges": [{"node": {"id": "t3_a"}}, {"node": {"id": "t3_b", "__typename": "AdPost"}}], "pageInfo": {"endCursor": "c1", "hasNextPage": true} });
		let (nodes, cursor) = connection(&conn);
		assert_eq!((nodes.iter().filter(|n| is_post(n)).count(), cursor), (1, Some("c1")));
		let last = json!({ "edges": [], "pageInfo": {"endCursor": "c2", "hasNextPage": false} });
		assert_eq!(connection(&last).1, None);
		assert_eq!(listing(vec![json!(1)], Some("c1"))["data"]["after"], after_param("c1"));
		assert!(listing(Vec::new(), None)["data"]["after"].is_null());
	}
}
