use cached::{Cached, SizedCache};
use log::{debug, warn};
use std::collections::HashSet;
use std::fmt::Debug;
use std::future::Future;
use std::hash::Hash;
use std::sync::Mutex;
use std::time::Duration;
use tokio::time::Instant;

/// Stale-while-revalidate cache. A hit younger than `fresh` is served as-is; one older than that
/// (up to `stale_max`) is served immediately while a single background refresh replaces it, so a
/// revisit within the window never waits on the fetch. Only Ok results are cached; values are
/// cloned on hit. The fetch function is the test seam: `client::json()` passes `fetch_json` (live Reddit),
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

#[cfg(test)]
mod tests {
	// Offline: the SWR cache driven by a fake fetch on a paused clock (AGENTS.md "Test seams").

	use super::*;
	use futures_lite::{future::Boxed, FutureExt};
	use std::sync::atomic::{AtomicUsize, Ordering};
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
}
