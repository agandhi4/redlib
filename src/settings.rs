#![allow(clippy::cmp_owned)]

use std::collections::HashMap;

// CRATES
use crate::cookie_chain::set_cookie_chain;
use crate::preferences::{deflate_decompress, Preferences};
use crate::server::ResponseExt;
use crate::utils::{redirect, template};
use askama::Template;
use futures_lite::StreamExt;
use hyper::{Body, Request, Response};
use tokio::time::timeout;
use url::form_urlencoded;

// STRUCTS
#[derive(Template)]
#[template(path = "settings.html")]
struct SettingsTemplate {
	prefs: Preferences,
	url: String,
}

// CONSTANTS

const PREFS: [&str; 19] = [
	"theme",
	"front_page",
	"layout",
	"wide",
	"comment_sort",
	"post_sort",
	"blur_spoiler",
	"show_nsfw",
	"blur_nsfw",
	"use_hls",
	"hide_hls_notification",
	"autoplay_videos",
	"hide_sidebar_and_summary",
	"fixed_navbar",
	"hide_awards",
	"hide_score",
	"disable_visit_reddit_confirmation",
	"video_quality",
	"remove_default_feeds",
];

// FUNCTIONS

/// Retrieve cookies from request "Cookie" header
pub async fn get(req: Request<Body>) -> Result<Response<Body>, String> {
	let url = req.uri().to_string();
	Ok(template(&SettingsTemplate {
		prefs: Preferences::new(&req),
		url,
	}))
}

/// Set cookies using response "Set-Cookie" header
pub async fn set(req: Request<Body>) -> Result<Response<Body>, String> {
	// Split the body into parts
	let (_, mut body) = req.into_parts();

	// Aggregate the body...
	// let whole_body = hyper::body::aggregate(req).await.map_err(|e| e.to_string())?;
	let body_bytes = body
		.try_fold(Vec::new(), |mut data, chunk| {
			data.extend_from_slice(&chunk);
			Ok(data)
		})
		.await
		.map_err(|e| e.to_string())?;

	let form = url::form_urlencoded::parse(&body_bytes).collect::<HashMap<_, _>>();

	let mut response = redirect("/settings");

	for &name in &PREFS {
		match form.get(name) {
			Some(value) => response.insert_persistent_cookie(name.to_owned(), value.to_string()),
			None => response.remove_cookie(name.to_string()),
		};
	}

	Ok(response)
}

fn set_cookies_method(req: Request<Body>, remove_cookies: bool) -> Response<Body> {
	// Split the body into parts
	let (parts, _) = req.into_parts();

	let query = parts.uri.query().unwrap_or_default().as_bytes();

	let form = url::form_urlencoded::parse(query).collect::<HashMap<_, _>>();

	let path = form.get("redirect").map_or_else(|| "/".to_string(), |value| redirect_path(value));

	let mut response = redirect(&path);

	for name in PREFS {
		match form.get(name) {
			Some(value) => response.insert_persistent_cookie(name.to_owned(), value.to_string()),
			None if remove_cookies => response.remove_cookie(name.to_string()),
			None => {}
		};
	}

	// We can't search through the cookies directly like in subreddit.rs, so instead we have to make a string out of the request's headers to search through
	let cookies_string = parts
		.headers
		.get("cookie")
		.map(|hv| hv.to_str().unwrap_or("").to_string()) // Return String
		.unwrap_or_else(String::new); // Return an empty string if None
	let has_cookie = |name: &str| cookies_string.contains(&format!("{name}="));

	// Write the subscriptions/filters the query string carries (an empty value is still one empty
	// chunk). A list it leaves out follows the PREFS rule above: restore expires it with every
	// numbered cookie after it, update keeps it. Update is what the HLS and NSFW-gate links call
	// with a single pref, so expiring there wiped every subscription (upstream #562).
	for chain in ["subscriptions", "filters"] {
		let list: Option<Vec<String>> = form.get(chain).map(|joined| joined.split('+').map(str::to_string).collect());
		if list.is_some() || remove_cookies {
			set_cookie_chain(&mut response, chain, list.as_deref(), has_cookie);
		}
	}

	response
}

/// A settings redirect target as a site path: the `%26`/`%23` the settings page escapes back
/// to `&`/`#`, and a leading `/` added when missing.
fn redirect_path(value: &str) -> String {
	let value = value.replace("%26", "&").replace("%23", "#");
	if value.starts_with('/') {
		value
	} else {
		format!("/{value}")
	}
}

/// Set cookies using response "Set-Cookie" header
pub async fn restore(req: Request<Body>) -> Result<Response<Body>, String> {
	Ok(set_cookies_method(req, true))
}

pub async fn update(req: Request<Body>) -> Result<Response<Body>, String> {
	Ok(set_cookies_method(req, false))
}

pub async fn encoded_restore(req: Request<Body>) -> Result<Response<Body>, String> {
	let body = hyper::body::to_bytes(req.into_body())
		.await
		.map_err(|e| format!("Failed to get bytes from request body: {e}"))?;

	if body.len() > 1024 * 1024 {
		return Err("Request body too large".to_string());
	}

	let encoded_prefs = form_urlencoded::parse(&body)
		.find(|(key, _)| key == "encoded_prefs")
		.map(|(_, value)| value)
		.ok_or_else(|| "encoded_prefs parameter not found in request body".to_string())?;

	let bytes = base2048::decode(&encoded_prefs).ok_or_else(|| "Failed to decode base2048 encoded preferences".to_string())?;

	let out = timeout(std::time::Duration::from_secs(1), async { deflate_decompress(bytes) })
		.await
		.map_err(|e| format!("Failed to decompress bytes: {e}"))??;

	let mut prefs: Preferences = timeout(std::time::Duration::from_secs(1), async { bincode::deserialize(&out) })
		.await
		.map_err(|e| format!("Failed to deserialize preferences: {e}"))?
		.map_err(|e| format!("Failed to deserialize bytes into Preferences struct: {e}"))?;

	prefs.available_themes = vec![];

	let url = format!("/settings/restore/?{}", prefs.to_urlencoded()?);

	Ok(redirect(&url))
}

#[cfg(test)]
mod tests {
	use super::*;

	/// Names of the cookies a response expires (a removal carries an expiry of now, not a year).
	fn expired_cookies(response: &Response<Body>) -> Vec<String> {
		let now = time::OffsetDateTime::now_utc();
		response
			.headers()
			.get_all("Set-Cookie")
			.iter()
			.filter_map(|header| cookie::Cookie::parse(header.to_str().ok()?.to_string()).ok())
			.filter(|cookie| cookie.expires_datetime().is_some_and(|at| at <= now))
			.map(|cookie| cookie.name().to_string())
			.collect()
	}

	fn settings_request(query: &str) -> Request<Body> {
		Request::builder()
			.uri(format!("/settings/update/?{query}"))
			.header("cookie", "subscriptions=rust; subscriptions1=linux; filters=pics")
			.body(Body::empty())
			.unwrap()
	}

	#[test]
	fn update_keeps_the_subscriptions_and_filters_it_does_not_name() {
		let response = set_cookies_method(settings_request("use_hls=on&redirect=r/rust"), false);
		assert_eq!(expired_cookies(&response), Vec::<String>::new());
	}

	#[test]
	fn restore_expires_the_subscriptions_and_filters_it_does_not_name() {
		let response = set_cookies_method(settings_request("use_hls=on"), true);
		let expired = expired_cookies(&response);
		for name in ["subscriptions", "subscriptions1", "filters"] {
			assert!(expired.contains(&name.to_string()), "{name} not expired in {expired:?}");
		}
	}

	#[test]
	fn redirect_path_unescapes_and_roots_the_target() {
		assert_eq!(redirect_path("r/rust?sort=new%26t=day%23top"), "/r/rust?sort=new&t=day#top");
		assert_eq!(redirect_path("/settings"), "/settings");
	}
}
