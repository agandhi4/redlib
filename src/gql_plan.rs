//! The GraphQL plan of each `reddit_path::Resource`: which persisted operations answer it (one,
//! or a second when the first only names ids), and their answers converted to the JSON API's
//! shape (`gql_posts`, `gql_users`). Every call goes through the `GqlFetch` it is given, so the
//! tests drive it with fakes. Used by `sources`, which decides whether a plan runs at all.

use crate::gql_ops;
use crate::gql_posts::{connection, is_post, listing, post};
use crate::gql_users::{comment, community, redditor, subreddit_about, unavailable_reason};
use crate::reddit_path::{Page, Resource, SearchPage, Sort, UserListing};
use futures_lite::future::Boxed;
use log::warn;
use serde::{Deserialize, Serialize};
use serde_json::Value;

static NULL: Value = Value::Null;

/// Sends one GraphQL body and returns its response; `client::fetch_gql` in production.
pub(crate) type GqlFetch<'a> = &'a (dyn Fn(Value) -> Boxed<Result<Value, String>> + Sync);

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum GqlError {
	/// Reddit's own answer (private, banned, quarantined, gated, suspended, missing), in the
	/// JSON API's words: the page's answer, as REST's would be.
	Refused(String),
	/// GraphQL cannot serve this request, though it works: REST serves it, the breaker stays shut.
	NotServed(String),
	/// The operation failed or answered without its data: REST serves it and the breaker opens.
	Failed(String),
}

/// The JSON API document `resource` reads, from GraphQL. `quarantine` is the reader's opt-in,
/// which only REST can carry (a cookie).
pub(crate) async fn run(resource: &Resource, quarantine: bool, gql: GqlFetch<'_>) -> Result<Value, GqlError> {
	match resource {
		Resource::SubredditListing { sub, page } => subreddit_listing(sub, page, quarantine, gql).await,
		Resource::Popular(page) => popular(page, gql).await,
		Resource::All(page) => all(page, gql).await,
		Resource::Multi { subs, page } => multi(subs, page, gql).await,
		Resource::About { sub } => about(sub, quarantine, gql).await,
		Resource::ById { ids } => Ok(listing(posts_by_ids(ids, gql).await?, None)),
		Resource::UserAbout { name } => user_about(name, gql).await,
		Resource::UserListing { name, listing: kind, page } => user_listing(name, *kind, page, gql).await,
		Resource::Search { query, page } => search(query, page, gql).await,
		Resource::SubredditSearch { query, limit } => communities(query, *limit, gql).await,
		Resource::Other => Err(GqlError::NotServed("no GraphQL plan".to_string())),
	}
}

async fn call(gql: GqlFetch<'_>, body: Value) -> Result<Value, GqlError> {
	gql(body).await.map_err(GqlError::Failed)
}

fn failed(operation: &str, what: &str) -> GqlError {
	GqlError::Failed(format!("{operation} {what}"))
}

/// A connection of post nodes as a Listing; `node` picks the post out of each edge's node.
fn posts_listing(conn: &Value, node: fn(&Value) -> &Value) -> Value {
	let (nodes, cursor) = connection(conn);
	listing(nodes.into_iter().map(node).filter(|n| is_post(n)).map(post).collect(), cursor)
}

fn itself(node: &Value) -> &Value {
	node
}

async fn subreddit_listing(sub: &str, page: &Page, quarantine: bool, gql: GqlFetch<'_>) -> Result<Value, GqlError> {
	let response = call(gql, gql_ops::subreddit_feed(sub, page)).await?;
	let elements = &response["data"]["postFeed"]["elements"];
	if elements.is_object() {
		return Ok(posts_listing(elements, itself));
	}
	// No feed (`UnavailableSubreddit`, without its reason): the subreddit itself says why.
	let info = call(gql, gql_ops::subreddit_info(sub)).await?;
	let info = &info["data"]["subredditInfoByName"];
	Err(refusal(sub, quarantine, info).unwrap_or_else(|| failed("SubredditFeedElements", "returned no feed")))
}

/// Why `info` (a `SubredditInfoByName` answer) is no subreddit to show: Reddit's refusal, or
/// NotServed for a quarantined or gated sub the reader opted into (REST sends the opt-in).
/// None when it is a subreddit after all.
fn refusal(sub: &str, quarantine: bool, info: &Value) -> Option<GqlError> {
	if info.is_null() {
		return Some(GqlError::Refused(format!("r/{sub} does not exist")));
	}
	match unavailable_reason(info) {
		Some(reason @ ("quarantined" | "gated")) if quarantine => Some(GqlError::NotServed(format!("r/{sub} is {reason}; the opt-in needs REST"))),
		Some(reason) => Some(GqlError::Refused(reason.to_string())),
		// Still Reddit's answer, for a reason this does not know: refused, never Failed, or one
		// odd sub would open the breaker and send every page of its kind to REST.
		None if info["__typename"] == "UnavailableSubreddit" => {
			warn!("[source] r/{sub}: unavailable for an unknown reason {}", info["forbiddenReason"]);
			Some(GqlError::Refused(format!("r/{sub} is unavailable")))
		}
		None => None,
	}
}

async fn about(sub: &str, quarantine: bool, gql: GqlFetch<'_>) -> Result<Value, GqlError> {
	let response = call(gql, gql_ops::subreddit_info(sub)).await?;
	let info = &response["data"]["subredditInfoByName"];
	if info["__typename"] == "Subreddit" {
		return Ok(subreddit_about(info));
	}
	Err(refusal(sub, quarantine, info).unwrap_or_else(|| failed("SubredditInfoByName", "returned no subreddit")))
}

/// Popular and r/all always have posts; an empty first page is a broken operation.
fn nonempty(listing: Value, operation: &str) -> Result<Value, GqlError> {
	match listing["data"]["children"].as_array() {
		Some(children) if !children.is_empty() => Ok(listing),
		_ => Err(failed(operation, "returned no posts")),
	}
}

async fn popular(page: &Page, gql: GqlFetch<'_>) -> Result<Value, GqlError> {
	let response = call(gql, gql_ops::popular_feed(page)).await?;
	// Each node is a recommendation wrapping the post.
	let listing = posts_listing(&response["data"]["popular"]["elements"], |node| &node["postInfo"]);
	nonempty(listing, "PopularFeedElements")
}

/// r/all names its posts (`groupId`); PostsByIds fetches them.
async fn all(page: &Page, gql: GqlFetch<'_>) -> Result<Value, GqlError> {
	let response = call(gql, gql_ops::all_feed(page)).await?;
	let (cells, cursor) = connection(&response["data"]["allV3"]["elements"]);
	let ids: Vec<String> = cells
		.iter()
		.filter_map(|cell| cell["groupId"].as_str())
		.filter(|id| id.starts_with("t3_"))
		.map(str::to_string)
		.collect();
	if ids.is_empty() {
		return Err(failed("AllFeedSdui", "returned no posts"));
	}
	nonempty(listing(posts_by_ids(&ids, gql).await?, cursor), "AllFeedSdui")
}

async fn posts_by_ids(ids: &[String], gql: GqlFetch<'_>) -> Result<Vec<Value>, GqlError> {
	let response = call(gql, gql_ops::posts_by_ids(ids)).await?;
	// A deleted post is a null entry, which leaves the listing short, as REST's would be.
	let posts = response["data"]["postsInfoByIds"].as_array().ok_or_else(|| failed("PostsByIds", "returned no posts"))?;
	Ok(posts.iter().filter(|node| is_post(node)).map(post).collect())
}

/// A multireddit (the front page of subscriptions included) as one search: `subreddit:a OR
/// subreddit:b …`. A failure here may be this query (Reddit's query limit is not documented;
/// 27 subs verified 2026-10-29), not the operation, so REST serves it without opening the breaker.
async fn multi(subs: &[String], page: &SearchPage, gql: GqlFetch<'_>) -> Result<Value, GqlError> {
	let query = subs.iter().map(|sub| format!("subreddit:{sub}")).collect::<Vec<_>>().join(" OR ");
	search(&query, page, gql).await.map_err(|e| match e {
		GqlError::Failed(e) => {
			warn!("[source] multireddit of {} subs: GraphQL search failed ({e}); REST", subs.len());
			GqlError::NotServed(e)
		}
		other => other,
	})
}

async fn search(query: &str, page: &SearchPage, gql: GqlFetch<'_>) -> Result<Value, GqlError> {
	let response = call(gql, gql_ops::search_posts(query, page)).await?;
	let posts = &response["data"]["search"]["general"]["posts"];
	if !posts.is_object() {
		return Err(failed("SearchPosts", "returned no results"));
	}
	Ok(posts_listing(posts, itself))
}

async fn communities(query: &str, limit: u32, gql: GqlFetch<'_>) -> Result<Value, GqlError> {
	let response = call(gql, gql_ops::search_communities(query, limit)).await?;
	let found = &response["data"]["search"]["general"]["communities"];
	if !found.is_object() {
		return Err(failed("SearchCommunities", "returned no results"));
	}
	let (nodes, _) = connection(found);
	Ok(listing(nodes.into_iter().filter(|node| node["name"].is_string()).map(community).collect(), None))
}

async fn user_about(name: &str, gql: GqlFetch<'_>) -> Result<Value, GqlError> {
	let response = call(gql, gql_ops::user_profile(name)).await?;
	let info = &response["data"]["redditorInfoByName"];
	if info["__typename"] == "Redditor" {
		return Ok(redditor(info));
	}
	Err(user_refusal(name, info).unwrap_or_else(|| failed("UserProfileDetails", "returned no user")))
}

/// Why `info` (a `UserProfileDetails` answer) is no user to show; None when it is one.
fn user_refusal(name: &str, info: &Value) -> Option<GqlError> {
	if info.is_null() {
		return Some(GqlError::Refused(format!("u/{name} does not exist")));
	}
	// `UnavailableRedditor`: suspended or deleted, which the JSON API calls suspended.
	info["__typename"]
		.as_str()
		.is_some_and(|t| t.starts_with("Unavailable"))
		.then(|| GqlError::Refused("suspended".to_string()))
}

/// A listing that came back without its connection: the user is gone, or the operation broke.
async fn missing_user_listing(name: &str, operation: &str, gql: GqlFetch<'_>) -> GqlError {
	match call(gql, gql_ops::user_profile(name)).await {
		Ok(response) => user_refusal(name, &response["data"]["redditorInfoByName"]).unwrap_or_else(|| failed(operation, "returned no listing")),
		Err(e) => e,
	}
}

/// One page of a user listing: its things and the next cursor of each side.
type Side = (Vec<Value>, Option<String>);

/// Where one side of the overview resumes: the GraphQL cursor of the page it is fetched from
/// (`None` is its first page) and how many of that page's things earlier overview pages showed.
#[derive(Serialize, Deserialize, Clone, Default)]
struct SideCursor {
	a: Option<String>,
	s: usize,
}

/// The overview's `after`: where each side resumes; a side with none is exhausted.
#[derive(Serialize, Deserialize)]
struct OverviewCursor {
	p: Option<SideCursor>,
	c: Option<SideCursor>,
}

/// One side's things for this overview page (the already-shown ones skipped), where it was
/// fetched from, and its next GraphQL cursor.
struct Fetched {
	things: Vec<Value>,
	at: Option<SideCursor>,
	next: Option<String>,
}

/// A thing's rank under one overview sort, higher first: both sides arrive in that order.
type Rank = fn(&Value) -> f64;

fn created(thing: &Value) -> f64 {
	thing["data"]["created_utc"].as_f64().unwrap_or_default()
}

fn score(thing: &Value) -> f64 {
	thing["data"]["score"].as_f64().unwrap_or_default()
}

/// Reddit's published hot rank (score's order of magnitude plus age in 12.5 h units), which
/// orders both posts and comments by `hot`.
fn hot(thing: &Value) -> f64 {
	let score = score(thing);
	score.signum() * score.abs().max(1.0).log10() + (created(thing) - 1_134_028_003.0) / 45_000.0
}

/// The rank the overview merges a sort by; None for a sort whose rank GraphQL does not carry
/// (controversial needs the vote split), which REST serves.
fn overview_rank(sort: Sort) -> Option<Rank> {
	match sort {
		Sort::New => Some(created),
		Sort::Top => Some(score),
		Sort::Hot => Some(hot),
		Sort::Controversial | Sort::Rising | Sort::Best => None,
	}
}

impl Fetched {
	fn new((things, next): Side, at: Option<SideCursor>) -> Self {
		let skip = at.as_ref().map_or(0, |at| at.s);
		Self {
			things: things.into_iter().skip(skip).collect(),
			at,
			next,
		}
	}

	/// The lowest-ranked thing this side shows, when the side has more: nothing ranked lower
	/// from the other side may show yet, since this side's next page may outrank it.
	fn bound(&self, rank: Rank) -> Option<f64> {
		self.next.as_ref()?;
		self.things.iter().map(rank).reduce(f64::min)
	}

	/// This side's things down to `bound`, and where the side resumes: past its page when all of
	/// it showed, else on the same page past what showed.
	fn take(self, rank: Rank, bound: Option<f64>) -> (Vec<Value>, Option<SideCursor>) {
		let Self { mut things, at, next } = self;
		let shown = bound.map_or(things.len(), |bound| things.iter().take_while(|t| rank(t) >= bound).count());
		let resume = if shown == things.len() {
			next.map(|a| SideCursor { a: Some(a), s: 0 })
		} else {
			at.map(|at| SideCursor { s: at.s + shown, ..at })
		};
		things.truncate(shown);
		(things, resume)
	}
}

async fn user_listing(name: &str, kind: UserListing, page: &Page, gql: GqlFetch<'_>) -> Result<Value, GqlError> {
	let (things, cursor) = match kind {
		UserListing::Overview => overview(name, page, gql).await?,
		side_kind => side(name, side_kind, Some(page), gql).await?,
	};
	Ok(listing(things, cursor.as_deref()))
}

/// One side of a user listing, posts (`Submitted`) or `Comments`; a side with no page to fetch
/// (an exhausted side of the overview) is empty.
async fn side(name: &str, kind: UserListing, page: Option<&Page>, gql: GqlFetch<'_>) -> Result<Side, GqlError> {
	match (kind, page) {
		(_, None) => Ok(Side::default()),
		(UserListing::Comments, Some(page)) => user_comments(name, page, gql).await,
		(_, Some(page)) => user_posts(name, page, gql).await,
	}
}

async fn user_posts(name: &str, page: &Page, gql: GqlFetch<'_>) -> Result<Side, GqlError> {
	let response = call(gql, gql_ops::user_posts(name, page)).await?;
	let posts = &response["data"]["postFeed"]["posts"];
	if !posts.is_object() {
		return Err(missing_user_listing(name, "UserSubmittedPosts", gql).await);
	}
	let (nodes, cursor) = connection(posts);
	Ok((nodes.into_iter().filter(|n| is_post(n)).map(post).collect(), cursor.map(str::to_string)))
}

/// Comment summaries from SubmittedComments, their bodies from LiveCommentsByIds.
async fn user_comments(name: &str, page: &Page, gql: GqlFetch<'_>) -> Result<Side, GqlError> {
	let response = call(gql, gql_ops::user_comments(name, page)).await?;
	let comments = &response["data"]["redditorInfoByName"]["comments"];
	if !comments.is_object() {
		return Err(missing_user_listing(name, "SubmittedComments", gql).await);
	}
	let (summaries, cursor) = connection(comments);
	let summaries: Vec<&Value> = summaries.into_iter().filter(|s| s["id"].as_str().is_some_and(|id| id.starts_with("t1_"))).collect();
	let cursor = cursor.map(str::to_string);
	if summaries.is_empty() {
		return Ok((Vec::new(), cursor));
	}
	let ids: Vec<String> = summaries.iter().filter_map(|s| s["id"].as_str()).map(str::to_string).collect();
	let bodies = call(gql, gql_ops::comments_by_ids(&ids)).await?;
	let bodies = bodies["data"]["commentsByIds"]
		.as_array()
		.ok_or_else(|| failed("LiveCommentsByIds", "returned no comments"))?;
	// A comment LiveCommentsByIds left out still lists, from its summary.
	let body = |id: &Value| bodies.iter().find(|b| b["id"] == *id).unwrap_or(&NULL);
	Ok((summaries.iter().map(|s| comment(s, body(&s["id"]))).collect(), cursor))
}

/// Posts and comments in the page's sort: a page of each side, merged by that sort's rank down
/// to a shared boundary (the higher of the two sides' lowest-ranked things, among sides with
/// more), so the order holds across pages. A side cut at the boundary resumes on the same page,
/// past what showed; both resume points travel in one `after`, so nothing repeats or is skipped.
async fn overview(name: &str, page: &Page, gql: GqlFetch<'_>) -> Result<Side, GqlError> {
	let Some(rank) = overview_rank(page.sort) else {
		return Err(GqlError::NotServed(format!("the overview cannot merge by {:?}", page.sort)));
	};
	let cursor = match &page.after {
		None => OverviewCursor {
			p: Some(SideCursor::default()),
			c: Some(SideCursor::default()),
		},
		Some(after) => serde_json::from_str(after).map_err(|_| GqlError::Refused("This page link is no longer valid".to_string()))?,
	};
	let side_page = |at: &Option<SideCursor>| {
		at.as_ref().map(|at| Page {
			after: at.a.clone(),
			..page.clone()
		})
	};
	let (posts_page, comments_page) = (side_page(&cursor.p), side_page(&cursor.c));
	let (posts, comments) = futures_lite::future::zip(
		side(name, UserListing::Submitted, posts_page.as_ref(), gql),
		side(name, UserListing::Comments, comments_page.as_ref(), gql),
	)
	.await;
	let (posts, comments) = (Fetched::new(posts?, cursor.p), Fetched::new(comments?, cursor.c));
	let bound = posts.bound(rank).into_iter().chain(comments.bound(rank)).reduce(f64::max);
	let ((mut things, p), (more, c)) = (posts.take(rank, bound), comments.take(rank, bound));
	things.extend(more);
	things.sort_by(|a, b| rank(b).total_cmp(&rank(a)));
	let next = (p.is_some() || c.is_some()).then(|| serde_json::to_string(&OverviewCursor { p, c }).unwrap_or_default());
	Ok((things, next))
}

#[cfg(test)]
mod tests {
	// Offline: every plan driven by a fake gql-fed that answers by operation name (AGENTS.md "Test seams").

	use super::*;
	use crate::gql_fields::after_param;
	use crate::reddit_path::parse;
	use futures_lite::FutureExt;
	use serde_json::json;
	use std::sync::Mutex;

	/// A gql-fed that answers each operation with its entry in `answers` (an Err when absent),
	/// recording the bodies it was sent.
	struct Fake {
		answers: Vec<(&'static str, Value)>,
		sent: Mutex<Vec<Value>>,
	}

	impl Fake {
		fn new(answers: Vec<(&'static str, Value)>) -> Self {
			Self {
				answers,
				sent: Mutex::new(Vec::new()),
			}
		}

		fn fetch(&self) -> impl Fn(Value) -> Boxed<Result<Value, String>> + Sync + '_ {
			move |body| {
				let operation = body["operationName"].as_str().unwrap_or_default().to_string();
				self.sent.lock().unwrap().push(body);
				let answer = self.answers.iter().find(|(name, _)| *name == operation).map(|(_, answer)| answer.clone());
				async move { answer.ok_or_else(|| format!("Reddit GraphQL {operation} error: not faked")) }.boxed()
			}
		}

		fn operations(&self) -> Vec<String> {
			self
				.sent
				.lock()
				.unwrap()
				.iter()
				.map(|body| body["operationName"].as_str().unwrap_or_default().to_string())
				.collect()
		}

		async fn run(&self, path: &str, quarantine: bool) -> Result<Value, GqlError> {
			run(&parse(path), quarantine, &self.fetch()).await
		}
	}

	fn node(id: &str, created: &str) -> Value {
		json!({ "__typename": "SubredditPost", "id": id, "title": "t", "createdAt": created, "subreddit": {"name": "rust"} })
	}

	fn edges(nodes: Vec<Value>, cursor: Option<&str>) -> Value {
		json!({ "edges": nodes.into_iter().map(|node| json!({ "node": node })).collect::<Vec<_>>(), "pageInfo": { "endCursor": cursor, "hasNextPage": cursor.is_some() } })
	}

	fn ids(listing: &Value) -> Vec<String> {
		listing["data"]["children"]
			.as_array()
			.unwrap()
			.iter()
			.map(|c| c["data"]["name"].as_str().unwrap_or_default().to_string())
			.collect()
	}

	fn info(info: Value) -> (&'static str, Value) {
		("SubredditInfoByName", json!({ "data": { "subredditInfoByName": info } }))
	}

	fn unavailable(reason: &str) -> Value {
		json!({ "__typename": "UnavailableSubreddit", "forbiddenReason": reason })
	}

	#[tokio::test]
	async fn a_subreddit_feed_is_a_listing_with_our_cursor() {
		let feed = json!({ "data": { "postFeed": { "elements": edges(vec![node("t3_a", ""), json!({"id": "ad"})], Some("c1")) } } });
		let fake = Fake::new(vec![("SubredditFeedElements", feed)]);
		let listing = fake.run("/r/rust/top.json?t=week", false).await.unwrap();
		assert_eq!(
			(ids(&listing), listing["data"]["after"].as_str()),
			(vec!["t3_a".to_string()], Some(after_param("c1").as_str()))
		);
		assert_eq!(fake.sent.lock().unwrap()[0]["variables"]["range"], "WEEK");
	}

	#[tokio::test]
	async fn a_missing_feed_asks_the_subreddit_why() {
		let no_feed = ("SubredditFeedElements", json!({ "data": { "postFeed": { "__typename": "UnavailableSubreddit" } } }));
		let answer = |info_answer: Value, quarantine: bool| {
			let fake = Fake::new(vec![no_feed.clone(), info(info_answer)]);
			async move { fake.run("/r/edgy/hot.json", quarantine).await.unwrap_err() }
		};
		assert_eq!(answer(unavailable("QUARANTINED"), false).await, GqlError::Refused("quarantined".into()));
		assert!(matches!(answer(unavailable("GATED"), true).await, GqlError::NotServed(_)));
		assert_eq!(answer(Value::Null, false).await, GqlError::Refused("r/edgy does not exist".into()));
		assert!(matches!(answer(json!({"__typename": "Subreddit"}), false).await, GqlError::Failed(_)));
	}

	#[tokio::test]
	async fn about_is_the_subreddit_or_its_refusal() {
		let fake = Fake::new(vec![info(json!({ "__typename": "Subreddit", "name": "rust", "title": "Rust" }))]);
		assert_eq!(fake.run("/r/rust/about.json?raw_json=1", false).await.unwrap()["data"]["display_name"], "rust");
		let private = Fake::new(vec![info(unavailable("PRIVATE"))]);
		assert_eq!(private.run("/r/x/about.json", true).await, Err(GqlError::Refused("private".into())));
		let unknown = Fake::new(vec![info(unavailable("SOMETHING_NEW"))]);
		assert_eq!(unknown.run("/r/x/about.json", false).await, Err(GqlError::Refused("r/x is unavailable".into())));
		let odd = Fake::new(vec![info(json!({ "__typename": "SomethingNew" }))]);
		assert!(matches!(odd.run("/r/x/about.json", false).await, Err(GqlError::Failed(_))));
	}

	#[tokio::test]
	async fn popular_unwraps_recommendations_and_must_have_posts() {
		let popular = |nodes| ("PopularFeedElements", json!({ "data": { "popular": { "elements": edges(nodes, None) } } }));
		let fake = Fake::new(vec![popular(vec![json!({ "__typename": "PostRecommendation", "postInfo": node("t3_p", "") })])]);
		assert_eq!(ids(&fake.run("/r/popular/hot.json?geo_filter=GLOBAL", false).await.unwrap()), vec!["t3_p"]);
		let empty = Fake::new(vec![popular(Vec::new())]);
		assert!(matches!(empty.run("/r/popular/hot.json", false).await, Err(GqlError::Failed(_))));
	}

	#[tokio::test]
	async fn all_names_ids_that_posts_by_ids_fills() {
		let cells = json!({ "data": { "allV3": { "elements": { "edges": [{"node": {"groupId": "t3_a"}}, {"node": {"groupId": "ad_1"}}], "pageInfo": {"endCursor": "c"} } } } });
		let posts = json!({ "data": { "postsInfoByIds": [node("t3_a", ""), null] } });
		let fake = Fake::new(vec![("AllFeedSdui", cells), ("PostsByIds", posts)]);
		let listing = fake.run("/r/all/hot.json", false).await.unwrap();
		assert_eq!(
			(ids(&listing), listing["data"]["after"].as_str()),
			(vec!["t3_a".to_string()], Some(after_param("c").as_str()))
		);
		assert_eq!(fake.sent.lock().unwrap()[1]["variables"]["ids"], json!(["t3_a"]));
		let none = Fake::new(vec![("AllFeedSdui", json!({ "data": { "allV3": { "elements": { "edges": [] } } } }))]);
		assert!(matches!(none.run("/r/all/hot.json", false).await, Err(GqlError::Failed(_))));
	}

	#[tokio::test]
	async fn by_id_skips_deleted_posts_and_needs_its_list() {
		let fake = Fake::new(vec![("PostsByIds", json!({ "data": { "postsInfoByIds": [null] } }))]);
		assert!(ids(&fake.run("/by_id/t3_gone.json", false).await.unwrap()).is_empty());
		let broken = Fake::new(vec![("PostsByIds", json!({ "data": null }))]);
		assert!(matches!(broken.run("/by_id/t3_a.json", false).await, Err(GqlError::Failed(_))));
	}

	#[tokio::test]
	async fn a_multireddit_is_an_or_search_whose_failure_is_not_served() {
		let results = json!({ "data": { "search": { "general": { "posts": edges(vec![node("t3_m", "")], None) } } } });
		let fake = Fake::new(vec![("SearchPosts", results)]);
		assert_eq!(ids(&fake.run("/r/rust%2Blinux/new.json", false).await.unwrap()), vec!["t3_m"]);
		let variables = fake.sent.lock().unwrap()[0]["variables"].clone();
		assert_eq!(
			(variables["query"].as_str(), variables["sort"].as_str()),
			(Some("subreddit:rust OR subreddit:linux"), Some("NEW"))
		);
		let failing = Fake::new(Vec::new());
		assert!(matches!(failing.run("/r/a+b/hot.json", false).await, Err(GqlError::NotServed(_))));
	}

	#[tokio::test]
	async fn searches_of_posts_and_communities() {
		let posts = (
			"SearchPosts",
			json!({ "data": { "search": { "general": { "posts": edges(vec![node("t3_s", "")], Some("OQ==")) } } } }),
		);
		let fake = Fake::new(vec![posts]);
		let listing = fake.run("/r/rust/search.json?q=async&restrict_sr=on&sort=new", false).await.unwrap();
		assert_eq!(listing["data"]["after"], after_param("OQ=="));
		assert_eq!(fake.sent.lock().unwrap()[0]["variables"]["query"], "subreddit:rust async");
		let missing = Fake::new(vec![("SearchPosts", json!({ "data": { "search": null } }))]);
		assert!(matches!(missing.run("/search.json?q=x", false).await, Err(GqlError::Failed(_))));

		let found = edges(vec![json!({ "name": "rust", "id": "t5_1" }), json!({ "id": "nameless" })], None);
		let fake = Fake::new(vec![("SearchCommunities", json!({ "data": { "search": { "general": { "communities": found } } } }))]);
		let listing = fake.run("/subreddits/search.json?q=rust&limit=3", false).await.unwrap();
		assert_eq!(listing["data"]["children"].as_array().unwrap().len(), 1);
		assert_eq!(listing["data"]["children"][0]["data"]["display_name"], "rust");
		let missing = Fake::new(vec![("SearchCommunities", json!({ "data": null }))]);
		assert!(matches!(missing.run("/subreddits/search.json?q=x", false).await, Err(GqlError::Failed(_))));
	}

	fn profile(info: Value) -> (&'static str, Value) {
		("UserProfileDetails", json!({ "data": { "redditorInfoByName": info } }))
	}

	#[tokio::test]
	async fn user_about_is_the_redditor_or_its_refusal() {
		let fake = Fake::new(vec![profile(json!({ "__typename": "Redditor", "name": "spez", "karma": {"total": 5} }))]);
		assert_eq!(fake.run("/user/spez/about.json", false).await.unwrap()["data"]["total_karma"], 5);
		let gone = Fake::new(vec![profile(Value::Null)]);
		assert_eq!(gone.run("/user/x/about.json", false).await, Err(GqlError::Refused("u/x does not exist".into())));
		let suspended = Fake::new(vec![profile(json!({ "__typename": "UnavailableRedditor" }))]);
		assert_eq!(suspended.run("/user/x/about.json", false).await, Err(GqlError::Refused("suspended".into())));
		let odd = Fake::new(vec![profile(json!({ "__typename": "RedditorV2" }))]);
		assert!(matches!(odd.run("/user/x/about.json", false).await, Err(GqlError::Failed(_))));
	}

	fn submitted(nodes: Vec<Value>, cursor: Option<&str>) -> (&'static str, Value) {
		("UserSubmittedPosts", json!({ "data": { "postFeed": { "posts": edges(nodes, cursor) } } }))
	}

	fn summaries(cursor: Option<&str>) -> (&'static str, Value) {
		let summary = json!({ "id": "t1_c", "createdAt": "2026-10-02T00:00:00+0000", "postInfo": {"id": "t3_x", "title": "On"} });
		(
			"SubmittedComments",
			json!({ "data": { "redditorInfoByName": { "comments": edges(vec![summary], cursor) } } }),
		)
	}

	fn bodies() -> (&'static str, Value) {
		(
			"LiveCommentsByIds",
			json!({ "data": { "commentsByIds": [{ "id": "t1_c", "permalink": "/r/rust/comments/x/on/c/", "content": {"markdown": "hi"} }] } }),
		)
	}

	#[tokio::test]
	async fn user_comments_join_summaries_with_bodies() {
		let fake = Fake::new(vec![summaries(None), bodies()]);
		let listing = fake.run("/user/spez/comments.json?sort=new", false).await.unwrap();
		let comment = &listing["data"]["children"][0]["data"];
		assert_eq!(
			(comment["link_title"].as_str(), comment["body"].as_str(), comment["subreddit"].as_str()),
			(Some("On"), Some("hi"), Some("rust"))
		);
		assert_eq!(fake.operations(), vec!["SubmittedComments", "LiveCommentsByIds"]);

		// A listing with no connection: the user is gone (or the operation broke)
		let gone = Fake::new(vec![("SubmittedComments", json!({ "data": { "redditorInfoByName": null } })), profile(Value::Null)]);
		assert_eq!(gone.run("/user/x/comments.json", false).await, Err(GqlError::Refused("u/x does not exist".into())));
		let broken = Fake::new(vec![("UserSubmittedPosts", json!({ "data": {} })), profile(json!({ "__typename": "Redditor" }))]);
		assert!(matches!(broken.run("/user/x/submitted.json", false).await, Err(GqlError::Failed(_))));
	}

	#[tokio::test]
	async fn the_overview_merges_both_sides_newest_first_and_continues_each() {
		let newer = node("t3_new", "2026-10-03T00:00:00+0000");
		let older = node("t3_old", "2026-10-01T00:00:00+0000");
		let fake = Fake::new(vec![submitted(vec![older, newer], Some("pc")), summaries(None), bodies()]);
		let listing = fake.run("/user/spez/overview.json?&raw_json=1", false).await.unwrap();
		assert_eq!(ids(&listing), vec!["t3_new", "t1_c", "t3_old"]);
		let after = listing["data"]["after"].as_str().unwrap().to_string();

		// Page 2: only the posts side has more
		let fake = Fake::new(vec![submitted(vec![node("t3_older", "2026-09-01T00:00:00+0000")], None)]);
		let listing = fake.run(&format!("/user/spez/overview.json?after={after}"), false).await.unwrap();
		assert_eq!((ids(&listing), fake.operations()), (vec!["t3_older".to_string()], vec!["UserSubmittedPosts".to_string()]));
		assert_eq!(fake.sent.lock().unwrap()[0]["variables"]["after"], "pc");
		assert!(listing["data"]["after"].is_null());

		// Both sides have more: page 1 shows nothing older than the newer side's oldest thing, and
		// the cut side resumes on its first page, past what showed
		let page = vec![node("t3_a", "2026-10-05T00:00:00+0000"), node("t3_b", "2026-10-04T00:00:00+0000")];
		let year_old = json!({ "id": "t1_c", "createdAt": "2025-10-02T00:00:00+0000", "postInfo": {"id": "t3_x", "title": "On"} });
		let comments = (
			"SubmittedComments",
			json!({ "data": { "redditorInfoByName": { "comments": edges(vec![year_old], Some("cc")) } } }),
		);
		let fake = Fake::new(vec![submitted(page, Some("pc")), comments.clone(), bodies()]);
		let listing = fake.run("/user/spez/overview.json", false).await.unwrap();
		assert_eq!(ids(&listing), vec!["t3_a", "t3_b"]);
		let after = listing["data"]["after"].as_str().unwrap().to_string();
		let fake = Fake::new(vec![submitted(vec![node("t3_d", "2024-01-01T00:00:00+0000")], None), comments, bodies()]);
		let listing = fake.run(&format!("/user/spez/overview.json?after={after}"), false).await.unwrap();
		// The year-old comment shows, the 2024 post waits: comments may still hold newer things
		assert_eq!(ids(&listing), vec!["t1_c"]);
		let sent = fake.sent.lock().unwrap().clone();
		let after_of = |op: &str| sent.iter().find(|b| b["operationName"] == op).map(|b| b["variables"]["after"].clone());
		assert_eq!((after_of("UserSubmittedPosts"), after_of("SubmittedComments")), (Some(json!("pc")), Some(Value::Null)));
		let after = listing["data"]["after"].as_str().unwrap().to_string();
		let empty = ("SubmittedComments", json!({ "data": { "redditorInfoByName": { "comments": edges(Vec::new(), None) } } }));
		let fake = Fake::new(vec![submitted(vec![node("t3_d", "2024-01-01T00:00:00+0000")], None), empty]);
		let listing = fake.run(&format!("/user/spez/overview.json?after={after}"), false).await.unwrap();
		let sent = fake.sent.lock().unwrap().clone();
		let after_of = |op: &str| sent.iter().find(|b| b["operationName"] == op).map(|b| b["variables"]["after"].clone());
		assert_eq!(
			(ids(&listing), after_of("UserSubmittedPosts"), after_of("SubmittedComments")),
			(vec!["t3_d".to_string()], Some(json!("pc")), Some(json!("cc")))
		);
		assert!(listing["data"]["after"].is_null());

		// Top merges by score; controversial has no rank here and is REST's
		let scored = |id: &str, score: i64| json!({ "__typename": "SubredditPost", "id": id, "title": "t", "score": score, "createdAt": "2026-10-01T00:00:00+0000", "subreddit": {"name": "rust"} });
		let high = json!({ "id": "t1_c", "score": 50, "createdAt": "2020-01-01T00:00:00+0000", "postInfo": {"id": "t3_x", "title": "On"} });
		let comments = ("SubmittedComments", json!({ "data": { "redditorInfoByName": { "comments": edges(vec![high], None) } } }));
		let fake = Fake::new(vec![submitted(vec![scored("t3_a", 90), scored("t3_b", 10)], None), comments, bodies()]);
		assert_eq!(
			ids(&fake.run("/user/spez/overview.json?sort=top&t=all", false).await.unwrap()),
			vec!["t3_a", "t1_c", "t3_b"]
		);
		assert!(matches!(
			Fake::new(Vec::new()).run("/user/spez/overview.json?sort=controversial", false).await,
			Err(GqlError::NotServed(_))
		));

		let foreign = after_param("not json");
		assert!(matches!(
			Fake::new(Vec::new()).run(&format!("/user/spez/overview.json?after={foreign}"), false).await,
			Err(GqlError::Refused(_))
		));
	}

	#[tokio::test]
	async fn other_resources_have_no_plan() {
		assert!(matches!(Fake::new(Vec::new()).run("/r/rust/wiki/index.json", false).await, Err(GqlError::NotServed(_))));
	}
}
