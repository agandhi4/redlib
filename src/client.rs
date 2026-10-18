use crate::dbg_msg;
use crate::oauth::{exit_for_restart, force_refresh_token, refresh_blocked_token, token_daemon, MobileSpoofMinter, Oauth, TokenManager, FRESH_TOKEN_BUDGET};
use crate::reddit_response::{interpret_response, TokenAction};
use crate::swr_cache::SwrCache;
use crate::utils::{format_url, Post};
use arc_swap::ArcSwap;
use cached::proc_macro::cached;
use futures_lite::{future::Boxed, FutureExt};
use log::{info, trace, warn};
use percent_encoding::{percent_encode, CONTROLS};
use serde_json::Value;
use std::result::Result;
use std::sync::atomic::Ordering;
use std::sync::LazyLock;
use std::time::Duration;
use tokio::sync::OnceCell;
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
