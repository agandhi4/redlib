#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031  # each @test is its own subshell by design
# Contract tests for bin/contract_probe.sh against a stub app: a python3 http.server on a free
# loopback port, configured per test through files it re-reads on every request:
#   $TMP/routes.json  {"<path>": {"status": n, "body": "...", "proxied_status": n}}
#                     proxied_status answers requests carrying X-Forwarded-For
#   $TMP/reqid        request-id mode: mint (default, 12 fresh hex), echo (inbound or mint),
#                     short (8 hex), constant, none
#   $TMP/logmode      json (default), text, or partial (JSON without `logger`)
# Every request appends one log line for it to $TMP/app.log, carrying the id it answered with
# and the version "abc1234". A fake `docker logs <name>` on PATH prints that file.

bats_require_minimum_version 1.5.0

SCRIPT="$BATS_TEST_DIRNAME/../bin/contract_probe.sh"

setup() {
  TMP=$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/probe.XXXXXX")
  unset BOOT_EXPECT_VERSION
  mkdir -p "$TMP/bin"
  export PATH=$TMP/bin:$PATH STUB_DIR=$TMP
  cat >"$TMP/bin/docker" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = logs ] && [ "$2" = demo-app ] && exec cat "$STUB_DIR/app.log"
echo "Error: No such container: $2" >&2; exit 1
FAKE
  chmod +x "$TMP/bin/docker"
  cat >"$TMP/stub.py" <<'STUB'
import json, os, secrets, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = os.environ["STUB_DIR"]

def setting(name, default):
    try:
        with open(os.path.join(DIR, name)) as f:
            return f.read().strip() or default
    except OSError:
        return default

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        with open(os.path.join(DIR, "routes.json")) as f:
            routes = json.load(f)
        route = routes.get(self.path, {"status": 404, "body": "not found"})
        status = route.get("status", 200)
        if self.headers.get("X-Forwarded-For") and "proxied_status" in route:
            status = route["proxied_status"]
        mode = setting("reqid", "mint")
        inbound = self.headers.get("X-Request-ID")
        rid = {"mint": secrets.token_hex(6), "short": secrets.token_hex(4),
               "constant": "aaaaaaaaaaaa", "none": None}.get(mode)
        if mode == "echo":
            rid = inbound or secrets.token_hex(6)
        body = route.get("body", "").encode()
        self.send_response(status)
        if rid:
            self.send_header("X-Request-ID", rid)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        logmode = setting("logmode", "json")
        line = {"ts": "2026-10-13T00:00:00Z", "level": "info", "logger": "demo.http",
                "msg": "request", "version": "abc1234", "request_id": rid, "route": self.path}
        if logmode == "partial":
            del line["logger"]
        text = json.dumps(line) if logmode != "text" else f"INFO request {self.path} {rid}"
        with open(os.path.join(DIR, "app.log"), "a") as f:
            f.write(text + "\n")

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(DIR, "port"), "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
STUB
  printf 'demo starting\n' >"$TMP/app.log"
  routes '{}'
  python3 -I "$TMP/stub.py" >"$TMP/stub.out" 2>&1 3>&- &
  STUB_PID=$!
  local _
  for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
  [ -s "$TMP/port" ] || { cat "$TMP/stub.out" >&2; return 1; }
  BASE="http://127.0.0.1:$(cat "$TMP/port")"
}

teardown() {
  kill "$STUB_PID" 2>/dev/null || true
  wait "$STUB_PID" 2>/dev/null || true
  rm -rf "$TMP"
}

routes() { printf '%s' "$1" >"$TMP/routes.json"; }
# ready <http-status> <body-json>
ready() { routes "$(python3 -c 'import json,sys; print(json.dumps({"/health/ready": {"status": int(sys.argv[1]), "body": sys.argv[2]}}))' "$1" "$2")"; }
probe() { run "$SCRIPT" "$BASE" "$@"; }

UP='{"status":"up","version":"abc1234","checks":{"database":{"status":"up"}}}'

# ---- usage ---------------------------------------------------------------------------------

@test "usage errors exit 2: no base, bad base, no flags, unknown flag, relative path, orphan --require-metric" {
  run "$SCRIPT";                                            [ "$status" -eq 2 ]
  run "$SCRIPT" localhost:8000 --live /x;                   [ "$status" -eq 2 ]
  run "$SCRIPT" "$BASE";                                    [ "$status" -eq 2 ]
  run "$SCRIPT" "$BASE" --frobnicate /x;                    [ "$status" -eq 2 ]
  run "$SCRIPT" "$BASE" --health health/ready;              [ "$status" -eq 2 ]
  run "$SCRIPT" "$BASE" --live;                             [ "$status" -eq 2 ]
  run "$SCRIPT" "$BASE" --require-metric app_info;          [ "$status" -eq 2 ]
  run "$SCRIPT" "$BASE" --metrics /m --require-metric 'a b'; [ "$status" -eq 2 ]
  run "$SCRIPT" "$BASE" --proxy-404 /metrics;               [ "$status" -eq 2 ]
}

# ---- live ------------------------------------------------------------------------------------

@test "live: 200 passes, anything else fails" {
  routes '{"/health/live": {"status": 200, "body": "ok"}}'
  probe --live /health/live
  [ "$status" -eq 0 ]
  [[ "$output" == *"probe live PASS /health/live 200"* ]]
  [[ "$output" == *"probe summary pass=1 fail=0"* ]]
  routes '{"/health/live": {"status": 500}}'
  probe --live /health/live
  [ "$status" -eq 1 ]
  [[ "$output" == *"probe live FAIL /health/live answered 500, expected 200"* ]]
}

# ---- health ----------------------------------------------------------------------------------

@test "health: the convention's shape passes, with and without BOOT_EXPECT_VERSION" {
  ready 200 '{"status":"up","version":"abc1234","checks":{"database":{"status":"up"},"loop":{"status":"down","required":false,"fix":"see docs"}}}'
  probe --health /health/ready
  [ "$status" -eq 0 ]
  [[ "$output" == *"probe health PASS /health/ready 200"* ]]
  BOOT_EXPECT_VERSION=abc1234 probe --health /health/ready
  [ "$status" -eq 0 ]
  [[ "$output" == *"version=abc1234"* ]]
}

@test "health: 503 with down and a required check down passes" {
  ready 503 '{"status":"down","version":"abc1234","checks":{"database":{"status":"down"}}}'
  probe --health /health/ready
  [ "$status" -eq 0 ]
}

@test "health: version mismatch fails" {
  ready 200 "$UP"
  BOOT_EXPECT_VERSION=fff0000 probe --health /health/ready
  [ "$status" -eq 1 ]
  [[ "$output" == *"version 'abc1234', expected 'fff0000'"* ]]
}

@test "health: status outside up|down fails (ok, healthy, degraded)" {
  local s
  for s in ok healthy degraded; do
    ready 200 "{\"status\":\"$s\",\"version\":\"abc1234\",\"checks\":{}}"
    probe --health /health/ready
    [ "$status" -eq 1 ]
    [[ "$output" == *"status '$s' is not up|down"* ]]
  done
}

@test "health: HTTP code and status must agree" {
  ready 200 '{"status":"down","version":"abc1234","checks":{"database":{"status":"down"}}}'
  probe --health /health/ready
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 200 with status 'down'"* ]]
  ready 500 "$UP"
  probe --health /health/ready
  [ "$status" -eq 1 ]
  [[ "$output" == *"answered 500, expected 200 or 503"* ]]
}

@test "health: up while a required check is down fails; an optional check down does not flip it" {
  ready 200 '{"status":"up","version":"abc1234","checks":{"database":{"status":"down"}}}'
  probe --health /health/ready
  [ "$status" -eq 1 ]
  [[ "$output" == *"required checks down: ['database']"* ]]
  ready 503 '{"status":"down","version":"abc1234","checks":{"loop":{"status":"down","required":false}}}'
  probe --health /health/ready
  [ "$status" -eq 1 ]
  [[ "$output" == *"required checks down: none"* ]]
}

@test "health: missing version, missing checks, bad check fields and leaked exception text fail" {
  ready 200 '{"status":"up","checks":{}}'
  probe --health /health/ready
  [[ "$output" == *"version None is not a non-empty string"* ]]
  ready 200 '{"status":"up","version":"abc1234"}'
  probe --health /health/ready
  [[ "$output" == *"checks is not an object"* ]]
  ready 200 '{"status":"up","version":"abc1234","checks":{"db":{"status":"up","required":"no","fix":3}}}'
  probe --health /health/ready
  [[ "$output" == *"check db required 'no' is not a boolean"* ]]
  [[ "$output" == *"check db fix is not a string"* ]]
  ready 503 '{"status":"down","version":"abc1234","checks":{"db":{"status":"down","error":"Traceback (most recent call last)"}}}'
  probe --health /health/ready
  [ "$status" -eq 1 ]
  [[ "$output" == *"body contains 'Traceback'"* ]]
  ready 200 'not json'
  probe --health /health/ready
  [ "$status" -eq 1 ]
  [[ "$output" == *"body is not a JSON object"* ]]
}

# ---- request id ------------------------------------------------------------------------------

@test "request-id: fresh 12-hex ids pass" {
  routes '{"/health/live": {"status": 200}}'
  probe --request-id /health/live
  [ "$status" -eq 0 ]
  [[ "$output" =~ probe\ request-id\ PASS\ /health/live\ [0-9a-f]{12}\ [0-9a-f]{12} ]]
}

@test "request-id: echoing the inbound id, a constant, a short id or no header fails" {
  routes '{"/health/live": {"status": 200}}'
  echo echo >"$TMP/reqid"
  probe --request-id /health/live
  [ "$status" -eq 1 ]
  [[ "$output" == *"the inbound X-Request-ID came back"* ]]
  echo constant >"$TMP/reqid"
  probe --request-id /health/live
  [[ "$output" == *"two requests got the same id 'aaaaaaaaaaaa'"* ]]
  echo short >"$TMP/reqid"
  probe --request-id /health/live
  [[ "$output" == *"is not 12 lowercase hex"* ]]
  echo none >"$TMP/reqid"
  probe --request-id /health/live
  [ "$status" -eq 1 ]
  [[ "$output" == *"no X-Request-ID response header"* ]]
}

# ---- json log --------------------------------------------------------------------------------

@test "json-log: a file and a container both pass, and the probed request id is found" {
  routes '{"/health/live": {"status": 200}}'
  probe --request-id /health/live --json-log "$TMP/app.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"probe json-log PASS"* ]]
  [[ "$output" == *"complete of"* ]]
  BOOT_EXPECT_VERSION=abc1234 probe --request-id /health/live --json-log demo-app
  [ "$status" -eq 0 ]
  [[ "$output" == *"probe json-log PASS demo-app"* ]]
}

@test "json-log: logs run last, after every other probe request" {
  routes '{"/health/live": {"status": 200}}'
  probe --json-log "$TMP/app.log" --request-id /health/live
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "probe request-id PASS"* ]]
  [[ "${lines[1]}" == "probe json-log PASS"* ]]
}

@test "json-log: text lines, a missing field, a wrong version or an absent request id fail" {
  routes '{"/health/live": {"status": 200}}'
  echo text >"$TMP/logmode"
  probe --live /health/live --json-log "$TMP/app.log"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no line carries every required field (0 complete of 0 JSON"* ]]
  echo partial >"$TMP/logmode"
  probe --live /health/live --json-log "$TMP/app.log"
  [[ "$output" == *"missing logger"* ]]
  echo json >"$TMP/logmode"
  BOOT_EXPECT_VERSION=fff0000 probe --live /health/live --json-log "$TMP/app.log"
  [[ "$output" == *"version=fff0000"* ]]
  : >"$TMP/app.log"
  echo partial >"$TMP/logmode"
  probe --request-id /health/live --json-log "$TMP/app.log"
  [ "$status" -eq 1 ]
}

@test "json-log: a request id the logs never mention fails" {
  routes '{"/health/live": {"status": 200}}'
  printf '%s\n' '{"ts":"t","level":"info","logger":"demo.boot","msg":"boot","version":"abc1234","request_id":null}' >"$TMP/fixed.log"
  probe --request-id /health/live --json-log "$TMP/fixed.log"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no line carries request_id"* ]]
}

@test "json-log: an unknown container fails as a probe, not a crash" {
  routes '{"/health/live": {"status": 200}}'
  probe --live /health/live --json-log no-such-app
  [ "$status" -eq 1 ]
  [[ "$output" == *"probe json-log FAIL no-such-app is neither a file nor a container"* ]]
}

# ---- metrics ---------------------------------------------------------------------------------

metrics_body() {
  python3 -c 'import json,sys; print(json.dumps({"/metrics": {"status": 200, "proxied_status": int(sys.argv[2]), "body": sys.argv[1]}}))' "$1" "${2:-404}" >"$TMP/routes.json"
}

GOOD_METRICS='# HELP app_info Build identity.
# TYPE app_info gauge
app_info{version="abc1234"} 1
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{route="/x",method="GET",status_class="2xx",le="0.1"} 3
http_request_duration_seconds_count{route="/x",method="GET",status_class="2xx"} 3
# TYPE http_request_db_statements histogram
# TYPE job_duration_seconds histogram
job_duration_seconds_count{name="sync",outcome="success"} 4
job_duration_seconds_count{name="sync",outcome="interrupted"} 1
job_duration_seconds_count{name="prune",outcome="discarded"} 1
job_duration_seconds_sum{name="prune",outcome="failure"} 2.5
'

@test "metrics: the standard exposition passes with every required name and the version" {
  metrics_body "$GOOD_METRICS"
  BOOT_EXPECT_VERSION=abc1234 probe --metrics /metrics --require-metric app_info \
    --require-metric http_request_duration_seconds --require-metric http_request_db_statements
  [ "$status" -eq 0 ]
  [[ "$output" == *"probe metrics PASS /metrics 200, proxied 404, required: app_info http_request_duration_seconds http_request_db_statements"* ]]
}

@test "metrics: an outcome outside the vocabulary fails and is named" {
  metrics_body "${GOOD_METRICS}job_duration_seconds_count{name=\"sync\",outcome=\"error\"} 1
job_duration_seconds_count{name=\"sync\",outcome=\"timeout\"} 1
"
  probe --metrics /metrics
  [ "$status" -eq 1 ]
  [[ "$output" == *"outcome outside {success,failure,interrupted,discarded}: error timeout"* ]]
}

@test "metrics: a proxied request that is served fails" {
  metrics_body "$GOOD_METRICS" 200
  probe --metrics /metrics
  [ "$status" -eq 1 ]
  [[ "$output" == *"with X-Forwarded-For it answered 200, expected 404"* ]]
}

@test "metrics: a missing name or an app_info with another version fails" {
  metrics_body "$GOOD_METRICS"
  probe --metrics /metrics --require-metric job_last_success_timestamp_seconds
  [ "$status" -eq 1 ]
  [[ "$output" == *"not exported: job_last_success_timestamp_seconds"* ]]
  BOOT_EXPECT_VERSION=fff0000 probe --metrics /metrics --require-metric app_info
  [ "$status" -eq 1 ]
  [[ "$output" == *"not exported: app_info{version=\"fff0000\"}"* ]]
}

@test "metrics: disabled metrics (404) fail with the METRICS_ENABLED hint" {
  probe --metrics /metrics
  [ "$status" -eq 1 ]
  [[ "$output" == *"answered 404, expected 200 (is METRICS_ENABLED set"* ]]
}

# ---- proxy 404 -------------------------------------------------------------------------------

@test "proxy-404: a 404 passes, a served URL fails" {
  probe --proxy-404 "$BASE/metrics"
  [ "$status" -eq 0 ]
  [[ "$output" == *"probe proxy-404 PASS"* ]]
  metrics_body "$GOOD_METRICS"
  probe --proxy-404 "$BASE/metrics"
  [ "$status" -eq 1 ]
  [[ "$output" == *"answered 200, expected 404"* ]]
}

# ---- all together ----------------------------------------------------------------------------

@test "every assertion runs after a failure and the summary counts them" {
  python3 -c 'import json,sys; print(json.dumps({"/health/live": {"status": 200}, "/health/ready": {"status": 200, "body": sys.argv[1]}}))' \
    '{"status":"ok","version":"abc1234","checks":{}}' >"$TMP/routes.json"
  probe --live /health/live --health /health/ready --request-id /health/live --json-log "$TMP/app.log"
  [ "$status" -eq 1 ]
  [[ "$output" == *"probe live PASS"* ]]
  [[ "$output" == *"probe health FAIL"* ]]
  [[ "$output" == *"probe request-id PASS"* ]]
  [[ "$output" == *"probe json-log PASS"* ]]
  [[ "$output" == *"probe summary pass=3 fail=1"* ]]
}
