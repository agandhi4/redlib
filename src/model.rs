//! The Reddit things redlib renders (posts, comments, flair, polls, awards, users, subreddits)
//! and their parsing from Reddit's JSON. Post media is `media::Media`.

#![allow(clippy::cmp_owned)]

use crate::client::json;
use crate::config::get_setting;
use crate::media::{GalleryMedia, Media};
use crate::preferences::Preferences;
use crate::rewrite::{format_url, rewrite_urls};
use crate::utils::{format_num, time, to_absolute_url, val};
use askama::Template;
use serde::Serialize;
use serde_json::Value;
use std::collections::HashSet;
use std::str::FromStr;

/// Post flair with content, background color and foreground color
#[derive(Serialize)]
pub struct Flair {
	pub flair_parts: Vec<FlairPart>,
	pub text: String,
	pub background_color: String,
	pub foreground_color: String,
}

/// Part of flair, either emoji or text
#[derive(Clone, Serialize)]
pub struct FlairPart {
	pub flair_part_type: String,
	pub value: String,
}

impl FlairPart {
	pub fn parse(flair_type: &str, rich_flair: Option<&Vec<Value>>, text_flair: Option<&str>) -> Vec<Self> {
		// Parse type of flair
		match flair_type {
			// If flair contains emojis and text
			"richtext" => match rich_flair {
				Some(rich) => rich
					.iter()
					// For each part of the flair, extract text and emojis
					.map(|part| {
						let value = |name: &str| part[name].as_str().unwrap_or_default();
						Self {
							flair_part_type: value("e").to_string(),
							value: match value("e") {
								"text" => value("t").to_string(),
								"emoji" => format_url(value("u")),
								_ => String::new(),
							},
						}
					})
					.collect::<Vec<Self>>(),
				None => Vec::new(),
			},
			// If flair contains only text
			"text" => match text_flair {
				Some(text) => vec![Self {
					flair_part_type: "text".to_string(),
					value: text.to_string(),
				}],
				None => Vec::new(),
			},
			_ => Vec::new(),
		}
	}
}

#[derive(Serialize)]
pub struct Author {
	pub name: String,
	pub flair: Flair,
	pub distinguished: String,
}

#[derive(Serialize)]
pub struct Poll {
	pub poll_options: Vec<PollOption>,
	pub voting_end_timestamp: (String, String),
	pub total_vote_count: u64,
}

impl Poll {
	pub fn parse(poll_data: &Value) -> Option<Self> {
		poll_data.as_object()?;

		let total_vote_count = poll_data["total_vote_count"].as_u64()?;
		// voting_end_timestamp is in the format of milliseconds
		let voting_end_timestamp = time(poll_data["voting_end_timestamp"].as_f64()? / 1000.0);
		let poll_options = PollOption::parse(&poll_data["options"])?;

		Some(Self {
			poll_options,
			voting_end_timestamp,
			total_vote_count,
		})
	}

	pub fn most_votes(&self) -> u64 {
		self.poll_options.iter().filter_map(|o| o.vote_count).max().unwrap_or(0)
	}
}

#[derive(Serialize)]
pub struct PollOption {
	pub id: u64,
	pub text: String,
	pub vote_count: Option<u64>,
}

impl PollOption {
	pub fn parse(options: &Value) -> Option<Vec<Self>> {
		Some(
			options
				.as_array()?
				.iter()
				.filter_map(|option| {
					// For each poll option

					// we can't just use as_u64() because "id": String("...") and serde would parse it as None
					let id = option["id"].as_str()?.parse::<u64>().ok()?;
					let text = option["text"].as_str()?.to_owned();
					let vote_count = option["vote_count"].as_u64();

					// Construct PollOption items
					Some(Self { id, text, vote_count })
				})
				.collect::<Vec<Self>>(),
		)
	}
}

/// Post flags with NSFW and stickied
#[derive(Serialize)]
pub struct Flags {
	pub spoiler: bool,
	pub nsfw: bool,
	pub stickied: bool,
}

/// Post containing content, metadata and media
#[derive(Serialize)]
pub struct Post {
	pub id: String,
	pub title: String,
	pub community: String,
	pub body: String,
	pub author: Author,
	pub permalink: String,
	pub link_title: String,
	pub poll: Option<Poll>,
	pub score: (String, String),
	pub upvote_ratio: i64,
	pub post_type: String,
	pub flair: Flair,
	pub flags: Flags,
	pub thumbnail: Media,
	pub media: Media,
	pub domain: String,
	pub rel_time: String,
	pub created: String,
	pub created_ts: u64,
	pub num_duplicates: u64,
	pub comments: (String, String),
	pub gallery: Vec<GalleryMedia>,
	pub awards: Awards,
	pub nsfw: bool,
	pub out_url: Option<String>,
	pub ws_url: String,
	#[serde(skip)]
	pub is_saved: bool,
}

impl Post {
	/// Fetch posts of a user or subreddit and return a vector of posts and the "after" value
	pub async fn fetch(path: &str, quarantine: bool) -> Result<(Vec<Self>, String), String> {
		// Send a request to the url
		let res = match json(path.to_string(), quarantine).await {
			// If success, receive JSON in response
			Ok(response) => response,
			// If the Reddit API returns an error, exit this function
			Err(msg) => return Err(msg),
		};

		// Fetch the list of posts from the JSON response
		// No `children` at all (an empty listing still has `[]`): Reddit sent something else to
		// this token. See client::distrust_listing.
		let Some(post_list) = res["data"]["children"].as_array() else {
			return Err(crate::client::distrust_listing(path, quarantine, &res).await);
		};

		let mut posts: Vec<Self> = Vec::new();

		// For each post from posts list
		for post in post_list {
			let data = &post["data"];

			let (rel_time, created) = time(data["created_utc"].as_f64().unwrap_or_default());
			let created_ts = data["created_utc"].as_f64().unwrap_or_default().round() as u64;
			let score = data["score"].as_i64().unwrap_or_default();
			let ratio: f64 = data["upvote_ratio"].as_f64().unwrap_or(1.0) * 100.0;
			let title = val(post, "title");

			// Determine the type of media along with the media URL
			let (post_type, media, gallery) = Media::parse(data).await;
			let awards = Awards::parse(&data["all_awardings"]);

			// selftext_html is set for text posts when browsing.
			let mut body = rewrite_urls(&val(post, "selftext_html"));
			if body.is_empty() {
				body = rewrite_urls(&val(post, "body_html"));
			}

			posts.push(Self {
				id: val(post, "id"),
				title,
				community: val(post, "subreddit"),
				body,
				author: Author {
					name: val(post, "author"),
					flair: Flair {
						flair_parts: FlairPart::parse(
							data["author_flair_type"].as_str().unwrap_or_default(),
							data["author_flair_richtext"].as_array(),
							data["author_flair_text"].as_str(),
						),
						text: val(post, "link_flair_text"),
						background_color: val(post, "author_flair_background_color"),
						foreground_color: val(post, "author_flair_text_color"),
					},
					distinguished: val(post, "distinguished"),
				},
				score: if data["hide_score"].as_bool().unwrap_or_default() {
					("\u{2022}".to_string(), "Hidden".to_string())
				} else {
					format_num(score)
				},
				upvote_ratio: ratio as i64,
				post_type,
				thumbnail: Media {
					url: format_url(val(post, "thumbnail").as_str()),
					alt_url: String::new(),
					width: data["thumbnail_width"].as_i64().unwrap_or_default(),
					height: data["thumbnail_height"].as_i64().unwrap_or_default(),
					poster: String::new(),
					download_name: String::new(),
				},
				media,
				domain: val(post, "domain"),
				flair: Flair {
					flair_parts: FlairPart::parse(
						data["link_flair_type"].as_str().unwrap_or_default(),
						data["link_flair_richtext"].as_array(),
						data["link_flair_text"].as_str(),
					),
					text: val(post, "link_flair_text"),
					background_color: val(post, "link_flair_background_color"),
					foreground_color: if val(post, "link_flair_text_color") == "dark" {
						"black".to_string()
					} else {
						"white".to_string()
					},
				},
				flags: Flags {
					spoiler: data["spoiler"].as_bool().unwrap_or_default(),
					nsfw: data["over_18"].as_bool().unwrap_or_default(),
					stickied: data["stickied"].as_bool().unwrap_or_default() || data["pinned"].as_bool().unwrap_or_default(),
				},
				permalink: val(post, "permalink"),
				link_title: val(post, "link_title"),
				poll: Poll::parse(&data["poll_data"]),
				rel_time,
				created,
				created_ts,
				num_duplicates: post["data"]["num_duplicates"].as_u64().unwrap_or(0),
				comments: format_num(data["num_comments"].as_i64().unwrap_or_default()),
				gallery,
				awards,
				nsfw: post["data"]["over_18"].as_bool().unwrap_or_default(),
				ws_url: val(post, "websocket_url"),
				out_url: post["data"]["url_overridden_by_dest"].as_str().map(|a| a.to_string()),
				is_saved: false,
			});
		}
		Ok((posts, res["data"]["after"].as_str().unwrap_or_default().to_string()))
	}
}

#[derive(Template)]
#[template(path = "comment.html")]
/// Comment with content, post, score and data/time that it was posted
pub struct Comment {
	pub id: String,
	pub kind: String,
	pub parent_id: String,
	pub parent_kind: String,
	pub post_link: String,
	pub post_author: String,
	pub body: String,
	pub author: Author,
	pub score: (String, String),
	pub rel_time: String,
	pub created: String,
	pub edited: (String, String),
	pub replies: Vec<Comment>,
	pub highlighted: bool,
	pub awards: Awards,
	pub collapsed: bool,
	pub is_filtered: bool,
	pub more_count: i64,
	/// Where a "more" placeholder links (`comments::build_comment`): its GraphQL cursor when it
	/// has one, else the parent comment's page.
	pub more_href: String,
	pub prefs: Preferences,
}

#[derive(Default, Clone, Serialize)]
pub struct Award {
	pub name: String,
	pub icon_url: String,
	pub description: String,
	pub count: i64,
}

impl std::fmt::Display for Award {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		write!(f, "{} {} {}", self.name, self.icon_url, self.description)
	}
}

#[derive(Serialize)]
pub struct Awards(pub Vec<Award>);

impl std::ops::Deref for Awards {
	type Target = Vec<Award>;

	fn deref(&self) -> &Self::Target {
		&self.0
	}
}

impl std::fmt::Display for Awards {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		self.iter().try_fold((), |_, award| writeln!(f, "{award}"))
	}
}

impl Awards {
	/// Convert Reddit awards JSON to Awards struct
	pub fn parse(items: &Value) -> Self {
		let parsed = items.as_array().unwrap_or(&Vec::new()).iter().fold(Vec::new(), |mut awards, item| {
			let name = item["name"].as_str().unwrap_or_default().to_string();
			let icon_url = format_url(item["resized_icons"][0]["url"].as_str().unwrap_or_default());
			let description = item["description"].as_str().unwrap_or_default().to_string();
			let count: i64 = i64::from_str(&item["count"].to_string()).unwrap_or(1);

			awards.push(Award {
				name,
				icon_url,
				description,
				count,
			});

			awards
		});

		Self(parsed)
	}
}

#[derive(Default)]
/// User struct containing metadata about user
pub struct User {
	pub name: String,
	pub title: String,
	pub icon: String,
	pub karma: i64,
	pub created: String,
	pub banner: String,
	pub description: String,
	pub nsfw: bool,
}

#[derive(Default)]
/// Subreddit struct containing metadata about community
pub struct Subreddit {
	pub name: String,
	pub title: String,
	pub description: String,
	pub info: String,
	// pub moderators: Vec<String>,
	pub icon: String,
	pub members: (String, String),
	pub active: (String, String),
	pub wiki: bool,
	pub nsfw: bool,
}

/// Filters a `Vec<Post>` by the given `HashSet` of filters (each filter being
/// a subreddit name or a user name). If a `Post`'s subreddit or author is
/// found in the filters, it is removed.
///
/// The first value of the return tuple is the number of posts filtered. The
/// second return value is `true` if all posts were filtered.
pub fn filter_posts(posts: &mut Vec<Post>, filters: &HashSet<String>) -> (u64, bool) {
	// This is the length of the Vec<Post> prior to applying the filter.
	let lb: u64 = posts.len().try_into().unwrap_or(0);

	if posts.is_empty() {
		(0, false)
	} else {
		posts.retain(|p| !(filters.contains(&p.community) || filters.contains(&["u_", &p.author.name].concat())));

		// Get the length of the Vec<Post> after applying the filter.
		// If lb > la, then at least one post was removed.
		let la: u64 = posts.len().try_into().unwrap_or(0);

		(lb - la, posts.is_empty())
	}
}

/// Creates a [`Post`] from a provided JSON.
pub async fn parse_post(post: &Value) -> Post {
	// Grab UTC time as unix timestamp
	let (rel_time, created) = time(post["data"]["created_utc"].as_f64().unwrap_or_default());
	// Parse post score and upvote ratio
	let score = post["data"]["score"].as_i64().unwrap_or_default();
	let ratio: f64 = post["data"]["upvote_ratio"].as_f64().unwrap_or(1.0) * 100.0;

	// Determine the type of media along with the media URL
	let (post_type, media, gallery) = Media::parse(&post["data"]).await;

	let created_ts = post["data"]["created_utc"].as_f64().unwrap_or_default().round() as u64;

	let awards: Awards = Awards::parse(&post["data"]["all_awardings"]);

	let permalink = val(post, "permalink");

	let poll = Poll::parse(&post["data"]["poll_data"]);

	let body = if val(post, "removed_by_category") == "moderator" {
		format!(
			"<div class=\"md\"><p>[removed] — <a href=\"https://{}{permalink}\">view removed post</a></p></div>",
			get_setting("REDLIB_PUSHSHIFT_FRONTEND").unwrap_or_else(|| String::from(crate::config::DEFAULT_PUSHSHIFT_FRONTEND)),
		)
	} else {
		let selftext = val(post, "selftext");
		if selftext.contains("```") {
			let mut html_output = String::new();
			let parser = pulldown_cmark::Parser::new(&selftext);
			pulldown_cmark::html::push_html(&mut html_output, parser);
			rewrite_urls(&html_output)
		} else {
			rewrite_urls(&val(post, "selftext_html"))
		}
	};

	// Build a post using data parsed from Reddit post API
	Post {
		id: val(post, "id"),
		title: val(post, "title"),
		community: val(post, "subreddit"),
		body,
		author: Author {
			name: val(post, "author"),
			flair: Flair {
				flair_parts: FlairPart::parse(
					post["data"]["author_flair_type"].as_str().unwrap_or_default(),
					post["data"]["author_flair_richtext"].as_array(),
					post["data"]["author_flair_text"].as_str(),
				),
				text: val(post, "link_flair_text"),
				background_color: val(post, "author_flair_background_color"),
				foreground_color: val(post, "author_flair_text_color"),
			},
			distinguished: val(post, "distinguished"),
		},
		permalink,
		link_title: val(post, "link_title"),
		poll,
		score: format_num(score),
		upvote_ratio: ratio as i64,
		post_type,
		media,
		thumbnail: Media {
			url: format_url(val(post, "thumbnail").as_str()),
			alt_url: String::new(),
			width: post["data"]["thumbnail_width"].as_i64().unwrap_or_default(),
			height: post["data"]["thumbnail_height"].as_i64().unwrap_or_default(),
			poster: String::new(),
			download_name: String::new(),
		},
		flair: Flair {
			flair_parts: FlairPart::parse(
				post["data"]["link_flair_type"].as_str().unwrap_or_default(),
				post["data"]["link_flair_richtext"].as_array(),
				post["data"]["link_flair_text"].as_str(),
			),
			text: val(post, "link_flair_text"),
			background_color: val(post, "link_flair_background_color"),
			foreground_color: if val(post, "link_flair_text_color") == "dark" {
				"black".to_string()
			} else {
				"white".to_string()
			},
		},
		flags: Flags {
			spoiler: post["data"]["spoiler"].as_bool().unwrap_or_default(),
			nsfw: post["data"]["over_18"].as_bool().unwrap_or_default(),
			stickied: post["data"]["stickied"].as_bool().unwrap_or_default() || post["data"]["pinned"].as_bool().unwrap_or(false),
		},
		domain: val(post, "domain"),
		rel_time,
		created,
		created_ts,
		num_duplicates: post["data"]["num_duplicates"].as_u64().unwrap_or(0),
		comments: format_num(post["data"]["num_comments"].as_i64().unwrap_or_default()),
		gallery,
		awards,
		nsfw: post["data"]["over_18"].as_bool().unwrap_or_default(),
		ws_url: val(post, "websocket_url"),
		out_url: post["data"]["url_overridden_by_dest"].as_str().map(|a| a.to_string()),
		is_saved: false,
	}
}

/// Returns the absolute URL of a post, as needed by RSS feeds
pub fn get_post_url(post: &Post) -> String {
	match post.post_type.as_str() {
		"image" | "gallery" | "gif" | "video" => return to_absolute_url(&post.permalink),
		_ => {}
	}

	if let Some(out_url) = &post.out_url {
		return if out_url.starts_with("/r/") { to_absolute_url(out_url) } else { out_url.clone() };
	}

	to_absolute_url(&post.permalink)
}

#[cfg(test)]
mod tests {
	use super::*;

	#[tokio::test(flavor = "multi_thread")]
	#[ignore = "hits live reddit"]
	async fn test_fetching_subreddit_quarantined() {
		crate::oauth::init_oauth_client().await;
		let subreddit = Post::fetch("/r/drugs", true).await;
		assert!(subreddit.is_ok());
		assert!(!subreddit.unwrap().0.is_empty());
	}

	#[tokio::test(flavor = "multi_thread")]
	#[ignore = "hits live reddit"]
	async fn test_fetching_nsfw_subreddit() {
		crate::oauth::init_oauth_client().await;
		// Gonwild is a place for closed, Euclidean Geometric shapes to exchange their nth terms for karma; showing off their edges in a comfortable environment without pressure.
		// Find a good sub that is tagged NSFW but that actually isn't in case my future employers are watching (they probably are)
		// switched from randnsfw as it is no longer functional.
		let subreddit = Post::fetch("/r/gonwild", false).await;
		assert!(subreddit.is_ok());
		assert!(!subreddit.unwrap().0.is_empty());
	}

	#[tokio::test(flavor = "multi_thread")]
	#[ignore = "hits live reddit"]
	async fn test_fetching_ws() {
		crate::oauth::init_oauth_client().await;
		let subreddit = Post::fetch("/r/popular", false).await;
		assert!(subreddit.is_ok());
		for post in subreddit.unwrap().0 {
			assert!(post.ws_url.starts_with("wss://k8s-lb.wss.redditmedia.com/link/"));
		}
	}
}
