//! Reddit's richtext JSON (RTJSON, the `document` of a GraphQL comment's `content.richtext`) as
//! the HTML of the JSON API's `body_html`; gql-fed sends `content.html` empty. Every text and
//! attribute is HTML-escaped, and only http(s) and local links survive (`url_attr`).
//! Used by `gql_comments`.
//!
//! Ported with it from upstream redlib PR #603, adapted from polak14's renderer (AGPL-3.0-only):
//! https://github.com/polak14/redlib/commit/a63460b4ac29c27401e3e2aaab34b68dca02991e

use crate::rewrite::format_url;
use serde_json::Value;

/// Only http(s) and local links may appear in rendered comment attributes; anything else
/// (`javascript:`, `data:`, protocol-relative `//host`) becomes an empty attribute.
fn url_attr(value: Option<&str>) -> String {
	let value = value.unwrap_or_default().trim();
	if value.chars().any(char::is_control) {
		return String::new();
	}
	let local = value.starts_with('/') && !value.starts_with("//") && !value.contains('\\');
	let web = url::Url::parse(value).is_ok_and(|u| matches!(u.scheme(), "http" | "https"));
	if !local && !web {
		return String::new();
	}
	htmlescape::encode_minimal(&format_url(value))
}

/// Renders richtext (RTJSON) nodes as the HTML of the JSON API's `body_html`.
pub(crate) fn render(nodes: &Value, media: &Value) -> String {
	nodes.as_array().into_iter().flatten().map(|node| element(node, media)).collect()
}

fn element(node: &Value, media: &Value) -> String {
	let children = || render(&node["c"], media);
	match node["e"].as_str().unwrap_or_default() {
		"par" if is_figure(node) => children(),
		"par" => format!("<p>{}</p>", children()),
		"text" => formatted(node),
		"br" => "<br>".to_string(),
		"hr" => "<hr>".to_string(),
		"h" => {
			let level = node["l"].as_u64().unwrap_or(1).clamp(1, 6);
			format!("<h{level}>{}</h{level}>", children())
		}
		"blockquote" => format!("<blockquote>{}</blockquote>", children()),
		"list" => {
			let tag = if node["o"] == true { "ol" } else { "ul" };
			format!("<{tag}>{}</{tag}>", children())
		}
		"li" => format!("<li>{}</li>", children()),
		"code" => code_block(node),
		"spoilertext" => format!("<span class=\"md-spoiler-text\">{}</span>", children()),
		"link" => link(node),
		kind @ ("r/" | "u/") => mention(node, kind),
		"img" | "gif" => figure(node, media),
		"table" => table(node, media),
		// Unknown elements: keep their content
		_ if node["c"].is_array() => children(),
		_ => htmlescape::encode_minimal(node["t"].as_str().unwrap_or_default()),
	}
}

/// A paragraph of only images is a figure, as in the JSON API's HTML.
fn is_figure(par: &Value) -> bool {
	par["c"]
		.as_array()
		.is_some_and(|c| c.iter().all(|child| matches!(child["e"].as_str(), Some("img" | "gif"))))
}

fn code_block(node: &Value) -> String {
	let lines: Vec<&str> = node["c"].as_array().into_iter().flatten().map(|line| line["t"].as_str().unwrap_or_default()).collect();
	format!("<pre><code>{}</code></pre>", htmlescape::encode_minimal(&lines.join("\n")))
}

fn link(node: &Value) -> String {
	let title = node["a"].as_str().map(|a| format!(" title=\"{}\"", htmlescape::encode_minimal(a))).unwrap_or_default();
	format!("<a href=\"{}\"{title}>{}</a>", url_attr(node["u"].as_str()), formatted(node))
}

fn mention(node: &Value, kind: &str) -> String {
	let name = htmlescape::encode_minimal(node["t"].as_str().unwrap_or_default());
	let slash = if node["l"] == true { "/" } else { "" };
	format!("<a href=\"/{kind}{name}\">{slash}{kind}{name}</a>")
}

/// An inline image or gif, looked up by id in the comment's `richtextMedia`.
fn figure(node: &Value, media: &Value) -> String {
	let Some(item) = media.as_array().and_then(|m| m.iter().find(|m| m["id"] == node["id"])) else {
		return String::new();
	};
	let src = url_attr(item["url"].as_str());
	format!("<figure><a href=\"{src}\"><img src=\"{src}\" loading=\"lazy\"></a></figure>")
}

/// RTJSON format bits and their tags
const FORMATS: [(u64, &str); 6] = [(1, "strong"), (2, "em"), (8, "del"), (16, "sub"), (32, "sup"), (64, "code")];

/// Text with format ranges (`[bits, start, length]` in characters) as HTML.
fn formatted(node: &Value) -> String {
	let text: Vec<char> = node["t"].as_str().unwrap_or_default().chars().collect();
	let bits = format_bits(&node["f"], text.len());
	let mut out = String::new();
	let mut start = 0;
	while start < text.len() {
		let end = (start..text.len()).find(|&i| bits[i] != bits[start]).unwrap_or(text.len());
		let tags: Vec<&str> = FORMATS.iter().filter(|(bit, _)| bits[start] & bit != 0).map(|(_, tag)| *tag).collect();
		tags.iter().for_each(|tag| out += &format!("<{tag}>"));
		out += &htmlescape::encode_minimal(&text[start..end].iter().collect::<String>());
		tags.iter().rev().for_each(|tag| out += &format!("</{tag}>"));
		start = end;
	}
	out
}

/// The format bits of each character of a text of `len` characters.
fn format_bits(ranges: &Value, len: usize) -> Vec<u64> {
	let mut bits = vec![0u64; len];
	for range in ranges.as_array().into_iter().flatten() {
		let (Some(format), Some(start), Some(span)) = (range[0].as_u64(), range[1].as_u64(), range[2].as_u64()) else {
			continue;
		};
		for b in bits.iter_mut().skip(start as usize).take(span as usize) {
			*b |= format;
		}
	}
	bits
}

fn table(node: &Value, media: &Value) -> String {
	let align = |header: Option<&Value>| match header.and_then(|h| h["a"].as_str()) {
		Some("L") => " align=\"left\"",
		Some("C") => " align=\"center\"",
		Some("R") => " align=\"right\"",
		_ => "",
	};
	let headers = node["h"].as_array().map(Vec::as_slice).unwrap_or_default();

	let mut out = "<table><thead><tr>".to_string();
	for header in headers {
		out += &format!("<th{}>{}</th>", align(Some(header)), render(&header["c"], media));
	}
	out += "</tr></thead><tbody>";
	for row in node["c"].as_array().into_iter().flatten() {
		out += "<tr>";
		for (i, cell) in row.as_array().into_iter().flatten().enumerate() {
			out += &format!("<td{}>{}</td>", align(headers.get(i)), render(&cell["c"], media));
		}
		out += "</tr>";
	}
	out + "</tbody></table>"
}

#[cfg(test)]
mod tests {
	use super::*;
	use serde_json::json;

	#[test]
	fn unsafe_urls_never_reach_html_attributes() {
		for url in [
			"javascript:alert(1)",
			"JaVaScRiPt:alert(1)",
			"java\nscript:alert(1)",
			"data:text/html,<script>x</script>",
			"//evil.test/x",
			"/\\evil.test",
			"vbscript:msgbox(1)",
		] {
			assert!(url_attr(Some(url)).is_empty(), "{url}");
		}
		assert_eq!(url_attr(None), "");
		assert_eq!(url_attr(Some("/r/rust?a=1&b=2")), "/r/rust?a=1&amp;b=2");
		assert_eq!(url_attr(Some("https://example.com/\"x")), "https://example.com/&quot;x");
		// Reddit links land on this instance
		assert_eq!(url_attr(Some("https://www.reddit.com/r/rust/")), "/r/rust/");
	}

	#[test]
	fn render_handles_text_formats_links_and_mentions() {
		let doc = json!([{ "e": "par", "c": [
			{ "e": "text", "t": "a <b> ünï bold", "f": [[1, 10, 4], [3, 12, 2], [64, 99, 1]] },
			{ "e": "link", "t": "x", "u": "javascript:alert(1)", "a": "t\"" },
			{ "e": "link", "t": "ok", "u": "https://example.com/?a=1&b=2", "f": [[2, 0, 2]] },
			{ "e": "r/", "t": "rust", "l": true },
			{ "e": "u/", "t": "spez", "l": false },
			{ "e": "br" },
			{ "e": "spoilertext", "c": [{ "e": "text", "t": "s" }] },
		]}]);
		assert_eq!(
			render(&doc, &Value::Null),
			concat!(
				"<p>a &lt;b&gt; ünï <strong>bo</strong><strong><em>ld</em></strong>",
				r#"<a href="" title="t&quot;">x</a>"#,
				r#"<a href="https://example.com/?a=1&amp;b=2"><em>ok</em></a>"#,
				r#"<a href="/r/rust">/r/rust</a><a href="/u/spez">u/spez</a><br>"#,
				r#"<span class="md-spoiler-text">s</span></p>"#,
			)
		);
	}

	#[test]
	fn render_handles_block_elements() {
		let doc = json!([
			{ "e": "h", "l": 9, "c": [{ "e": "text", "t": "H" }] },
			{ "e": "blockquote", "c": [{ "e": "par", "c": [{ "e": "text", "t": "q" }] }] },
			{ "e": "code", "c": [{ "e": "raw", "t": "<x>" }, { "e": "raw", "t": "y" }] },
			{ "e": "list", "o": true, "c": [{ "e": "li", "c": [{ "e": "par", "c": [{ "e": "text", "t": "i" }] }] }] },
			{ "e": "list", "c": [{ "e": "li", "c": [{ "e": "text", "t": "u" }] }] },
			{ "e": "hr" },
			{ "e": "table", "h": [{ "a": "R", "c": [{ "e": "text", "t": "H" }] }, { "c": [] }], "c": [[{ "c": [{ "e": "text", "t": "1" }] }, { "c": [] }]] },
			{ "e": "future", "c": [{ "e": "text", "t": "kept" }] },
		]);
		assert_eq!(
			render(&doc, &Value::Null),
			concat!(
				"<h6>H</h6>",
				"<blockquote><p>q</p></blockquote>",
				"<pre><code>&lt;x&gt;\ny</code></pre>",
				"<ol><li><p>i</p></li></ol>",
				"<ul><li>u</li></ul>",
				"<hr>",
				r#"<table><thead><tr><th align="right">H</th><th></th></tr></thead><tbody><tr><td align="right">1</td><td></td></tr></tbody></table>"#,
				"kept",
			)
		);
	}

	#[test]
	fn render_resolves_images_through_richtext_media() {
		let doc = json!([
			{ "e": "par", "c": [{ "e": "gif", "id": "giphy|g" }, { "e": "img", "id": "missing" }] },
			{ "e": "par", "c": [{ "e": "text", "t": "see " }, { "e": "img", "id": "i1" }] },
		]);
		let media = json!([
			{ "id": "giphy|g", "url": "https://external-preview.redd.it/g.gif?s=1&a=2" },
			{ "id": "i1", "url": "https://i.redd.it/x.png" },
		]);
		assert_eq!(
			render(&doc, &media),
			concat!(
				// A paragraph of only images is a bare figure; an unknown id renders nothing
				r#"<figure><a href="/preview/external-pre/g.gif?s=1&amp;a=2"><img src="/preview/external-pre/g.gif?s=1&amp;a=2" loading="lazy"></a></figure>"#,
				r#"<p>see <figure><a href="/img/x.png"><img src="/img/x.png" loading="lazy"></a></figure></p>"#,
			)
		);
	}
}
