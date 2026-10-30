//! A lock-free "skip until" timer over Unix seconds: tripped, it answers `allows == false` until
//! its deadline, so a burst of pages never waits on another's bookkeeping. Used by `sources`
//! (one per GraphQL kind) and by `client` (REST while Reddit answers it with the block page).

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
use time::{macros::format_description, OffsetDateTime};

/// The Unix second until which the guarded source is skipped; 0 when it never tripped.
pub(crate) struct Breaker(AtomicU64);

impl Breaker {
	pub(crate) const fn new() -> Self {
		Self(AtomicU64::new(0))
	}

	/// Whether the guarded source is tried at `now`.
	pub(crate) fn allows(&self, now: u64) -> bool {
		self.0.load(Ordering::Relaxed) <= now
	}

	/// Skips the source until `now + secs`. True when this opened it, so a burst of failing
	/// pages logs the switch once.
	pub(crate) fn trip(&self, now: u64, secs: u64) -> bool {
		self.0.swap(now + secs, Ordering::Relaxed) <= now
	}

	/// The source answered. True when it had tripped before, i.e. this is the switch back.
	pub(crate) fn close(&self) -> bool {
		self.0.swap(0, Ordering::Relaxed) != 0
	}

	/// The Unix second the source is skipped until, while open.
	pub(crate) fn open_until(&self, now: u64) -> Option<u64> {
		Some(self.0.load(Ordering::Relaxed)).filter(|until| *until > now)
	}
}

pub(crate) fn unix_now() -> u64 {
	SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_secs())
}

/// `until` as "HH:MM UTC", for /info and error pages.
pub(crate) fn clock(until: u64) -> String {
	let at = OffsetDateTime::from_unix_timestamp(i64::try_from(until).unwrap_or(0)).unwrap_or(OffsetDateTime::UNIX_EPOCH);
	format!("{} UTC", at.format(format_description!("[hour]:[minute]")).unwrap_or_default())
}

#[cfg(test)]
mod tests {
	use super::*;

	const T0: u64 = 1_800_000_000;

	#[test]
	fn a_burst_trips_once_and_the_deadline_reopens_it() {
		let breaker = Breaker::new();
		assert!(breaker.allows(T0) && breaker.open_until(T0).is_none());
		assert!(breaker.trip(T0, 600));
		assert!(!breaker.trip(T0 + 1, 600));
		assert_eq!(breaker.open_until(T0 + 1), Some(T0 + 601));
		assert!(!breaker.allows(T0 + 600));
		assert!(breaker.allows(T0 + 601));
		assert!(breaker.close());
		assert!(!breaker.close());
		assert_eq!(clock(T0), "08:00 UTC");
	}
}
