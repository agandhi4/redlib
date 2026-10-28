//! The subreddit RSS feed (`/r/:sub.rss`), enabled by `REDLIB_ENABLE_RSS`.

use crate::config;
use crate::model::{get_post_url, Post};
use crate::rewrite::{format_url, rewrite_urls};
use crate::server::RequestExt;
use crate::subreddit::{listing_sort, subreddit};
use crate::utils::{error, to_absolute_url};
use chrono::DateTime;
use htmlescape::decode_html;
use hyper::{Body, Request, Response};
use rss::{ChannelBuilder, Enclosure, Item};

pub async fn rss(req: Request<Body>) -> Result<Response<Body>, String> {
	if config::get_setting("REDLIB_ENABLE_RSS").is_none() {
		return Ok(error(req, "RSS is disabled on this instance.").await.unwrap_or_default());
	}

	use hyper::header::CONTENT_TYPE;

	// Get subreddit
	let sub = req.param("sub").unwrap_or_default();
	let sort = listing_sort(&req);

	// Get path
	let path = format!("/r/{sub}/{sort}.json?{}", req.uri().query().unwrap_or_default());

	// Get subreddit link
	let subreddit_link: String = format!("{}/r/{sub}", config::get_setting("REDLIB_FULL_URL").unwrap_or_default());

	// Get subreddit data
	let subreddit = subreddit(&sub, false).await?;

	// Get posts
	let (posts, _) = Post::fetch(&path, false).await?;

	// Build the RSS feed
	let channel = ChannelBuilder::default()
		.title(&subreddit.title)
		.description(&subreddit.description)
		.link(&subreddit_link)
		.items(
			posts
				.into_iter()
				.map(|post| {
					let mut item = Item {
						title: Some(post.title.to_string()),
						link: Some(format_url(&get_post_url(&post))),
						author: Some(post.author.name.to_string()),
						content: Some(rewrite_urls(&decode_html(&post.body).unwrap())),
						pub_date: Some(DateTime::from_timestamp(post.created_ts as i64, 0).unwrap_or_default().to_rfc2822()),
						description: Some(format!("<a href='{}'>Comments</a>", to_absolute_url(&post.permalink))),
						..Default::default()
					};

					apply_enclosure(&mut item, &post);
					item
				})
				.collect::<Vec<_>>(),
		)
		.build();

	// Serialize the feed to RSS
	let body = channel.to_string().into_bytes();

	// Create the HTTP response
	let mut res = Response::new(Body::from(body));
	res.headers_mut().insert(CONTENT_TYPE, hyper::header::HeaderValue::from_static("application/rss+xml"));

	Ok(res)
}

// Set enclosure image for RSS feed item
fn apply_enclosure(item: &mut Item, post: &Post) {
	item.set_enclosure(get_rss_image(post));

	// Embed the number of gallery images in description and content since
	// only the first image in the gallery is used for the enclosure
	if post.post_type == "gallery" && post.gallery.len() > 1 {
		item.set_description(format!("<a href='{}'>Gallery with {} images</a>", to_absolute_url(&post.permalink), post.gallery.len()));

		if let Some(content) = item.content() {
			let new_content = format!("{}<br/>{}", item.description().unwrap_or(""), content,);
			item.set_content(new_content);
		}
	}
}

fn get_rss_image(post: &Post) -> Option<Enclosure> {
	let image_url = match post.post_type.as_str() {
		"image" => Some(post.media.url.clone()),
		"gallery" => post.gallery.first().and_then(|media| decode_html(&media.url).ok()),
		"gif" | "video" => decode_html(&post.media.poster).ok(),
		_ => None,
	};

	image_url.map(|url| {
		let mut enclosure = Enclosure::default();
		enclosure.set_mime_type(get_mime_type(&url));
		enclosure.set_url(to_absolute_url(&url));
		enclosure.set_length("0");
		enclosure
	})
}

/// Determines the MIME type based on file extension in a URL.
/// Handles both absolute and relative URLs with query parameters.
fn get_mime_type(url: &str) -> &'static str {
	// Extract the path component, removing query parameters
	let path = url.split('?').next().unwrap_or(url);

	// Get the file extension (everything after the last dot)
	let extension = path.rsplit('.').next().unwrap_or("").to_lowercase();

	// Match common image extensions
	match extension.as_str() {
		"jpg" | "jpeg" => "image/jpeg",
		"png" => "image/png",
		"gif" => "image/gif",
		"webp" => "image/webp",
		"svg" => "image/svg+xml",
		_ => "application/octet-stream",
	}
}
