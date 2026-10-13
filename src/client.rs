use crate::dbg_msg;
use crate::oauth::{exit_for_restart, force_refresh_token, refresh_blocked_token, token_daemon, MobileSpoofMinter, Oauth, TokenManager, FRESH_TOKEN_BUDGET};
use crate::server::RequestExt;
use crate::utils::{format_url, Post};
use arc_swap::ArcSwap;
use cached::proc_macro::cached;
use cached::{Cached, SizedCache};
use futures_lite::{future::Boxed, FutureExt};
use hyper::{header, Body, Request as HyperRequest, Response as HyperResponse};
use log::{debug, error, info, trace, warn};
use percent_encoding::{percent_encode, CONTROLS};
use serde_json::Value;
use std::collections::HashSet;
use std::fmt::Debug;
use std::future::Future;
use std::hash::Hash;
use std::result::Result;
use std::sync::atomic::Ordering;
use std::sync::{LazyLock, Mutex};
use std::time::Duration;
use tokio::sync::OnceCell;
use tokio::time::Instant;
use wreq::redirect::Policy;
use wreq::{header as wreq_header, Client as WreqClient, EmulationFactory, Method, Response as WreqResponse};
use wreq_util::{Emulation, EmulationOS, EmulationOption};

const REDDIT_URL_BASE: &str = "https://oauth.reddit.com";
const REDDIT_URL_BASE_HOST: &str = "oauth.reddit.com";

const REDDIT_SHORT_URL_BASE: &str = "https://redd.it";
const REDDIT_SHORT_URL_BASE_HOST: &str = "redd.it";

const ALTERNATIVE_REDDIT_URL_BASE: &str = "https://www.reddit.com";
const ALTERNATIVE_REDDIT_URL_BASE_HOST: &str = "www.reddit.com";

pub static CLIENT: LazyLock<WreqClient> = LazyLock::new(build_client);

// Populated once by `init_oauth_client()` at startup. This used to be a `LazyLock` whose
// initializer ran `futures_lite::block_on(Oauth::new())` from inside the tokio runtime; a
// nested foreign executor never resets tokio's cooperative budget, so on a slow/degraded
// network every timer and socket returned Pending+wake forever and the main thread spun at
// 100% CPU before the server ever listened (Sept 2026 outage). Bootstrapping must stay async.
static OAUTH_SESSION: OnceCell<TokenManager<MobileSpoofMinter>> = OnceCell::const_new();

/// Bootstraps the OAuth client and starts the token-refresh daemon. Must complete, inside the
/// tokio runtime, before anything calls `oauth_client()`. Idempotent: concurrent or repeated
/// calls (tests) share the first initialization. Exits the process if every mint attempt fails.
pub async fn init_oauth_client() {
	OAUTH_SESSION
		.get_or_init(|| async {
			let session = TokenManager::bootstrap(MobileSpoofMinter).await.unwrap_or_else(|e| exit_for_restart(&e));
			tokio::spawn(token_daemon());
			session
		})
		.await;
}

/// The live token manager: current token, request budget, rotation. Panics if
/// `init_oauth_client()` has not completed — that is a startup-ordering bug in `main`, never a
/// runtime condition.
pub(crate) fn oauth_session() -> &'static TokenManager<MobileSpoofMinter> {
	OAUTH_SESSION.get().expect("OAuth client used before init_oauth_client() completed")
}

/// The live OAuth client (token + spoofed device headers).
pub fn oauth_client() -> &'static ArcSwap<Oauth> {
	oauth_session().current()
}

const URL_PAIRS: [(&str, &str); 2] = [
	(ALTERNATIVE_REDDIT_URL_BASE, ALTERNATIVE_REDDIT_URL_BASE_HOST),
	(REDDIT_SHORT_URL_BASE, REDDIT_SHORT_URL_BASE_HOST),
];

pub fn build_client() -> WreqClient {
	// Keeping this list short to aid in privacy.
	// The more emulations, the more unique a fingerprint each instance has.
	// But some emulations should increase evasiveness.
	let emulation = [Emulation::Chrome145, Emulation::Firefox147];
	let emulation_os = [EmulationOS::Android, EmulationOS::Windows];

	let rand = fastrand::usize(..);
	let emulation = EmulationOption::builder()
		.emulation(emulation[rand % emulation.len()])
		.emulation_os(emulation_os[rand % emulation_os.len()])
		.build()
		.emulation();

	info!("Building Wreq client with random emulation {:?}", emulation);
	WreqClient::builder()
		.emulation(emulation)
		.redirect(Policy::none())
		.build()
		.expect("Should always be able to build a client")
}

/// Gets the canonical path for a resource on Reddit. This is accomplished by
/// making a `HEAD` request to Reddit at the path given in `path`.
///
/// This function returns `Ok(Some(path))`, where `path`'s value is identical
/// to that of the value of the argument `path`, if Reddit responds to our
/// `HEAD` request with a 2xx-family HTTP code. It will also return an
/// `Ok(Some(String))` if Reddit responds to our `HEAD` request with a
/// `Location` header in the response, and the HTTP code is in the 3xx-family;
/// the `String` will contain the path as reported in `Location`. The return
/// value is `Ok(None)` if Reddit responded with a 3xx, but did not provide a
/// `Location` header. An `Err(String)` is returned if Reddit responds with a
/// 429, or if we were unable to decode the value in the `Location` header.
#[cached(size = 1024, time = 600, result = true)]
#[async_recursion::async_recursion]
pub async fn canonical_path(path: String, tries: i8) -> Result<Option<String>, String> {
	if tries == 0 {
		return Ok(None);
	}

	// for each URL pair, try the HEAD request
	let res = {
		// for url base and host in URL_PAIRS, try reddit_short_head(path.clone(), true, url_base, url_base_host) and if it succeeds, set res. else, res = None
		let mut res = None;
		for (url_base, url_base_host) in URL_PAIRS {
			res = reddit_short_head(path.clone(), true, url_base, url_base_host).await.ok();
			if let Some(res) = &res {
				if !res.status().is_client_error() {
					break;
				}
			}
		}
		res
	};

	let res = res.ok_or_else(|| "Unable to make HEAD request to Reddit.".to_string())?;
	let status = res.status().as_u16();
	let policy_error = res.headers().get(wreq_header::RETRY_AFTER).is_some();

	match status {
		// If Reddit responds with a 2xx, then the path is already canonical.
		200..=299 => Ok(Some(path)),

		// If Reddit responds with a 301, then the path is redirected.
		301 => match res.headers().get(wreq_header::LOCATION) {
			Some(val) => {
				let Ok(original) = val.to_str() else {
					return Err("Unable to decode Location header.".to_string());
				};

				// We need to strip the .json suffix from the original path.
				// In addition, we want to remove share parameters.
				// Cut it off here instead of letting it propagate all the way
				// to main.rs
				let stripped_uri = original.strip_suffix(".json").unwrap_or(original).split('?').next().unwrap_or_default();

				// The reason why we now have to format_url, is because the new OAuth
				// endpoints seem to return full paths, instead of relative paths.
				// So we need to strip the .json suffix from the original path, and
				// also remove all Reddit domain parts with format_url.
				// Otherwise, it will literally redirect to Reddit.com.
				let uri = format_url(stripped_uri);

				// Decrement tries and try again
				canonical_path(uri, tries - 1).await
			}
			None => Ok(None),
		},

		// If Reddit responds with anything other than 3xx (except for the 2xx and 301
		// as above), return a None.
		300..=399 => Ok(None),

		// Rate limiting
		429 => Err("Too many requests.".to_string()),

		// Special condition rate limiting - https://github.com/redlib-org/redlib/issues/229
		403 if policy_error => Err("Too many requests.".to_string()),

		_ => Ok(
			res
				.headers()
				.get(wreq_header::LOCATION)
				.map(|val| percent_encode(val.as_bytes(), CONTROLS).to_string().trim_start_matches(REDDIT_URL_BASE).to_string()),
		),
	}
}

pub async fn proxy(req: HyperRequest<Body>, format: &str) -> Result<HyperResponse<Body>, String> {
	let mut url = format!("{format}?{}", req.uri().query().unwrap_or_default());

	// For each parameter in request
	for (name, value) in &req.params() {
		// Fill the parameter value in the url
		url = url.replace(&format!("{{{name}}}"), value);
	}

	// First parameter is target URL (mandatory).
	let wreq_uri = wreq::Uri::try_from(url.clone()).map_err(|_| "Couldn't parse URL".to_string())?;

	// Reddit's CDN intermittently drops connections (resets, HTTP/2 GOAWAY) under
	// concurrent load. Without a retry, each such drop renders as a permanently
	// blank image on the page, so retry transport errors and 5xx briefly.
	const MAX_ATTEMPTS: u32 = 3;
	let mut last_err = String::new();

	for attempt in 1..=MAX_ATTEMPTS {
		let mut builder = CLIENT.get(wreq_uri.clone());

		// Copy useful headers from original request
		for &key in &["Range", "If-Modified-Since", "Cache-Control"] {
			if let Some(value) = req.headers().get(key) {
				builder = builder.header(key, value.as_bytes());
			}
		}

		// Add User-Agent header of the currently spoofed device
		{
			let client = oauth_client().load_full();
			builder = builder.header("User-Agent", client.user_agent());
		}

		// This is needed or Reddit will redirect us to a /media landing page that just renders the image.
		builder = builder.header(wreq_header::ACCEPT, "*/*");

		match builder.send().await {
			// Retry CDN-side errors; pass the final attempt's response through unmodified.
			Ok(res) if res.status().is_server_error() && attempt < MAX_ATTEMPTS => {
				last_err = format!("upstream returned {}", res.status());
			}
			Ok(mut res) => {
				let headers = res.headers_mut();

				let mut rm = |key: &str| headers.remove(key);

				rm("access-control-expose-headers");
				rm("server");
				rm("vary");
				rm("etag");
				rm("x-cdn");
				rm("x-cdn-client-region");
				rm("x-cdn-name");
				rm("x-cdn-server-region");
				rm("x-reddit-cdn");
				rm("x-reddit-video-features");
				rm("Nel");
				rm("Report-To");

				return Ok(res.into_hyper_response());
			}
			Err(e) => {
				last_err = e.to_string();
			}
		}

		if attempt < MAX_ATTEMPTS {
			warn!("Proxy fetch for {url} failed (attempt {attempt}/{MAX_ATTEMPTS}): {last_err}");
			tokio::time::sleep(std::time::Duration::from_millis(250 * u64::from(attempt))).await;
		}
	}

	error!("Proxy fetch for {url} failed after {MAX_ATTEMPTS} attempts: {last_err}");
	Err(last_err)
}

/// Makes a GET request to Reddit at `path`. By default, this will honor HTTP
/// 3xx codes Reddit returns and will automatically redirect.
fn reddit_get(path: String, quarantine: bool) -> Boxed<Result<WreqResponse, String>> {
	request(&Method::GET, path, true, quarantine, REDDIT_URL_BASE, REDDIT_URL_BASE_HOST)
}

/// Makes a HEAD request to Reddit at `path, using the short URL base. This will not follow redirects.
fn reddit_short_head(path: String, quarantine: bool, base_path: &'static str, host: &'static str) -> Boxed<Result<WreqResponse, String>> {
	request(&Method::HEAD, path, false, quarantine, base_path, host)
}

// /// Makes a HEAD request to Reddit at `path`. This will not follow redirects.
// fn reddit_head(path: String, quarantine: bool) -> Boxed<Result<Response<Body>, String>> {
// 	request(&Method::HEAD, path, false, quarantine, false)
// }
// Unused - reddit_head is only ever called in the context of a short URL

/// Makes a request to Reddit. If `redirect` is `true`, `request_with_redirect`
/// will recurse on the URL that Reddit provides in the Location HTTP header
/// in its response.
fn request(method: &'static Method, path: String, redirect: bool, quarantine: bool, base_path: &'static str, host: &'static str) -> Boxed<Result<WreqResponse, String>> {
	// Build Reddit URL from path.
	let url = format!("{base_path}{path}");

	let mut headers: Vec<(String, String)> = vec![
		("Host".into(), host.into()),
		(
			"Cookie".into(),
			if quarantine {
				"_options=%7B%22pref_quarantine_optin%22%3A%20true%2C%20%22pref_gated_sr_optin%22%3A%20true%7D".into()
			} else {
				"".into()
			},
		),
	];

	{
		let client = oauth_client().load_full();
		for (key, value) in client.headers_map.clone() {
			headers.push((key, value));
		}
	}

	// shuffle headers: https://github.com/redlib-org/redlib/issues/324
	fastrand::shuffle(&mut headers);

	let mut builder = CLIENT.request(method.clone(), &url);

	for (key, value) in headers {
		builder = builder.header(key, value);
	}

	async move {
		match builder.send().await {
			Ok(response) => {
				// Reddit may respond with a 3xx. Decide whether or not to
				// redirect based on caller params.
				if response.status().is_redirection() {
					if !redirect {
						return Ok(response);
					};
					let location_header = response.headers().get(wreq::header::LOCATION);
					if location_header.and_then(|h| h.to_str().ok()) == Some(ALTERNATIVE_REDDIT_URL_BASE) {
						return Err("Reddit response was invalid".to_string());
					}
					return request(
						method,
						location_header
							.map(|val| {
								// We need to make adjustments to the URI
								// we get back from Reddit. Namely, we
								// must:
								//
								//     1. Remove the authority (e.g.
								//     https://www.reddit.com) that may be
								//     present, so that we recurse on the
								//     path (and query parameters) as
								//     required.
								//
								//     2. Percent-encode the path.
								let new_path = percent_encode(val.as_bytes(), CONTROLS)
									.to_string()
									.trim_start_matches(REDDIT_URL_BASE)
									.trim_start_matches(ALTERNATIVE_REDDIT_URL_BASE)
									.to_string();
								format!("{new_path}{}raw_json=1", if new_path.contains('?') { "&" } else { "?" })
							})
							.unwrap_or_default()
							.to_string(),
						true,
						quarantine,
						base_path,
						host,
					)
					.await;
				};

				Ok(response)
			}
			Err(e) => {
				dbg_msg!("{method} {REDDIT_URL_BASE}{path}: {}", e);

				Err(e.to_string())
			}
		}
	}
	.boxed()
}

/// Stale-while-revalidate cache. A hit younger than `fresh` is served as-is; one older than that
/// (up to `stale_max`) is served immediately while a single background refresh replaces it, so a
/// revisit within the window never waits on the fetch. Only Ok results are cached; values are
/// cloned on hit. The fetch function is the test seam: `json()` passes `fetch_json` (live Reddit),
/// the offline tests pass a fake. Ages use tokio's clock so tests can pause and advance it.
pub(crate) struct SwrCache<K, V> {
	fresh: Duration,
	stale_max: Duration,
	entries: Mutex<SizedCache<K, (Instant, V)>>,
	// Keys with a background refresh in flight, so a burst of stale hits spawns one fetch.
	refreshing: Mutex<HashSet<K>>,
}

impl<K, V> SwrCache<K, V>
where
	K: Hash + Eq + Clone + Debug + Send + 'static,
	V: Clone + Send + 'static,
{
	pub(crate) fn new(size: usize, fresh: Duration, stale_max: Duration) -> Self {
		Self {
			fresh,
			stale_max,
			entries: Mutex::new(SizedCache::with_size(size)),
			refreshing: Mutex::new(HashSet::new()),
		}
	}

	/// `&'static self` because a stale hit spawns a refresh task that outlives the call.
	pub(crate) async fn get<F, Fut>(&'static self, key: K, fetch: F) -> Result<V, String>
	where
		F: FnOnce(K) -> Fut + Send + 'static,
		Fut: Future<Output = Result<V, String>> + Send + 'static,
	{
		let hit = {
			let mut entries = self.entries.lock().unwrap();
			match entries.cache_get(&key).map(|(fetched_at, value)| (fetched_at.elapsed(), value.clone())) {
				Some((age, _)) if age > self.stale_max => {
					entries.cache_remove(&key);
					None
				}
				hit => hit,
			}
		};
		if let Some((age, value)) = hit {
			if age > self.fresh {
				debug!("Serving stale entry ({}s old) and refreshing: {key:?}", age.as_secs());
				self.spawn_refresh(key, fetch);
			}
			return Ok(value);
		}
		// Cold misses are not single-flighted: two simultaneous first requests for one key both
		// go upstream. Rare for one user, and the cost is a duplicate request, not a wrong answer.
		let value = fetch(key.clone()).await?;
		self.entries.lock().unwrap().cache_set(key, (Instant::now(), value.clone()));
		Ok(value)
	}

	fn spawn_refresh<F, Fut>(&'static self, key: K, fetch: F)
	where
		F: FnOnce(K) -> Fut + Send + 'static,
		Fut: Future<Output = Result<V, String>> + Send + 'static,
	{
		if !self.refreshing.lock().unwrap().insert(key.clone()) {
			return;
		}
		tokio::spawn(async move {
			match fetch(key.clone()).await {
				Ok(value) => {
					self.entries.lock().unwrap().cache_set(key.clone(), (Instant::now(), value));
				}
				// Keep serving the stale copy; it ages out at stale_max on its own.
				Err(e) => warn!("Background refresh failed for {key:?}: {e}"),
			}
			self.refreshing.lock().unwrap().remove(&key);
		});
	}
}

// Reddit JSON cache: fresh 30s, then stale-while-revalidate up to 5 minutes. Worst case ~100
// thread JSONs (~1MB each) resident for 5 minutes.
const JSON_FRESH: Duration = Duration::from_secs(30);
const JSON_STALE_MAX: Duration = Duration::from_secs(300);
type JsonKey = (String, bool);
static JSON_CACHE: LazyLock<SwrCache<JsonKey, Value>> = LazyLock::new(|| SwrCache::new(100, JSON_FRESH, JSON_STALE_MAX));

/// Make a request to a Reddit API and parse the JSON response, through the
/// stale-while-revalidate cache above.
pub async fn json(path: String, quarantine: bool) -> Result<Value, String> {
	JSON_CACHE.get((path, quarantine), |(path, quarantine)| fetch_json(path, quarantine)).await
}

/// What `fetch_json` must do to the token after a response, as decided by `interpret_response`.
#[derive(Debug, PartialEq, Eq)]
enum TokenAction {
	None,
	/// Empty body: the token's budget is spent. Rotate without holding up this request.
	RotateInBackground,
	/// JSON 401 "Unauthorized": the token expired. Rotate before answering.
	Rotate,
	/// Non-JSON 403: Reddit's network-policy block page for a flagged token/device pair.
	RotateBlocked,
}

/// Fetch and parse one Reddit JSON document. Uncached; every caller goes through `json()`.
async fn fetch_json(path: String, quarantine: bool) -> Result<Value, String> {
	let session = oauth_session();

	// First, handle rolling over the OAuth client if need be.
	let current_rate_limit = session.ratelimit_remaining().load(Ordering::SeqCst);
	let is_rolling_over = session.is_rolling_over();
	if current_rate_limit < 10 && !is_rolling_over {
		warn!("Rate limit {current_rate_limit} is low. Spawning force_refresh_token()");
		tokio::spawn(force_refresh_token());
	}
	session.ratelimit_remaining().fetch_sub(1, Ordering::SeqCst);

	// Fetch the url...
	let response = match reddit_get(path.clone(), quarantine).await {
		Ok(response) => response,
		Err(e) => return Err(format!("Couldn't send request to Reddit: {e} | {path}")),
	};
	let status = response.status().as_u16();

	let reset: Option<String> = if let (Some(remaining), Some(reset), Some(used)) = (
		response.headers().get("x-ratelimit-remaining").and_then(|val| val.to_str().ok().map(|s| s.to_string())),
		response.headers().get("x-ratelimit-reset").and_then(|val| val.to_str().ok().map(|s| s.to_string())),
		response.headers().get("x-ratelimit-used").and_then(|val| val.to_str().ok().map(|s| s.to_string())),
	) {
		trace!(
			"Ratelimit remaining: Header says {remaining}, we have {current_rate_limit}. Resets in {reset}. Rollover: {}. Ratelimit used: {used}",
			if is_rolling_over { "yes" } else { "no" },
		);

		// If can parse remaining as a float, round to a u16 and save
		if let Ok(val) = remaining.parse::<f32>() {
			session.ratelimit_remaining().store(val.round() as u16, Ordering::SeqCst);
		}

		Some(reset)
	} else {
		None
	};

	let body = match response.bytes().await {
		Ok(body) => body,
		Err(e) => return Err(format!("Failed receiving body from Reddit: {e} | {path}")),
	};

	let (result, action) = interpret_response(status, &body, reset.as_deref(), &path);
	match action {
		TokenAction::None => {}
		TokenAction::RotateInBackground => {
			tokio::spawn(force_refresh_token());
		}
		TokenAction::Rotate => force_refresh_token().await,
		TokenAction::RotateBlocked => refresh_blocked_token().await,
	}
	result
}

/// Classify one Reddit response: the caller's result, and what must happen to the token. Pure, so
/// the rotation triggers (401, non-JSON 403, empty body) are tested offline.
fn interpret_response(status: u16, body: &[u8], ratelimit_reset: Option<&str>, path: &str) -> (Result<Value, String>, TokenAction) {
	if body.is_empty() {
		let msg = match ratelimit_reset {
			Some(val) => format!(
				"Reddit rate limit exceeded. Try refreshing in a few seconds.\
				 Rate limit will reset in: {val}"
			),
			None => "Reddit rate limit exceeded".to_string(),
		};
		return (Err(msg), TokenAction::RotateInBackground);
	}

	let json: Value = match serde_json::from_slice(body) {
		Ok(json) => json,
		Err(e) => {
			error!("Got an invalid response from reddit {e}. Status code: {status}");
			return if status == 403 {
				(
					Err("Reddit blocked this session. A new one was issued; refresh the page.".to_string()),
					TokenAction::RotateBlocked,
				)
			} else if (500..600).contains(&status) {
				(Err("Reddit is having issues, check if there's an outage".to_string()), TokenAction::None)
			} else {
				(Err(format!("Failed to parse page JSON data: {e} | {path}")), TokenAction::None)
			};
		}
	};

	// If user is suspended
	if json["data"]["is_suspended"].as_bool() == Some(true) {
		return (Err("suspended".into()), TokenAction::None);
	}

	// Reddit returned an API error
	if json["error"].is_i64() {
		// OAuth token has expired; http status 401
		if json["message"] == "Unauthorized" {
			error!("Forcing a token refresh");
			return (Err("OAuth token has expired. Please refresh the page!".to_string()), TokenAction::Rotate);
		}
		for reason in ["quarantined", "gated", "private", "banned"] {
			if json["reason"] == reason {
				return (Err(reason.into()), TokenAction::None);
			}
		}
		return (
			Err(format!("Reddit error {} \"{}\": {} | {path}", json["error"], json["reason"], json["message"])),
			TokenAction::None,
		);
	}

	(Ok(json), TokenAction::None)
}

async fn self_check(sub: &str) -> Result<(), String> {
	let query = format!("/r/{sub}/hot.json?&raw_json=1");

	match Post::fetch(&query, true).await {
		Ok(_) => Ok(()),
		Err(e) => Err(e),
	}
}

pub async fn rate_limit_check() -> Result<(), String> {
	// First, check a subreddit.
	self_check("reddit").await?;
	// This will reduce the rate limit to 99. Assert this check.
	let remaining = oauth_session().ratelimit_remaining();
	if remaining.load(Ordering::SeqCst) != FRESH_TOKEN_BUDGET {
		return Err(format!(
			"Rate limit check 1 failed: expected {FRESH_TOKEN_BUDGET}, got {}",
			remaining.load(Ordering::SeqCst)
		));
	}
	// Now, we switch out the OAuth client.
	// This checks for the IP rate limit association.
	force_refresh_token().await;
	// Now, check a new sub to break cache.
	self_check("rust").await?;
	// Again, assert the rate limit check.
	if remaining.load(Ordering::SeqCst) != FRESH_TOKEN_BUDGET {
		return Err(format!(
			"Rate limit check 2 failed: expected {FRESH_TOKEN_BUDGET}, got {}",
			remaining.load(Ordering::SeqCst)
		));
	}

	Ok(())
}

trait IntoHyperResponse {
	fn into_hyper_response(self) -> HyperResponse<Body>;
}

impl IntoHyperResponse for WreqResponse {
	fn into_hyper_response(self) -> HyperResponse<Body> {
		let status = self.status();
		let version = self.version();

		let mut builder = HyperResponse::builder().status(status.as_u16()).version(match version {
			wreq::Version::HTTP_09 => hyper::Version::HTTP_09,
			wreq::Version::HTTP_10 => hyper::Version::HTTP_10,
			wreq::Version::HTTP_11 => hyper::Version::HTTP_11,
			wreq::Version::HTTP_2 => hyper::Version::HTTP_2,
			wreq::Version::HTTP_3 => hyper::Version::HTTP_3,
			_ => hyper::Version::HTTP_11,
		});

		for (name, value) in self.headers() {
			builder = builder.header(
				header::HeaderName::from_bytes(name.as_str().as_bytes()).unwrap(),
				header::HeaderValue::from_bytes(value.as_bytes()).unwrap(),
			);
		}

		builder.body(Body::wrap_stream(self.bytes_stream())).unwrap()
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use {crate::config::get_setting, sealed_test::prelude::*};

	const POPULAR_URL: &str = "/r/popular/hot.json?&raw_json=1&geo_filter=GLOBAL";

	#[tokio::test(flavor = "multi_thread")]
	#[ignore = "hits live reddit"]
	async fn test_rate_limit_check() {
		init_oauth_client().await;
		// The check asserts a fresh token's budget (99); other tests in this process share the
		// client and have already spent some, so refresh first — matches main's ordering.
		force_refresh_token().await;
		rate_limit_check().await.unwrap();
	}

	#[test]
	#[ignore = "hits live reddit"]
	#[sealed_test(env = [("REDLIB_DEFAULT_SUBSCRIPTIONS", "rust")])]
	fn test_default_subscriptions() {
		tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap().block_on(async {
			let subscriptions = get_setting("REDLIB_DEFAULT_SUBSCRIPTIONS");
			assert!(subscriptions.is_some());

			// check rate limit
			init_oauth_client().await;
			force_refresh_token().await;
			rate_limit_check().await.unwrap();
		});
	}

	#[tokio::test(flavor = "multi_thread")]
	#[ignore = "hits live reddit"]
	async fn test_localization_popular() {
		init_oauth_client().await;
		let val = json(POPULAR_URL.to_string(), false).await.unwrap();
		assert_eq!("GLOBAL", val["data"]["geo_filter"].as_str().unwrap());
	}

	#[tokio::test(flavor = "multi_thread")]
	#[ignore = "hits live reddit"]
	async fn test_obfuscated_share_link() {
		init_oauth_client().await;
		let share_link = "/r/rust/s/kPgq8WNHRK".into();
		// Correct link without share parameters
		let canonical_link = "/r/rust/comments/18t5968/why_use_tuple_struct_over_standard_struct/kfbqlbc/".into();
		assert_eq!(canonical_path(share_link, 3).await, Ok(Some(canonical_link)));
	}

	#[tokio::test(flavor = "multi_thread")]
	#[ignore = "hits live reddit"]
	async fn test_private_sub() {
		init_oauth_client().await;
		let link = json("/r/suicide/about.json?raw_json=1".into(), true).await;
		assert!(link.is_err());
		assert_eq!(link, Err("private".into()));
	}

	#[tokio::test(flavor = "multi_thread")]
	#[ignore = "hits live reddit"]
	async fn test_banned_sub() {
		init_oauth_client().await;
		let link = json("/r/aaa/about.json?raw_json=1".into(), true).await;
		assert!(link.is_err());
		assert_eq!(link, Err("banned".into()));
	}

	// Offline: the SWR cache driven by a fake fetch on a paused clock (AGENTS.md "Test seams").

	use serde_json::json;
	use std::sync::atomic::AtomicUsize;
	use std::sync::Arc;
	use tokio::sync::Notify;

	const FRESH: Duration = Duration::from_secs(30);
	const STALE_MAX: Duration = Duration::from_secs(300);

	/// The cache's refresh task needs `&'static`; each test gets its own, leaked for the process.
	fn cache() -> &'static SwrCache<&'static str, usize> {
		Box::leak(Box::new(SwrCache::new(10, FRESH, STALE_MAX)))
	}

	/// A fetch that returns how many times it has been called (1, 2, ...).
	fn counting(calls: &Arc<AtomicUsize>) -> impl FnOnce(&'static str) -> Boxed<Result<usize, String>> {
		let calls = calls.clone();
		move |_| async move { Ok(calls.fetch_add(1, Ordering::SeqCst) + 1) }.boxed()
	}

	fn failing(calls: &Arc<AtomicUsize>) -> impl FnOnce(&'static str) -> Boxed<Result<usize, String>> {
		let calls = calls.clone();
		move |_| {
			async move {
				calls.fetch_add(1, Ordering::SeqCst);
				Err("upstream down".to_string())
			}
			.boxed()
		}
	}

	/// Let spawned refresh tasks run to completion: with the clock paused, a sleep only returns
	/// once every other task is idle.
	async fn settle() {
		tokio::time::sleep(Duration::from_millis(1)).await;
	}

	#[tokio::test(start_paused = true)]
	async fn swr_fresh_hit_skips_the_fetch() {
		let (cache, calls) = (cache(), Arc::new(AtomicUsize::new(0)));
		assert_eq!(cache.get("k", counting(&calls)).await, Ok(1));
		tokio::time::advance(FRESH - Duration::from_secs(1)).await;
		assert_eq!(cache.get("k", counting(&calls)).await, Ok(1));
		settle().await;
		assert_eq!(calls.load(Ordering::SeqCst), 1);
	}

	#[tokio::test(start_paused = true)]
	async fn swr_stale_hit_serves_stale_then_refreshes() {
		let (cache, calls) = (cache(), Arc::new(AtomicUsize::new(0)));
		cache.get("k", counting(&calls)).await.unwrap();
		tokio::time::advance(FRESH + Duration::from_secs(1)).await;

		assert_eq!(cache.get("k", counting(&calls)).await, Ok(1), "stale value served without waiting");
		settle().await;
		assert_eq!(calls.load(Ordering::SeqCst), 2, "one background refresh");
		assert_eq!(cache.get("k", counting(&calls)).await, Ok(2), "refreshed value replaces the stale one");
		settle().await;
		assert_eq!(calls.load(Ordering::SeqCst), 2, "the refreshed entry is fresh again");
	}

	#[tokio::test(start_paused = true)]
	async fn swr_concurrent_stale_hits_refresh_once() {
		let (cache, calls) = (cache(), Arc::new(AtomicUsize::new(0)));
		cache.get("k", counting(&calls)).await.unwrap();
		tokio::time::advance(FRESH + Duration::from_secs(1)).await;

		// The refresh parks on a gate so every hit below lands while it is in flight.
		let gate = Arc::new(Notify::new());
		for _ in 0..5 {
			let (gate, calls) = (gate.clone(), calls.clone());
			let held = move |_| {
				async move {
					gate.notified().await;
					Ok(calls.fetch_add(1, Ordering::SeqCst) + 1)
				}
				.boxed()
			};
			assert_eq!(cache.get("k", held).await, Ok(1));
		}
		gate.notify_one();
		settle().await;
		// A second refresh would still be parked on the gate, uncounted; this catches it.
		assert_eq!(cache.refreshing.lock().unwrap().len(), 0, "no refresh left in flight");
		assert_eq!(calls.load(Ordering::SeqCst), 2, "five stale hits, one refresh");
		assert_eq!(cache.get("k", counting(&calls)).await, Ok(2));
	}

	#[tokio::test(start_paused = true)]
	async fn swr_failed_refresh_keeps_the_stale_copy_and_retries() {
		let (cache, calls) = (cache(), Arc::new(AtomicUsize::new(0)));
		cache.get("k", counting(&calls)).await.unwrap();
		tokio::time::advance(FRESH + Duration::from_secs(1)).await;

		assert_eq!(cache.get("k", failing(&calls)).await, Ok(1));
		settle().await;
		assert_eq!(cache.get("k", counting(&calls)).await, Ok(1), "still the stale copy");
		settle().await;
		assert_eq!(calls.load(Ordering::SeqCst), 3, "the failed refresh released its slot, so the next stale hit refreshed");
		assert_eq!(cache.get("k", counting(&calls)).await, Ok(3));
	}

	#[tokio::test(start_paused = true)]
	async fn swr_expired_entry_is_a_miss() {
		let (cache, calls) = (cache(), Arc::new(AtomicUsize::new(0)));
		cache.get("k", counting(&calls)).await.unwrap();
		tokio::time::advance(STALE_MAX + Duration::from_secs(1)).await;
		assert_eq!(cache.get("k", counting(&calls)).await, Ok(2), "past stale_max the caller waits for a fresh fetch");
	}

	#[tokio::test(start_paused = true)]
	async fn swr_errors_are_not_cached() {
		let (cache, calls) = (cache(), Arc::new(AtomicUsize::new(0)));
		assert_eq!(cache.get("k", failing(&calls)).await, Err("upstream down".to_string()));
		assert_eq!(cache.get("k", counting(&calls)).await, Ok(2));
	}

	#[tokio::test(start_paused = true)]
	async fn swr_keys_are_independent() {
		let (cache, calls) = (cache(), Arc::new(AtomicUsize::new(0)));
		assert_eq!(cache.get("a", counting(&calls)).await, Ok(1));
		assert_eq!(cache.get("b", counting(&calls)).await, Ok(2));
		assert_eq!(cache.get("a", counting(&calls)).await, Ok(1));
	}

	// Offline: response classification, which decides when fetch_json rotates the token.

	fn interpret(status: u16, body: &str) -> (Result<Value, String>, TokenAction) {
		interpret_response(status, body.as_bytes(), None, "/r/rust.json")
	}

	#[test]
	fn interpret_ok_json_passes_through() {
		assert_eq!(interpret(200, r#"{"data":{"x":1}}"#), (Ok(json!({"data": {"x": 1}})), TokenAction::None));
	}

	#[test]
	fn interpret_expired_token_rotates_before_answering() {
		let (result, action) = interpret(401, r#"{"message":"Unauthorized","error":401}"#);
		assert_eq!(result, Err("OAuth token has expired. Please refresh the page!".to_string()));
		assert_eq!(action, TokenAction::Rotate);
	}

	#[test]
	fn interpret_html_403_rotates_the_blocked_token() {
		let (result, action) = interpret(403, "<html><body>whoa there, pardner!</body></html>");
		assert_eq!(result, Err("Reddit blocked this session. A new one was issued; refresh the page.".to_string()));
		assert_eq!(action, TokenAction::RotateBlocked);
	}

	#[test]
	fn interpret_json_403_is_an_api_error_not_a_block() {
		let (result, action) = interpret(403, r#"{"error":403,"reason":"private","message":"Forbidden"}"#);
		assert_eq!((result, action), (Err("private".to_string()), TokenAction::None));
	}

	#[test]
	fn interpret_empty_body_is_a_spent_budget() {
		let (result, action) = interpret_response(200, b"", Some("42"), "/r/rust.json");
		assert!(result.unwrap_err().ends_with("Rate limit will reset in: 42"));
		assert_eq!(action, TokenAction::RotateInBackground);
	}

	#[test]
	fn interpret_non_json_errors_do_not_touch_the_token() {
		assert_eq!(interpret(502, "<html>bad gateway</html>").1, TokenAction::None);
		assert_eq!(
			interpret(502, "<html>bad gateway</html>").0,
			Err("Reddit is having issues, check if there's an outage".to_string())
		);
		let (result, action) = interpret(200, "not json");
		assert!(result.unwrap_err().starts_with("Failed to parse page JSON data"));
		assert_eq!(action, TokenAction::None);
	}

	#[test]
	fn interpret_named_reasons_and_suspension() {
		for reason in ["quarantined", "gated", "private", "banned"] {
			let body = format!(r#"{{"error":403,"reason":"{reason}","message":"Forbidden"}}"#);
			assert_eq!(interpret(403, &body), (Err(reason.to_string()), TokenAction::None));
		}
		assert_eq!(interpret(200, r#"{"data":{"is_suspended":true}}"#).0, Err("suspended".to_string()));
		assert_eq!(
			interpret(404, r#"{"error":404,"message":"Not Found"}"#).0,
			Err(r#"Reddit error 404 "null": "Not Found" | /r/rust.json"#.to_string())
		);
	}

	#[tokio::test(flavor = "multi_thread")]
	#[ignore = "hits live reddit"]
	async fn test_gated_sub() {
		init_oauth_client().await;
		// quarantine to false to specifically catch when we _don't_ catch it
		let link = json("/r/drugs/about.json?raw_json=1".into(), false).await;
		assert!(link.is_err());
		assert_eq!(link, Err("gated".into()));
	}
}
