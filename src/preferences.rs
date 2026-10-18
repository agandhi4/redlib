//! User preferences: read from cookies (falling back to `REDLIB_DEFAULT_*`), including the
//! numbered `subscriptions`/`filters` chains, and their urlencoded and bincode encodings.

use crate::config::get_setting;
use crate::server::RequestExt;
use cookie::Cookie;
use hyper::{Body, Request};
use libflate::deflate::{Decoder, Encoder};
use revision::revisioned;
use rust_embed::RustEmbed;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::collections::HashSet;
use std::io::{Read, Write};

#[derive(Default, Serialize, Deserialize, Debug, PartialEq, Eq)]
#[revisioned(revision = 1)]
pub struct Preferences {
	#[revision(start = 1)]
	#[serde(skip_serializing, skip_deserializing)]
	pub available_themes: Vec<String>,
	#[revision(start = 1)]
	pub theme: String,
	#[revision(start = 1)]
	pub front_page: String,
	#[revision(start = 1)]
	pub layout: String,
	#[revision(start = 1)]
	pub wide: String,
	#[revision(start = 1)]
	pub blur_spoiler: String,
	#[revision(start = 1)]
	pub show_nsfw: String,
	#[revision(start = 1)]
	pub blur_nsfw: String,
	#[revision(start = 1)]
	pub hide_hls_notification: String,
	#[revision(start = 1)]
	pub video_quality: String,
	#[revision(start = 1)]
	pub hide_sidebar_and_summary: String,
	#[revision(start = 1)]
	pub use_hls: String,
	#[revision(start = 1)]
	pub autoplay_videos: String,
	#[revision(start = 1)]
	pub fixed_navbar: String,
	#[revision(start = 1)]
	pub disable_visit_reddit_confirmation: String,
	#[revision(start = 1)]
	pub comment_sort: String,
	#[revision(start = 1)]
	pub post_sort: String,
	#[revision(start = 1)]
	#[serde(serialize_with = "serialize_vec_with_plus", deserialize_with = "deserialize_vec_with_plus")]
	pub subscriptions: Vec<String>,
	#[revision(start = 1)]
	#[serde(serialize_with = "serialize_vec_with_plus", deserialize_with = "deserialize_vec_with_plus")]
	pub filters: Vec<String>,
	#[revision(start = 1)]
	pub hide_awards: String,
	#[revision(start = 1)]
	pub hide_score: String,
	#[revision(start = 1)]
	pub remove_default_feeds: String,
}

fn serialize_vec_with_plus<S>(vec: &[String], serializer: S) -> Result<S::Ok, S::Error>
where
	S: Serializer,
{
	serializer.serialize_str(&vec.join("+"))
}

fn deserialize_vec_with_plus<'de, D>(deserializer: D) -> Result<Vec<String>, D::Error>
where
	D: Deserializer<'de>,
{
	let string = String::deserialize(deserializer)?;
	if string.is_empty() {
		return Ok(Vec::new());
	}
	Ok(string.split('+').map(|s| s.to_string()).collect())
}

#[derive(RustEmbed)]
#[folder = "static/themes/"]
#[include = "*.css"]
pub struct ThemeAssets;

impl Preferences {
	/// Build preferences from cookies
	pub fn new(req: &Request<Body>) -> Self {
		// Read available theme names from embedded css files.
		// Always make the default "system" theme available.
		let mut themes = vec!["system".to_string()];
		for file in ThemeAssets::iter() {
			let chunks: Vec<&str> = file.as_ref().split(".css").collect();
			themes.push(chunks[0].to_owned());
		}
		Self {
			available_themes: themes,
			theme: setting(req, "theme"),
			front_page: setting(req, "front_page"),
			// oldreddit is the only maintained layout; cookie/env can still override
			layout: setting_or_default(req, "layout", "oldreddit".to_string()),
			wide: setting(req, "wide"),
			blur_spoiler: setting(req, "blur_spoiler"),
			show_nsfw: setting(req, "show_nsfw"),
			hide_sidebar_and_summary: setting(req, "hide_sidebar_and_summary"),
			blur_nsfw: setting(req, "blur_nsfw"),
			use_hls: setting(req, "use_hls"),
			hide_hls_notification: setting(req, "hide_hls_notification"),
			video_quality: setting(req, "video_quality"),
			autoplay_videos: setting(req, "autoplay_videos"),
			fixed_navbar: setting_or_default(req, "fixed_navbar", "on".to_string()),
			disable_visit_reddit_confirmation: setting(req, "disable_visit_reddit_confirmation"),
			comment_sort: setting(req, "comment_sort"),
			post_sort: setting(req, "post_sort"),
			subscriptions: setting_list(req, "subscriptions"),
			filters: setting_list(req, "filters"),
			hide_awards: setting(req, "hide_awards"),
			hide_score: setting(req, "hide_score"),
			remove_default_feeds: setting(req, "remove_default_feeds"),
		}
	}

	pub fn to_urlencoded(&self) -> Result<String, String> {
		serde_urlencoded::to_string(self).map_err(|e| e.to_string())
	}

	pub fn to_bincode(&self) -> Result<Vec<u8>, String> {
		bincode::serialize(self).map_err(|e| e.to_string())
	}
	pub fn to_compressed_bincode(&self) -> Result<Vec<u8>, String> {
		deflate_compress(self.to_bincode()?)
	}
	pub fn to_bincode_str(&self) -> Result<String, String> {
		Ok(base2048::encode(&self.to_compressed_bincode()?))
	}
}

pub fn deflate_compress(i: Vec<u8>) -> Result<Vec<u8>, String> {
	let mut e = Encoder::new(Vec::new());
	e.write_all(&i).map_err(|e| e.to_string())?;
	e.finish().into_result().map_err(|e| e.to_string())
}

pub fn deflate_decompress(i: Vec<u8>) -> Result<Vec<u8>, String> {
	let mut decoder = Decoder::new(&i[..]);
	let mut out = Vec::new();
	decoder.read_to_end(&mut out).map_err(|e| format!("Failed to read from gzip decoder: {e}"))?;
	Ok(out)
}

/// Gets a `HashSet` of filters from the cookie in the given `Request`.
pub fn get_filters(req: &Request<Body>) -> HashSet<String> {
	setting(req, "filters").split('+').map(String::from).filter(|s| !s.is_empty()).collect::<HashSet<String>>()
}

/// Retrieve the value of a setting by name
pub fn setting(req: &Request<Body>, name: &str) -> String {
	// Parse a cookie value from request

	// If this was called with "subscriptions" and the "subscriptions" cookie has a value
	if name == "subscriptions" && req.cookie("subscriptions").is_some() {
		// Create subscriptions string
		let mut subscriptions = String::new();

		// Default subscriptions cookie
		if req.cookie("subscriptions").is_some() {
			subscriptions.push_str(req.cookie("subscriptions").unwrap().value());
		}

		// Start with first numbered subscription cookie
		let mut subscriptions_number = 1;

		// While whatever subscriptionsNUMBER cookie we're looking at has a value
		while req.cookie(&format!("subscriptions{subscriptions_number}")).is_some() {
			// Push whatever subscriptionsNUMBER cookie we're looking at into the subscriptions string
			subscriptions.push_str(req.cookie(&format!("subscriptions{subscriptions_number}")).unwrap().value());

			// Increment subscription cookie number
			subscriptions_number += 1;
		}

		// Return the subscriptions cookies as one large string
		subscriptions
	}
	// If this was called with "filters" and the "filters" cookie has a value
	else if name == "filters" && req.cookie("filters").is_some() {
		// Create filters string
		let mut filters = String::new();

		// Default filters cookie
		if req.cookie("filters").is_some() {
			filters.push_str(req.cookie("filters").unwrap().value());
		}

		// Start with first numbered filters cookie
		let mut filters_number = 1;

		// While whatever filtersNUMBER cookie we're looking at has a value
		while req.cookie(&format!("filters{filters_number}")).is_some() {
			// Push whatever filtersNUMBER cookie we're looking at into the filters string
			filters.push_str(req.cookie(&format!("filters{filters_number}")).unwrap().value());

			// Increment filters cookie number
			filters_number += 1;
		}

		// Return the filters cookies as one large string
		filters
	}
	// The above two still come to this if there was no existing value
	else {
		req
			.cookie(name)
			.unwrap_or_else(|| {
				// If there is no cookie for this setting, try receiving a default from the config
				if let Some(default) = get_setting(&format!("REDLIB_DEFAULT_{}", name.to_uppercase())) {
					Cookie::new(name, default)
				} else {
					Cookie::from(name)
				}
			})
			.value()
			.to_string()
	}
}

/// Retrieve a `+`-delimited list setting (subscriptions, filters), sorted case-insensitively.
/// Sorting here (not just at subscribe time) covers cookies written before sorting existed
/// or restored from a settings link — display order everywhere derives from this.
pub fn setting_list(req: &Request<Body>, name: &str) -> Vec<String> {
	let mut list: Vec<String> = setting(req, name).split('+').map(String::from).filter(|s| !s.is_empty()).collect();
	list.sort_by_key(|s| s.to_lowercase());
	list
}

/// Retrieve the value of a setting by name or the default value
pub fn setting_or_default(req: &Request<Body>, name: &str, default: String) -> String {
	let value = setting(req, name);
	if value.is_empty() {
		default
	} else {
		value
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn serialize_prefs() {
		let prefs = Preferences {
			available_themes: vec![],
			theme: "laserwave".to_owned(),
			front_page: "default".to_owned(),
			layout: "compact".to_owned(),
			wide: "on".to_owned(),
			blur_spoiler: "on".to_owned(),
			show_nsfw: "off".to_owned(),
			blur_nsfw: "on".to_owned(),
			hide_hls_notification: "off".to_owned(),
			video_quality: "best".to_owned(),
			hide_sidebar_and_summary: "off".to_owned(),
			use_hls: "on".to_owned(),
			autoplay_videos: "on".to_owned(),
			fixed_navbar: "on".to_owned(),
			disable_visit_reddit_confirmation: "on".to_owned(),
			comment_sort: "confidence".to_owned(),
			post_sort: "top".to_owned(),
			subscriptions: vec!["memes".to_owned(), "mildlyinteresting".to_owned()],
			filters: vec![],
			hide_awards: "off".to_owned(),
			hide_score: "off".to_owned(),
			remove_default_feeds: "off".to_owned(),
		};
		let urlencoded = serde_urlencoded::to_string(prefs).expect("Failed to serialize Prefs");

		assert_eq!(urlencoded, "theme=laserwave&front_page=default&layout=compact&wide=on&blur_spoiler=on&show_nsfw=off&blur_nsfw=on&hide_hls_notification=off&video_quality=best&hide_sidebar_and_summary=off&use_hls=on&autoplay_videos=on&fixed_navbar=on&disable_visit_reddit_confirmation=on&comment_sort=confidence&post_sort=top&subscriptions=memes%2Bmildlyinteresting&filters=&hide_awards=off&hide_score=off&remove_default_feeds=off");
	}

	#[test]
	fn test_default_prefs_serialization_loop_json() {
		let prefs = Preferences::default();
		let serialized = serde_json::to_string(&prefs).unwrap();
		let deserialized: Preferences = serde_json::from_str(&serialized).unwrap();
		assert_eq!(prefs, deserialized);
	}

	#[test]
	fn test_default_prefs_serialization_loop_bincode() {
		let prefs = Preferences::default();
		test_round_trip(&prefs, false);
		test_round_trip(&prefs, true);
	}

	static KNOWN_GOOD_CONFIGS: &[&str] = &[
		"ఴӅβØØҞÉဏႢձĬ༧ȒʯऌԔӵ୮༏",
		"ਧՊΥÀÃǎƱГ۸ඣമĖฤ႙ʟาúໜϾௐɥঀĜໃહཞઠѫҲɂఙ࿔ǲઉƲӟӻĻฅΜδ໖ԜǗဖငƦơ৶Ą௩ԹʛใЛʃශаΏ",
		"ਧԩΥÀÃÎŠ౭൩ඔႠϼҭöҪƸռઇԾॐნɔາǒՍҰच௨ಖມŃЉŐདƦ๙ϩএఠȝഽйʮჯඒϰळՋ௮ສ৵ऎΦѧਹಧଟƙŃ३î༦ŌပղयƟแҜ།",
	];

	#[test]
	fn test_known_good_configs_deserialization() {
		for config in KNOWN_GOOD_CONFIGS {
			let bytes = base2048::decode(config).unwrap();
			let decompressed = deflate_decompress(bytes).unwrap();
			assert!(bincode::deserialize::<Preferences>(&decompressed).is_ok());
		}
	}

	#[test]
	fn test_known_good_configs_full_round_trip() {
		for config in KNOWN_GOOD_CONFIGS {
			let bytes = base2048::decode(config).unwrap();
			let decompressed = deflate_decompress(bytes).unwrap();
			let prefs: Preferences = bincode::deserialize(&decompressed).unwrap();
			test_round_trip(&prefs, false);
			test_round_trip(&prefs, true);
		}
	}

	fn test_round_trip(input: &Preferences, compression: bool) {
		let serialized = bincode::serialize(input).unwrap();
		let compressed = if compression { deflate_compress(serialized).unwrap() } else { serialized };
		let decompressed = if compression { deflate_decompress(compressed).unwrap() } else { compressed };
		let deserialized: Preferences = bincode::deserialize(&decompressed).unwrap();
		assert_eq!(*input, deserialized);
	}
}
