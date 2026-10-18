//! The `subscriptions`/`filters` cookie chains: a list too long for one 4096-byte cookie is
//! written as `name`, `name1`, `name2`, … and read back by `preferences::setting`.

use crate::server::ResponseExt;
use hyper::{Body, Response};

// Join items in chunks of 4000 bytes in length for cookies
pub fn join_until_size_limit<T: std::fmt::Display>(vec: &[T]) -> Vec<std::string::String> {
	let mut result = Vec::new();
	let mut list = String::new();
	let mut current_size = 0;

	for item in vec {
		// Size in bytes
		let item_size = item.to_string().len();
		// Use 4000 bytes to leave us some headroom because the name and options of the cookie count towards the 4096 byte cap
		if current_size + item_size > 4000 {
			// If last item add a seperator on the end of the list so it's interpreted properly in tanden with the next cookie
			list.push('+');

			// Push current list to result vector
			result.push(list);

			// Reset the list variable so we can continue with only new items
			list = String::new();
		}
		// Add separator if not the first item
		if !list.is_empty() {
			list.push('+');
		}
		// Add current item to list
		list.push_str(&item.to_string());
		current_size = list.len() + item_size;
	}
	// Make sure to push whatever the remaining subreddits are there into the result vector
	result.push(list);

	// Return resulting vector
	result
}

/// Writes `items` as the cookie chain `name`, `name1`, `name2`, … (`join_until_size_limit`
/// chunks, read back by `Preferences::new`), then expires the numbered cookies after the last
/// chunk while `has_cookie` says the request carries them. `None` expires the whole chain.
/// Used by `subscriptions_filters` and `settings::set_cookies_method`, which test for a cookie
/// differently (parsed cookie vs a substring of the raw header), so the caller passes the test.
pub fn set_cookie_chain(response: &mut Response<Body>, name: &str, items: Option<&[String]>, has_cookie: impl Fn(&str) -> bool) {
	let first_stale = match items {
		Some(items) => {
			let chunks = join_until_size_limit(items);
			let written = chunks.len();
			for (number, chunk) in chunks.into_iter().enumerate() {
				let cookie_name = if number == 0 { name.to_string() } else { format!("{name}{number}") };
				response.insert_persistent_cookie(cookie_name, chunk);
			}
			written
		}
		None => {
			response.remove_cookie(name.to_string());
			1
		}
	};

	for number in first_stale.. {
		let numbered = format!("{name}{number}");
		if !has_cookie(&numbered) {
			break;
		}
		response.remove_cookie(numbered);
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use cookie::Cookie;
	use time::OffsetDateTime;

	/// Each Set-Cookie header as (name, value, still valid): removals carry an expiry of now.
	fn set_cookies(response: &Response<Body>) -> Vec<(String, String, bool)> {
		response
			.headers()
			.get_all("Set-Cookie")
			.iter()
			.map(|header| {
				let cookie = Cookie::parse(header.to_str().unwrap().to_string()).unwrap();
				let valid = cookie.expires_datetime().is_some_and(|at| at > OffsetDateTime::now_utc());
				(cookie.name().to_string(), cookie.value().to_string(), valid)
			})
			.collect()
	}

	#[test]
	fn cookie_chain_writes_chunks_then_expires_the_stale_numbered_cookies() {
		// Two chunks: two 2500-byte names cannot share one cookie (join_until_size_limit's 4000).
		let long: Vec<String> = ["a", "b"].iter().map(|c| c.repeat(2500)).collect();
		let carried = ["subscriptions2", "subscriptions3"];
		let mut response = Response::new(Body::empty());
		set_cookie_chain(&mut response, "subscriptions", Some(&long), |name| carried.contains(&name));

		let names: Vec<(String, bool)> = set_cookies(&response).into_iter().map(|(name, _, valid)| (name, valid)).collect();
		let expected = [("subscriptions", true), ("subscriptions1", true), ("subscriptions2", false), ("subscriptions3", false)];
		assert_eq!(names, expected.map(|(name, valid)| (name.to_string(), valid)));
	}

	#[test]
	fn cookie_chain_joins_items_with_plus() {
		let mut response = Response::new(Body::empty());
		set_cookie_chain(&mut response, "filters", Some(&["rust".to_string(), "linux".to_string()]), |_| false);
		assert_eq!(set_cookies(&response), vec![("filters".to_string(), "rust+linux".to_string(), true)]);
	}

	#[test]
	fn cookie_chain_none_expires_the_whole_chain() {
		let carried = ["filters1", "filters2", "filters4"];
		let mut response = Response::new(Body::empty());
		set_cookie_chain(&mut response, "filters", None, |name| carried.contains(&name));

		// Stops at the first gap: filters4 is past filters3, which the request does not carry.
		let names: Vec<(String, bool)> = set_cookies(&response).into_iter().map(|(name, _, valid)| (name, valid)).collect();
		let expected = [("filters", false), ("filters1", false), ("filters2", false)];
		assert_eq!(names, expected.map(|(name, valid)| (name.to_string(), valid)));
	}
}
