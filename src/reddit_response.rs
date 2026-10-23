//! Classification of one Reddit API response into the caller's result and the token action.
//! Used by `client::fetch_json`, which performs the action.

use log::error;
use serde_json::Value;

/// What `fetch_json` must do to the token after a response, as decided by `interpret_response`.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum TokenAction {
	None,
	/// Empty body: the token's budget is spent. Rotate without holding up this request.
	RotateInBackground,
	/// JSON 401 "Unauthorized": the token expired. Rotate before answering.
	Rotate,
	/// Non-JSON 403 off the thread routes: Reddit's network-policy block page for a flagged
	/// token/device pair, which a rotation fixes (Oct 2026). The same page answers the thread
	/// routes for every logged-out token, which no rotation fixes, so `is_thread_route` keeps those
	/// out of here; a 403 on some other route Reddit starts blocking still lands here, hence the
	/// hedged message and the 60s cooldown in `oauth::refresh_blocked_token`.
	RotateBlocked,
}

/// The error for a thread Reddit no longer serves to logged-out tokens. `post::item` answers it with
/// the post alone (from `/by_id/`) and a note that comments need a Reddit login.
pub(crate) const THREAD_LOGIN_REQUIRED: &str = "thread_login_required";

/// `/{r,u,user}/<name>/comments/…` or a bare `/comments/…`. Since 2026-10-23 (when the `%2F`
/// spelling that worked from 2026-10-20 was closed) Reddit 403s these for every app-only token,
/// so their 403 is a route block, not a flagged token, and must never rotate one.
pub(crate) fn is_thread_route(path: &str) -> bool {
	let route = path.split('?').next().unwrap_or_default();
	route.starts_with("/comments/")
		|| ["/r/", "/u/", "/user/"].iter().any(|prefix| {
			route
				.strip_prefix(prefix)
				.and_then(|rest| rest.split_once('/'))
				.is_some_and(|(_, tail)| tail.starts_with("comments/"))
		})
}

/// Classify one Reddit response: the caller's result, and what must happen to the token. Pure, so
/// the rotation triggers (401, non-JSON 403, empty body) are tested offline.
pub(crate) fn interpret_response(status: u16, body: &[u8], ratelimit_reset: Option<&str>, path: &str) -> (Result<Value, String>, TokenAction) {
	// First, whatever the body: an empty 403 on a thread route is the same refusal, and the
	// empty-body branch below would rotate the token for it with no cooldown at all.
	if status == 403 && is_thread_route(path) {
		return (Err(THREAD_LOGIN_REQUIRED.to_string()), TokenAction::None);
	}

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
					Err("Reddit refused this request (403 block page). The session is being renewed; if a refresh does not help, Reddit is blocking this kind of page for logged-out clients.".to_string()),
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

#[cfg(test)]
mod tests {
	use super::*;
	use serde_json::json;

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
	fn a_thread_route_403_is_a_route_block_and_keeps_the_token() {
		for path in [
			"/r/nyc/comments/1xadhhx/.json?&sort=confidence&raw_json=1",
			"/comments/1xadhhx/.json",
			"/user/spez/comments/abc123/t/.json",
		] {
			// With the HTML block page, and with no body at all (which once read as a spent budget).
			for body in [&b"<body class=theme-beta>blocked</body>"[..], b""] {
				let (result, action) = interpret_response(403, body, Some("5"), path);
				assert_eq!(result, Err(THREAD_LOGIN_REQUIRED.to_string()), "{path}");
				assert_eq!(action, TokenAction::None, "{path}");
			}
		}
	}

	#[test]
	fn thread_routes_are_told_from_their_neighbours() {
		for path in [
			"/r/nyc/comments/1xadhhx/",
			"/r/comments/comments/1x/.json",
			"/u/spez/comments/abc/t.json",
			"/comments/1xadhhx",
		] {
			assert!(is_thread_route(path), "{path}");
		}
		for path in [
			"/r/nyc/hot.json",
			"/user/spez/comments.json?raw_json=1",
			"/r/nyc/about.json",
			"/by_id/t3_1xadhhx.json",
			"/r/nyc/search.json?q=/comments/x",
		] {
			assert!(!is_thread_route(path), "{path}");
		}
	}

	#[test]
	fn interpret_html_403_rotates_the_blocked_token() {
		let (result, action) = interpret(403, "<html><body>whoa there, pardner!</body></html>");
		assert_eq!(
			result,
			Err(
				"Reddit refused this request (403 block page). The session is being renewed; if a refresh does not help, Reddit is blocking this kind of page for logged-out clients."
					.to_string()
			)
		);
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
}
