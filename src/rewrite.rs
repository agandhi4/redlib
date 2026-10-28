//! Rewrites Reddit URLs onto this instance's routes (`format_url`), and Reddit's body HTML:
//! links, previews and emoji (`rewrite_urls`), emotes (`rewrite_emotes`), `- ` bullet lines.

use regex::Regex;
use serde_json::Value;
use serde_json_path::{JsonPath, JsonPathExt};
use std::sync::LazyLock;
use url::Url;

static REGEX_URL_WWW: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"https?://www\.reddit\.com/(.*)").unwrap());
static REGEX_URL_OLD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"https?://old\.reddit\.com/(.*)").unwrap());
static REGEX_URL_NP: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"https?://np\.reddit\.com/(.*)").unwrap());
static REGEX_URL_PLAIN: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"https?://reddit\.com/(.*)").unwrap());
// A video's mp4 fallback is DASH_<size> or, on newer uploads, CMAF_<size> (upstream #506).
static REGEX_URL_VIDEOS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"https?://v\.redd\.it/(.*)/(DASH|CMAF)_([0-9]{2,4}(\.mp4|$|\?source=fallback))").unwrap());
static REGEX_URL_VIDEOS_HLS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"https?://v\.redd\.it/(.+)/(HLSPlaylist\.m3u8.*)$").unwrap());
static REGEX_URL_IMAGES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"https?://i\.redd\.it/(.*)").unwrap());
static REGEX_URL_THUMBS_A: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"https?://a\.thumbs\.redditmedia\.com/(.*)").unwrap());
static REGEX_URL_THUMBS_B: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"https?://b\.thumbs\.redditmedia\.com/(.*)").unwrap());
static REGEX_URL_EMOJI: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"https?://emoji\.redditmedia\.com/(.*)/(.*)").unwrap());
static REGEX_URL_PREVIEW: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"https?://preview\.redd\.it/(.*)").unwrap());
static REGEX_URL_EXTERNAL_PREVIEW: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"https?://external\-preview\.redd\.it/(.*)").unwrap());
static REGEX_URL_STYLES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"https?://styles\.redditmedia\.com/(.*)").unwrap());
static REGEX_URL_STATIC_MEDIA: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"https?://www\.redditstatic\.com/(.*)").unwrap());

/// Direct urls to proxy if proxy is enabled
pub fn format_url(url: &str) -> String {
	if url.is_empty() || url == "self" || url == "default" || url == "nsfw" || url == "spoiler" {
		String::new()
	} else {
		Url::parse(url).map_or(url.to_string(), |parsed| {
			let domain = parsed.domain().unwrap_or_default();

			let capture = |regex: &Regex, format: &str, segments: i16| {
				regex.captures(url).map_or(String::new(), |caps| match segments {
					1 => [format, &caps[1]].join(""),
					2 => [format, &caps[1], "/", &caps[2]].join(""),
					_ => String::new(),
				})
			};

			macro_rules! chain {
				() => {
					{
						String::new()
					}
				};

				( $first_fn:expr, $($other_fns:expr), *) => {
					{
						let result = $first_fn;
						if result.is_empty() {
							chain!($($other_fns,)*)
						}
						else
						{
							result
						}
					}
				};
			}

			match domain {
				"www.reddit.com" => capture(&REGEX_URL_WWW, "/", 1),
				"old.reddit.com" => capture(&REGEX_URL_OLD, "/", 1),
				"np.reddit.com" => capture(&REGEX_URL_NP, "/", 1),
				"reddit.com" => capture(&REGEX_URL_PLAIN, "/", 1),
				"v.redd.it" => chain!(video_url(url), capture(&REGEX_URL_VIDEOS_HLS, "/hls/", 2)),
				"i.redd.it" => capture(&REGEX_URL_IMAGES, "/img/", 1),
				"a.thumbs.redditmedia.com" => capture(&REGEX_URL_THUMBS_A, "/thumb/a/", 1),
				"b.thumbs.redditmedia.com" => capture(&REGEX_URL_THUMBS_B, "/thumb/b/", 1),
				"emoji.redditmedia.com" => capture(&REGEX_URL_EMOJI, "/emoji/", 2),
				"preview.redd.it" => capture(&REGEX_URL_PREVIEW, "/preview/pre/", 1),
				"external-preview.redd.it" => capture(&REGEX_URL_EXTERNAL_PREVIEW, "/preview/external-pre/", 1),
				"styles.redditmedia.com" => capture(&REGEX_URL_STYLES, "/style/", 1),
				"www.redditstatic.com" => capture(&REGEX_URL_STATIC_MEDIA, "/static/", 1),
				_ => url.to_string(),
			}
		})
	}
}

/// `/vid/<id>/<dash|cmaf>/<size>`, the routes in `main.rs` that proxy each container back to its
/// v.redd.it name; empty when `url` is not an mp4 fallback.
fn video_url(url: &str) -> String {
	REGEX_URL_VIDEOS
		.captures(url)
		.map_or(String::new(), |caps| format!("/vid/{}/{}/{}", &caps[1], caps[2].to_ascii_lowercase(), &caps[3]))
}

static REGEX_BULLET: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?m)^- (.*)$").unwrap());
static REGEX_BULLET_CONSECUTIVE_LINES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"</ul>\n<ul>").unwrap());

pub fn render_bullet_lists(input_text: &str) -> String {
	// ref: https://stackoverflow.com/a/4902622
	// First enclose each bullet with <ul> <li> tags
	let text1 = REGEX_BULLET.replace_all(input_text, "<ul><li>$1</li></ul>").to_string();
	// Then remove any consecutive </ul> <ul> tags
	REGEX_BULLET_CONSECUTIVE_LINES.replace_all(&text1, "").to_string()
}

// These are links we want to replace in-body
static REDDIT_REGEX: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"href="(https|http|)://(www\.|old\.|np\.|amp\.|new\.|)(reddit\.com|redd\.it)/"#).unwrap());
static REDDIT_PREVIEW_REGEX: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"https?://(external-preview|preview|i)\.redd\.it(.*)").unwrap());
static REDDIT_EMOJI_REGEX: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"https?://(www|).redditstatic\.com/(.*)").unwrap());
static REDLIB_PREVIEW_LINK_REGEX: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"/(img|preview/)(pre|external-pre)?/(.*?)>"#).unwrap());
static REDLIB_PREVIEW_TEXT_REGEX: LazyLock<Regex> = LazyLock::new(|| Regex::new(r">(.*?)</a>").unwrap());

/// Rewrite Reddit links to Redlib in body of text
pub fn rewrite_urls(input_text: &str) -> String {
	let mut text1 =
		// Rewrite Reddit links to Redlib
		REDDIT_REGEX.replace_all(input_text, r#"href="/"#).to_string();

	loop {
		if REDDIT_EMOJI_REGEX.find(&text1).is_none() {
			break;
		} else {
			text1 = REDDIT_EMOJI_REGEX
				.replace_all(&text1, format_url(REDDIT_EMOJI_REGEX.find(&text1).map(|x| x.as_str()).unwrap_or_default()))
				.to_string()
		}
	}

	// Remove (html-encoded) "\" from URLs.
	text1 = text1.replace("%5C", "").replace("\\_", "_");

	// Rewrite external media previews to Redlib
	loop {
		if REDDIT_PREVIEW_REGEX.find(&text1).is_none() {
			return text1;
		} else {
			let formatted_url = format_url(REDDIT_PREVIEW_REGEX.find(&text1).map(|x| x.as_str()).unwrap_or_default());

			let image_url = REDLIB_PREVIEW_LINK_REGEX.find(&formatted_url).map_or("", |m| m.as_str());
			let mut image_caption = REDLIB_PREVIEW_TEXT_REGEX.find(&formatted_url).map_or("", |m| m.as_str());

			/* As long as image_caption isn't empty remove first and last four characters of image_text to leave us with just the text in the caption without any HTML.
			This makes it possible to enclose it in a <figcaption> later on without having stray HTML breaking it */
			if !image_caption.is_empty() {
				image_caption = &image_caption[1..image_caption.len() - 4];
			}

			// image_url contains > at the end of it, and right above this we remove image_text's front >, leaving us with just a single > between them
			let image_to_replace = format!("<p><a href=\"{image_url}{image_caption}</a></p>");

			/* We don't want to show a caption that's just the image's link, so we check if we find a Reddit preview link within the image's caption.
			If we don't find one we must have actual text, so we include a <figcaption> block that contains it.
			Otherwise we don't include the <figcaption> block as we don't need it. */
			let _image_replacement = if REDDIT_PREVIEW_REGEX.find(image_caption).is_none() {
				// Without this " would show as \" instead. "\&quot;" is how the quotes are formatted within image_text beforehand
				format!(
					"<figure><a href=\"{image_url}<img loading=\"lazy\" src=\"{image_url}</a><figcaption>{}</figcaption></figure>",
					image_caption.replace("\\&quot;", "\"")
				)
			} else {
				format!("<figure><a href=\"{image_url}<img loading=\"lazy\" src=\"{image_url}</a></figure>")
			};

			/* In order to know if we're dealing with a normal or external preview we need to take a look at the first capture group of REDDIT_PREVIEW_REGEX
			if it's preview we're dealing with something that needs /preview/pre, external-preview is /preview/external-pre, and i is /img */
			let reddit_preview_regex_capture = REDDIT_PREVIEW_REGEX.captures(&text1).unwrap().get(1).map_or("", |m| m.as_str());

			let _preview_type = match reddit_preview_regex_capture {
				"preview" => "/preview/pre",
				"external-preview" => "/preview/external-pre",
				_ => "/img",
			};

			text1 = REDDIT_PREVIEW_REGEX
				.replace(&text1, format!("{_preview_type}$2"))
				.replace(&image_to_replace, &_image_replacement)
		}
	}
}

// These links all follow a pattern of "https://reddit-econ-prod-assets-permanent.s3.amazonaws.com/asset-manager/SUBREDDIT_ID/RANDOM_FILENAME.png"
static REDDIT_EMOTE_LINK_REGEX: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"https://reddit-econ-prod-assets-permanent.s3.amazonaws.com/asset-manager/(.*)"#).unwrap());

// These all follow a pattern of '"emote|SUBREDDIT_IT|NUMBER"', we want the number
static REDDIT_EMOTE_ID_NUMBER_REGEX: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#""emote\|.*\|(.*)""#).unwrap());

pub fn rewrite_emotes(media_metadata: &Value, comment: String) -> String {
	/* Create the paths we'll use to look for our data inside the json.
	Because we don't know the name of any given emote we use a wildcard to parse them. */
	let link_path = JsonPath::parse("$[*].s.u").expect("valid JSON Path");
	let id_path = JsonPath::parse("$[*].id").expect("valid JSON Path");
	let size_path = JsonPath::parse("$[*].s.y").expect("valid JSON Path");

	// Extract all of the results from those json paths
	let link_nodes = media_metadata.json_path(&link_path);
	let id_nodes = media_metadata.json_path(&id_path);

	// Initialize our vectors
	let mut id_vec = Vec::new();
	let mut link_vec = Vec::new();

	// Add the relevant data to each of our vectors so we can access it by number later
	for current_id in id_nodes {
		id_vec.push(current_id)
	}
	for current_link in link_nodes {
		link_vec.push(current_link)
	}

	/* Set index to the length of link_vec.
	This is one larger than we'll actually be looking at, but we correct that later */
	let mut index = link_vec.len();

	// Comment needs to be in scope for when we call rewrite_urls()
	let mut comment = comment;

	/* Loop until index hits zero.
	This also prevents us from trying to do anything on an empty vector */
	while index != 0 {
		/* Subtract 1 from index to get the real index we should be looking at.
		Then continue on each subsequent loop to continue until we hit the last entry in the vector.
		This is how we get this to deal with multiple emotes in a single message and properly replace each ID with it's link */
		index -= 1;

		// Convert our current index in id_vec into a string so we can search through it with regex
		let current_id = id_vec[index].to_string();

		/* The ID number can be multiple lengths, so we capture it with regex.
		We also want to only attempt anything when we get matches to avoid panicking */
		if let Some(id_capture) = REDDIT_EMOTE_ID_NUMBER_REGEX.captures(&current_id) {
			// Format the ID to include the colons it has in the comment text
			let id = format!(":{}:", &id_capture[1]);

			// Convert current link to string to search through it with the regex
			let link = link_vec[index].to_string();

			// Make sure we only do operations when we get matches, otherwise we panic when trying to access the first match
			if let Some(link_capture) = REDDIT_EMOTE_LINK_REGEX.captures(&link) {
				/* Reddit sends a size for the image based on whether it's alone or accompanied by text.
				It's a good idea and makes everything look nicer, so we'll do the same. */
				let size = media_metadata.json_path(&size_path).first().unwrap().to_string();

				// Replace the ID we found earlier in the comment with the respective image and it's link from the regex capture
				let to_replace_with = format!(
					"<img loading=\"lazy\" src=\"/emote/{} width=\"{size}\" height=\"{size}\" style=\"vertical-align:text-bottom\">",
					&link_capture[1]
				);

				// Inside the comment replace the ID we found with the string that will embed the image
				comment = comment.replace(&id, &to_replace_with);
			}
		}
	}

	// render bullet (unordered) lists
	comment = render_bullet_lists(&comment);

	// Call rewrite_urls() to transform any other Reddit links
	rewrite_urls(&comment)
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn rewrite_urls_removes_backslashes_and_rewrites_url() {
		assert_eq!(
			rewrite_urls(
				"<a href=\"https://new.reddit.com/r/linux%5C_gaming/comments/x/just%5C_a%5C_test%5C/\">https://new.reddit.com/r/linux\\_gaming/comments/x/just\\_a\\_test/</a>"
			),
			"<a href=\"/r/linux_gaming/comments/x/just_a_test/\">https://new.reddit.com/r/linux_gaming/comments/x/just_a_test/</a>"
		);
		assert_eq!(
			rewrite_urls(
				"e.g. &lt;a href=\"https://www.reddit.com/r/linux%5C_gaming/comments/ql9j15/anyone%5C_else%5C_confused%5C_with%5C_linus%5C_linux%5C_issues/\"&gt;https://www.reddit.com/r/linux\\_gaming/comments/ql9j15/anyone\\_else\\_confused\\_with\\_linus\\_linux\\_issues/&lt;/a&gt;"
			),
			"e.g. &lt;a href=\"/r/linux_gaming/comments/ql9j15/anyone_else_confused_with_linus_linux_issues/\"&gt;https://www.reddit.com/r/linux_gaming/comments/ql9j15/anyone_else_confused_with_linus_linux_issues/&lt;/a&gt;"
		);
	}

	#[test]
	fn rewrite_urls_keeps_intentional_backslashes() {
		assert_eq!(
			rewrite_urls("printf \"\\npolkit.addRule(function(action, subject)"),
			"printf \"\\npolkit.addRule(function(action, subject)"
		);
	}

	#[test]
	fn test_format_url() {
		assert_eq!(format_url("https://a.thumbs.redditmedia.com/XYZ.jpg"), "/thumb/a/XYZ.jpg");
		assert_eq!(format_url("https://emoji.redditmedia.com/a/b"), "/emoji/a/b");

		assert_eq!(
			format_url("https://external-preview.redd.it/foo.jpg?auto=webp&s=bar"),
			"/preview/external-pre/foo.jpg?auto=webp&s=bar"
		);

		assert_eq!(format_url("https://i.redd.it/foobar.jpg"), "/img/foobar.jpg");
		assert_eq!(
			format_url("https://preview.redd.it/qwerty.jpg?auto=webp&s=asdf"),
			"/preview/pre/qwerty.jpg?auto=webp&s=asdf"
		);
		assert_eq!(format_url("https://www.redditstatic.com/gold/awards/icon/icon.png"), "/static/gold/awards/icon/icon.png");
		assert_eq!(
			format_url("https://www.redditstatic.com/marketplace-assets/v1/core/emotes/snoomoji_emotes/free_emotes_pack/shrug.gif"),
			"/static/marketplace-assets/v1/core/emotes/snoomoji_emotes/free_emotes_pack/shrug.gif"
		);

		assert_eq!(format_url(""), "");
		assert_eq!(format_url("self"), "");
		assert_eq!(format_url("default"), "");
		assert_eq!(format_url("nsfw"), "");
		assert_eq!(format_url("spoiler"), "");
	}

	#[test]
	fn format_url_routes_each_video_container() {
		assert_eq!(format_url("https://v.redd.it/foo/DASH_360.mp4?source=fallback"), "/vid/foo/dash/360.mp4");
		assert_eq!(format_url("https://v.redd.it/foo/CMAF_720.mp4?source=fallback"), "/vid/foo/cmaf/720.mp4");
		assert_eq!(
			format_url("https://v.redd.it/foo/HLSPlaylist.m3u8?a=bar&v=1&f=sd"),
			"/hls/foo/HLSPlaylist.m3u8?a=bar&v=1&f=sd"
		);
	}

	#[test]
	fn test_rewriting_emoji() {
		let input = r#"<div class="md"><p>How can you have such hard feelings towards a license? <img src="https://www.redditstatic.com/marketplace-assets/v1/core/emotes/snoomoji_emotes/free_emotes_pack/shrug.gif" width="20" height="20" style="vertical-align:middle"> Let people use what license they want, and BSD is one of the least restrictive ones AFAIK.</p>"#;
		let output = r#"<div class="md"><p>How can you have such hard feelings towards a license? <img src="/static/marketplace-assets/v1/core/emotes/snoomoji_emotes/free_emotes_pack/shrug.gif" width="20" height="20" style="vertical-align:middle"> Let people use what license they want, and BSD is one of the least restrictive ones AFAIK.</p>"#;
		assert_eq!(rewrite_urls(input), output);
	}

	#[test]
	fn test_rewriting_image_links() {
		let input =
			r#"<p><a href="https://preview.redd.it/6awags382xo31.png?width=2560&amp;format=png&amp;auto=webp&amp;s=9c563aed4f07a91bdd249b5a3cea43a79710dcfc">caption 1</a></p>"#;
		let output = r#"<figure><a href="/preview/pre/6awags382xo31.png?width=2560&amp;format=png&amp;auto=webp&amp;s=9c563aed4f07a91bdd249b5a3cea43a79710dcfc"><img loading="lazy" src="/preview/pre/6awags382xo31.png?width=2560&amp;format=png&amp;auto=webp&amp;s=9c563aed4f07a91bdd249b5a3cea43a79710dcfc"></a><figcaption>caption 1</figcaption></figure>"#;
		assert_eq!(rewrite_urls(input), output);
	}

	#[test]
	fn test_rewriting_emotes() {
		let json_input = serde_json::from_str(r#"{"emote|t5_31hpy|2028":{"e":"Image","id":"emote|t5_31hpy|2028","m":"image/png","s":{"u":"https://reddit-econ-prod-assets-permanent.s3.amazonaws.com/asset-manager/t5_31hpy/PW6WsOaLcd.png","x":60,"y":60},"status":"valid","t":"sticker"}}"#).expect("Valid JSON");
		let comment_input = r#"<div class="comment_body "><div class="md"><p>:2028:</p></div></div>"#;
		let output = r#"<div class="comment_body "><div class="md"><p><img loading="lazy" src="/emote/t5_31hpy/PW6WsOaLcd.png" width="60" height="60" style="vertical-align:text-bottom"></p></div></div>"#;
		assert_eq!(rewrite_emotes(&json_input, comment_input.to_string()), output);
	}

	#[test]
	fn test_rewriting_bullet_list() {
		let input = r#"<div class="md"><p>Hi, I&#39;ve bought this very same monitor and found no calibration whatsoever. I have an ICC profile that has been set up since I&#39;ve installed its driver from the LG website and it works ok. I also used <a href="http://www.lagom.nl/lcd-test/">http://www.lagom.nl/lcd-test/</a> to calibrate it. After some good tinkering I&#39;ve found the following settings + the color profile from the driver gets me past all the tests perfectly:
- Brightness 50 (still have to settle on this one, it&#39;s personal preference, it controls the backlight, not the colors)
- Contrast 70 (which for me was the default one)
- Picture mode Custom
- Super resolution + Off (it looks horrible anyway)
- Sharpness 50 (default one I think)
- Black level High (low messes up gray colors)
- DFC Off
- Response Time Middle (personal preference, <a href="https://www.blurbusters.com/">https://www.blurbusters.com/</a> show horrible overdrive with it on high)
- Freesync doesn&#39;t matter
- Black stabilizer 50
- Gamma setting on 0
- Color Temp Medium
How`s your monitor by the way? Any IPS bleed whatsoever? I either got lucky or the panel is pretty good, 0 bleed for me, just the usual IPS glow. How about the pixels? I see the pixels even at one meter away, especially on Microsoft Edge&#39;s icon for example, the blue background is just blocky, don&#39;t know why.</p>
</div>"#;
		let output = r#"<div class="md"><p>Hi, I&#39;ve bought this very same monitor and found no calibration whatsoever. I have an ICC profile that has been set up since I&#39;ve installed its driver from the LG website and it works ok. I also used <a href="http://www.lagom.nl/lcd-test/">http://www.lagom.nl/lcd-test/</a> to calibrate it. After some good tinkering I&#39;ve found the following settings + the color profile from the driver gets me past all the tests perfectly:
<ul><li>Brightness 50 (still have to settle on this one, it&#39;s personal preference, it controls the backlight, not the colors)</li><li>Contrast 70 (which for me was the default one)</li><li>Picture mode Custom</li><li>Super resolution + Off (it looks horrible anyway)</li><li>Sharpness 50 (default one I think)</li><li>Black level High (low messes up gray colors)</li><li>DFC Off</li><li>Response Time Middle (personal preference, <a href="https://www.blurbusters.com/">https://www.blurbusters.com/</a> show horrible overdrive with it on high)</li><li>Freesync doesn&#39;t matter</li><li>Black stabilizer 50</li><li>Gamma setting on 0</li><li>Color Temp Medium</li></ul>
How`s your monitor by the way? Any IPS bleed whatsoever? I either got lucky or the panel is pretty good, 0 bleed for me, just the usual IPS glow. How about the pixels? I see the pixels even at one meter away, especially on Microsoft Edge&#39;s icon for example, the blue background is just blocky, don&#39;t know why.</p>
</div>"#;

		assert_eq!(render_bullet_lists(input), output);
	}
}
