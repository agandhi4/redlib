//! Health contract (~/.claude/conventions/observability.md, Health Contract).
//!
//! `/health/live` checks nothing and answers 200 while the process serves. `/health/ready` runs
//! every registered check and answers 503 when one is down. The body names what is down, never
//! why: the endpoint is unauthenticated, so the detail goes to the log.
//! Used by: src/main.rs (the router), the Dockerfile HEALTHCHECK and scripts/ci/smoke_image.sh
//! (both read /health/ready and its `version`).

use std::{collections::BTreeMap, future::Future, pin::Pin, sync::Arc, time::Duration};

use axum::{Json, Router, extract::State, http::StatusCode, routing::get};
use serde_json::{Map, Value, json};

/// A readiness check resolves to `true` when its dependency is up.
pub type CheckFuture = Pin<Box<dyn Future<Output = bool> + Send>>;
pub type Check = Arc<dyn Fn() -> CheckFuture + Send + Sync>;

/// A check that has not answered by then is down: the container healthcheck gives the whole
/// request 5 s, and a hung database must not hang the probe.
const CHECK_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Clone)]
struct Health {
    version: Arc<str>,
    checks: Arc<BTreeMap<&'static str, Check>>,
}

/// The `/health/*` routes. Register a dependency (a database round-trip, ...) in `checks` as
/// the service gains one.
pub fn router(version: &str, checks: BTreeMap<&'static str, Check>) -> Router {
    let state = Health {
        version: version.into(),
        checks: Arc::new(checks),
    };
    Router::new()
        .route("/health/live", get(live))
        .route("/health/ready", get(ready))
        .with_state(state)
}

async fn live(State(health): State<Health>) -> Json<Value> {
    Json(json!({ "status": "up", "version": &*health.version }))
}

async fn ready(State(health): State<Health>) -> (StatusCode, Json<Value>) {
    let mut checks = Map::new();
    let mut all_up = true;
    for (name, check) in health.checks.iter() {
        let up = tokio::time::timeout(CHECK_TIMEOUT, check())
            .await
            .unwrap_or(false);
        all_up &= up;
        checks.insert((*name).to_owned(), json!({ "status": status(up) }));
    }
    let code = if all_up {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    let body = json!({ "status": status(all_up), "version": &*health.version, "checks": checks });
    (code, Json(body))
}

fn status(up: bool) -> &'static str {
    if up { "up" } else { "down" }
}

#[cfg(test)]
mod tests {
    use axum::body::{Body, to_bytes};
    use axum::http::Request;
    use tower::ServiceExt;

    use super::*;

    async fn get_json(app: Router, path: &str) -> (StatusCode, Value) {
        let request = Request::get(path).body(Body::empty()).unwrap();
        let response = app.oneshot(request).await.unwrap();
        let status = response.status();
        let body = to_bytes(response.into_body(), 64 * 1024).await.unwrap();
        (status, serde_json::from_slice(&body).unwrap())
    }

    fn check(up: bool) -> Check {
        Arc::new(move || Box::pin(async move { up }))
    }

    #[tokio::test]
    async fn live_reports_the_version() {
        let (status, body) = get_json(router("test", BTreeMap::new()), "/health/live").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body, json!({ "status": "up", "version": "test" }));
    }

    #[tokio::test]
    async fn ready_is_200_when_every_check_is_up() {
        let app = router("test", BTreeMap::from([("database", check(true))]));
        let (status, body) = get_json(app, "/health/ready").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            body,
            json!({ "status": "up", "version": "test", "checks": { "database": { "status": "up" } } })
        );
    }

    #[tokio::test]
    async fn ready_is_503_when_a_check_is_down_and_names_it() {
        let app = router(
            "test",
            BTreeMap::from([("cache", check(true)), ("database", check(false))]),
        );
        let (status, body) = get_json(app, "/health/ready").await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body["status"], "down");
        assert_eq!(body["checks"]["database"]["status"], "down");
        assert_eq!(body["checks"]["cache"]["status"], "up");
    }

    #[tokio::test(start_paused = true)]
    async fn a_hung_check_is_down_after_the_timeout() {
        let hung: Check = Arc::new(|| Box::pin(std::future::pending()));
        let app = router("test", BTreeMap::from([("database", hung)]));
        let (status, body) = get_json(app, "/health/ready").await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body["checks"]["database"]["status"], "down");
    }

    #[tokio::test]
    async fn unknown_paths_are_404() {
        let request = Request::get("/nope").body(Body::empty()).unwrap();
        let response = router("test", BTreeMap::new())
            .oneshot(request)
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }
}
