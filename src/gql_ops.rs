//! The one table of Reddit's persisted GraphQL operations that redlib sends to gql-fed, and the
//! pure builders of their POST bodies. Used by `gql_comments` (PostComments) and `gql_plan`
//! (every other read).
//!
//! gql-fed only runs persisted queries: a body carries the operation's name and the sha256 of
//! its query text, never the text itself, and anything else is refused ("Authentication
//! required"). The hashes are the Android app's, taken from frap129/stealth
//! (GraphQlOperation.kt, RedditSource.kt for the variables) and Amqx/reddit-gql
//! (src/operations.ts), and verified live on 2026-10-29. Reddit retires hashes with app
//! releases: a retired one answers `PersistedQueryNotFound`, `sources` then serves that kind of
//! page from REST, and the fix is a new hash here.

use crate::reddit_path::{Page, SearchPage};
use serde_json::{json, Value};

pub(crate) struct Operation {
	pub name: &'static str,
	pub hash: &'static str,
}

pub(crate) const POST_COMMENTS: Operation = Operation {
	name: "PostComments",
	hash: "314f29c2494fd78c7844ef2c6b09acb4bef5b37ab50b4ddc01691d6d5c8433f8",
};
/// One subreddit's posts. Serves no `all`, `popular` or `a+b` (null or empty).
const SUBREDDIT_FEED: Operation = Operation {
	name: "SubredditFeedElements",
	hash: "97046e2a48050f10a507db354a8da60955ffccb586dcf63163bdfc6610d5cf7a",
};
const POPULAR_FEED: Operation = Operation {
	name: "PopularFeedElements",
	hash: "728c0f9a4d12c17b8cffe07669bb1a8770b0f2ec0c84e040485f8fad2d9c417f",
};
/// r/all as post ids only (`groupId`); the posts come from `POSTS_BY_IDS`.
const ALL_FEED: Operation = Operation {
	name: "AllFeedSdui",
	hash: "0e9c0045dd244e934efd0ea4fefc00cb0b4d91523e2f09c8af075856cb59b937",
};
const POSTS_BY_IDS: Operation = Operation {
	name: "PostsByIds",
	hash: "29a8d4c6e135fffb95fc4cd303c57ad926c6c5ff582f4c4577c8a69b7f322d91",
};
const SUBREDDIT_INFO: Operation = Operation {
	name: "SubredditInfoByName",
	hash: "8c1815b07b762aee3c086cc84306f14b3907018e9ee152046c8e4d08ad4c7b88",
};
const USER_PROFILE: Operation = Operation {
	name: "UserProfileDetails",
	hash: "4822704f40348a38e37626b62f7f2a4e4af88aa5ab90f271a0c539db7ab2ac2f",
};
const USER_POSTS: Operation = Operation {
	name: "UserSubmittedPosts",
	hash: "78a213c02a340db4a707d4bcd375ce34f733b75893379603acb4ec20388fafe6",
};
/// A user's comments as summaries (id, score, post); the bodies come from `COMMENTS_BY_IDS`.
const USER_COMMENTS: Operation = Operation {
	name: "SubmittedComments",
	hash: "e1b37f521fb40af2120946b70e7fbf6a3d924db2abaf28ff2164d4cfacca28db",
};
const COMMENTS_BY_IDS: Operation = Operation {
	name: "LiveCommentsByIds",
	hash: "51ab9f2e0eb87b6dac9aac02012ba7046049e516ec55ec442abfed0f19c6f311",
};
/// Post search; `subreddit:<name>` in the query restricts it, and an `OR` of those is a multireddit.
const SEARCH_POSTS: Operation = Operation {
	name: "SearchPosts",
	hash: "8610e33521c90caa8d12576800c18b708ce0d19df3dfac8e2aad55d9860e4bf9",
};
const SEARCH_COMMUNITIES: Operation = Operation {
	name: "SearchCommunities",
	hash: "a3333069c1ead3ceec6d9bf4da4185ff584f69d0ba8b586e545b32ea62170932",
};

const PAGE_SIZE: u32 = 25;

/// The POST body of `op` with `variables`.
pub(crate) fn body(op: &Operation, variables: Value) -> Value {
	json!({
		"operationName": op.name,
		"variables": variables,
		"extensions": { "persistedQuery": { "version": 1, "sha256Hash": op.hash } },
	})
}

/// `variables` plus a feed page's sort, its range under `range_key` (the operations disagree on
/// the name) and its cursor; absent ones are left out, as the app sends them.
fn paged(mut variables: Value, page: &Page, range_key: &str) -> Value {
	variables["sort"] = page.sort.gql().into();
	if let Some(range) = page.range {
		variables[range_key] = range.gql().into();
	}
	if let Some(after) = &page.after {
		variables["after"] = after.as_str().into();
	}
	variables
}

pub(crate) fn subreddit_feed(sub: &str, page: &Page) -> Value {
	let variables = json!({ "subredditName": sub, "pageSize": PAGE_SIZE, "includeSubredditInPosts": true });
	body(&SUBREDDIT_FEED, paged(variables, page, "range"))
}

pub(crate) fn popular_feed(page: &Page) -> Value {
	body(&POPULAR_FEED, paged(json!({ "pageSize": PAGE_SIZE }), page, "range"))
}

pub(crate) fn all_feed(page: &Page) -> Value {
	body(&ALL_FEED, paged(json!({}), page, "time"))
}

pub(crate) fn posts_by_ids(ids: &[String]) -> Value {
	body(&POSTS_BY_IDS, json!({ "ids": ids, "includeExtendedVideoAsset": true, "includePlaybackMp4s": true }))
}

pub(crate) fn subreddit_info(sub: &str) -> Value {
	body(&SUBREDDIT_INFO, json!({ "subredditName": sub, "includeRecapFields": false, "includeDevvitData": false }))
}

pub(crate) fn user_profile(name: &str) -> Value {
	body(&USER_PROFILE, json!({ "username": name }))
}

pub(crate) fn user_posts(name: &str, page: &Page) -> Value {
	let variables = json!({ "username": name, "pageSize": PAGE_SIZE, "includeSubredditInPosts": true });
	body(&USER_POSTS, paged(variables, page, "range"))
}

pub(crate) fn user_comments(name: &str, page: &Page) -> Value {
	body(&USER_COMMENTS, paged(json!({ "name": name }), page, "range"))
}

pub(crate) fn comments_by_ids(ids: &[String]) -> Value {
	body(
		&COMMENTS_BY_IDS,
		json!({ "ids": ids, "includePremiumAvatarTreatment": false, "includeCommentsHtmlField": true }),
	)
}

pub(crate) fn search_posts(query: &str, page: &SearchPage) -> Value {
	let mut variables = json!({ "query": query, "sort": page.sort.gql(), "pageSize": PAGE_SIZE, "productSurface": "" });
	if let Some(range) = page.range {
		variables["filters"] = json!([{ "key": "time_range", "value": range.filter() }]);
	}
	if let Some(after) = &page.after {
		variables["afterCursor"] = after.as_str().into();
	}
	body(&SEARCH_POSTS, variables)
}

pub(crate) fn search_communities(query: &str, limit: u32) -> Value {
	body(&SEARCH_COMMUNITIES, json!({ "query": query, "pageSize": limit, "productSurface": "" }))
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::reddit_path::tests::page;
	use crate::reddit_path::{Range, SearchSort, Sort};

	#[test]
	fn bodies_name_the_persisted_query() {
		let body = subreddit_info("rust");
		assert_eq!(body["operationName"], "SubredditInfoByName");
		assert_eq!(body["extensions"]["persistedQuery"], json!({ "version": 1, "sha256Hash": SUBREDDIT_INFO.hash }));
		assert_eq!(body["variables"]["subredditName"], "rust");
		assert_eq!(user_profile("spez")["variables"], json!({ "username": "spez" }));
		assert_eq!(posts_by_ids(&["t3_a".to_string()])["variables"]["ids"], json!(["t3_a"]));
		assert_eq!(comments_by_ids(&["t1_a".to_string()])["operationName"], "LiveCommentsByIds");
		assert_eq!(search_communities("rust", 3)["variables"]["pageSize"], 3);
	}

	#[test]
	fn feeds_send_only_the_page_fields_they_have() {
		let first = subreddit_feed("rust", &page(Sort::Hot, None, None))["variables"].clone();
		assert_eq!(first, json!({ "subredditName": "rust", "sort": "HOT", "pageSize": 25, "includeSubredditInPosts": true }));
		let top = popular_feed(&page(Sort::Top, Some(Range::Week), Some("c1")))["variables"].clone();
		assert_eq!(top, json!({ "sort": "TOP", "range": "WEEK", "after": "c1", "pageSize": 25 }));
		// AllFeedSdui names its range `time`
		assert_eq!(all_feed(&page(Sort::Top, Some(Range::Day), None))["variables"], json!({ "sort": "TOP", "time": "DAY" }));
		assert_eq!(user_posts("spez", &page(Sort::New, None, None))["variables"]["username"], "spez");
		assert_eq!(
			user_comments("spez", &page(Sort::New, Some(Range::All), None))["variables"],
			json!({ "name": "spez", "sort": "NEW", "range": "ALL" })
		);
	}

	#[test]
	fn search_carries_its_range_as_a_filter_and_its_cursor_as_after_cursor() {
		let page = SearchPage {
			sort: SearchSort::Top,
			range: Some(Range::Month),
			after: Some("OQ==".into()),
		};
		let variables = &search_posts("subreddit:rust async", &page)["variables"];
		assert_eq!(variables["sort"], "TOP");
		assert_eq!(variables["filters"], json!([{ "key": "time_range", "value": "month" }]));
		assert_eq!(variables["afterCursor"], "OQ==");
		let plain = SearchPage {
			sort: SearchSort::Relevance,
			range: None,
			after: None,
		};
		let variables = &search_posts("rust", &plain)["variables"];
		assert!(variables["filters"].is_null() && variables["afterCursor"].is_null());
	}
}
