//! GraphQL subreddits, wiki pages, redditors and profile comments converted to the JSON API's
//! `t5`, `wikipage`, `t2` and `t1` things, so `subreddit.rs`, `search.rs`, `user.rs` and
//! `Post::fetch` read them unchanged. Pure. Used by `gql_plan`.

use crate::gql_fields::{awards, content_html, edited, flair, lowercase, timestamp};
use serde_json::{json, Value};

/// Why Reddit refuses a subreddit (`UnavailableSubreddit.forbiddenReason`), in the error words
/// the JSON API uses and the pages already handle ("private", "quarantined", ...). None for a
/// subreddit that is not unavailable, or an unknown reason.
pub(crate) fn unavailable_reason(node: &Value) -> Option<&'static str> {
	if node["__typename"] != "UnavailableSubreddit" {
		return None;
	}
	Some(match node["forbiddenReason"].as_str()? {
		"PRIVATE" => "private",
		"QUARANTINED" => "quarantined",
		"GATED" => "gated",
		"BANNED" => "banned",
		_ => return None,
	})
}

/// A `SubredditInfoByName` subreddit as `/r/<sub>/about.json`.
pub(crate) fn subreddit_about(info: &Value) -> Value {
	let description = &info["description"];
	let sidebar = description["markdown"]
		.as_str()
		.filter(|m| !m.is_empty())
		.map(|_| format!("<div class=\"md\">{}</div>", content_html(description)));
	let mut about = community(info);
	let data = &mut about["data"];
	data["description"] = description["markdown"].clone();
	data["description_html"] = sidebar.into();
	data["accounts_active"] = info["communityStats"]["weeklyActiveUsersCount"].as_u64().or_else(|| info["activeCount"].as_u64()).into();
	data["wiki_enabled"] = (info["wiki"]["indexPage"]["status"] == "VALID").into();
	data["quarantine"] = (info["isQuarantined"] == true).into();
	data["banner_background_image"] = info["styles"]["bannerBackgroundImage"].clone();
	data["primary_color"] = info["styles"]["primaryColor"].clone();
	about
}

/// A `SubredditWiki` page as `/r/<sub>/wiki/<page>.json`; `subreddit::wiki` reads `content_html`.
pub(crate) fn wiki_page(page: &Value) -> Value {
	wikipage(Some(format!("<div class=\"md wiki\">{}</div>", content_html(&page["content"]))))
}

/// The answer for a missing wiki page: the wiki's existing pages (`wiki.index.pageTree`), as links
/// under a heading that says so. With none, no `content_html`, which `subreddit::wiki` shows as
/// "Wiki not found".
pub(crate) fn wiki_missing(sub: &str, page: &str, wiki: &Value) -> Value {
	let links: String = wiki["index"]["pageTree"]
		.as_array()
		.into_iter()
		.flatten()
		.filter(|node| node["isPagePresent"] == true)
		.filter_map(|node| node["path"].as_str())
		.map(|path| {
			let path = htmlescape::encode_minimal(path);
			format!("<li><a href=\"/r/{sub}/wiki/{path}\">{path}</a></li>")
		})
		.collect();
	let html = (!links.is_empty()).then(|| format!("<h3>No {} page; this wiki's pages:</h3><ul>{links}</ul>", htmlescape::encode_minimal(page)));
	wikipage(html)
}

fn wikipage(content_html: Option<String>) -> Value {
	json!({ "kind": "wikipage", "data": { "content_html": content_html } })
}

/// A subreddit node (`SubredditInfoByName`, `SearchCommunities`) as the `t5` fields both share.
pub(crate) fn community(node: &Value) -> Value {
	let name = node["name"].as_str().unwrap_or_default();
	json!({
		"kind": "t5",
		"data": {
			"id": node["id"].as_str().and_then(|id| id.strip_prefix("t5_")),
			"name": node["id"],
			"display_name": name,
			"display_name_prefixed": format!("r/{name}"),
			"url": format!("/r/{name}/"),
			"title": node["title"],
			"public_description": node["publicDescriptionText"],
			"community_icon": node["styles"]["icon"],
			"icon_img": node["styles"]["legacyIcon"]["url"],
			"subscribers": node["subscribersCount"].as_f64().map(|count| count as u64),
			"over18": node["isNsfw"] == true,
			"subreddit_type": lowercase(&node["type"]),
			"created_utc": timestamp(&node["createdAt"]),
		}
	})
}

/// A `UserProfileDetails` redditor as `/user/<name>/about.json`.
pub(crate) fn redditor(info: &Value) -> Value {
	let profile = &info["profileInfo"];
	json!({
		"kind": "t2",
		"data": {
			"name": info["name"],
			"id": info["id"].as_str().and_then(|id| id.strip_prefix("t2_")),
			"total_karma": info["karma"]["total"].as_i64().unwrap_or_default(),
			"created": timestamp(&profile["createdAt"]).unwrap_or_default(),
			"icon_img": info["icon"]["url"],
			"subreddit": {
				"title": profile["title"],
				"icon_img": info["icon"]["url"],
				"banner_img": profile["styles"]["profileBanner"],
				"public_description": profile["publicDescriptionText"],
				"over_18": profile["isNsfw"] == true,
			}
		}
	})
}

/// A profile comment as a `t1` of a user listing: `summary` is its `SubmittedComments` node (the
/// post it answers), `full` its `LiveCommentsByIds` node (body, author, permalink).
pub(crate) fn comment(summary: &Value, full: &Value) -> Value {
	let fullname = summary["id"].as_str().unwrap_or_default();
	let permalink = full["permalink"].as_str().unwrap_or_default();
	let author_flair = &full["authorFlair"];
	let (flair_type, flair_richtext) = flair(author_flair);
	json!({
		"kind": "t1",
		"data": {
			"id": fullname.strip_prefix("t1_").unwrap_or(fullname),
			"name": fullname,
			"author": full["authorInfo"]["name"].as_str().unwrap_or("[deleted]"),
			"body": full["content"]["markdown"],
			"body_html": format!("<div class=\"md\">{}</div>", content_html(&full["content"])),
			"link_id": summary["postInfo"]["id"],
			"link_title": summary["postInfo"]["title"],
			"permalink": permalink,
			"subreddit": subreddit_of(permalink),
			"score": full["score"].as_i64().or_else(|| summary["score"].as_i64()).unwrap_or_default(),
			"score_hidden": full["isScoreHidden"] == true,
			"created_utc": timestamp(&summary["createdAt"]).or_else(|| timestamp(&full["createdAt"])).unwrap_or_default(),
			"edited": edited(&full["editedAt"]),
			"stickied": full["isStickied"] == true,
			"distinguished": lowercase(&full["distinguishedAs"]),
			"author_flair_type": flair_type,
			"author_flair_richtext": flair_richtext,
			"author_flair_text": author_flair["text"],
			"all_awardings": awards(&full["awardings"]),
		}
	})
}

/// The subreddit a permalink lives in: `r/<sub>/…` → `<sub>`, a profile's `user/<name>/…` → `u_<name>`.
fn subreddit_of(permalink: &str) -> String {
	let mut segments = permalink.trim_start_matches('/').split('/');
	match (segments.next(), segments.next()) {
		(Some("r"), Some(sub)) => sub.to_string(),
		(Some("user" | "u"), Some(name)) => format!("u_{name}"),
		_ => String::new(),
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn unavailable_subreddits_name_their_reason() {
		let unavailable = |reason: &str| json!({"__typename": "UnavailableSubreddit", "forbiddenReason": reason});
		assert_eq!(unavailable_reason(&unavailable("PRIVATE")), Some("private"));
		assert_eq!(unavailable_reason(&unavailable("QUARANTINED")), Some("quarantined"));
		assert_eq!(unavailable_reason(&unavailable("GATED")), Some("gated"));
		assert_eq!(unavailable_reason(&unavailable("BANNED")), Some("banned"));
		assert_eq!(unavailable_reason(&unavailable("SOMETHING_NEW")), None);
		assert_eq!(unavailable_reason(&json!({"__typename": "Subreddit"})), None);
	}

	#[test]
	fn a_wiki_page_renders_its_richtext() {
		let page = json!({ "status": "VALID", "content": { "richtext": r#"{"document":[{"e":"h","l":1,"c":[{"e":"raw","t":"Rules"}]},{"e":"par","c":[{"e":"img","id":"i1"}]}]}"#, "richtextMedia": [{ "id": "i1", "url": "https://i.redd.it/x.png" }] } });
		assert_eq!(
			wiki_page(&page),
			json!({ "kind": "wikipage", "data": { "content_html": concat!(
				r#"<div class="md wiki"><h1>Rules</h1>"#,
				r#"<figure><a href="/img/x.png"><img src="/img/x.png" loading="lazy"></a></figure></div>"#,
			) } })
		);
	}

	#[test]
	fn a_missing_wiki_page_lists_the_pages_that_exist() {
		let tree = json!({ "index": { "pageTree": [
			{ "depth": 0, "name": "config", "path": "config", "parent": null, "isPagePresent": false },
			{ "depth": 1, "name": "sidebar", "path": "config/sidebar", "parent": "config", "isPagePresent": true },
			{ "depth": 0, "name": "rules", "path": "rules<b>", "parent": null, "isPagePresent": true },
		] } });
		assert_eq!(
			wiki_missing("rust", "index", &tree)["data"]["content_html"],
			concat!(
				"<h3>No index page; this wiki's pages:</h3><ul>",
				r#"<li><a href="/r/rust/wiki/config/sidebar">config/sidebar</a></li>"#,
				r#"<li><a href="/r/rust/wiki/rules&lt;b&gt;">rules&lt;b&gt;</a></li></ul>"#,
			)
		);
		// No page to list: the handler's own "Wiki not found"
		assert!(wiki_missing("rust", "index", &json!({ "index": { "pageTree": [] } }))["data"]["content_html"].is_null());
		assert!(wiki_missing("rust", "index", &Value::Null)["data"]["content_html"].is_null());
	}

	#[test]
	fn subreddit_about_has_the_fields_subreddit_rs_reads() {
		let info = json!({
			"__typename": "Subreddit", "id": "t5_2qh0u", "name": "pics", "title": "Pictures", "publicDescriptionText": "Photos",
			"description": {"markdown": "Rules", "richtext": r#"{"document":[{"e":"par","c":[{"e":"text","t":"Rules"}]}]}"#},
			"subscribersCount": 33573693.0, "activeCount": 0, "communityStats": {"weeklyActiveUsersCount": 3307684},
			"styles": {"icon": "https://styles.redditmedia.com/i.png", "legacyIcon": {"url": "https://b.thumbs.redditmedia.com/l.png"}},
			"isNsfw": false, "wiki": {"indexPage": {"status": "VALID"}}, "type": "PUBLIC", "createdAt": "2008-01-25T00:31:09.512000+0000",
		});
		let data = &subreddit_about(&info)["data"];
		assert_eq!(
			(data["display_name"].as_str(), data["title"].as_str(), data["public_description"].as_str()),
			(Some("pics"), Some("Pictures"), Some("Photos"))
		);
		assert_eq!(data["description_html"], "<div class=\"md\"><p>Rules</p></div>");
		assert_eq!((data["subscribers"].as_u64(), data["accounts_active"].as_u64()), (Some(33573693), Some(3307684)));
		assert_eq!((data["wiki_enabled"].as_bool(), data["over18"].as_bool()), (Some(true), Some(false)));
		assert_eq!(data["community_icon"], "https://styles.redditmedia.com/i.png");
		assert_eq!(
			(data["subreddit_type"].as_str(), data["url"].as_str(), data["id"].as_str()),
			(Some("public"), Some("/r/pics/"), Some("2qh0u"))
		);
		assert!(subreddit_about(&json!({"name": "x"}))["data"]["description_html"].is_null());
	}

	#[test]
	fn redditor_has_the_fields_user_rs_reads() {
		let info = json!({
			"name": "spez", "id": "t2_1w72", "karma": {"total": 941124}, "icon": {"url": "https://styles.redditmedia.com/p.png"},
			"profileInfo": {"createdAt": "2005-06-06T04:00:00.000000+0000", "title": "spez", "publicDescriptionText": "hi", "isNsfw": false, "styles": {"profileBanner": null}},
		});
		let data = &redditor(&info)["data"];
		assert_eq!(
			(data["name"].as_str(), data["total_karma"].as_i64(), data["created"].as_f64()),
			(Some("spez"), Some(941124), Some(1118030400.0))
		);
		assert_eq!(data["subreddit"]["icon_img"], "https://styles.redditmedia.com/p.png");
		assert_eq!(
			(data["subreddit"]["public_description"].as_str(), data["subreddit"]["over_18"].as_bool()),
			(Some("hi"), Some(false))
		);
	}

	#[test]
	fn comments_join_their_summary_and_body() {
		let summary = json!({"id": "t1_c1", "score": 3, "createdAt": "2026-08-05T18:31:50.140000+0000", "postInfo": {"id": "t3_p1", "title": "The post"}});
		let full = json!({
			"id": "t1_c1", "score": 5, "permalink": "/r/rust/comments/p1/the_post/c1/", "authorInfo": {"name": "spez"},
			"content": {"markdown": "body", "richtext": r#"{"document":[{"e":"par","c":[{"e":"text","t":"body"}]}]}"#, "html": null},
			"distinguishedAs": "ADMIN",
		});
		let data = &comment(&summary, &full)["data"];
		assert_eq!(
			(data["id"].as_str(), data["link_title"].as_str(), data["subreddit"].as_str()),
			(Some("c1"), Some("The post"), Some("rust"))
		);
		assert_eq!((data["body_html"].as_str(), data["score"].as_i64()), (Some("<div class=\"md\"><p>body</p></div>"), Some(5)));
		assert_eq!((data["distinguished"].as_str(), data["created_utc"].as_f64()), (Some("admin"), Some(1785954710.0)));
		assert_eq!(subreddit_of("/user/spez/comments/p/t/c/"), "u_spez");
		assert_eq!(subreddit_of(""), "");
		// A comment LiveCommentsByIds lost keeps its summary's score and an unknown author
		assert_eq!(comment(&summary, &Value::Null)["data"]["author"], "[deleted]");
		assert_eq!(comment(&summary, &Value::Null)["data"]["score"], 3);
	}
}
