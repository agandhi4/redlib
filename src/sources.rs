//! Where every Reddit read comes from: GraphQL first, REST as the fallback, and the only place
//! that decides. Since 2026-10-29 oauth.reddit.com answers our anonymous tokens with a 403 block
//! page on every route while gql-fed's persisted queries still answer, so each REST path the
//! pages build is parsed (`reddit_path`) and served by its GraphQL plan (`gql_plan`); REST
//! (`client::fetch_json`) covers what has no plan and a kind whose plan fails, which is what
//! Reddit retiring a persisted query looks like. A failure opens that kind's breaker for
//! `GQL_RETRY_AFTER`, so a retired query costs one failed call per 5 minutes, not per page.
//! Used by every page through `json`; /info shows `status`.

use crate::client::{cached_json, fetch_gql, fetch_json};
use crate::gql_plan::{run, GqlError, GqlFetch};
use crate::reddit_path::{parse, without_gql_cursor, Kind};
use futures_lite::{future::Boxed, FutureExt};
use log::{info, warn};
use serde_json::Value;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
use time::{macros::format_description, OffsetDateTime};

/// How long a kind reads from REST after its GraphQL plan failed, in seconds.
const GQL_RETRY_AFTER: u64 = 300;

/// REST errors the pages match on exactly (`subreddit::community` and others); never decorated.
const REDDIT_REASONS: [&str; 6] = ["quarantined", "gated", "private", "banned", "suspended", crate::reddit_response::THREAD_LOGIN_REQUIRED];

/// Fetches one REST document; `client::fetch_json` in production.
type RestFetch<'a> = &'a (dyn Fn(String, bool) -> Boxed<Result<Value, String>> + Sync);

/// One breaker per `Kind`: the Unix second until which its GraphQL plan is skipped (0 when it
/// has never failed). Lock-free, so a page never waits on another's bookkeeping.
pub(crate) struct Breakers([AtomicU64; Kind::ALL.len()]);

impl Breakers {
	const fn new() -> Self {
		Self([const { AtomicU64::new(0) }; Kind::ALL.len()])
	}

	fn slot(&self, kind: Kind) -> &AtomicU64 {
		&self.0[kind as usize]
	}

	/// Whether `kind` tries GraphQL at `now`.
	fn allows(&self, kind: Kind, now: u64) -> bool {
		self.slot(kind).load(Ordering::Relaxed) <= now
	}

	/// Sends `kind` to REST until `now + GQL_RETRY_AFTER`. True when this opened it, so a burst
	/// of failing pages logs the switch once.
	fn trip(&self, kind: Kind, now: u64) -> bool {
		self.slot(kind).swap(now + GQL_RETRY_AFTER, Ordering::Relaxed) <= now
	}

	/// GraphQL answered `kind`. True when it had failed before, i.e. this is the switch back.
	fn close(&self, kind: Kind) -> bool {
		self.slot(kind).swap(0, Ordering::Relaxed) != 0
	}

	/// The Unix second `kind` reads from REST until, while its breaker is open.
	fn open_until(&self, kind: Kind, now: u64) -> Option<u64> {
		Some(self.slot(kind).load(Ordering::Relaxed)).filter(|until| *until > now)
	}
}

static BREAKERS: Breakers = Breakers::new();

/// The JSON API document for a REST `path`, as the pages have always read it, through the JSON
/// cache (`client::cached_json`); from GraphQL when its kind can, else REST.
pub async fn json(path: String, quarantine: bool) -> Result<Value, String> {
	cached_json(path, quarantine, |path, quarantine| async move {
		route(&path, quarantine, unix_now(), &BREAKERS, &live_gql, &live_rest).await
	})
	.await
}

/// Each kind's current source, for /info: "GraphQL", or "REST until HH:MM UTC".
pub fn status() -> Vec<(&'static str, String)> {
	status_at(&BREAKERS, unix_now())
}

fn status_at(breakers: &Breakers, now: u64) -> Vec<(&'static str, String)> {
	let clock = format_description!("[hour]:[minute]");
	Kind::ALL
		.iter()
		.map(|kind| {
			let source = breakers.open_until(*kind, now).map_or_else(
				|| "GraphQL".to_string(),
				|until| {
					let at = OffsetDateTime::from_unix_timestamp(until as i64).unwrap_or(OffsetDateTime::UNIX_EPOCH);
					format!("REST until {} UTC", at.format(clock).unwrap_or_default())
				},
			);
			(kind.name(), source)
		})
		.collect()
}

fn unix_now() -> u64 {
	SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_secs())
}

fn live_gql(body: Value) -> Boxed<Result<Value, String>> {
	fetch_gql(body).boxed()
}

fn live_rest(path: String, quarantine: bool) -> Boxed<Result<Value, String>> {
	fetch_json(path, quarantine).boxed()
}

/// The source decision for one read at `now`. Logs once per switch of a kind, never per page.
async fn route(path: &str, quarantine: bool, now: u64, breakers: &Breakers, gql: GqlFetch<'_>, rest: RestFetch<'_>) -> Result<Value, String> {
	let resource = parse(path);
	let Some(kind) = resource.kind() else {
		return rest(path.to_string(), quarantine).await;
	};
	if !breakers.allows(kind, now) {
		return fallback(path, quarantine, rest).await;
	}
	let gql_error = match run(&resource, quarantine, gql).await {
		Ok(value) => return answered(kind, breakers, Ok(value)),
		Err(GqlError::Refused(reason)) => return answered(kind, breakers, Err(reason)),
		Err(GqlError::NotServed(e)) => e,
		Err(GqlError::Failed(e)) => {
			if breakers.trip(kind, now) {
				warn!("[source] {}: GraphQL failed ({e}); REST for {} min", kind.name(), GQL_RETRY_AFTER / 60);
			}
			e
		}
	};
	fallback(path, quarantine, rest).await.map_err(|rest_error| combined(rest_error, &gql_error))
}

/// GraphQL answered (a document, or Reddit's refusal): its breaker closes.
fn answered(kind: Kind, breakers: &Breakers, result: Result<Value, String>) -> Result<Value, String> {
	if breakers.close(kind) {
		info!("[source] {}: GraphQL back", kind.name());
	}
	result
}

/// REST for `path`. A page that continues a GraphQL listing (`after=g_…`) cannot continue on REST,
/// which then serves its first page.
async fn fallback(path: &str, quarantine: bool, rest: RestFetch<'_>) -> Result<Value, String> {
	match without_gql_cursor(path) {
		Some(first_page) => {
			warn!("[source] {path}: REST cannot continue a GraphQL page; serving its first page");
			rest(first_page, quarantine).await
		}
		None => rest(path.to_string(), quarantine).await,
	}
}

/// REST's error (it carries Reddit's block-page wording) with the GraphQL one appended briefly;
/// a reason word the pages match on stays bare.
fn combined(rest_error: String, gql_error: &str) -> String {
	if REDDIT_REASONS.contains(&rest_error.as_str()) {
		return rest_error;
	}
	let brief: String = gql_error.chars().take(160).collect();
	format!("{rest_error} (GraphQL: {brief})")
}

#[cfg(test)]
mod tests {
	// Offline: the router driven by fake gql-fed and REST fetchers at explicit times (AGENTS.md "Test seams").

	use super::*;
	use crate::gql_fields::after_param;
	use serde_json::json;
	use std::sync::atomic::AtomicUsize;
	use std::sync::Mutex;

	const T0: u64 = 1_800_000_000;
	const FEED: &str = "/r/rust/hot.json?&raw_json=1";

	/// A fake source: answers with `answer` (Ok) or `Err(error)`, counting calls and keeping the
	/// last request it saw.
	struct Fake {
		answer: Result<Value, String>,
		calls: AtomicUsize,
		last: Mutex<Option<Value>>,
	}

	impl Fake {
		fn ok(answer: Value) -> Self {
			Self {
				answer: Ok(answer),
				calls: AtomicUsize::new(0),
				last: Mutex::new(None),
			}
		}

		fn failing(error: &str) -> Self {
			Self {
				answer: Err(error.to_string()),
				calls: AtomicUsize::new(0),
				last: Mutex::new(None),
			}
		}

		fn calls(&self) -> usize {
			self.calls.load(Ordering::SeqCst)
		}

		fn answer(&self, request: Value) -> Boxed<Result<Value, String>> {
			self.calls.fetch_add(1, Ordering::SeqCst);
			*self.last.lock().unwrap() = Some(request);
			let answer = self.answer.clone();
			async move { answer }.boxed()
		}
	}

	fn feed() -> Value {
		json!({ "data": { "postFeed": { "elements": { "edges": [{ "node": { "id": "t3_g" } }], "pageInfo": {} } } } })
	}

	fn rest_listing() -> Value {
		json!({ "kind": "Listing", "data": { "children": [{ "kind": "t3", "data": { "name": "t3_r" } }] } })
	}

	async fn read(path: &str, now: u64, breakers: &Breakers, gql: &Fake, rest: &Fake) -> Result<Value, String> {
		let gql_fetch = |body: Value| gql.answer(body);
		let rest_fetch = |path: String, _: bool| rest.answer(path.into());
		route(path, false, now, breakers, &gql_fetch, &rest_fetch).await
	}

	fn first_name(listing: &Value) -> &str {
		listing["data"]["children"][0]["data"]["name"].as_str().unwrap_or_default()
	}

	#[tokio::test]
	async fn graphql_answers_without_rest() {
		let (breakers, gql, rest) = (Breakers::new(), Fake::ok(feed()), Fake::ok(rest_listing()));
		let listing = read(FEED, T0, &breakers, &gql, &rest).await.unwrap();
		assert_eq!((first_name(&listing), gql.calls(), rest.calls()), ("t3_g", 1, 0));
	}

	#[tokio::test]
	async fn a_failure_sends_the_kind_to_rest_for_five_minutes() {
		let (breakers, gql, rest) = (
			Breakers::new(),
			Fake::failing("Reddit GraphQL SubredditFeedElements error: PersistedQueryNotFound"),
			Fake::ok(rest_listing()),
		);
		assert_eq!(first_name(&read(FEED, T0, &breakers, &gql, &rest).await.unwrap()), "t3_r");
		assert_eq!((gql.calls(), rest.calls()), (1, 1));
		assert_eq!(status_at(&breakers, T0)[0], ("listing", "REST until 08:05 UTC".to_string()));
		assert_eq!(status_at(&breakers, T0)[1], ("post", "GraphQL".to_string()));

		// Open: GraphQL is skipped, for this kind only
		read(FEED, T0 + 299, &breakers, &gql, &rest).await.unwrap();
		assert_eq!((gql.calls(), rest.calls()), (1, 2));
		read("/r/rust/about.json", T0 + 299, &breakers, &gql, &rest).await.unwrap();
		assert_eq!(gql.calls(), 2);

		// After five minutes GraphQL is tried again, and its success closes the breaker
		let healed = Fake::ok(feed());
		assert_eq!(first_name(&read(FEED, T0 + 300, &breakers, &healed, &rest).await.unwrap()), "t3_g");
		assert_eq!((healed.calls(), rest.calls()), (1, 3));
		assert_eq!(status_at(&breakers, T0 + 300)[0].1, "GraphQL");
		assert!(!breakers.close(Kind::Listing));
	}

	#[tokio::test]
	async fn rest_cursors_and_unplanned_paths_skip_graphql() {
		let (breakers, gql, rest) = (Breakers::new(), Fake::ok(feed()), Fake::ok(rest_listing()));
		read("/r/rust/hot.json?after=t3_abc", T0, &breakers, &gql, &rest).await.unwrap();
		read("/r/rust/wiki/index.json?raw_json=1", T0, &breakers, &gql, &rest).await.unwrap();
		assert_eq!((gql.calls(), rest.calls()), (0, 2));
		assert_eq!(*rest.last.lock().unwrap(), Some(json!("/r/rust/wiki/index.json?raw_json=1")));
	}

	#[tokio::test]
	async fn rest_drops_a_graphql_cursor_and_both_failures_combine() {
		let (breakers, gql, rest) = (Breakers::new(), Fake::failing("gql down"), Fake::failing("Reddit refused this request (403 block page)."));
		let next = format!("/r/rust/hot.json?after={}&raw_json=1", after_param("c"));
		let error = read(&next, T0, &breakers, &gql, &rest).await.unwrap_err();
		assert_eq!(error, "Reddit refused this request (403 block page). (GraphQL: gql down)");
		assert_eq!(*rest.last.lock().unwrap(), Some(json!("/r/rust/hot.json?raw_json=1")));
		// While open, REST's error is the whole answer
		assert_eq!(
			read(FEED, T0 + 1, &breakers, &gql, &rest).await.unwrap_err(),
			"Reddit refused this request (403 block page)."
		);
		assert_eq!(combined("quarantined".into(), "x"), "quarantined");
	}

	#[tokio::test]
	async fn refusals_answer_and_not_served_keeps_the_breaker_shut() {
		let breakers = Breakers::new();
		let rest = Fake::ok(rest_listing());
		let private = Fake::ok(json!({ "data": { "subredditInfoByName": { "__typename": "UnavailableSubreddit", "forbiddenReason": "PRIVATE" } } }));
		assert_eq!(read("/r/x/about.json", T0, &breakers, &private, &rest).await, Err("private".to_string()));
		assert_eq!(rest.calls(), 0);

		// A multireddit search failure is served by REST without opening the listing breaker
		read("/r/a+b/hot.json", T0, &breakers, &Fake::failing("too long"), &rest).await.unwrap();
		assert_eq!(rest.calls(), 1);
		assert!(breakers.allows(Kind::Listing, T0));
	}

	#[test]
	fn a_burst_of_failures_trips_once() {
		let breakers = Breakers::new();
		assert!(breakers.trip(Kind::Search, T0));
		assert!(!breakers.trip(Kind::Search, T0));
		assert!(!breakers.allows(Kind::Search, T0 + GQL_RETRY_AFTER - 1));
		assert!(breakers.allows(Kind::Search, T0 + GQL_RETRY_AFTER));
		// A failure after the window is a new switch
		assert!(breakers.trip(Kind::Search, T0 + GQL_RETRY_AFTER));
		assert!(breakers.close(Kind::Search));
		assert_eq!(breakers.open_until(Kind::Search, T0), None);
	}

	// Live: each kind through the real router (make test-live).

	async fn live(path: &str) -> Value {
		crate::oauth::init_oauth_client().await;
		json(path.to_string(), false).await.unwrap()
	}

	#[tokio::test(flavor = "multi_thread")]
	#[ignore = "hits live reddit"]
	async fn live_feed_post_about_user_and_search() {
		let feed = live("/r/pics/hot.json?&raw_json=1").await;
		assert!(!feed["data"]["children"].as_array().unwrap().is_empty());
		let id = feed["data"]["children"][0]["data"]["name"].as_str().unwrap().to_string();
		assert_eq!(first_name(&live(&format!("/by_id/{id}.json?raw_json=1")).await), id);
		assert_eq!(live("/r/rust/about.json?raw_json=1").await["data"]["display_name"], "rust");
		assert!(live("/user/spez/about.json?raw_json=1").await["data"]["total_karma"].as_i64().unwrap() > 100);
		assert!(!live("/search.json?q=rust&raw_json=1").await["data"]["children"].as_array().unwrap().is_empty());
		assert!(status().iter().all(|(_, source)| source == "GraphQL"));
	}
}
