#![allow(dead_code)]
#![allow(clippy::cmp_owned)]

use crate::config::{self, get_setting};
use crate::preferences::{setting, Preferences};
use crate::{client::json, server::RequestExt};
use askama::Template;
use hyper::{Body, Request, Response};
use log::{error, warn};
use serde_json::Value;
use std::collections::HashMap;
use std::env;
use std::string::ToString;
use std::sync::LazyLock;
use time::{macros::format_description, Duration, OffsetDateTime};
use url::Url;

/// Write a message to stderr on debug mode. This function is a no-op on
/// release code.
#[macro_export]
macro_rules! dbg_msg {
	($x:expr) => {
		#[cfg(debug_assertions)]
		eprintln!("{}:{}: {}", file!(), line!(), $x.to_string())
	};

	($($x:expr),+) => {
		#[cfg(debug_assertions)]
		dbg_msg!(format!($($x),+))
	};
}

/// Identifies whether or not the page is a subreddit, a user page, or a post.
/// This is used by the NSFW landing template to determine the mesage to convey
/// to the user.
#[derive(PartialEq, Eq)]
pub enum ResourceType {
	Subreddit,
	User,
	Post,
}

#[derive(Template)]
#[template(path = "error.html")]
pub struct ErrorTemplate {
	pub msg: String,
	pub prefs: Preferences,
	pub url: String,
}

#[derive(Template)]
#[template(path = "info.html")]
pub struct InfoTemplate {
	pub msg: String,
	pub prefs: Preferences,
	pub url: String,
}

/// Template for NSFW landing page. The landing page is displayed when a page's
/// content is wholly NSFW, but a user has not enabled the option to view NSFW
/// posts.
#[derive(Template)]
#[template(path = "nsfwlanding.html")]
pub struct NSFWLandingTemplate {
	/// Identifier for the resource. This is either a subreddit name or a
	/// username. (In the case of the latter, set is_user to true.)
	pub res: String,

	/// Identifies whether or not the resource is a subreddit, a user page,
	/// or a post.
	pub res_type: ResourceType,

	/// User preferences.
	pub prefs: Preferences,

	/// Request URL.
	pub url: String,
}

/// Parser for query params, used in sorting (eg. /r/rust/?sort=hot)
#[derive(serde::Deserialize)]
pub struct Params {
	pub t: Option<String>,
	pub q: Option<String>,
	pub sort: Option<String>,
	pub after: Option<String>,
	pub before: Option<String>,
}

//
// FORMATTING
//

/// Grab a query parameter from a url
pub fn param(path: &str, value: &str) -> Option<String> {
	Some(
		Url::parse(format!("https://libredd.it/{path}").as_str())
			.ok()?
			.query_pairs()
			.into_owned()
			.collect::<HashMap<_, _>>()
			.get(value)?
			.clone(),
	)
}

/// Instance-defined named feeds (`REDLIB_DEFAULT_FEEDS`), parsed once at startup.
/// Format: `Name:sub1+sub2|Name2:sub3+sub4` — declaration order is display order,
/// name is shown verbatim (matched case-insensitively in the /f/:name route).
/// Deliberately instance config rather than a user pref: feeds reference sub names
/// directly, so they work identically on every browser regardless of subscription
/// cookies, and stay out of the Preferences restore/bincode surface.
/// Used by: subreddit::feed, sub_list macro (utils.html), aside panel (subreddit.html).
pub static FEEDS: LazyLock<Vec<(String, String)>> = LazyLock::new(|| parse_feeds(&get_setting("REDLIB_DEFAULT_FEEDS").unwrap_or_default()));

/// Parse `REDLIB_DEFAULT_FEEDS`. Malformed entries (no `:`, empty name or sub list) are skipped
/// with a warning. A name repeated case-insensitively keeps its first definition: `/f/:name`
/// matches case-insensitively, so a later duplicate could never be reached.
fn parse_feeds(raw: &str) -> Vec<(String, String)> {
	let mut feeds: Vec<(String, String)> = Vec::new();
	for entry in raw.split('|').map(str::trim).filter(|entry| !entry.is_empty()) {
		let Some((name, subs)) = entry.split_once(':').map(|(name, subs)| (name.trim(), subs.trim())) else {
			warn!("REDLIB_DEFAULT_FEEDS: skipping \"{entry}\" (expected Name:sub1+sub2)");
			continue;
		};
		if name.is_empty() || subs.is_empty() {
			warn!("REDLIB_DEFAULT_FEEDS: skipping \"{entry}\" (empty name or sub list)");
		} else if feeds.iter().any(|(existing, _)| existing.eq_ignore_ascii_case(name)) {
			warn!("REDLIB_DEFAULT_FEEDS: skipping duplicate feed \"{name}\" (first definition wins)");
		} else {
			feeds.push((name.to_owned(), subs.to_owned()));
		}
	}
	feeds
}

/// Template helper: the instance's named feeds (askama can't reference statics directly).
pub fn feeds() -> &'static Vec<(String, String)> {
	&FEEDS
}

/// Detect and redirect in the event of a random subreddit
pub async fn catch_random(sub: &str, additional: &str) -> Result<Response<Body>, String> {
	if sub == "random" || sub == "randnsfw" {
		Ok(redirect(&format!(
			"/r/{}{additional}",
			json(format!("/r/{sub}/about.json?raw_json=1"), false).await?["data"]["display_name"]
				.as_str()
				.unwrap_or_default()
		)))
	} else {
		Err("No redirect needed".to_string())
	}
}

/// Format vote count to a string that will be displayed.
/// Append `m` and `k` for millions and thousands respectively, and
/// round to the nearest tenth.
pub fn format_num(num: i64) -> (String, String) {
	let truncated = if num >= 1_000_000 || num <= -1_000_000 {
		format!("{:.1}m", num as f64 / 1_000_000.0)
	} else if num >= 1000 || num <= -1000 {
		format!("{:.1}k", num as f64 / 1_000.0)
	} else {
		num.to_string()
	};

	(truncated, num.to_string())
}

/// Parse a relative and absolute time from a UNIX timestamp
pub fn time(created: f64) -> (String, String) {
	let time = OffsetDateTime::from_unix_timestamp(created.round() as i64).unwrap_or(OffsetDateTime::UNIX_EPOCH);
	let now = OffsetDateTime::now_utc();
	let min = time.min(now);
	let max = time.max(now);
	let time_delta = max - min;

	// If the time difference is more than a month, show full date
	let mut rel_time = if time_delta > Duration::days(30) {
		time.format(format_description!("[month repr:short] [day] '[year repr:last_two]")).unwrap_or_default()
	// Otherwise, show relative date/time
	} else if time_delta.whole_days() > 0 {
		format!("{}d", time_delta.whole_days())
	} else if time_delta.whole_hours() > 0 {
		format!("{}h", time_delta.whole_hours())
	} else {
		format!("{}m", time_delta.whole_minutes())
	};

	if time_delta <= Duration::days(30) {
		if now < time {
			rel_time += " left";
		} else {
			rel_time += " ago";
		}
	}

	(
		rel_time,
		time
			.format(format_description!("[month repr:short] [day] [year], [hour]:[minute]:[second] UTC"))
			.unwrap_or_default(),
	)
}

/// val() function used to parse JSON from Reddit APIs
pub fn val(j: &Value, k: &str) -> String {
	j["data"][k].as_str().unwrap_or_default().to_string()
}

//
// NETWORKING
//

pub fn template(t: &impl Template) -> Response<Body> {
	Response::builder()
		.status(200)
		.header("content-type", "text/html")
		.body(t.render().unwrap_or_default().into())
		.unwrap_or_default()
}

pub fn redirect(path: &str) -> Response<Body> {
	Response::builder()
		.status(302)
		.header("content-type", "text/html")
		.header("Location", path)
		.body(format!("Redirecting to <a href=\"{path}\">{path}</a>...").into())
		.unwrap_or_default()
}

/// Renders a generic error landing page.
pub async fn error(req: Request<Body>, msg: &str) -> Result<Response<Body>, String> {
	error!("Error page rendered: {}", msg.split('|').next().unwrap_or_default());
	let url = req.uri().to_string();
	let body = ErrorTemplate {
		msg: msg.to_string(),
		prefs: Preferences::new(&req),
		url,
	}
	.render()
	.unwrap_or_default();

	Ok(Response::builder().status(404).header("content-type", "text/html").body(body.into()).unwrap_or_default())
}

/// Renders a generic info landing page.
pub async fn info(req: Request<Body>, msg: &str) -> Result<Response<Body>, String> {
	let url = req.uri().to_string();
	let body = InfoTemplate {
		msg: msg.to_string(),
		prefs: Preferences::new(&req),
		url,
	}
	.render()
	.unwrap_or_default();

	Ok(Response::builder().status(200).header("content-type", "text/html").body(body.into()).unwrap_or_default())
}

/// Returns true if the config/env variable `REDLIB_SFW_ONLY` carries the
/// value `on`.
///
/// If this variable is set as such, the instance will operate in SFW-only
/// mode; all NSFW content will be filtered. Attempts to access NSFW
/// subreddits or posts or userpages for users Reddit has deemed NSFW will
/// be denied.
pub fn sfw_only() -> bool {
	match get_setting("REDLIB_SFW_ONLY") {
		Some(val) => val == "on",
		None => false,
	}
}

/// Returns true if the config/env variable REDLIB_ENABLE_RSS is set to "on".
/// If this variable is set as such, the instance will enable RSS feeds.
/// Otherwise, the instance will not provide RSS feeds.
pub fn enable_rss() -> bool {
	match get_setting("REDLIB_ENABLE_RSS") {
		Some(val) => val == "on",
		None => false,
	}
}

/// Returns true if the config/env variable `REDLIB_ROBOTS_DISABLE_INDEXING` carries the
/// value `on`.
///
/// If this variable is set as such, the instance will block all robots in robots.txt and
/// insert the noindex, nofollow meta tag on every page.
pub fn disable_indexing() -> bool {
	match get_setting("REDLIB_ROBOTS_DISABLE_INDEXING") {
		Some(val) => val == "on",
		None => false,
	}
}

/// Determines if a request should redirect to a NSFW landing gate.
pub fn should_be_nsfw_gated(req: &Request<Body>, _req_url: &str) -> bool {
	(setting(req, "show_nsfw") != "on") || sfw_only()
}

/// Renders the landing page for NSFW content when the user has not enabled
/// "show NSFW posts" in settings.
pub async fn nsfw_landing(req: Request<Body>, req_url: String) -> Result<Response<Body>, String> {
	let res_type: ResourceType;

	// Determine from the request URL if the resource is a subreddit, a user
	// page, or a post.
	let resource: String = if !req.param("name").unwrap_or_default().is_empty() {
		res_type = ResourceType::User;
		req.param("name").unwrap_or_default()
	} else if !req.param("id").unwrap_or_default().is_empty() {
		res_type = ResourceType::Post;
		req.param("id").unwrap_or_default()
	} else {
		res_type = ResourceType::Subreddit;
		req.param("sub").unwrap_or_default()
	};

	let body = NSFWLandingTemplate {
		res: resource,
		res_type,
		prefs: Preferences::new(&req),
		url: req_url,
	}
	.render()
	.unwrap_or_default();

	Ok(Response::builder().status(403).header("content-type", "text/html").body(body.into()).unwrap_or_default())
}

/// Returns the last (non-empty) segment of a path string
pub fn url_path_basename(path: &str) -> String {
	let url_result = Url::parse(format!("https://libredd.it/{path}").as_str());

	match url_result {
		Ok(mut url) => {
			url.path_segments_mut().unwrap().pop_if_empty();

			url.path_segments().unwrap().next_back().unwrap().to_string()
		}
		Err(_) => path.to_string(),
	}
}

/// Returns an absolute URL given a relative URL, as needed by RSS feeds
pub fn to_absolute_url(relative_path: &str) -> String {
	format!("{}{}", config::get_setting("REDLIB_FULL_URL").unwrap_or_default(), relative_path)
}

#[cfg(test)]
mod tests {
	use super::{format_num, parse_feeds, url_path_basename};

	fn feeds(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
		pairs.iter().map(|(name, subs)| ((*name).to_owned(), (*subs).to_owned())).collect()
	}

	#[test]
	fn parse_feeds_valid_keeps_declaration_order_and_trims() {
		assert_eq!(
			parse_feeds("Tech:rust+golang| News : worldnews+news "),
			feeds(&[("Tech", "rust+golang"), ("News", "worldnews+news")])
		);
	}

	#[test]
	fn parse_feeds_empty_is_no_feeds() {
		assert_eq!(parse_feeds(""), feeds(&[]));
		assert_eq!(parse_feeds(" | |"), feeds(&[]));
	}

	#[test]
	fn parse_feeds_skips_malformed_entries() {
		assert_eq!(parse_feeds("NoColon|:rust|Empty:|Ok:rust|  :  "), feeds(&[("Ok", "rust")]));
	}

	#[test]
	fn parse_feeds_first_duplicate_name_wins_case_insensitively() {
		assert_eq!(parse_feeds("Tech:rust|tech:golang|TECH:zig|Other:news"), feeds(&[("Tech", "rust"), ("Other", "news")]));
	}

	#[test]
	fn format_num_works() {
		assert_eq!(format_num(567), ("567".to_string(), "567".to_string()));
		assert_eq!(format_num(1234), ("1.2k".to_string(), "1234".to_string()));
		assert_eq!(format_num(1999), ("2.0k".to_string(), "1999".to_string()));
		assert_eq!(format_num(1001), ("1.0k".to_string(), "1001".to_string()));
		assert_eq!(format_num(1_999_999), ("2.0m".to_string(), "1999999".to_string()));
	}

	#[test]
	fn test_url_path_basename() {
		// without trailing slash
		assert_eq!(url_path_basename("/first/last"), "last");
		// with trailing slash
		assert_eq!(url_path_basename("/first/last/"), "last");
		// with query parameters
		assert_eq!(url_path_basename("/first/last/?some=query"), "last");
		// file path
		assert_eq!(url_path_basename("/cdn/image.jpg"), "image.jpg");
		// when a full url is passed instead of just a path
		assert_eq!(url_path_basename("https://doma.in/first/last"), "last");
		// empty path
		assert_eq!(url_path_basename("/"), "");
	}
}
