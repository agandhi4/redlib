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
	/// Non-JSON 403: Reddit's network-policy block page. For a flagged token/device pair a
	/// rotation fixes it (Oct 2026). The same page also answers a ROUTE Reddit blocks for every
	/// logged-out client (threads, 2026-10-20), which no rotation fixes: hence the hedged message
	/// and the 60s cooldown in `oauth::refresh_blocked_token`. Same body, so they can't be told apart here.
	RotateBlocked,
}

/// Classify one Reddit response: the caller's result, and what must happen to the token. Pure, so
/// the rotation triggers (401, non-JSON 403, empty body) are tested offline.
pub(crate) fn interpret_response(status: u16, body: &[u8], ratelimit_reset: Option<&str>, path: &str) -> (Result<Value, String>, TokenAction) {
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
