//! Process entry (Dockerfile CMD). Every environment variable the service reads is read here;
//! .env.example mirrors them.

mod health;

use std::collections::BTreeMap;

use tokio::net::TcpListener;
use tokio::signal::unix::{SignalKind, signal};

const DEFAULT_PORT: u16 = 8080;

#[tokio::main]
async fn main() -> std::io::Result<()> {
    let port = match std::env::var("PORT") {
        Ok(raw) => raw
            .parse()
            .unwrap_or_else(|_| panic!("PORT must be a port number, got {raw:?}")),
        Err(_) => DEFAULT_PORT,
    };
    // Baked into the image by the build (ARG -> ENV); never set in compose. Reported by
    // /health/ready and the boot line (observability.md, Release Identity).
    let version = std::env::var("APP_VERSION").unwrap_or_else(|_| "dev".to_owned());

    let app = health::router(&version, BTreeMap::new());
    let listener = TcpListener::bind(("0.0.0.0", port)).await?;

    // The boot line states what is enforced (observability.md, Logging). One JSON line until
    // the service adopts a logger.
    println!(
        "{}",
        serde_json::json!({ "level": "info", "logger": "__NAME__.main", "msg": "listening", "version": version, "port": port })
    );

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown())
        .await
}

/// The binary is PID 1 in the image, so `docker stop`'s SIGTERM arrives here; Ctrl-C locally.
async fn shutdown() {
    let mut term = signal(SignalKind::terminate()).expect("install the SIGTERM handler");
    tokio::select! {
        _ = term.recv() => {}
        _ = tokio::signal::ctrl_c() => {}
    }
}
