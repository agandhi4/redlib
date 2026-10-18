#![allow(clippy::cmp_owned)]

use crate::cookie_chain::set_cookie_chain;
use crate::utils::{
	catch_random, error, filter_posts, format_num, format_url, get_filters, info, nsfw_landing, param, redirect, rewrite_urls, setting, template, val, Post, Preferences,
	Subreddit, FEEDS,
};
use crate::{client::json, server::RequestExt, server::ResponseExt};
use askama::Template;
use cookie::Cookie;
use hyper::{Body, Request, Response};

use regex::Regex;
use std::sync::LazyLock;

// STRUCTS
#[derive(Template)]
#[template(path = "subreddit.html")]
struct SubredditTemplate {
	sub: Subreddit,
	posts: Vec<Post>,
	sort: (String, String),
	ends: (String, String),
	prefs: Preferences,
	url: String,
	redirect_url: String,
	/// Whether the subreddit itself is filtered.
	is_filtered: bool,
	/// Whether all fetched posts are filtered (to differentiate between no posts fetched in the first place,
	/// and all fetched posts being filtered).
	all_posts_filtered: bool,
	/// Whether all posts were hidden because they are NSFW (and user has disabled show NSFW)
	all_posts_hidden_nsfw: bool,
	no_posts: bool,
	/// Set when rendering a named feed (/f/:name) — keeps sort links rooted at
	/// /f/:name instead of the raw /r/a+b+c chain. Display name from FEEDS.
	feed: Option<String>,
}

#[derive(Template)]
#[template(path = "wiki.html")]
struct WikiTemplate {
	sub: String,
	wiki: String,
	page: String,
	prefs: Preferences,
	url: String,
}

#[derive(Template)]
#[template(path = "wall.html")]
struct WallTemplate {
	title: String,
	sub: String,
	msg: String,
	prefs: Preferences,
	url: String,
}

static GEO_FILTER_MATCH: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"geo_filter=(?<region>\w+)").unwrap());

// SERVICES

/// Named feed (/f/:name): resolve the instance-configured sub list (FEEDS) and
/// render it as a multireddit via community(), injecting the chain as the "sub"
/// param and the display name as "feed" so the page keeps its /f/ identity.
pub async fn feed(req: Request<Body>) -> Result<Response<Body>, String> {
	let name = req.param("name").unwrap_or_default();
	match FEEDS.iter().find(|(feed_name, _)| feed_name.eq_ignore_ascii_case(&name)) {
		Some((feed_name, subs)) => {
			let mut req = req;
			let mut params = req.params();
			params.insert("sub".to_string(), subs.clone());
			params.insert("feed".to_string(), feed_name.clone());
			req.set_params(params);
			community(req).await
		}
		None => error(req, &format!("Feed \"{name}\" is not configured on this instance (REDLIB_DEFAULT_FEEDS)")).await,
	}
}

/// The sub `/` (and a feed path without `/r/<sub>`) shows: the `front_page` preference, or
/// for `default` and unset the subscriptions joined with `+`, or `popular` without any.
fn front_page_sub(front_page: &str, subscribed: &str) -> String {
	match (front_page, subscribed) {
		("default" | "", "") => "popular".to_string(),
		("default" | "", subscribed) => subscribed.to_string(),
		(front_page, _) => front_page.to_string(),
	}
}

pub async fn community(req: Request<Body>) -> Result<Response<Body>, String> {
	// Build Reddit API path
	let root = req.uri().path() == "/";
	let feed = req.param("feed");
	let query = req.uri().query().unwrap_or_default().to_string();
	let subscribed = setting(&req, "subscriptions");
	let front_page = setting(&req, "front_page");
	let remove_default_feeds = setting(&req, "remove_default_feeds") == "on";
	let post_sort = req.cookie("post_sort").map_or_else(|| "hot".to_string(), |c| c.value().to_string());
	let sort = req.param("sort").unwrap_or_else(|| req.param("id").unwrap_or(post_sort));

	let sub_name = req.param("sub").unwrap_or_else(|| front_page_sub(&front_page, &subscribed));

	if (sub_name == "popular" || sub_name == "all") && remove_default_feeds {
		if subscribed.is_empty() {
			return info(req, "Subscribe to some subreddits! (Default feeds disabled in settings)").await;
		}
		// If there are subscribed subs, but we get here, then the problem is that front_page pref is set to something besides default.
		// Tell user to go to settings and change front page to default.
		return info(
			req,
			"You have subscribed to some subreddits, but your front page is not set to default. Visit settings and change front page to default.",
		)
		.await;
	}

	let quarantined = can_access_quarantine(&req, &sub_name) || root;

	// Handle random subreddits
	if let Ok(random) = catch_random(&sub_name, "").await {
		return Ok(random);
	}

	if req.param("sub").is_some() && sub_name.starts_with("u_") {
		return Ok(redirect(&["/user/", &sub_name[2..]].concat()));
	}

	// Subreddit metadata and the post listing are independent Reddit calls, so they run
	// concurrently: one upstream round-trip per cache-cold page instead of two. Feed pages
	// always render as multireddits, even when the configured chain is a single sub.
	let metadata = async {
		if feed.is_none() && !sub_name.contains('+') && sub_name != subscribed && sub_name != "popular" && sub_name != "all" {
			// Regular subreddit
			subreddit(&sub_name, quarantined).await.unwrap_or_default()
		} else if sub_name == subscribed {
			// Subscription feed
			if req.uri().path().starts_with("/r/") {
				subreddit(&sub_name, quarantined).await.unwrap_or_default()
			} else {
				Subreddit::default()
			}
		} else {
			// Multireddit, all, popular — a named feed titles the page with its name
			Subreddit {
				name: sub_name.clone(),
				title: feed.clone().unwrap_or_default(),
				..Subreddit::default()
			}
		}
	};

	let mut params = String::from("&raw_json=1");
	if sub_name == "popular" {
		let geo_filter = match GEO_FILTER_MATCH.captures(&query) {
			Some(geo_filter) => geo_filter["region"].to_string(),
			None => "GLOBAL".to_owned(),
		};
		params.push_str(&format!("&geo_filter={geo_filter}"));
	}

	let path = format!("/r/{}/{sort}.json?{}{params}", sub_name.replace('+', "%2B"), req.uri().query().unwrap_or_default());
	let url = String::from(req.uri().path_and_query().map_or("", |val| val.as_str()));
	let redirect_url = url[1..].replace('?', "%3F").replace('&', "%26").replace('+', "%2B");
	let filters = get_filters(&req);

	// If all requested subs are filtered, we don't need to fetch posts.
	let is_filtered = sub_name.split('+').all(|s| filters.contains(s));
	let listing = async {
		if is_filtered {
			None
		} else {
			Some(Post::fetch(&path, quarantined).await)
		}
	};

	let (sub, listing) = tokio::join!(metadata, listing);

	let req_url = req.uri().to_string();
	// Return landing page if this is an NSFW community but the user has disabled the
	// display of NSFW content or if the instance is SFW-only. (The listing was already
	// fetched alongside the metadata; that one wasted request is the price of the join.)
	if sub.nsfw && crate::utils::should_be_nsfw_gated(&req, &req_url) {
		return Ok(nsfw_landing(req, req_url).await.unwrap_or_default());
	}

	match listing {
		None => Ok(template(&SubredditTemplate {
			sub,
			posts: Vec::new(),
			sort: (sort, param(&path, "t").unwrap_or_default()),
			ends: (param(&path, "after").unwrap_or_default(), String::new()),
			prefs: Preferences::new(&req),
			url,
			redirect_url,
			is_filtered: true,
			all_posts_filtered: false,
			all_posts_hidden_nsfw: false,
			no_posts: false,
			feed,
		})),
		Some(Ok((mut posts, after))) => {
			let (_, all_posts_filtered) = filter_posts(&mut posts, &filters);
			let no_posts = posts.is_empty();
			let all_posts_hidden_nsfw = !no_posts && (posts.iter().all(|p| p.flags.nsfw) && setting(&req, "show_nsfw") != "on");
			if sort == "new" {
				posts.sort_by_key(|post| std::cmp::Reverse(post.created_ts));
				posts.sort_by_key(|post| std::cmp::Reverse(post.flags.stickied));
			}
			Ok(template(&SubredditTemplate {
				sub,
				posts,
				sort: (sort, param(&path, "t").unwrap_or_default()),
				ends: (param(&path, "after").unwrap_or_default(), after),
				prefs: Preferences::new(&req),
				url,
				redirect_url,
				is_filtered: false,
				all_posts_filtered,
				all_posts_hidden_nsfw,
				no_posts,
				feed,
			}))
		}
		Some(Err(msg)) => match msg.as_str() {
			"quarantined" | "gated" => Ok(quarantine(&req, sub_name, &msg)),
			"private" => error(req, &format!("r/{sub_name} is a private community")).await,
			"banned" => error(req, &format!("r/{sub_name} has been banned from Reddit")).await,
			_ => error(req, &msg).await,
		},
	}
}

pub fn quarantine(req: &Request<Body>, sub: String, restriction: &str) -> Response<Body> {
	let wall = WallTemplate {
		title: format!("r/{sub} is {restriction}"),
		msg: "Please click the button below to continue to this subreddit.".to_string(),
		url: req.uri().to_string(),
		sub,
		prefs: Preferences::new(req),
	};

	Response::builder()
		.status(403)
		.header("content-type", "text/html")
		.body(wall.render().unwrap_or_default().into())
		.unwrap_or_default()
}

pub async fn add_quarantine_exception(req: Request<Body>) -> Result<Response<Body>, String> {
	let subreddit = req.param("sub").ok_or("Invalid URL")?;
	let redir = param(&format!("?{}", req.uri().query().unwrap_or_default()), "redir").ok_or("Invalid URL")?;
	let mut response = redirect(&redir);
	response.insert_cookie(
		Cookie::build((&format!("allow_quaran_{}", subreddit.to_lowercase()), "true"))
			.path("/")
			.http_only(true)
			.expires(cookie::Expiration::Session)
			.into(),
	);
	Ok(response)
}

pub fn can_access_quarantine(req: &Request<Body>, sub: &str) -> bool {
	// Determine if the subreddit can be accessed
	setting(req, &format!("allow_quaran_{}", sub.to_lowercase())).parse().unwrap_or_default()
}

/// The display name to store for one `+`-separated part of a subscribe/filter request:
/// Reddit's casing, from the sub's listing when it is there, else from its about.json.
async fn display_name(part: &str, listing_names: &[(String, &str)]) -> String {
	if part.starts_with("u_") {
		return part.to_owned();
	}
	let lowercase = part.to_lowercase();
	if let Some(&(_, display)) = listing_names.iter().find(|(name, _)| *name == lowercase) {
		return display.to_owned();
	}
	match json(format!("/r/{part}/about.json?raw_json=1"), true).await {
		Ok(about) => about["data"]["display_name"].as_str().unwrap_or(part).to_owned(),
		Err(_) => part.to_owned(),
	}
}

/// Applies the request path's action to one sub name. The tests are "the path has this
/// segment", in this order, so a sub literally named e.g. `filter` can match two of them.
fn apply_list_action(action: &[String], part: &str, sub_list: &mut Vec<String>, filters: &mut Vec<String>) {
	let has = |segment: &str| action.iter().any(|s| s == segment);
	let owned = part.to_owned();
	let lowercase = part.to_lowercase();
	if has("subscribe") && !sub_list.contains(&owned) {
		sub_list.push(owned);
		filters.retain(|s| s.to_lowercase() != lowercase);
		sub_list.sort_by_key(|a| a.to_lowercase());
		filters.sort_by_key(|a| a.to_lowercase());
	} else if has("unsubscribe") {
		sub_list.retain(|s| s.to_lowercase() != lowercase);
	} else if has("filter") && !filters.contains(&owned) {
		filters.push(owned);
		sub_list.retain(|s| s.to_lowercase() != lowercase);
		filters.sort_by_key(|a| a.to_lowercase());
		sub_list.sort_by_key(|a| a.to_lowercase());
	} else if has("unfilter") {
		filters.retain(|s| s.to_lowercase() != lowercase);
	}
}

// Sub, filter, unfilter, or unsub by setting subscription cookie using response "Set-Cookie" header
pub async fn subscriptions_filters(req: Request<Body>) -> Result<Response<Body>, String> {
	let sub = req.param("sub").unwrap_or_default();
	let action: Vec<String> = req.uri().path().split('/').map(String::from).collect();

	// Handle random subreddits
	if sub == "random" || sub == "randnsfw" {
		if action.iter().any(|s| s == "filter" || s == "unfilter") {
			return Err("Can't filter random subreddit!".to_string());
		}
		return Err("Can't subscribe to random subreddit!".to_string());
	}

	let query = req.uri().query().unwrap_or_default().to_string();

	let preferences = Preferences::new(&req);
	let mut sub_list = preferences.subscriptions;
	let mut filters = preferences.filters;

	// The sub's hot listing carries each post's subreddit display name, which spares an
	// about.json request per part in display_name.
	let posts = json(format!("/r/{sub}/hot.json?raw_json=1"), true).await;
	let listing_names: Vec<(String, &str)> = posts
		.as_ref()
		.ok()
		.and_then(|posts| posts["data"]["children"].as_array())
		.map(|list| {
			list
				.iter()
				.map(|post| {
					let display_name = post["data"]["subreddit"].as_str().unwrap_or_default();
					(display_name.to_lowercase(), display_name)
				})
				.collect()
		})
		.unwrap_or_default();

	for part in sub.split('+').filter(|x| x != &"") {
		let part = display_name(part, &listing_names).await;
		apply_list_action(&action, &part, &mut sub_list, &mut filters);
	}

	// Redirect back to subreddit
	// check for redirect parameter if unsubscribing/unfiltering from outside sidebar
	let path = param(&format!("?{query}"), "redirect").map_or_else(|| format!("/r/{sub}"), |redirect_path| format!("/{redirect_path}"));

	let mut response = redirect(&path);
	let has_cookie = |name: &str| req.cookie(name).is_some();
	set_cookie_chain(&mut response, "subscriptions", (!sub_list.is_empty()).then_some(sub_list.as_slice()), has_cookie);
	set_cookie_chain(&mut response, "filters", (!filters.is_empty()).then_some(filters.as_slice()), has_cookie);

	Ok(response)
}

pub async fn wiki(req: Request<Body>) -> Result<Response<Body>, String> {
	let sub = req.param("sub").unwrap_or_else(|| "reddit.com".to_string());
	let quarantined = can_access_quarantine(&req, &sub);
	// Handle random subreddits
	if let Ok(random) = catch_random(&sub, "/wiki").await {
		return Ok(random);
	}

	let page = req.param("page").unwrap_or_else(|| "index".to_string());
	let path: String = format!("/r/{sub}/wiki/{page}.json?raw_json=1");
	let url = req.uri().to_string();

	match json(path, quarantined).await {
		Ok(response) => Ok(template(&WikiTemplate {
			sub,
			wiki: rewrite_urls(response["data"]["content_html"].as_str().unwrap_or("<h3>Wiki not found</h3>")),
			page,
			prefs: Preferences::new(&req),
			url,
		})),
		Err(msg) => {
			if msg == "quarantined" || msg == "gated" {
				Ok(quarantine(&req, sub, &msg))
			} else {
				error(req, &msg).await
			}
		}
	}
}

pub async fn sidebar(req: Request<Body>) -> Result<Response<Body>, String> {
	let sub = req.param("sub").unwrap_or_else(|| "reddit.com".to_string());
	let quarantined = can_access_quarantine(&req, &sub);

	// Handle random subreddits
	if let Ok(random) = catch_random(&sub, "/about/sidebar").await {
		return Ok(random);
	}

	// Build the Reddit JSON API url
	let path: String = format!("/r/{sub}/about.json?raw_json=1");
	let url = req.uri().to_string();

	// Send a request to the url
	match json(path, quarantined).await {
		// If success, receive JSON in response
		Ok(response) => Ok(template(&WikiTemplate {
			wiki: rewrite_urls(&val(&response, "description_html")),
			// wiki: format!(
			// 	"{}<hr><h1>Moderators</h1><br><ul>{}</ul>",
			// 	rewrite_urls(&val(&response, "description_html"),
			// 	moderators(&sub, quarantined).await.unwrap_or(vec!["Could not fetch moderators".to_string()]).join(""),
			// ),
			sub,
			page: "Sidebar".to_string(),
			prefs: Preferences::new(&req),
			url,
		})),
		Err(msg) => {
			if msg == "quarantined" || msg == "gated" {
				Ok(quarantine(&req, sub, &msg))
			} else {
				error(req, &msg).await
			}
		}
	}
}

// pub async fn moderators(sub: &str, quarantined: bool) -> Result<Vec<String>, String> {
// 	// Retrieve and format the html for the moderators list
// 	Ok(
// 		moderators_list(sub, quarantined)
// 			.await?
// 			.iter()
// 			.map(|m| format!("<li><a style=\"color: var(--accent)\" href=\"/u/{name}\">{name}</a></li>", name = m))
// 			.collect(),
// 	)
// }

// async fn moderators_list(sub: &str, quarantined: bool) -> Result<Vec<String>, String> {
// 	// Build the moderator list URL
// 	let path: String = format!("/r/{}/about/moderators.json?raw_json=1", sub);

// 	// Retrieve response
// 	json(path, quarantined).await.map(|response| {
// 		// Traverse json tree and format into list of strings
// 		response["data"]["children"]
// 			.as_array()
// 			.unwrap_or(&Vec::new())
// 			.iter()
// 			.filter_map(|moderator| {
// 				let name = moderator["name"].as_str().unwrap_or_default();
// 				if name.is_empty() {
// 					None
// 				} else {
// 					Some(name.to_string())
// 				}
// 			})
// 			.collect::<Vec<_>>()
// 	})
// }

// SUBREDDIT
pub async fn subreddit(sub: &str, quarantined: bool) -> Result<Subreddit, String> {
	// Build the Reddit JSON API url
	let path: String = format!("/r/{sub}/about.json?raw_json=1");

	// Send a request to the url
	let res = json(path, quarantined).await?;

	// Metadata regarding the subreddit
	let members: i64 = res["data"]["subscribers"].as_u64().unwrap_or_default() as i64;
	let active: i64 = res["data"]["accounts_active"].as_u64().unwrap_or_default() as i64;

	// Fetch subreddit icon either from the community_icon or icon_img value
	let community_icon: &str = res["data"]["community_icon"].as_str().unwrap_or_default();
	let icon = if community_icon.is_empty() { val(&res, "icon_img") } else { community_icon.to_string() };

	Ok(Subreddit {
		name: val(&res, "display_name"),
		title: val(&res, "title"),
		description: val(&res, "public_description"),
		info: rewrite_urls(&val(&res, "description_html")),
		// moderators: moderators_list(sub, quarantined).await.unwrap_or_default(),
		icon: format_url(&icon),
		members: format_num(members),
		active: format_num(active),
		wiki: res["data"]["wiki_enabled"].as_bool().unwrap_or_default(),
		nsfw: res["data"]["over18"].as_bool().unwrap_or_default(),
	})
}

#[cfg(test)]
mod tests {
	use super::*;

	fn owned(items: &[&str]) -> Vec<String> {
		items.iter().map(|s| (*s).to_string()).collect()
	}

	#[test]
	fn front_page_sub_prefers_the_setting_then_subscriptions_then_popular() {
		assert_eq!(front_page_sub("", ""), "popular");
		assert_eq!(front_page_sub("default", ""), "popular");
		assert_eq!(front_page_sub("default", "rust+linux"), "rust+linux");
		assert_eq!(front_page_sub("", "rust"), "rust");
		assert_eq!(front_page_sub("all", "rust"), "all");
	}

	#[test]
	fn list_actions_move_a_sub_between_subscriptions_and_filters() {
		let path = |action: &str| owned(&["", "r", "Rust", action]);
		let (mut subs, mut filters) = (owned(&["linux"]), owned(&["rust"]));

		apply_list_action(&path("subscribe"), "Rust", &mut subs, &mut filters);
		assert_eq!((subs.clone(), filters.clone()), (owned(&["linux", "Rust"]), owned(&[])));

		apply_list_action(&path("filter"), "Rust", &mut subs, &mut filters);
		assert_eq!((subs.clone(), filters.clone()), (owned(&["linux"]), owned(&["Rust"])));

		apply_list_action(&path("unfilter"), "rust", &mut subs, &mut filters);
		apply_list_action(&path("unsubscribe"), "LINUX", &mut subs, &mut filters);
		assert_eq!((subs, filters), (owned(&[]), owned(&[])));
	}

	#[test]
	fn list_action_tests_path_segments_in_order() {
		// Already subscribed, so "subscribe" does nothing and the sub's own name, a later
		// segment test, applies: the order apply_list_action documents.
		let action = owned(&["", "r", "filter", "subscribe"]);
		let (mut subs, mut filters) = (owned(&["filter"]), owned(&[]));
		apply_list_action(&action, "filter", &mut subs, &mut filters);
		assert_eq!((subs, filters), (owned(&[]), owned(&["filter"])));
	}

	#[tokio::test(flavor = "multi_thread")]
	#[ignore = "hits live reddit"]
	async fn test_fetching_subreddit() {
		crate::client::init_oauth_client().await;
		let subreddit = subreddit("rust", false).await;
		assert!(subreddit.is_ok());
	}

	#[tokio::test(flavor = "multi_thread")]
	#[ignore = "hits live reddit"]
	async fn test_gated_and_quarantined() {
		crate::client::init_oauth_client().await;
		let quarantined = subreddit("edgy", true).await;
		assert!(quarantined.is_ok());
		let gated = subreddit("drugs", true).await;
		assert!(gated.is_ok());
	}
}
