//! GraphQL field conversions shared by every GraphQL-to-JSON-API converter (`gql_comments`,
//! `gql_posts`, `gql_users`): timestamps, flair, awards, rich text bodies, and the base64 that
//! carries Reddit's cursors through our URLs. Pure.

use crate::rtjson::render;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use chrono::DateTime;
use serde_json::{json, Value};

/// Longest base64 cursor accepted from a URL; Reddit's own are far shorter.
const MAX_CURSOR_LEN: usize = 8192;
/// Marks a listing's `after` as a GraphQL cursor; REST's are fullnames (`t3_…`, `t1_…`).
const AFTER_PREFIX: &str = "g_";

/// Reddit's cursors carry `:`, `+`, `/` and `=`; URL-safe base64 keeps them intact in a query string.
pub(crate) fn encode_cursor(cursor: &str) -> String {
	URL_SAFE_NO_PAD.encode(cursor)
}

pub(crate) fn decode_cursor(cursor: &str) -> Result<String, String> {
	if cursor.len() > MAX_CURSOR_LEN {
		return Err("invalid cursor (too long)".to_string());
	}
	URL_SAFE_NO_PAD
		.decode(cursor)
		.ok()
		.and_then(|bytes| String::from_utf8(bytes).ok())
		.ok_or_else(|| "invalid cursor".to_string())
}

/// A GraphQL `endCursor` as a listing's `after`, which our pages put back in `?after=`.
pub(crate) fn after_param(cursor: &str) -> String {
	format!("{AFTER_PREFIX}{}", encode_cursor(cursor))
}

/// The GraphQL cursor in an `after=` value: None when it is not ours (a REST fullname),
/// Some(Err) when it is ours but does not decode.
pub(crate) fn cursor_from_after(after: &str) -> Option<Result<String, String>> {
	after.strip_prefix(AFTER_PREFIX).map(decode_cursor)
}

/// `2026-10-20T01:20:04.977000+0000` as Unix seconds.
pub(crate) fn timestamp(value: &Value) -> Option<f64> {
	DateTime::parse_from_str(value.as_str()?, "%Y-%m-%dT%H:%M:%S%.f%z").ok().map(|t| t.timestamp() as f64)
}

/// `editedAt` as the JSON API's `edited`: a timestamp, or false.
pub(crate) fn edited(value: &Value) -> Value {
	timestamp(value).map_or(Value::Bool(false), Value::from)
}

/// The JSON API's `*_flair_type` and `*_flair_richtext` for a GraphQL flair (author or post).
pub(crate) fn flair(flair: &Value) -> (&'static str, Value) {
	let richtext: Value = flair["richtext"].as_str().and_then(|r| serde_json::from_str(r).ok()).unwrap_or_default();
	let kind = if richtext.as_array().is_some_and(|r| !r.is_empty()) {
		"richtext"
	} else if flair["text"].as_str().is_some_and(|t| !t.is_empty()) {
		"text"
	} else {
		""
	};
	(kind, richtext)
}

/// `DARK`/`LIGHT` as the JSON API's `dark`/`light`.
pub(crate) fn lowercase(value: &Value) -> Value {
	value.as_str().map_or(Value::Null, |s| s.to_lowercase().into())
}

/// `all_awardings` in the shape `model::Awards::parse` reads. Comments name the icon
/// `static_icon_16`, posts `icon_16`.
pub(crate) fn awards(awardings: &Value) -> Vec<Value> {
	awardings
		.as_array()
		.into_iter()
		.flatten()
		.map(|a| {
			let award = &a["award"];
			let icon = if award["static_icon_16"].is_object() {
				&award["static_icon_16"]
			} else {
				&award["icon_16"]
			};
			json!({ "name": award["name"], "count": a["total"], "resized_icons": [{ "url": icon["url"] }] })
		})
		.collect()
}

/// The HTML of a GraphQL `content` (`markdown`, plus `richtext`: a JSON string holding
/// `{"document": [...]}`; gql-fed leaves `html` empty or plain text). Richtext renders through
/// `rtjson`; without it the markdown is escaped into one paragraph.
pub(crate) fn content_html(content: &Value) -> String {
	let richtext: Value = content["richtext"].as_str().and_then(|r| serde_json::from_str(r).ok()).unwrap_or_default();
	if richtext["document"].is_array() {
		render(&richtext["document"], &content["richtextMedia"])
	} else {
		format!("<p>{}</p>", htmlescape::encode_minimal(content["markdown"].as_str().unwrap_or_default()))
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn cursors_round_trip_and_foreign_ones_are_refused() {
		let after = after_param("opaque:+/= cursor");
		assert!(after.starts_with("g_"));
		assert_eq!(cursor_from_after(&after), Some(Ok("opaque:+/= cursor".to_string())));
		assert_eq!(cursor_from_after("t3_abc"), None);
		assert!(cursor_from_after("g_%FF").unwrap().is_err());
		assert!(decode_cursor(&encode_cursor(&"x".repeat(7000))).is_err());
		// Valid base64 that is not UTF-8
		assert!(decode_cursor(&URL_SAFE_NO_PAD.encode([0xff, 0xfe])).is_err());
	}

	#[test]
	fn timestamps_parse_with_and_without_fractions() {
		assert_eq!(timestamp(&json!("2026-10-20T01:20:04.977000+0000")), Some(1792459204.0));
		assert_eq!(timestamp(&json!("2026-10-20T01:20:04+0000")), Some(1792459204.0));
		assert_eq!(timestamp(&json!("yesterday")), None);
		assert_eq!(edited(&Value::Null), false);
		assert_eq!(edited(&json!("2026-10-20T01:20:04+0000")), 1792459204.0);
	}

	#[test]
	fn flair_kinds() {
		assert_eq!(flair(&json!({"text": "t", "richtext": r#"[{"e":"text","t":"t"}]"#})).0, "richtext");
		assert_eq!(flair(&json!({"text": "t", "richtext": "[]"})), ("text", json!([])));
		assert_eq!(flair(&Value::Null).0, "");
		assert_eq!(lowercase(&json!("DARK")), "dark");
		assert!(lowercase(&Value::Null).is_null());
	}

	#[test]
	fn awards_read_either_icon_spelling() {
		let comment = json!([{"total": 2, "award": {"name": "A", "static_icon_16": {"url": "s"}}}]);
		let post = json!([{"total": 1, "award": {"name": "B", "icon_16": {"url": "p"}}}]);
		assert_eq!(awards(&comment), vec![json!({"name": "A", "count": 2, "resized_icons": [{"url": "s"}]})]);
		assert_eq!(awards(&post)[0]["resized_icons"][0]["url"], "p");
		assert!(awards(&Value::Null).is_empty());
	}

	#[test]
	fn content_renders_richtext_else_escaped_markdown() {
		let rich = json!({"markdown": "hi", "richtext": r#"{"document":[{"e":"par","c":[{"e":"text","t":"hi"}]}]}"#});
		assert_eq!(content_html(&rich), "<p>hi</p>");
		assert_eq!(content_html(&json!({"markdown": "<b>&"})), "<p>&lt;b&gt;&amp;</p>");
	}
}
