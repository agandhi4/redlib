#![allow(dead_code)]
#![allow(clippy::cmp_owned)]

use cookie::Cookie;
use futures_lite::{future::Boxed, Future, FutureExt};
use hyper::{
	header,
	service::{make_service_fn, service_fn},
	HeaderMap,
};
use hyper::{Body, Method, Request, Response, Server as HyperServer};
use route_recognizer::{Params, Router};
use std::{pin::Pin, result::Result, string::ToString};
use time::{Duration, OffsetDateTime};

use crate::compression::compress_response;
use crate::config;
use crate::upstream_log;

const BANNED_USER_AGENTS: &[&str] = &[
	"AI2Bot",
	"Ai2Bot-Dolma",
	"Amazonbot",
	"Andibot",
	"Applebot",
	"Applebot-Extended",
	"Awario",
	"Brightbot 1.0",
	"Bytespider",
	"CCBot",
	"ChatGPT-User",
	"Claude-SearchBot",
	"Claude-User",
	"Claude-Web",
	"ClaudeBot",
	"Cotoyogi",
	"Crawlspace",
	"Datenbank Crawler",
	"Devin",
	"Diffbot",
	"DuckAssistBot",
	"Echobot Bot",
	"EchoboxBot",
	"FacebookBot",
	"Factset_spyderbot",
	"FirecrawlAgent",
	"FriendlyCrawler",
	"GPTBot",
	"Google-CloudVertexBot",
	"Google-Extended",
	"GoogleOther",
	"GoogleOther-Image",
	"GoogleOther-Video",
	"ICC-Crawler",
	"ISSCyberRiskCrawler",
	"ImagesiftBot",
	"Kangaroo Bot",
	"Meta-ExternalAgent",
	"Meta-ExternalFetcher",
	"MistralAI-User",
	"MistralAI-User/1.0",
	"MyCentralAIScraperBot",
	"NovaAct",
	"OAI-SearchBot",
	"Operator",
	"PanguBot",
	"Panscient",
	"Perplexity-User",
	"PerplexityBot",
	"PetalBot",
	"PhindBot",
	"Poseidon Research Crawler",
	"QualifiedBot",
	"QuillBot",
	"SBIntuitionsBot",
	"Scrapy",
	"SemrushBot",
	"SemrushBot-BA",
	"SemrushBot-CT",
	"SemrushBot-OCOB",
	"SemrushBot-SI",
	"SemrushBot-SWA",
	"Sidetrade indexer bot",
	"TikTokSpider",
	"Timpibot",
	"VelenPublicWebCrawler",
	"WARDBot",
	"Webzio-Extended",
	"YandexAdditional",
	"YandexAdditionalBot",
	"YouBot",
	"aiHitBot",
	"anthropic-ai",
	"bedrockbot",
	"cohere-ai",
	"cohere-training-data-crawler",
	"facebookexternalhit",
	"iaskspider/2.0",
	"img2dataset",
	"meta-externalagent",
	"meta-externalfetcher",
	"omgili",
	"omgilibot",
	"panscient.com",
	"quillbot.com",
	"wpbot",
];

type BoxResponse = Pin<Box<dyn Future<Output = Result<Response<Body>, String>> + Send>>;

pub struct Route<'a> {
	router: &'a mut Router<fn(Request<Body>) -> BoxResponse>,
	path: String,
}

pub struct Server {
	pub default_headers: HeaderMap,
	router: Router<fn(Request<Body>) -> BoxResponse>,
}

#[macro_export]
macro_rules! headers(
	{ $($key:expr => $value:expr),+ } => {
		{
			let mut m = hyper::HeaderMap::new();
			$(
				if let Ok(val) = hyper::header::HeaderValue::from_str($value) {
					m.insert($key, val);
				}
			)+
			m
		}
	 };
);

pub trait RequestExt {
	fn params(&self) -> Params;
	fn param(&self, name: &str) -> Option<String>;
	fn set_params(&mut self, params: Params) -> Option<Params>;
	fn cookies(&self) -> Vec<Cookie<'_>>;
	fn cookie(&self, name: &str) -> Option<Cookie<'_>>;
}

pub trait ResponseExt {
	fn cookies(&self) -> Vec<Cookie<'_>>;
	fn insert_cookie(&mut self, cookie: Cookie<'_>);
	/// A preference cookie: site-wide, HttpOnly, kept for 52 weeks. `remove_cookie` expires one.
	fn insert_persistent_cookie(&mut self, name: String, value: String);
	fn remove_cookie(&mut self, name: String);
}

impl RequestExt for Request<Body> {
	fn params(&self) -> Params {
		self.extensions().get::<Params>().unwrap_or(&Params::new()).clone()
		// self.extensions()
		// 	.get::<RequestMeta>()
		// 	.and_then(|meta| meta.route_params())
		// 	.expect("Routerify: No RouteParams added while processing request")
	}

	fn param(&self, name: &str) -> Option<String> {
		self.params().find(name).map(std::borrow::ToOwned::to_owned)
	}

	fn set_params(&mut self, params: Params) -> Option<Params> {
		self.extensions_mut().insert(params)
	}

	fn cookies(&self) -> Vec<Cookie<'_>> {
		self.headers().get("Cookie").map_or(Vec::new(), |header| {
			header
				.to_str()
				.unwrap_or_default()
				.split("; ")
				.map(|cookie| Cookie::parse(cookie).unwrap_or_else(|_| Cookie::from("")))
				.collect()
		})
	}

	fn cookie(&self, name: &str) -> Option<Cookie<'_>> {
		self.cookies().into_iter().find(|c| c.name() == name)
	}
}

impl ResponseExt for Response<Body> {
	fn cookies(&self) -> Vec<Cookie<'_>> {
		self.headers().get("Cookie").map_or(Vec::new(), |header| {
			header
				.to_str()
				.unwrap_or_default()
				.split("; ")
				.map(|cookie| Cookie::parse(cookie).unwrap_or_else(|_| Cookie::from("")))
				.collect()
		})
	}

	fn insert_cookie(&mut self, cookie: Cookie<'_>) {
		if let Ok(val) = header::HeaderValue::from_str(&cookie.to_string()) {
			self.headers_mut().append("Set-Cookie", val);
		}
	}

	fn insert_persistent_cookie(&mut self, name: String, value: String) {
		self.insert_cookie(
			Cookie::build((name, value))
				.path("/")
				.http_only(true)
				.expires(OffsetDateTime::now_utc() + Duration::weeks(52))
				.into(),
		);
	}

	fn remove_cookie(&mut self, name: String) {
		let removal_cookie = Cookie::build(name).path("/").http_only(true).expires(OffsetDateTime::now_utc());
		if let Ok(val) = header::HeaderValue::from_str(&removal_cookie.to_string()) {
			self.headers_mut().append("Set-Cookie", val);
		}
	}
}

impl Route<'_> {
	fn method(&mut self, method: &Method, dest: fn(Request<Body>) -> BoxResponse) -> &mut Self {
		self.router.add(&format!("/{}{}", method.as_str(), self.path), dest);
		self
	}

	/// Add an endpoint for `GET` requests
	pub fn get(&mut self, dest: fn(Request<Body>) -> BoxResponse) -> &mut Self {
		self.method(&Method::GET, dest)
	}

	/// Add an endpoint for `POST` requests
	pub fn post(&mut self, dest: fn(Request<Body>) -> BoxResponse) -> &mut Self {
		self.method(&Method::POST, dest)
	}
}

impl Default for Server {
	fn default() -> Self {
		Self::new()
	}
}

impl Server {
	pub fn new() -> Self {
		Self {
			default_headers: HeaderMap::new(),
			router: Router::new(),
		}
	}

	pub fn at(&mut self, path: &str) -> Route<'_> {
		Route {
			path: path.to_owned(),
			router: &mut self.router,
		}
	}

	pub fn listen(self, addr: &str) -> Boxed<Result<(), hyper::Error>> {
		let make_svc = make_service_fn(move |_conn| {
			// For correct borrowing, these values need to be borrowed
			let router = self.router.clone();
			let default_headers = self.default_headers.clone();

			// This is the `Service` that will handle the connection.
			// `service_fn` is a helper to convert a function that
			// returns a Response into a `Service`.
			// let shared_router = router.clone();
			async move {
				Ok::<_, String>(service_fn(move |req: Request<Body>| {
					let req_headers = req.headers().clone();
					let def_headers = default_headers.clone();

					// Catch robots.txt-disrespecful bots who still identify themselves
					// Typically justified as "human triggered" actions.
					if match config::get_setting("REDLIB_ROBOTS_DISABLE_INDEXING") {
						Some(val) => val == "on",
						None => false,
					} {
						if let Some(user_agent) = req_headers.get("user-agent") {
							if let Ok(user_agent_str) = user_agent.to_str() {
								for banned in BANNED_USER_AGENTS {
									if user_agent_str.contains(banned) {
										return new_boilerplate(def_headers, req_headers, 403, Body::from("Forbidden")).boxed();
									}
								}
							}
						}
					}

					// Remove double slashes and decode encoded slashes
					let mut path = req.uri().path().replace("//", "/").replace("%2F", "/");

					// Remove trailing slashes
					if path != "/" && path.ends_with('/') {
						path.pop();
					}

					// Replace HEAD with GET for routing
					let (method, is_head) = match req.method() {
						&Method::HEAD => (&Method::GET, true),
						method => (method, false),
					};

					// Match the visited path with an added route
					match router.recognize(&format!("/{}{}", method.as_str(), path)) {
						// If a route was configured for this path
						Ok(found) => {
							let mut parammed = req;
							parammed.set_params(found.params().clone());

							// Run the route's function
							let cause = upstream_log::Cause::of(&req_headers);
							let func = upstream_log::scope(cause, (found.handler().to_owned().to_owned())(parammed));
							async move {
								match func.await {
									Ok(mut res) => {
										res.headers_mut().extend(def_headers);
										if is_head {
											*res.body_mut() = Body::empty();
										} else {
											let _ = compress_response(&req_headers, &mut res).await;
										}

										Ok(res)
									}
									Err(msg) => new_boilerplate(def_headers, req_headers, 500, if is_head { Body::empty() } else { Body::from(msg) }).await,
								}
							}
							.boxed()
						}
						// If there was a routing error
						Err(e) => new_boilerplate(def_headers, req_headers, 404, if is_head { Body::empty() } else { e.into() }).boxed(),
					}
				}))
			}
		});

		// Build SocketAddr from provided address
		let address = &addr.parse().unwrap_or_else(|_| panic!("Cannot parse {addr} as address (example format: 0.0.0.0:8080)"));

		// Bind server to address specified above. Gracefully shut down if CTRL+C is pressed
		let server = HyperServer::bind(address).serve(make_svc).with_graceful_shutdown(async {
			#[cfg(windows)]
			// Wait for the CTRL+C signal
			tokio::signal::ctrl_c().await.expect("Failed to install CTRL+C signal handler");

			#[cfg(unix)]
			{
				// Wait for CTRL+C or SIGTERM signals
				let mut signal_terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).expect("Failed to install SIGTERM signal handler");
				tokio::select! {
					_ = tokio::signal::ctrl_c() => (),
					_ = signal_terminate.recv() => ()
				}
			}
		});

		server.boxed()
	}
}

/// Create a boilerplate Response for error conditions. This response will be
/// compressed if requested by client.
async fn new_boilerplate(
	default_headers: HeaderMap<header::HeaderValue>,
	req_headers: HeaderMap<header::HeaderValue>,
	status: u16,
	body: Body,
) -> Result<Response<Body>, String> {
	match Response::builder().status(status).body(body) {
		Ok(mut res) => {
			let _ = compress_response(&req_headers, &mut res).await;

			res.headers_mut().extend(default_headers.clone());
			Ok(res)
		}
		Err(msg) => Err(msg.to_string()),
	}
}
