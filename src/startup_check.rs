//! Startup diagnostics `main` runs once after OAuth bootstrap and before the listener opens.
//! Kept out of client.rs so the transport layer never imports the Reddit data model.
use crate::model::Post;
use crate::oauth::{force_refresh_token, oauth_session, FRESH_TOKEN_BUDGET};
use std::sync::atomic::Ordering;

async fn self_check(sub: &str) -> Result<(), String> {
	let query = format!("/r/{sub}/hot.json?&raw_json=1");

	match Post::fetch(&query, true).await {
		Ok(_) => Ok(()),
		Err(e) => Err(e),
	}
}

pub async fn rate_limit_check() -> Result<(), String> {
	// First, check a subreddit.
	self_check("reddit").await?;
	// This will reduce the rate limit to 99. Assert this check.
	let remaining = oauth_session().ratelimit_remaining();
	if remaining.load(Ordering::SeqCst) != FRESH_TOKEN_BUDGET {
		return Err(format!(
			"Rate limit check 1 failed: expected {FRESH_TOKEN_BUDGET}, got {}",
			remaining.load(Ordering::SeqCst)
		));
	}
	// Now, we switch out the OAuth client.
	// This checks for the IP rate limit association.
	force_refresh_token().await;
	// Now, check a new sub to break cache.
	self_check("rust").await?;
	// Again, assert the rate limit check.
	if remaining.load(Ordering::SeqCst) != FRESH_TOKEN_BUDGET {
		return Err(format!(
			"Rate limit check 2 failed: expected {FRESH_TOKEN_BUDGET}, got {}",
			remaining.load(Ordering::SeqCst)
		));
	}

	Ok(())
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::oauth::init_oauth_client;
	use {crate::config::get_setting, sealed_test::prelude::*};

	#[tokio::test(flavor = "multi_thread")]
	#[ignore = "hits live reddit"]
	async fn test_rate_limit_check() {
		init_oauth_client().await;
		// The check asserts a fresh token's budget (99); other tests in this process share the
		// client and have already spent some, so refresh first — matches main's ordering.
		force_refresh_token().await;
		rate_limit_check().await.unwrap();
	}

	#[test]
	#[ignore = "hits live reddit"]
	#[sealed_test(env = [("REDLIB_DEFAULT_SUBSCRIPTIONS", "rust")])]
	fn test_default_subscriptions() {
		tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap().block_on(async {
			let subscriptions = get_setting("REDLIB_DEFAULT_SUBSCRIPTIONS");
			assert!(subscriptions.is_some());

			// check rate limit
			init_oauth_client().await;
			force_refresh_token().await;
			rate_limit_check().await.unwrap();
		});
	}
}
