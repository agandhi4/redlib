use log::{error, info};
use rusqlite::{params, Connection};
use std::collections::HashSet;
use std::sync::{LazyLock, Mutex};

const HISTORY_WINDOW_SECS: i64 = 7 * 24 * 60 * 60;

// Idempotent by construction (IF NOT EXISTS): it runs on every open, so a new table or index is
// added here and existing databases pick it up at the next start. A column change to an existing
// table needs a real migration step, which this file does not have yet.
const SCHEMA: &str = "CREATE TABLE IF NOT EXISTS reading_history (
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
	CREATE INDEX IF NOT EXISTS idx_saved_subreddit ON saved_items(subreddit);";

// The process-wide store. Panics at first use if the directory behind REDLIB_DB_PATH is missing
// or unwritable (docs/fork.md "Building on the Mac"); `main` forces it at startup via `init()`.
static DB: LazyLock<Mutex<Store>> = LazyLock::new(|| {
	let path = std::env::var("REDLIB_DB_PATH").unwrap_or_else(|_| "/data/redlib.db".to_string());
	let store = Store::open(&path).unwrap_or_else(|e| panic!("Failed to open SQLite database at {path}: {e}"));
	info!("SQLite database initialized at {path}");
	Mutex::new(store)
});

/// Initialize the database. Call once at startup to ensure tables exist.
pub fn init() {
	LazyLock::force(&DB);
}

/// Record a post visit. Upserts so revisits update the timestamp.
pub fn record_visit(post_id: &str, title: &str, subreddit: &str, url: &str) {
	if let Err(e) = DB.lock().unwrap().record_visit(post_id, title, subreddit, url, now()) {
		error!("Failed to record visit for {post_id}: {e}");
	}
}

/// Get the set of post IDs visited in the last 7 days.
pub fn visited_ids() -> HashSet<String> {
	DB.lock().unwrap().visited_ids(now()).unwrap_or_else(|e| {
		error!("Failed to read reading history: {e}");
		HashSet::new()
	})
}

/// Save a post/thread.
pub fn save_item(post_id: &str, title: &str, subreddit: &str, url: &str) {
	if let Err(e) = DB.lock().unwrap().save_item(post_id, title, subreddit, url, now()) {
		error!("Failed to save item {post_id}: {e}");
	}
}

/// Remove a saved item.
pub fn unsave_item(post_id: &str) {
	if let Err(e) = DB.lock().unwrap().unsave_item(post_id) {
		error!("Failed to unsave item {post_id}: {e}");
	}
}

/// Check if a post is saved.
pub fn is_saved(post_id: &str) -> bool {
	DB.lock().unwrap().is_saved(post_id)
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
	DB.lock().unwrap().saved_items_grouped(now()).unwrap_or_else(|e| {
		error!("Failed to read saved items: {e}");
		Vec::new()
	})
}

/// Delete reading history entries older than 7 days.
pub fn cleanup_history() {
	if let Err(e) = DB.lock().unwrap().cleanup_history(now()) {
		error!("Failed to cleanup reading history: {e}");
	}
}

/// One SQLite connection and every query against it. Times are explicit unix seconds so the
/// tests can place rows in the past; the free functions above pass `now()`.
struct Store {
	conn: Connection,
}

impl Store {
	fn open(path: &str) -> rusqlite::Result<Self> {
		Self::with_schema(Connection::open(path)?)
	}

	fn with_schema(conn: Connection) -> rusqlite::Result<Self> {
		// Enable WAL mode for better concurrent read performance
		conn.execute_batch("PRAGMA journal_mode=WAL;")?;
		conn.execute_batch(SCHEMA)?;
		Ok(Self { conn })
	}

	fn record_visit(&self, post_id: &str, title: &str, subreddit: &str, url: &str, at: i64) -> rusqlite::Result<()> {
		self.conn.execute(
			"INSERT INTO reading_history (post_id, title, subreddit, url, visited_at)
			 VALUES (?1, ?2, ?3, ?4, ?5)
			 ON CONFLICT(post_id) DO UPDATE SET visited_at = ?5, title = ?2",
			params![post_id, title, subreddit, url, at],
		)?;
		Ok(())
	}

	fn visited_ids(&self, now: i64) -> rusqlite::Result<HashSet<String>> {
		let mut stmt = self.conn.prepare("SELECT post_id FROM reading_history WHERE visited_at > ?1")?;
		let ids = stmt.query_map(params![now - HISTORY_WINDOW_SECS], |row| row.get(0))?.filter_map(Result::ok).collect();
		Ok(ids)
	}

	/// Saving an already-saved post keeps its original `saved_at`.
	fn save_item(&self, post_id: &str, title: &str, subreddit: &str, url: &str, at: i64) -> rusqlite::Result<()> {
		self.conn.execute(
			"INSERT OR IGNORE INTO saved_items (post_id, title, subreddit, url, saved_at)
			 VALUES (?1, ?2, ?3, ?4, ?5)",
			params![post_id, title, subreddit, url, at],
		)?;
		Ok(())
	}

	fn unsave_item(&self, post_id: &str) -> rusqlite::Result<()> {
		self.conn.execute("DELETE FROM saved_items WHERE post_id = ?1", params![post_id])?;
		Ok(())
	}

	fn is_saved(&self, post_id: &str) -> bool {
		self.conn.query_row("SELECT 1 FROM saved_items WHERE post_id = ?1", params![post_id], |_| Ok(())).is_ok()
	}

	/// Groups ordered by subreddit, items within a group newest first.
	fn saved_items_grouped(&self, now: i64) -> rusqlite::Result<Vec<SavedGroup>> {
		let mut stmt = self
			.conn
			.prepare("SELECT post_id, title, subreddit, url, saved_at FROM saved_items ORDER BY subreddit, saved_at DESC")?;
		let items = stmt
			.query_map([], |row| {
				Ok(SavedItem {
					post_id: row.get(0)?,
					title: row.get(1)?,
					subreddit: row.get(2)?,
					url: row.get(3)?,
					saved_at: format_age(now - row.get::<_, i64>(4)?),
				})
			})?
			.filter_map(Result::ok);

		let mut groups: Vec<SavedGroup> = Vec::new();
		for item in items {
			if let Some(group) = groups.last_mut().filter(|g| g.subreddit == item.subreddit) {
				group.items.push(item);
			} else {
				groups.push(SavedGroup {
					subreddit: item.subreddit.clone(),
					items: vec![item],
				});
			}
		}
		Ok(groups)
	}

	fn cleanup_history(&self, now: i64) -> rusqlite::Result<()> {
		self.conn.execute("DELETE FROM reading_history WHERE visited_at < ?1", params![now - HISTORY_WINDOW_SECS])?;
		Ok(())
	}
}

fn now() -> i64 {
	std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64
}

fn format_age(seconds_ago: i64) -> String {
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

#[cfg(test)]
mod tests {
	use super::*;
	use std::path::PathBuf;

	const NOW: i64 = 1_800_000_000;
	const DAY: i64 = 24 * 60 * 60;

	fn memory() -> Store {
		Store::with_schema(Connection::open_in_memory().unwrap()).unwrap()
	}

	/// A database file in the system temp dir, removed (with its WAL sidecars) on drop.
	struct TempDb(PathBuf);

	impl TempDb {
		fn new(name: &str) -> Self {
			let path = std::env::temp_dir().join(format!("redlib-db-test-{}-{name}.db", std::process::id()));
			let db = Self(path);
			db.remove();
			db
		}

		fn path(&self) -> &str {
			self.0.to_str().unwrap()
		}

		fn remove(&self) {
			for suffix in ["", "-wal", "-shm"] {
				let _ = std::fs::remove_file(format!("{}{suffix}", self.path()));
			}
		}
	}

	impl Drop for TempDb {
		fn drop(&mut self) {
			self.remove();
		}
	}

	#[test]
	fn open_creates_the_schema_in_wal_mode() {
		let file = TempDb::new("schema");
		let store = Store::open(file.path()).unwrap();
		let mode: String = store.conn.query_row("PRAGMA journal_mode", [], |row| row.get(0)).unwrap();
		assert_eq!(mode, "wal");
		let tables: Vec<String> = store
			.conn
			.prepare("SELECT name FROM sqlite_master WHERE type IN ('table', 'index') AND name NOT LIKE 'sqlite_%' ORDER BY name")
			.unwrap()
			.query_map([], |row| row.get(0))
			.unwrap()
			.map(Result::unwrap)
			.collect();
		assert_eq!(tables, ["idx_history_visited_at", "idx_saved_subreddit", "reading_history", "saved_items"]);
	}

	#[test]
	fn reopening_an_existing_file_keeps_its_rows() {
		let file = TempDb::new("reopen");
		Store::open(file.path()).unwrap().save_item("p1", "Title", "rust", "/r/rust/comments/p1", NOW).unwrap();
		let reopened = Store::open(file.path()).unwrap();
		assert!(reopened.is_saved("p1"));
		Store::with_schema(reopened.conn).unwrap();
	}

	#[test]
	fn record_visit_upserts_the_timestamp_and_title() {
		let store = memory();
		store.record_visit("p1", "Old title", "rust", "/r/rust/comments/p1", NOW - 8 * DAY).unwrap();
		assert!(store.visited_ids(NOW).unwrap().is_empty(), "an 8-day-old visit is outside the window");

		store.record_visit("p1", "New title", "rust", "/r/rust/comments/p1", NOW).unwrap();
		assert_eq!(store.visited_ids(NOW).unwrap(), HashSet::from(["p1".to_string()]));
		let (count, title): (i64, String) = store
			.conn
			.query_row("SELECT COUNT(*), MAX(title) FROM reading_history", [], |row| Ok((row.get(0)?, row.get(1)?)))
			.unwrap();
		assert_eq!((count, title.as_str()), (1, "New title"));
	}

	#[test]
	fn cleanup_history_drops_only_visits_older_than_the_window() {
		let store = memory();
		store.record_visit("old", "t", "rust", "/u", NOW - 8 * DAY).unwrap();
		store.record_visit("recent", "t", "rust", "/u", NOW - DAY).unwrap();
		store.cleanup_history(NOW).unwrap();
		let remaining: Vec<String> = store
			.conn
			.prepare("SELECT post_id FROM reading_history")
			.unwrap()
			.query_map([], |row| row.get(0))
			.unwrap()
			.map(Result::unwrap)
			.collect();
		assert_eq!(remaining, ["recent"]);
	}

	#[test]
	fn save_unsave_round_trip() {
		let store = memory();
		assert!(!store.is_saved("p1"));
		store.save_item("p1", "Title", "rust", "/r/rust/comments/p1", NOW).unwrap();
		assert!(store.is_saved("p1"));
		store.unsave_item("p1").unwrap();
		assert!(!store.is_saved("p1"));
		store.unsave_item("p1").unwrap();
	}

	#[test]
	fn saving_twice_keeps_the_first_saved_at() {
		let store = memory();
		store.save_item("p1", "Title", "rust", "/u", NOW - 2 * DAY).unwrap();
		store.save_item("p1", "Title", "rust", "/u", NOW).unwrap();
		let groups = store.saved_items_grouped(NOW).unwrap();
		assert_eq!(groups[0].items[0].saved_at, "2d ago");
	}

	#[test]
	fn saved_items_group_by_subreddit_newest_first() {
		let store = memory();
		store.save_item("a1", "A old", "askscience", "/a1", NOW - 3 * 3600).unwrap();
		store.save_item("r1", "R", "rust", "/r1", NOW - 30).unwrap();
		store.save_item("a2", "A new", "askscience", "/a2", NOW - 5 * 60).unwrap();

		let groups = store.saved_items_grouped(NOW).unwrap();
		let shape: Vec<(&str, Vec<(&str, &str)>)> = groups
			.iter()
			.map(|g| (g.subreddit.as_str(), g.items.iter().map(|i| (i.post_id.as_str(), i.saved_at.as_str())).collect()))
			.collect();
		assert_eq!(shape, [("askscience", vec![("a2", "5m ago"), ("a1", "3h ago")]), ("rust", vec![("r1", "just now")])]);
		assert_eq!((groups[1].items[0].title.as_str(), groups[1].items[0].url.as_str()), ("R", "/r1"));
	}

	#[test]
	fn format_age_boundaries() {
		assert_eq!(format_age(59), "just now");
		assert_eq!(format_age(60), "1m ago");
		assert_eq!(format_age(3599), "59m ago");
		assert_eq!(format_age(3600), "1h ago");
		assert_eq!(format_age(86_399), "23h ago");
		assert_eq!(format_age(86_400), "1d ago");
	}
}
