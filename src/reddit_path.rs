//! The REST paths redlib's pages build (`/r/<sub>/<sort>.json?…`, `/by_id/…`, `/user/…`,
//! `/search.json?…`) parsed into the `Resource` they read, so `sources` can serve it from
//! GraphQL. Pure. Anything it does not recognise, and any page reached through a REST cursor, is
//! `Resource::Other`: REST only (`random`, a user's upvoted or saved, a REST fallback's next page).

use crate::gql_fields::cursor_from_after;
use log::debug;
use percent_encoding::percent_decode_str;

/// Which breaker a resource's GraphQL plan answers to (`sources`). Copy, and a fixed set.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Kind {
	Listing,
	Post,
	About,
	User,
	Search,
	Wiki,
	Duplicates,
}

impl Kind {
	pub(crate) const ALL: [Self; 7] = [Self::Listing, Self::Post, Self::About, Self::User, Self::Search, Self::Wiki, Self::Duplicates];

	pub(crate) fn name(self) -> &'static str {
		match self {
			Self::Listing => "listing",
			Self::Post => "post",
			Self::About => "about",
			Self::User => "user",
			Self::Search => "search",
			Self::Wiki => "wiki",
			Self::Duplicates => "duplicates",
		}
	}
}

/// A feed sort, by its REST name; `gql()` is the GraphQL enum value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Sort {
	Hot,
	New,
	Top,
	Rising,
	Controversial,
	Best,
}

impl Sort {
	fn parse(name: &str) -> Option<Self> {
		Some(match name {
			"hot" => Self::Hot,
			"new" => Self::New,
			"top" => Self::Top,
			"rising" => Self::Rising,
			"controversial" => Self::Controversial,
			"best" => Self::Best,
			_ => return None,
		})
	}

	pub(crate) fn gql(self) -> &'static str {
		match self {
			Self::Hot => "HOT",
			Self::New => "NEW",
			Self::Top => "TOP",
			Self::Rising => "RISING",
			Self::Controversial => "CONTROVERSIAL",
			Self::Best => "BEST",
		}
	}
}

/// A REST `t=` value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Range {
	Hour,
	Day,
	Week,
	Month,
	Year,
	All,
}

impl Range {
	const NAMES: [(&'static str, Self); 6] = [
		("hour", Self::Hour),
		("day", Self::Day),
		("week", Self::Week),
		("month", Self::Month),
		("year", Self::Year),
		("all", Self::All),
	];

	fn parse(name: &str) -> Option<Self> {
		Self::NAMES.iter().find(|(n, _)| *n == name).map(|(_, range)| *range)
	}

	/// The REST spelling, which the search `time_range` filter also takes.
	pub(crate) fn filter(self) -> &'static str {
		Self::NAMES.iter().find(|(_, range)| *range == self).map_or("all", |(name, _)| name)
	}

	pub(crate) fn gql(self) -> &'static str {
		match self {
			Self::Hour => "HOUR",
			Self::Day => "DAY",
			Self::Week => "WEEK",
			Self::Month => "MONTH",
			Self::Year => "YEAR",
			Self::All => "ALL",
		}
	}
}

/// A search sort, by its REST name.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SearchSort {
	Relevance,
	Hot,
	Top,
	New,
	Comments,
}

impl SearchSort {
	fn parse(name: &str) -> Option<Self> {
		Some(match name {
			"relevance" => Self::Relevance,
			"hot" => Self::Hot,
			"top" => Self::Top,
			"new" => Self::New,
			"comments" => Self::Comments,
			_ => return None,
		})
	}

	pub(crate) fn gql(self) -> &'static str {
		match self {
			Self::Relevance => "RELEVANCE",
			Self::Hot => "HOT",
			Self::Top => "TOP",
			Self::New => "NEW",
			Self::Comments => "COMMENTS",
		}
	}

	/// A multireddit is served by search, which cannot sort by rising or controversial: those
	/// (and `best`) read as hot.
	fn for_feed(sort: Sort) -> Self {
		match sort {
			Sort::Hot => Self::Hot,
			Sort::New => Self::New,
			Sort::Top => Self::Top,
			Sort::Rising | Sort::Controversial | Sort::Best => {
				debug!("[source] multireddit sort {sort:?} is not searchable; serving hot");
				Self::Hot
			}
		}
	}
}

/// One page of a feed: its sort, range and GraphQL cursor (decoded from our `g_` after).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Page {
	pub sort: Sort,
	pub range: Option<Range>,
	pub after: Option<String>,
}

/// One page of a post search.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SearchPage {
	pub sort: SearchSort,
	pub range: Option<Range>,
	pub after: Option<String>,
}

/// A duplicates listing's sort. GetDuplicatePosts takes none, so the plan sorts locally.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum DuplicateSort {
	NumComments,
	New,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum UserListing {
	Overview,
	Submitted,
	Comments,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Resource {
	SubredditListing {
		sub: String,
		page: Page,
	},
	Popular(Page),
	All(Page),
	/// `a+b+…`, the front page of subscriptions included.
	Multi {
		subs: Vec<String>,
		page: SearchPage,
	},
	About {
		sub: String,
	},
	/// Fullnames (`t3_…`).
	ById {
		ids: Vec<String>,
	},
	UserAbout {
		name: String,
	},
	UserListing {
		name: String,
		listing: UserListing,
		page: Page,
	},
	/// `query` already carries a `subreddit:<name>` restriction when the search had one.
	Search {
		query: String,
		page: SearchPage,
	},
	/// Community search (`/subreddits/search.json`).
	SubredditSearch {
		query: String,
		limit: u32,
	},
	/// A wiki page; `page` may hold `/` (`config/sidebar`).
	Wiki {
		sub: String,
		page: String,
	},
	/// A post (`id`, no `t3_`) and the other posts of its link. `sort` None keeps Reddit's order.
	Duplicates {
		id: String,
		sort: Option<DuplicateSort>,
	},
	Other,
}

impl Resource {
	/// The breaker that governs this resource; None for `Other`, which is REST only.
	pub(crate) fn kind(&self) -> Option<Kind> {
		Some(match self {
			Self::SubredditListing { .. } | Self::Popular(_) | Self::All(_) | Self::Multi { .. } => Kind::Listing,
			Self::ById { .. } => Kind::Post,
			Self::About { .. } => Kind::About,
			Self::UserAbout { .. } | Self::UserListing { .. } => Kind::User,
			Self::Search { .. } | Self::SubredditSearch { .. } => Kind::Search,
			Self::Wiki { .. } => Kind::Wiki,
			Self::Duplicates { .. } => Kind::Duplicates,
			Self::Other => return None,
		})
	}
}

/// The query parameters of a path, decoded.
struct Query(Vec<(String, String)>);

impl Query {
	fn get(&self, key: &str) -> Option<&str> {
		self.0.iter().find(|(k, v)| k == key && !v.is_empty()).map(|(_, v)| v.as_str())
	}

	/// Whether `key` is present at all, even empty.
	fn has(&self, key: &str) -> bool {
		self.0.iter().any(|(k, _)| k == key)
	}

	/// The GraphQL cursor this page continues from. Err for a page REST must serve: one reached
	/// through a REST cursor (`after=t3_…`, any `before=` but ours), or a `g_` cursor that does
	/// not decode. Our `before=g_…` (the PREV link) has no GraphQL meaning and reads as page 1.
	fn cursor(&self) -> Result<Option<String>, ()> {
		if self.get("before").is_some_and(|before| cursor_from_after(before).is_none()) {
			return Err(());
		}
		match self.get("after").map(cursor_from_after) {
			None => Ok(None),
			Some(Some(Ok(cursor))) => Ok(Some(cursor)),
			Some(_) => Err(()),
		}
	}

	fn range(&self) -> Option<Range> {
		self.get("t").and_then(Range::parse)
	}
}

/// Subreddit and user names, as Reddit allows them.
fn valid_name(name: &str) -> bool {
	!name.is_empty() && name.len() <= 64 && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// The resource `path` (with its query) reads.
pub(crate) fn parse(path: &str) -> Resource {
	let (route, query) = path.split_once('?').unwrap_or((path, ""));
	let query = Query(url::form_urlencoded::parse(query.as_bytes()).into_owned().collect());
	let Some(route) = route.strip_suffix(".json") else {
		return Resource::Other;
	};
	let route = percent_decode_str(route).decode_utf8_lossy();
	let segments: Vec<&str> = route.trim_matches('/').split('/').collect();
	let parsed = match segments.as_slice() {
		["r", sub, "about"] => about(sub),
		["r", sub, "search"] => search(Some(sub), &query),
		["r", sub, "wiki", page @ ..] => wiki(sub, page),
		["r", _, "duplicates", id] | ["r", _, "duplicates", id, _] | ["duplicates", id] | ["duplicates", id, _] => duplicates(id, &query),
		["r", sub, sort] => listing(sub, sort, &query),
		["r", sub] => listing(sub, "hot", &query),
		["by_id", ids] => by_id(ids),
		["user", name, "about"] => valid_name(name).then(|| Resource::UserAbout { name: (*name).to_string() }),
		["user", name, listing] => user_listing(name, listing, &query),
		["user", name] => user_listing(name, "overview", &query),
		["search"] => search(None, &query),
		["subreddits", "search"] => subreddit_search(&query),
		_ => None,
	};
	parsed.unwrap_or(Resource::Other)
}

fn about(sub: &str) -> Option<Resource> {
	(valid_name(sub) && !is_random(sub)).then(|| Resource::About { sub: sub.to_string() })
}

/// `random`/`randnsfw` redirect to a different sub on every REST call; GraphQL has no such name.
fn is_random(sub: &str) -> bool {
	sub == "random" || sub == "randnsfw"
}

fn listing(sub: &str, sort: &str, query: &Query) -> Option<Resource> {
	let page = Page {
		sort: Sort::parse(sort)?,
		range: query.range(),
		after: query.cursor().ok()?,
	};
	let subs: Vec<&str> = sub.split('+').filter(|s| !s.is_empty()).collect();
	if subs.is_empty() || !subs.iter().all(|s| valid_name(s)) || subs.iter().any(|s| is_random(s)) {
		return None;
	}
	Some(match subs.as_slice() {
		["popular"] => Resource::Popular(page),
		["all"] => Resource::All(page),
		[one] => Resource::SubredditListing { sub: (*one).to_string(), page },
		many => Resource::Multi {
			subs: many.iter().map(|s| (*s).to_string()).collect(),
			page: SearchPage {
				sort: SearchSort::for_feed(page.sort),
				// REST's default range for a top listing
				range: page.range.or((page.sort == Sort::Top).then_some(Range::Day)),
				after: page.after,
			},
		},
	})
}

/// `/r/<sub>/wiki/<page>`. The site-wide `/wiki` reads `r/reddit.com`, no subreddit name: REST.
fn wiki(sub: &str, page: &[&str]) -> Option<Resource> {
	let valid = valid_name(sub) && !is_random(sub) && !page.is_empty() && page.iter().all(|segment| valid_name(segment));
	valid.then(|| Resource::Wiki {
		sub: sub.to_string(),
		page: page.join("/"),
	})
}

/// `/r/<sub>/duplicates/<id>`. GetDuplicatePosts has no paging, so a page reached through
/// `before=`/`after=` (only REST makes those links) stays REST.
fn duplicates(id: &str, query: &Query) -> Option<Resource> {
	if query.has("before") || query.has("after") || id.is_empty() || !id.bytes().all(|b| b.is_ascii_alphanumeric()) {
		return None;
	}
	let sort = match query.get("sort") {
		// REST's default, and the template's
		None | Some("num_comments") => Some(DuplicateSort::NumComments),
		Some("new") => Some(DuplicateSort::New),
		Some(_) => None,
	};
	Some(Resource::Duplicates { id: id.to_string(), sort })
}

fn by_id(ids: &str) -> Option<Resource> {
	let ids: Vec<String> = ids.split(',').map(str::to_string).collect();
	let valid = |id: &String| id.strip_prefix("t3_").is_some_and(|id| !id.is_empty() && id.bytes().all(|b| b.is_ascii_alphanumeric()));
	ids.iter().all(valid).then_some(Resource::ById { ids })
}

fn user_listing(name: &str, listing: &str, query: &Query) -> Option<Resource> {
	let listing = match listing {
		"overview" => UserListing::Overview,
		"submitted" => UserListing::Submitted,
		"comments" => UserListing::Comments,
		_ => return None,
	};
	let page = Page {
		// REST's default for a user's listings
		sort: Sort::parse(query.get("sort").unwrap_or("new"))?,
		range: query.range(),
		after: query.cursor().ok()?,
	};
	valid_name(name).then(|| Resource::UserListing {
		name: name.to_string(),
		listing,
		page,
	})
}

/// `/search` and `/r/<sub>/search`, which only stays in the sub with `restrict_sr`. A search for
/// subreddits or users (`type=sr,user`) is REST's.
fn search(sub: Option<&str>, query: &Query) -> Option<Resource> {
	if query.get("type").is_some_and(|kind| kind != "link") {
		return None;
	}
	let q = query.get("q")?.trim();
	let restrict = matches!(query.get("restrict_sr"), Some("on" | "true" | "1"));
	let q = match sub.filter(|_| restrict) {
		// Grouped, so an OR in the query cannot escape the restriction. A query with its own
		// parentheses could unbalance the group; REST serves it.
		Some(_) if q.contains(['(', ')']) => return None,
		Some(sub) if valid_name(sub) => format!("subreddit:{sub} ({q})"),
		// A restricted multireddit search would need a grouped OR; REST serves it.
		Some(_) => return None,
		None => q.to_string(),
	};
	let page = SearchPage {
		sort: SearchSort::parse(query.get("sort").unwrap_or("relevance"))?,
		range: query.range(),
		after: query.cursor().ok()?,
	};
	Some(Resource::Search { query: q, page })
}

fn subreddit_search(query: &Query) -> Option<Resource> {
	let limit = query.get("limit").and_then(|l| l.parse().ok()).unwrap_or(3_u32).clamp(1, 50);
	Some(Resource::SubredditSearch {
		query: query.get("q")?.to_string(),
		limit,
	})
}

/// `path` without a GraphQL `after`/`before`, for REST, which cannot read one (that page then
/// starts over). None when there was nothing to drop.
pub(crate) fn without_gql_cursor(path: &str) -> Option<String> {
	let (route, query) = path.split_once('?')?;
	let is_ours = |pair: &&str| {
		pair
			.split_once('=')
			.is_some_and(|(key, value)| (key == "after" || key == "before") && cursor_from_after(value).is_some())
	};
	let pairs: Vec<&str> = query.split('&').collect();
	if !pairs.iter().any(is_ours) {
		return None;
	}
	let kept: Vec<&str> = pairs.into_iter().filter(|pair| !is_ours(pair)).collect();
	Some(format!("{route}?{}", kept.join("&")))
}

#[cfg(test)]
pub(crate) mod tests {
	use super::*;
	use crate::gql_fields::after_param;

	/// A feed page; also used by `gql_ops`'s tests.
	pub(crate) fn page(sort: Sort, range: Option<Range>, after: Option<&str>) -> Page {
		Page {
			sort,
			range,
			after: after.map(str::to_string),
		}
	}

	#[test]
	fn subreddit_listings_with_sort_range_and_cursor() {
		assert_eq!(
			parse("/r/pics/hot.json?&raw_json=1"),
			Resource::SubredditListing {
				sub: "pics".into(),
				page: page(Sort::Hot, None, None)
			}
		);
		let next = format!("/r/pics/top.json?sort=top&t=week&after={}&raw_json=1", after_param("c:1"));
		assert_eq!(
			parse(&next),
			Resource::SubredditListing {
				sub: "pics".into(),
				page: page(Sort::Top, Some(Range::Week), Some("c:1"))
			}
		);
		assert_eq!(parse("/r/pics/top.json?t=forever").kind(), Some(Kind::Listing));
		assert_eq!(
			parse("/r/popular/rising.json?&raw_json=1&geo_filter=GLOBAL"),
			Resource::Popular(page(Sort::Rising, None, None))
		);
		assert_eq!(parse("/r/all/new.json"), Resource::All(page(Sort::New, None, None)));
		for other in ["/r/pics/gilded.json", "/r/random/hot.json", "/r/pi cs/hot.json"] {
			assert_eq!(parse(other), Resource::Other, "{other}");
		}
	}

	#[test]
	fn rest_cursors_keep_the_page_on_rest() {
		assert_eq!(parse("/r/pics/hot.json?after=t3_abc"), Resource::Other);
		assert_eq!(parse("/r/pics/hot.json?before=t3_abc"), Resource::Other);
		assert_eq!(parse("/r/pics/hot.json?after=g_%25%25"), Resource::Other);
		// Our PREV link carries our own cursor in `before`: page 1
		let prev = format!("/r/pics/hot.json?before={}", after_param("c"));
		assert_eq!(
			parse(&prev),
			Resource::SubredditListing {
				sub: "pics".into(),
				page: page(Sort::Hot, None, None)
			}
		);
	}

	#[test]
	fn multireddits_are_searches_with_a_searchable_sort() {
		let subs = vec!["rust".to_string(), "linux".to_string()];
		let multi = |sort, range| Resource::Multi {
			subs: subs.clone(),
			page: SearchPage { sort, range, after: None },
		};
		assert_eq!(parse("/r/rust%2Blinux/hot.json?&raw_json=1"), multi(SearchSort::Hot, None));
		assert_eq!(parse("/r/rust+linux/top.json"), multi(SearchSort::Top, Some(Range::Day)));
		assert_eq!(parse("/r/rust+linux/top.json?t=year"), multi(SearchSort::Top, Some(Range::Year)));
		assert_eq!(parse("/r/rust+linux/controversial.json"), multi(SearchSort::Hot, None));
		assert_eq!(parse("/r/rust+linux/new.json"), multi(SearchSort::New, None));
	}

	#[test]
	fn about_posts_and_users() {
		assert_eq!(parse("/r/rust/about.json?raw_json=1"), Resource::About { sub: "rust".into() });
		assert_eq!(parse("/r/randnsfw/about.json"), Resource::Other);
		assert_eq!(parse("/by_id/t3_1xadhhx.json?raw_json=1"), Resource::ById { ids: vec!["t3_1xadhhx".into()] });
		assert_eq!(parse("/by_id/t3_a,t3_b.json").kind(), Some(Kind::Post));
		assert_eq!(parse("/by_id/t1_a.json"), Resource::Other);
		assert_eq!(parse("/user/spez/about.json?raw_json=1"), Resource::UserAbout { name: "spez".into() });
		let user = |listing, sort, range| Resource::UserListing {
			name: "spez".into(),
			listing,
			page: page(sort, range, None),
		};
		assert_eq!(parse("/user/spez/overview.json?&raw_json=1"), user(UserListing::Overview, Sort::New, None));
		assert_eq!(
			parse("/user/spez/submitted.json?sort=top&t=all&raw_json=1"),
			user(UserListing::Submitted, Sort::Top, Some(Range::All))
		);
		assert_eq!(parse("/user/spez/comments.json?sort=hot"), user(UserListing::Comments, Sort::Hot, None));
		assert_eq!(parse("/user/spez/upvoted.json"), Resource::Other);
		assert_eq!(parse("/user/spez/comments/abc/t.json"), Resource::Other);
	}

	#[test]
	fn searches() {
		let search = |query: &str, sort, range| Resource::Search {
			query: query.into(),
			page: SearchPage { sort, range, after: None },
		};
		assert_eq!(parse("/search.json?q=rust+lang&raw_json=1"), search("rust lang", SearchSort::Relevance, None));
		assert_eq!(
			parse("/search.json?q=rust&sort=top&t=week&include_over_18=on"),
			search("rust", SearchSort::Top, Some(Range::Week))
		);
		assert_eq!(
			parse("/r/rust/search.json?q=async&restrict_sr=on"),
			search("subreddit:rust (async)", SearchSort::Relevance, None)
		);
		assert_eq!(
			parse("/r/rust/search.json?q=async%20OR%20tokio&restrict_sr=on"),
			search("subreddit:rust (async OR tokio)", SearchSort::Relevance, None)
		);
		assert_eq!(parse("/r/rust/search.json?q=(a&restrict_sr=on"), Resource::Other);
		// Unrestricted, a sub's search is Reddit-wide
		assert_eq!(parse("/r/rust/search.json?q=async"), search("async", SearchSort::Relevance, None));
		assert_eq!(parse("/r/a+b/search.json?q=x&restrict_sr=on"), Resource::Other);
		assert_eq!(parse("/search.json?q=x&type=sr_user"), Resource::Other);
		assert_eq!(parse("/search.json?q=x&sort=random"), Resource::Other);
		assert_eq!(parse("/search.json?sort=new"), Resource::Other);
		assert_eq!(
			parse("/subreddits/search.json?q=rust+lang&limit=50"),
			Resource::SubredditSearch {
				query: "rust lang".into(),
				limit: 50
			}
		);
		assert_eq!(parse("/subreddits/search.json?q=x").kind(), Some(Kind::Search));
	}

	#[test]
	fn wiki_pages() {
		let wiki = |page: &str| Resource::Wiki {
			sub: "rust".into(),
			page: page.into(),
		};
		assert_eq!(parse("/r/rust/wiki/index.json?raw_json=1"), wiki("index"));
		assert_eq!(parse("/r/rust/wiki/config/sidebar.json?raw_json=1"), wiki("config/sidebar"));
		assert_eq!(parse("/r/rust/wiki/rules/.json?raw_json=1"), wiki("rules"));
		assert_eq!(parse("/r/rust/wiki/rules.json").kind(), Some(Kind::Wiki));
		for other in [
			"/r/random/wiki/index.json",
			"/r/randnsfw/wiki/index.json",
			"/r/reddit.com/wiki/index.json",
			"/r/rust/wiki/a b.json",
			"/r/rust/wiki/a//b.json",
		] {
			assert_eq!(parse(other), Resource::Other, "{other}");
		}
	}

	#[test]
	fn duplicates_with_their_sort_and_no_rest_cursor() {
		let dups = |sort| Resource::Duplicates { id: "abc".into(), sort };
		assert_eq!(parse("/r/news/duplicates/abc.json?&raw_json=1"), dups(Some(DuplicateSort::NumComments)));
		assert_eq!(parse("/r/news/duplicates/abc/a_title.json?sort=new&raw_json=1"), dups(Some(DuplicateSort::New)));
		assert_eq!(parse("/duplicates/abc.json?sort=num_comments"), dups(Some(DuplicateSort::NumComments)));
		assert_eq!(parse("/duplicates/abc/t.json?sort=top"), dups(None));
		assert_eq!(parse("/r/news/duplicates/abc.json").kind(), Some(Kind::Duplicates));
		for other in [
			"/r/news/duplicates/abc.json?after=t3_x&sort=new",
			"/r/news/duplicates/abc.json?before=t3_x&sort=num_comments&limit=1",
			"/r/news/duplicates/abc.json?before=",
			"/r/news/duplicates/a-c.json",
		] {
			assert_eq!(parse(other), Resource::Other, "{other}");
		}
	}

	#[test]
	fn names_round_trip() {
		for kind in Kind::ALL {
			assert!(!kind.name().is_empty());
		}
		for (name, range) in Range::NAMES {
			assert_eq!(range.filter(), name);
			assert_eq!(range.gql(), name.to_uppercase());
		}
		for sort in ["hot", "new", "top", "rising", "controversial", "best"] {
			assert_eq!(Sort::parse(sort).unwrap().gql(), sort.to_uppercase());
		}
		for sort in ["relevance", "hot", "top", "new", "comments"] {
			assert_eq!(SearchSort::parse(sort).unwrap().gql(), sort.to_uppercase());
		}
	}

	#[test]
	fn rest_paths_lose_only_our_cursor() {
		let ours = after_param("c");
		assert_eq!(
			without_gql_cursor(&format!("/r/pics/hot.json?sort=hot&after={ours}&raw_json=1")).as_deref(),
			Some("/r/pics/hot.json?sort=hot&raw_json=1")
		);
		assert_eq!(without_gql_cursor(&format!("/r/pics/hot.json?before={ours}")).as_deref(), Some("/r/pics/hot.json?"));
		assert_eq!(without_gql_cursor("/r/pics/hot.json?after=t3_x"), None);
		assert_eq!(without_gql_cursor("/r/pics/hot.json"), None);
	}
}
