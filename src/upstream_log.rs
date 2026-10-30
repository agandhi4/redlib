//! One log line per HTTP request redlib sends to a Reddit host, so the logs answer "how much do
//! we ask Reddit for, and why" (2026-10-30: is our own traffic what gets us blocked?). Logged at
//! info under the `upstream` target, which main.rs's default filter enables, as logfmt:
//! `kind=gql target="SubredditFeedElements" status=200 ms=412 cause=page`.
//!
//! Cache hits send nothing, so they log nothing: the lines count real requests, and a redirect
//! or a retry is its own request and its own line. Written by the four senders:
//! `client::request` (REST and HEAD), `client::gql_post`, `oauth_device` (token mints) and
//! `media_proxy` (the CDN). The cause is a task-local that `server` sets per request and
//! main.rs around startup. Spawned work (the JSON cache's stale-while-revalidate refresh, token
//! rotation, the token daemon) does not inherit it and logs `background`.
//! Querying it: docs/fork.md "Upstream request log".

use hyper::HeaderMap;
use log::info;
use std::future::Future;
use std::time::Instant;

/// Why redlib is talking to Reddit: the reader's page, the prefetcher, or startup.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cause {
	Page,
	Prefetch,
	Startup,
}

impl Cause {
	/// The cause of a request redlib serves. `static/prefetch.js` marks its fetches with
	/// `Purpose: prefetch` (the header's legacy standard name; `Sec-Purpose` is browser-only).
	pub fn of(headers: &HeaderMap) -> Self {
		match headers.get("purpose") {
			Some(value) if value.as_bytes().eq_ignore_ascii_case(b"prefetch") => Self::Prefetch,
			_ => Self::Page,
		}
	}

	const fn name(self) -> &'static str {
		match self {
			Self::Page => "page",
			Self::Prefetch => "prefetch",
			Self::Startup => "startup",
		}
	}
}

tokio::task_local! {
	static CAUSE: Cause;
}

/// Runs `future` with `cause` as the cause of every Reddit request it sends.
pub fn scope<F: Future>(cause: Cause, future: F) -> impl Future<Output = F::Output> {
	CAUSE.scope(cause, future)
}

fn current_cause() -> &'static str {
	CAUSE.try_with(|cause| cause.name()).unwrap_or("background")
}

/// What kind of Reddit request a line is.
#[derive(Clone, Copy)]
pub(crate) enum Kind {
	/// A JSON API GET on oauth.reddit.com.
	Rest,
	/// A share-link resolution (`client::canonical_path`).
	Head,
	/// A persisted query on gql-fed.
	Gql,
	/// An anonymous token mint.
	Token,
	/// An image or video from the CDN; `target` is its host only.
	Media,
}

impl Kind {
	const fn name(self) -> &'static str {
		match self {
			Self::Rest => "rest",
			Self::Head => "head",
			Self::Gql => "gql",
			Self::Token => "token",
			Self::Media => "media",
		}
	}
}

/// One request on its way to Reddit, from just before its send. `finish` logs its status, or
/// `failed` when it got no response; dropped unfinished (an outer timeout cancelled the send,
/// e.g. the token mint's 5 s), it logs `cancelled`, since Reddit may have received it anyway.
/// The cause is read at the start: a drop can run outside the task-local's scope.
#[must_use = "an unfinished request logs as cancelled"]
pub(crate) struct InFlight {
	kind: Kind,
	target: String,
	started: Instant,
	cause: &'static str,
	logged: bool,
}

pub(crate) fn start(kind: Kind, target: &str) -> InFlight {
	InFlight {
		kind,
		target: target.to_string(),
		started: Instant::now(),
		cause: current_cause(),
		logged: false,
	}
}

impl InFlight {
	pub(crate) fn finish<E>(mut self, result: &Result<wreq::Response, E>) {
		self.log(&status_of(result));
	}

	fn log(&mut self, status: &str) {
		self.logged = true;
		info!(target: "upstream", "{}", line(self.kind, &self.target, status, self.started.elapsed().as_millis(), self.cause));
	}
}

impl Drop for InFlight {
	fn drop(&mut self) {
		if !self.logged {
			self.log("cancelled");
		}
	}
}

fn status_of<E>(result: &Result<wreq::Response, E>) -> String {
	result.as_ref().map_or_else(|_| "failed".to_string(), |response| response.status().as_u16().to_string())
}

fn line(kind: Kind, target: &str, status: &str, ms: u128, cause: &str) -> String {
	format!("kind={} target={target:?} status={status} ms={ms} cause={cause}", kind.name())
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn a_line_is_logfmt_with_the_target_quoted() {
		assert_eq!(
			line(Kind::Rest, "/search.json?q=rust lang", "403", 120, "page"),
			r#"kind=rest target="/search.json?q=rust lang" status=403 ms=120 cause=page"#
		);
		assert_eq!(
			line(Kind::Media, "i.redd.it", "failed", 3001, "page"),
			r#"kind=media target="i.redd.it" status=failed ms=3001 cause=page"#
		);
	}

	#[test]
	fn a_response_logs_its_status_and_a_transport_error_logs_failed() {
		let response = wreq::Response::from(http::Response::builder().status(403).body("").unwrap());
		let answered: Result<wreq::Response, ()> = Ok(response);
		assert_eq!(status_of(&answered), "403");
		assert_eq!(status_of(&Err::<wreq::Response, _>(())), "failed");
		let request = start(Kind::Rest, "/r/rust/hot.json");
		assert!(!request.logged);
		request.finish(&answered);
	}

	#[tokio::test]
	async fn a_send_cancelled_by_a_timeout_still_logs_with_its_cause() {
		let send = scope(Cause::Startup, async {
			let request = start(Kind::Token, "https://accounts.reddit.com/api/access_token");
			assert_eq!(request.cause, "startup");
			std::future::pending::<()>().await;
			request.finish(&Err::<wreq::Response, _>(()));
		});
		// The timeout drops the send unfinished: the guard's Drop logs it as cancelled
		assert!(tokio::time::timeout(std::time::Duration::from_millis(1), send).await.is_err());
	}

	#[test]
	fn the_prefetcher_is_told_apart_by_its_purpose_header() {
		let mut headers = HeaderMap::new();
		assert_eq!(Cause::of(&headers), Cause::Page);
		headers.insert("purpose", "Prefetch".parse().unwrap());
		assert_eq!(Cause::of(&headers), Cause::Prefetch);
	}

	#[tokio::test]
	async fn the_cause_is_the_scope_s_and_background_outside_one() {
		assert_eq!(current_cause(), "background");
		assert_eq!(scope(Cause::Prefetch, async { current_cause() }).await, "prefetch");
		// A spawned task does not inherit it: the JSON cache's refresh logs as background
		let spawned = scope(Cause::Page, async { tokio::spawn(async { current_cause() }).await.unwrap() }).await;
		assert_eq!(spawned, "background");
	}
}
