use log::{error, info};
use rusqlite::{params, Connection};
use std::sync::{LazyLock, Mutex};

static DB: LazyLock<Mutex<Connection>> = LazyLock::new(|| {
	let path = std::env::var("REDLIB_DB_PATH").unwrap_or_else(|_| "/data/redlib.db".to_string());
	let conn = Connection::open(&path).expect("Failed to open SQLite database");
	// Enable WAL mode for better concurrent read performance
	conn.execute_batch("PRAGMA journal_mode=WAL;").expect("Failed to set WAL mode");
	conn
		.execute_batch(
			"CREATE TABLE IF NOT EXISTS reading_history (
				post_id TEXT PRIMARY KEY,
				title TEXT NOT NULL,
				subreddit TEXT NOT NULL,
				url TEXT NOT NULL,
				visited_at INTEGER NOT NULL
			);
			CREATE TABLE IF NOT EXISTS saved_items (
				post_id TEXT PRIMARY KEY,
				title TEXT NOT NULL,
				subreddit TEXT NOT NULL,
				url TEXT NOT NULL,
				saved_at INTEGER NOT NULL
			);
			CREATE INDEX IF NOT EXISTS idx_history_visited_at ON reading_history(visited_at);
			CREATE INDEX IF NOT EXISTS idx_saved_subreddit ON saved_items(subreddit);",
		)
		.expect("Failed to create tables");
	info!("SQLite database initialized at {path}");
	Mutex::new(conn)
});

/// Initialize the database. Call once at startup to ensure tables exist.
pub fn init() {
	LazyLock::force(&DB);
}

/// Record a post visit. Upserts so revisits update the timestamp.
pub fn record_visit(post_id: &str, title: &str, subreddit: &str, url: &str) {
	let timestamp = now();
	let db = DB.lock().unwrap();
	if let Err(e) = db.execute(
		"INSERT INTO reading_history (post_id, title, subreddit, url, visited_at)
		 VALUES (?1, ?2, ?3, ?4, ?5)
		 ON CONFLICT(post_id) DO UPDATE SET visited_at = ?5, title = ?2",
		params![post_id, title, subreddit, url, timestamp],
	) {
		error!("Failed to record visit for {post_id}: {e}");
	}
}

/// Get the set of post IDs visited in the last 7 days.
pub fn visited_ids() -> std::collections::HashSet<String> {
	let cutoff = now() - (7 * 24 * 60 * 60);
	let db = DB.lock().unwrap();
	let mut stmt = db
		.prepare("SELECT post_id FROM reading_history WHERE visited_at > ?1")
		.unwrap();
	stmt.query_map(params![cutoff], |row| row.get(0))
		.unwrap()
		.filter_map(|r| r.ok())
		.collect()
}

/// Save a post/thread.
pub fn save_item(post_id: &str, title: &str, subreddit: &str, url: &str) {
	let timestamp = now();
	let db = DB.lock().unwrap();
	if let Err(e) = db.execute(
		"INSERT OR IGNORE INTO saved_items (post_id, title, subreddit, url, saved_at)
		 VALUES (?1, ?2, ?3, ?4, ?5)",
		params![post_id, title, subreddit, url, timestamp],
	) {
		error!("Failed to save item {post_id}: {e}");
	}
}

/// Remove a saved item.
pub fn unsave_item(post_id: &str) {
	let db = DB.lock().unwrap();
	if let Err(e) = db.execute("DELETE FROM saved_items WHERE post_id = ?1", params![post_id]) {
		error!("Failed to unsave item {post_id}: {e}");
	}
}

/// Check if a post is saved.
pub fn is_saved(post_id: &str) -> bool {
	let db = DB.lock().unwrap();
	db.query_row("SELECT 1 FROM saved_items WHERE post_id = ?1", params![post_id], |_| Ok(()))
		.is_ok()
}

/// A saved item returned from the database.
pub struct SavedItem {
	pub post_id: String,
	pub title: String,
	pub subreddit: String,
	pub url: String,
	pub saved_at: String,
}

/// A group of saved items by subreddit.
pub struct SavedGroup {
	pub subreddit: String,
	pub items: Vec<SavedItem>,
}

/// Get all saved items, grouped by subreddit.
pub fn saved_items_grouped() -> Vec<SavedGroup> {
	let db = DB.lock().unwrap();
	let mut stmt = db
		.prepare("SELECT post_id, title, subreddit, url, saved_at FROM saved_items ORDER BY subreddit, saved_at DESC")
		.unwrap();
	let items: Vec<SavedItem> = stmt
		.query_map([], |row| {
			let timestamp: i64 = row.get(4)?;
			Ok(SavedItem {
				post_id: row.get(0)?,
				title: row.get(1)?,
				subreddit: row.get(2)?,
				url: row.get(3)?,
				saved_at: format_timestamp(timestamp),
			})
		})
		.unwrap()
		.filter_map(|r| r.ok())
		.collect();

	// Group by subreddit
	let mut groups: Vec<SavedGroup> = Vec::new();
	for item in items {
		if let Some(group) = groups.last_mut().filter(|g| g.subreddit == item.subreddit) {
			group.items.push(item);
		} else {
			let sub = item.subreddit.clone();
			groups.push(SavedGroup {
				subreddit: sub,
				items: vec![item],
			});
		}
	}
	groups
}

/// Delete reading history entries older than 7 days.
pub fn cleanup_history() {
	let cutoff = now() - (7 * 24 * 60 * 60);
	let db = DB.lock().unwrap();
	if let Err(e) = db.execute("DELETE FROM reading_history WHERE visited_at < ?1", params![cutoff]) {
		error!("Failed to cleanup reading history: {e}");
	}
}

fn now() -> i64 {
	std::time::SystemTime::now()
		.duration_since(std::time::UNIX_EPOCH)
		.unwrap()
		.as_secs() as i64
}

fn format_timestamp(ts: i64) -> String {
	let seconds_ago = now() - ts;
	if seconds_ago < 60 {
		"just now".to_string()
	} else if seconds_ago < 3600 {
		format!("{}m ago", seconds_ago / 60)
	} else if seconds_ago < 86400 {
		format!("{}h ago", seconds_ago / 3600)
	} else {
		format!("{}d ago", seconds_ago / 86400)
	}
}
