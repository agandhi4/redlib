use crate::oauth_device::{AuthError, MobileSpoofAuth, OauthBackend};
use arc_swap::ArcSwap;
use log::{error, info, trace, warn};
use std::{
	collections::HashMap,
	future::Future,
	sync::{
		atomic::{AtomicBool, AtomicU16, Ordering},
		Arc,
	},
	time::{Duration, Instant},
};
use tokio::sync::OnceCell;
use tokio::time::{error::Elapsed, timeout};

const OAUTH_MAX_ATTEMPTS: u32 = 10;
const OAUTH_TIMEOUT: Duration = Duration::from_secs(5);

// A token younger than this is never rotated for being blocked: if a fresh token is
// refused too, the block is on the IP, and minting more would only hammer the auth endpoint.
const BLOCKED_TOKEN_REFRESH_COOLDOWN: Duration = Duration::from_secs(60);

// Requests a freshly minted token may make before `client::fetch_json` rolls it over early.
// `startup_check::rate_limit_check` asserts a fresh token reports exactly this after one request.
pub(crate) const FRESH_TOKEN_BUDGET: u16 = 99;

// The daemon rotates this long before expiry, but never sooner than the floor after a mint, so a
// short or zero `expires_in` from Reddit cannot turn the daemon into a mint loop.
const TOKEN_REFRESH_MARGIN: Duration = Duration::from_secs(120);
const TOKEN_REFRESH_FLOOR: Duration = Duration::from_secs(60);

// Spoofed client for Android devices
#[derive(Debug, Clone)]
pub struct Oauth {
	pub(crate) headers_map: HashMap<String, String>,
	expires_in: u64,
	minted_at: Instant,
	pub(crate) backend: MobileSpoofAuth,
}

impl Oauth {
	/// Mint a token for one spoofed Android device, retried up to OAUTH_MAX_ATTEMPTS times; Err
	/// once they are spent. Callers in production exit on Err (see `exit_for_restart`).
	async fn mint_mobile_spoof() -> Result<Self, String> {
		// (Upstream also carries a GenericWebAuth fallback; Reddit answers 401 to its
		// hardcoded client id, in upstream too, so it was removed here — see docs/fork.md.)
		let backend = MobileSpoofAuth::new();

		for attempt in 1..=OAUTH_MAX_ATTEMPTS {
			match Self::new_with_timeout_with_backend(backend.clone()).await {
				Ok(Ok(oauth)) => {
					info!("[✅] Successfully created OAuth client");
					return Ok(oauth);
				}
				Ok(Err(e)) => {
					error!(
						"[⛔] Failed to create OAuth client (attempt {attempt}/{OAUTH_MAX_ATTEMPTS}): {}",
						match e {
							AuthError::Wreq(error) => error.to_string(),
							AuthError::SerdeDeserialize(error) => error.to_string(),
							AuthError::Field((value, error)) => format!("{error}\n{value}"),
						}
					);
				}
				Err(_) => {
					error!("[⛔] Failed to create OAuth client before timeout (attempt {attempt}/{OAUTH_MAX_ATTEMPTS})");
				}
			}

			if attempt < OAUTH_MAX_ATTEMPTS {
				tokio::time::sleep(OAUTH_TIMEOUT).await;
			}
		}

		Err(format!("Failed to create OAuth client after {OAUTH_MAX_ATTEMPTS} attempts"))
	}

	async fn new_with_timeout_with_backend(mut backend: MobileSpoofAuth) -> Result<Result<Self, AuthError>, Elapsed> {
		timeout(OAUTH_TIMEOUT, async move {
			let response = backend.authenticate().await?;

			// Build headers_map from backend headers + Authorization header
			let mut headers_map = backend.get_headers();
			headers_map.insert("Authorization".to_owned(), format!("Bearer {}", response.token));
			headers_map.extend(response.additional_headers);

			Ok(Self {
				headers_map,
				expires_in: response.expires_in,
				minted_at: Instant::now(),
				backend,
			})
		})
		.await
	}

	pub fn user_agent(&self) -> &str {
		self.backend.user_agent()
	}
}

/// The test seam for token rotation: one complete mint (retries included), the only network call
/// `TokenManager` makes. Production uses `MobileSpoofMinter`; the offline tests below use a fake.
pub(crate) trait Minter: Send + Sync + 'static {
	fn mint(&self) -> impl Future<Output = Result<Oauth, String>> + Send;
}

/// Production minter: a spoofed Android device against Reddit's auth endpoint.
pub(crate) struct MobileSpoofMinter;

impl Minter for MobileSpoofMinter {
	fn mint(&self) -> impl Future<Output = Result<Oauth, String>> + Send {
		Oauth::mint_mobile_spoof()
	}
}

/// What a rotation request did. Production logs it (and exits on `Failed`); tests assert it.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Rotation {
	Rotated,
	/// Another caller is mid-mint; this one returned at once without minting.
	AlreadyRotating,
	/// A blocked-token rotation was refused: the current token is younger than the cooldown.
	CoolingDown,
	/// Every mint attempt failed. The current token is unchanged and the next rotation may retry.
	Failed(String),
}

/// Owns the live token and every rule for replacing it: single-flight rotation, the per-token
/// request budget, and the blocked-token cooldown. One process-wide instance lives behind
/// `oauth_session()`; tests build their own over a fake `Minter`.
pub(crate) struct TokenManager<M> {
	current: ArcSwap<Oauth>,
	rolling_over: AtomicBool,
	ratelimit_remaining: AtomicU16,
	minter: M,
}

impl<M: Minter> TokenManager<M> {
	pub(crate) async fn bootstrap(minter: M) -> Result<Self, String> {
		let first = minter.mint().await?;
		Ok(Self {
			current: ArcSwap::from_pointee(first),
			rolling_over: AtomicBool::new(false),
			ratelimit_remaining: AtomicU16::new(FRESH_TOKEN_BUDGET),
			minter,
		})
	}

	pub(crate) fn current(&self) -> &ArcSwap<Oauth> {
		&self.current
	}

	/// Remaining request budget for the current token, per Reddit's `x-ratelimit-remaining`.
	pub(crate) fn ratelimit_remaining(&self) -> &AtomicU16 {
		&self.ratelimit_remaining
	}

	pub(crate) fn is_rolling_over(&self) -> bool {
		self.rolling_over.load(Ordering::SeqCst)
	}

	/// Mint a new token/device pair and swap it in. Single-flight: a call while another is
	/// minting returns `AlreadyRotating` instead of minting twice.
	pub(crate) async fn rotate(&self) -> Rotation {
		if self.rolling_over.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst).is_err() {
			trace!("Skipping refresh token roll over, already in progress");
			return Rotation::AlreadyRotating;
		}
		// Clears the flag even if this future is dropped mid-mint (a request whose client went
		// away). Without it the flag stayed set forever and no token was ever rotated again.
		let _guard = RollingOverGuard(&self.rolling_over);

		trace!("Rolling over refresh token. Current rate limit: {}", self.ratelimit_remaining.load(Ordering::SeqCst));
		match self.minter.mint().await {
			Ok(new_client) => {
				self.current.store(Arc::new(new_client));
				self.ratelimit_remaining.store(FRESH_TOKEN_BUDGET, Ordering::SeqCst);
				info!("[🔄] OAuth token rotated");
				Rotation::Rotated
			}
			Err(e) => Rotation::Failed(e),
		}
	}

	/// Reddit sometimes flags a long-lived token/device pair and answers every request with a
	/// 403 HTML "blocked due to a network policy" page, while a freshly minted pair from the same
	/// IP works (Oct 2026). Rotating both here is what a container restart used to do by hand.
	pub(crate) async fn rotate_blocked(&self) -> Rotation {
		let age = self.current.load().minted_at.elapsed();
		if age < BLOCKED_TOKEN_REFRESH_COOLDOWN {
			warn!("[🚫] Reddit blocked a token minted {age:?} ago; not rotating again yet (possible IP-level block)");
			return Rotation::CoolingDown;
		}
		warn!("[🚫] Reddit blocked the current token (minted {age:?} ago). Rotating token and device...");
		self.rotate().await
	}
}

struct RollingOverGuard<'a>(&'a AtomicBool);

impl Drop for RollingOverGuard<'_> {
	fn drop(&mut self) {
		self.0.store(false, Ordering::SeqCst);
	}
}

/// How long the daemon waits before rotating a token that expires in `expires_in` seconds.
fn refresh_delay(expires_in: u64) -> Duration {
	Duration::from_secs(expires_in).saturating_sub(TOKEN_REFRESH_MARGIN).max(TOKEN_REFRESH_FLOOR)
}

/// Production policy for a mint that exhausted its retries, at bootstrap and on rotation alike:
/// exit and let the container restart policy take over (AGENTS.md "Startup order").
pub(crate) fn exit_for_restart(reason: &str) -> ! {
	error!("[⛔] {reason}; exiting for the restart policy");
	std::process::exit(1);
}

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

fn exit_on_failed_mint(outcome: Rotation) {
	if let Rotation::Failed(e) = outcome {
		exit_for_restart(&e);
	}
}

pub async fn token_daemon() {
	loop {
		let duration = refresh_delay(oauth_session().current().load().expires_in);

		info!("[⏳] Waiting for {duration:?} seconds before refreshing OAuth token...");

		tokio::time::sleep(duration).await;

		info!("[⌛] {duration:?} Elapsed! Refreshing OAuth token...");

		force_refresh_token().await;
	}
}

pub async fn force_refresh_token() {
	exit_on_failed_mint(oauth_session().rotate().await);
}

/// Used by `client::fetch_json` on a non-JSON 403; see `TokenManager::rotate_blocked`.
pub async fn refresh_blocked_token() {
	exit_on_failed_mint(oauth_session().rotate_blocked().await);
}

#[cfg(test)]
mod tests {
	use super::*;

	#[tokio::test(flavor = "multi_thread")]
	#[ignore = "hits live reddit"]
	async fn test_oauth_client() {
		// Integration test - tests the overall Oauth client
		init_oauth_client().await;
		assert!(oauth_client().load_full().headers_map.contains_key("Authorization"));
	}

	#[tokio::test(flavor = "multi_thread")]
	#[ignore = "hits live reddit"]
	async fn test_oauth_client_refresh() {
		init_oauth_client().await;
		force_refresh_token().await;
	}

	#[tokio::test(flavor = "multi_thread")]
	#[ignore = "hits live reddit"]
	async fn test_oauth_token_exists() {
		init_oauth_client().await;
		let client = oauth_client().load_full();
		let auth_header = client.headers_map.get("Authorization").unwrap();
		assert!(auth_header.starts_with("Bearer "));
	}

	#[tokio::test(flavor = "multi_thread")]
	#[ignore = "hits live reddit"]
	async fn test_oauth_headers_len() {
		init_oauth_client().await;
		assert!(oauth_client().load_full().headers_map.len() >= 3);
	}

	// Offline: a fake Minter stands in for Reddit's auth endpoint (AGENTS.md "Test seams").

	use std::sync::atomic::AtomicUsize;
	use tokio::sync::Notify;

	/// A token named `bearer`, minted `age` ago, without touching the network.
	fn fake_oauth(bearer: &str, age: Duration) -> Oauth {
		Oauth {
			headers_map: HashMap::from([("Authorization".to_owned(), format!("Bearer {bearer}"))]),
			expires_in: 86_400,
			minted_at: Instant::now().checked_sub(age).expect("test host has been up longer than the token age"),
			backend: MobileSpoofAuth::new(),
		}
	}

	/// Mints `tok-1`, `tok-2`, ... (aged `age`), or fails while `fail` is set. With `gate`, each
	/// mint first waits for one `notify_one`, so a test can hold a rotation mid-mint.
	#[derive(Default)]
	struct FakeMinter {
		calls: AtomicUsize,
		fail: AtomicBool,
		age: Duration,
		gate: Option<Arc<Notify>>,
	}

	impl Minter for FakeMinter {
		async fn mint(&self) -> Result<Oauth, String> {
			if let Some(gate) = &self.gate {
				gate.notified().await;
			}
			let n = self.calls.fetch_add(1, Ordering::SeqCst) + 1;
			if self.fail.load(Ordering::SeqCst) {
				return Err(format!("mint {n} refused"));
			}
			Ok(fake_oauth(&format!("tok-{n}"), self.age))
		}
	}

	/// Gated tests deadlock if single-flight breaks; fail them instead of hanging the suite.
	async fn bounded<T>(fut: impl Future<Output = T>) -> T {
		tokio::time::timeout(Duration::from_secs(5), fut)
			.await
			.expect("rotation deadlocked: more mints than the gate releases")
	}

	fn bearer<M: Minter>(manager: &TokenManager<M>) -> String {
		manager.current().load().headers_map["Authorization"].clone()
	}

	async fn manager(minter: FakeMinter) -> TokenManager<FakeMinter> {
		if let Some(gate) = &minter.gate {
			gate.notify_one(); // let the bootstrap mint through
		}
		TokenManager::bootstrap(minter).await.unwrap()
	}

	#[tokio::test]
	async fn bootstrap_mints_once_with_a_full_budget() {
		let m = manager(FakeMinter::default()).await;
		assert_eq!(bearer(&m), "Bearer tok-1");
		assert_eq!(m.minter.calls.load(Ordering::SeqCst), 1);
		assert_eq!(m.ratelimit_remaining().load(Ordering::SeqCst), FRESH_TOKEN_BUDGET);
		assert!(!m.is_rolling_over());
	}

	#[tokio::test]
	async fn bootstrap_failure_is_an_error() {
		let minter = FakeMinter::default();
		minter.fail.store(true, Ordering::SeqCst);
		assert_eq!(TokenManager::bootstrap(minter).await.err(), Some("mint 1 refused".to_owned()));
	}

	// The expired-token path: fetch_json's 401 handling and the daemon both land here.
	#[tokio::test]
	async fn rotate_swaps_the_token_and_restores_the_budget() {
		let m = manager(FakeMinter::default()).await;
		m.ratelimit_remaining().store(3, Ordering::SeqCst);
		assert_eq!(m.rotate().await, Rotation::Rotated);
		assert_eq!(bearer(&m), "Bearer tok-2");
		assert_eq!(m.ratelimit_remaining().load(Ordering::SeqCst), FRESH_TOKEN_BUDGET);
		assert!(!m.is_rolling_over());
	}

	#[tokio::test]
	async fn failed_rotation_keeps_the_old_token_and_allows_a_retry() {
		let m = manager(FakeMinter::default()).await;
		m.minter.fail.store(true, Ordering::SeqCst);
		assert_eq!(m.rotate().await, Rotation::Failed("mint 2 refused".to_owned()));
		assert_eq!(bearer(&m), "Bearer tok-1");
		assert!(!m.is_rolling_over(), "a failed mint must not leave the rotation flag set");

		m.minter.fail.store(false, Ordering::SeqCst);
		assert_eq!(m.rotate().await, Rotation::Rotated);
		assert_eq!(bearer(&m), "Bearer tok-3");
	}

	#[tokio::test]
	async fn concurrent_rotations_mint_once() {
		let gate = Arc::new(Notify::new());
		let m = manager(FakeMinter {
			gate: Some(gate.clone()),
			..FakeMinter::default()
		})
		.await;
		// join! polls in order: the first rotation takes the flag and parks in the gated mint,
		// the second sees the flag, then releases the gate.
		let (first, second) = bounded(async {
			tokio::join!(m.rotate(), async {
				let r = m.rotate().await;
				gate.notify_one();
				r
			})
		})
		.await;
		assert_eq!((first, second), (Rotation::Rotated, Rotation::AlreadyRotating));
		assert_eq!(m.minter.calls.load(Ordering::SeqCst), 2);
	}

	#[tokio::test]
	async fn a_dropped_rotation_does_not_wedge_the_flag() {
		let gate = Arc::new(Notify::new());
		let m = manager(FakeMinter {
			gate: Some(gate.clone()),
			..FakeMinter::default()
		})
		.await;
		{
			let mut abandoned = std::pin::pin!(m.rotate());
			assert!(futures_lite::future::poll_once(&mut abandoned).await.is_none(), "mint should be parked on the gate");
			assert!(m.is_rolling_over());
		}
		assert!(!m.is_rolling_over());
		gate.notify_one();
		assert_eq!(bounded(m.rotate()).await, Rotation::Rotated);
	}

	// The 403 self-heal: rotate once, then refuse until the cooldown passes, so a block that
	// survives rotation (an IP-level one) never becomes a mint per request.
	#[tokio::test]
	async fn blocked_token_rotates_once_then_cools_down() {
		let m = manager(FakeMinter {
			age: Duration::ZERO,
			..FakeMinter::default()
		})
		.await;
		m.current()
			.store(Arc::new(fake_oauth("long-lived", BLOCKED_TOKEN_REFRESH_COOLDOWN + Duration::from_secs(1))));

		assert_eq!(m.rotate_blocked().await, Rotation::Rotated);
		assert_eq!(bearer(&m), "Bearer tok-2");
		for _ in 0..3 {
			assert_eq!(m.rotate_blocked().await, Rotation::CoolingDown);
		}
		assert_eq!(m.minter.calls.load(Ordering::SeqCst), 2, "one bootstrap mint plus exactly one rotation");
	}

	#[tokio::test]
	async fn a_fresh_token_is_never_rotated_for_a_block() {
		let m = manager(FakeMinter::default()).await;
		assert_eq!(m.rotate_blocked().await, Rotation::CoolingDown);
		assert_eq!(bearer(&m), "Bearer tok-1");
	}

	#[test]
	fn refresh_delay_leaves_a_margin_and_has_a_floor() {
		assert_eq!(refresh_delay(86_400), Duration::from_secs(86_280));
		assert_eq!(refresh_delay(150), TOKEN_REFRESH_FLOOR);
		assert_eq!(refresh_delay(0), TOKEN_REFRESH_FLOOR, "a zero expiry must not spin the daemon");
	}
}
