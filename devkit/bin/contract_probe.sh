#!/usr/bin/env bash
# Runtime assertions for the observability contract (~/.claude/conventions/observability.md),
# run against a booted app. A repo's smoke calls it after `boot_image.sh up` prints BASE:
#
#   devkit/bin/contract_probe.sh "$BASE" --health /health/ready --request-id /health/live \
#     --json-log "$NAME-app" --metrics /metrics --require-metric app_info
#
# Every assertion is opt-in by flag, so a repo turns one on in the PR that makes it comply and
# the probe ratchets with the fleet (phase3-plan.md D2). The same checks hold for Python, TS and
# Rust images: they read only HTTP and log lines.
#
# Usage: devkit/bin/contract_probe.sh <base-url> [assertion flags...]
#   --live <path>           answers 200 (checks nothing else: live must never flap)
#   --health <path>         the /health/ready contract: 200 with status "up" or 503 with "down"
#                           (owner decision D: nothing else, no "degraded"); `version` a
#                           non-empty string, equal to $BOOT_EXPECT_VERSION when set (decision
#                           E: bare <sha7>); `checks` an object of {status: up|down, required?:
#                           bool, fix?: string}; top-level is down exactly when a check that is
#                           not `required: false` is down; no "Traceback" or "Error:" in the body
#   --request-id <path>     X-Request-ID on the response is 12 lowercase hex and minted here:
#                           a 12-hex inbound id must NOT come back ("never trust an inbound id"),
#                           and two requests get two ids. The id seen is what --json-log looks for
#   --json-log <src>        <src> is a file, else a container name read with `docker logs`.
#                           At least one line parses as a JSON object carrying ts, level, logger,
#                           msg, version, request_id (with version = $BOOT_EXPECT_VERSION when
#                           set); with --request-id, some line carries the id that request got
#   --metrics <path>        200 Prometheus text; every job_duration_seconds `outcome` is one of
#                           success|failure|interrupted|discarded (decision C); the same path
#                           with X-Forwarded-For answers 404 (proxied scrapes are refused)
#   --require-metric <name> repeatable, needs --metrics: <name> is exported (a TYPE line or a
#                           sample, histogram suffixes included). For app_info with
#                           $BOOT_EXPECT_VERSION set: a sample app_info{...version="<v>"...} 1
#   --proxy-404 <url>       an absolute URL (the public /metrics, after a deploy) answers 404
#
# Output: one `probe <assertion> PASS|FAIL <detail>` line per assertion on stdout, in a fixed
# order (logs last, so they hold every probe request), then `probe summary pass=<n> fail=<n>`.
# Every assertion runs even after a failure, so one smoke run shows every gap.
# Exit 0 all pass, 1 any FAIL, 2 usage or a missing tool (curl, python3; docker for a container
# log source).
#
# Why python3 for JSON: the health body and log lines need a real parser (sed cannot tell
# "status" in a check from the top-level one); jq is not on every gate box, python3 is.
set -uo pipefail

usage() {
  echo "usage: contract_probe.sh <base-url> [--live P] [--health P] [--request-id P] [--json-log FILE|CONTAINER] [--metrics P [--require-metric NAME]...] [--proxy-404 URL]" >&2
  exit 2
}
need() { command -v "$1" >/dev/null || { echo "contract_probe: $1 not found on PATH" >&2; exit 2; }; }

[ $# -ge 1 ] || usage
case "$1" in -h|--help) usage ;; http://*|https://*) BASE=${1%/} ;; *) echo "contract_probe: base must be an http(s) URL (got '$1')" >&2; usage ;; esac
shift

LIVE="" HEALTH="" REQID_PATH="" LOG_SRC="" METRICS="" PROXY_URL=""
REQUIRED_METRICS=()
path_arg() { # <flag> <value>: a path on BASE
  case "$2" in /*) ;; *) echo "contract_probe: $1 takes a path starting with / (got '$2')" >&2; usage ;; esac
}
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || { echo "contract_probe: $1 needs a value" >&2; usage; }
  case "$1" in
    --live) path_arg "$1" "$2"; LIVE=$2 ;;
    --health) path_arg "$1" "$2"; HEALTH=$2 ;;
    --request-id) path_arg "$1" "$2"; REQID_PATH=$2 ;;
    --json-log) LOG_SRC=$2 ;;
    --metrics) path_arg "$1" "$2"; METRICS=$2 ;;
    --require-metric)
      [[ "$2" =~ ^[a-zA-Z_:][a-zA-Z0-9_:]*$ ]] || { echo "contract_probe: '$2' is not a metric name" >&2; usage; }
      REQUIRED_METRICS+=("$2") ;;
    --proxy-404)
      case "$2" in http://*|https://*) PROXY_URL=$2 ;; *) echo "contract_probe: --proxy-404 takes an absolute URL (got '$2')" >&2; usage ;; esac ;;
    *) echo "contract_probe: unknown flag '$1'" >&2; usage ;;
  esac
  shift 2
done
[ ${#REQUIRED_METRICS[@]} -eq 0 ] || [ -n "$METRICS" ] || { echo "contract_probe: --require-metric needs --metrics" >&2; usage; }
[ -n "$LIVE$HEALTH$REQID_PATH$LOG_SRC$METRICS$PROXY_URL" ] || { echo "contract_probe: no assertion flags given" >&2; usage; }

need curl
[ -z "$HEALTH$LOG_SRC" ] || need python3
if [ -n "$LOG_SRC" ] && [ ! -f "$LOG_SRC" ]; then need docker; fi

EXPECT_VERSION=${BOOT_EXPECT_VERSION:-}
readonly OUTCOMES="success failure interrupted discarded"
readonly FOREIGN_ID=0123456789ab  # a well-formed id the app must replace, never echo
PASSED=0
FAILED=0
SEEN_ID=""

pass() { echo "probe $1 PASS $2"; PASSED=$((PASSED + 1)); }
fail() { echo "probe $1 FAIL $2"; FAILED=$((FAILED + 1)); }

# http_code <url> [curl args...]: the status code only ("000" when nothing answered).
http_code() {
  local url=$1; shift
  curl -s -o /dev/null --max-time 10 -w '%{http_code}' "$@" "$url" 2>/dev/null
}

# response_id <headers-file>: the X-Request-ID value, CR stripped, or nothing.
response_id() {
  awk 'tolower($1) == "x-request-id:" { sub(/\r$/, "", $2); print $2; exit }' "$1"
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/contract_probe.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

probe_live() {
  local code
  code=$(http_code "$BASE$LIVE")
  if [ "$code" = 200 ]; then pass live "$LIVE 200"; else fail live "$LIVE answered $code, expected 200"; fi
}

# The validator prints one problem per line and nothing when the body meets the contract.
# Quoted heredocs read with `read -d ''` (which returns 1 at EOF, hence `|| true`): the Python
# is taken verbatim, and bash 3.2 misparses heredocs and `case` inside $(...).
HEALTH_PY=""
read -r -d '' HEALTH_PY <<'PY' || true
import json, os, sys
code, expect = sys.argv[1], os.environ.get("EXPECT_VERSION", "")
raw = sys.stdin.read()
problems = []
for leak in ("Traceback", "Error:"):
    if leak in raw:
        problems.append(f"body contains {leak!r}: no exception text in an unauthenticated body")
try:
    doc = json.loads(raw)
except ValueError:
    doc = None
if not isinstance(doc, dict):
    print("body is not a JSON object: " + raw[:120].replace("\n", " "))
    sys.exit(0)
status = doc.get("status")
if status not in ("up", "down"):
    problems.append(f"status {status!r} is not up|down")
elif (code == "200") != (status == "up"):
    problems.append(f"HTTP {code} with status {status!r}: 200 means up, 503 means down")
version = doc.get("version")
if not isinstance(version, str) or not version:
    problems.append(f"version {version!r} is not a non-empty string")
elif expect and version != expect:
    problems.append(f"version {version!r}, expected {expect!r}")
checks = doc.get("checks")
if not isinstance(checks, dict):
    problems.append("checks is not an object")
    checks = {}
required_down = []
for name, check in sorted(checks.items()):
    if not isinstance(check, dict):
        problems.append(f"check {name} is not an object")
        continue
    if check.get("status") not in ("up", "down"):
        problems.append(f"check {name} status {check.get('status')!r} is not up|down")
    if "required" in check and not isinstance(check["required"], bool):
        problems.append(f"check {name} required {check['required']!r} is not a boolean")
    if "fix" in check and not isinstance(check["fix"], str):
        problems.append(f"check {name} fix is not a string")
    if check.get("status") == "down" and check.get("required", True) is not False:
        required_down.append(name)
if status in ("up", "down") and (status == "down") != bool(required_down):
    problems.append(
        f"status {status!r} but required checks down: {required_down or 'none'}"
        " (top-level is down exactly when a required check is down)"
    )
print("\n".join(problems))
PY

probe_health() {
  local code problems
  code=$(curl -s -o "$TMP/health.body" --max-time 10 -w '%{http_code}' "$BASE$HEALTH" 2>/dev/null)
  case "$code" in
    200|503) ;;
    *) fail health "$HEALTH answered $code, expected 200 or 503"; return ;;
  esac
  problems=$(EXPECT_VERSION="$EXPECT_VERSION" python3 -I -c "$HEALTH_PY" "$code" <"$TMP/health.body") \
    || { fail health "$HEALTH validator crashed"; return; }
  if [ -z "$problems" ]; then
    pass health "$HEALTH $code${EXPECT_VERSION:+ version=$EXPECT_VERSION}"
  else
    fail health "$HEALTH: $(printf '%s' "$problems" | paste -sd ';' -)"
  fi
}

probe_request_id() {
  local first second
  curl -s -o /dev/null --max-time 10 -D "$TMP/reqid1.h" -H "X-Request-ID: $FOREIGN_ID" "$BASE$REQID_PATH" 2>/dev/null
  curl -s -o /dev/null --max-time 10 -D "$TMP/reqid2.h" "$BASE$REQID_PATH" 2>/dev/null
  first=$(response_id "$TMP/reqid1.h")
  second=$(response_id "$TMP/reqid2.h")
  if [ -z "$first" ] || [ -z "$second" ]; then
    fail request-id "$REQID_PATH: no X-Request-ID response header"
  elif ! [[ "$first" =~ ^[0-9a-f]{12}$ && "$second" =~ ^[0-9a-f]{12}$ ]]; then
    fail request-id "$REQID_PATH: X-Request-ID '$first' / '$second' is not 12 lowercase hex"
  elif [ "$first" = "$FOREIGN_ID" ]; then
    fail request-id "$REQID_PATH: the inbound X-Request-ID came back; mint a fresh id at the outermost middleware"
  elif [ "$first" = "$second" ]; then
    fail request-id "$REQID_PATH: two requests got the same id '$first'"
  else
    SEEN_ID=$second
    pass request-id "$REQID_PATH $first $second"
  fi
}

LOG_PY=""
read -r -d '' LOG_PY <<'PY' || true
import json, os, sys
expect, want_id = os.environ.get("EXPECT_VERSION", ""), os.environ.get("SEEN_ID", "")
required = ("ts", "level", "logger", "msg", "version", "request_id")
lines = parsed = complete = 0
id_found = False
missing_union = set()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    lines += 1
    try:
        doc = json.loads(line)
    except ValueError:
        continue
    if not isinstance(doc, dict):
        continue
    parsed += 1
    missing = [k for k in required if k not in doc]
    if expect and doc.get("version") != expect:
        missing.append(f"version={expect}")
    if missing:
        missing_union.update(missing)
        continue
    complete += 1
    if want_id and doc.get("request_id") == want_id:
        id_found = True
summary = f"{complete} complete of {parsed} JSON of {lines} lines"
if complete == 0:
    gaps = ", ".join(sorted(missing_union)) or "every field"
    print(f"FAIL no line carries every required field ({summary}; missing {gaps})")
elif want_id and not id_found:
    print(f"FAIL no line carries request_id {want_id} ({summary})")
else:
    print(f"PASS {summary}")
PY

probe_json_log() {
  local verdict
  if [ -f "$LOG_SRC" ]; then
    cp "$LOG_SRC" "$TMP/app.log"
  elif ! docker logs "$LOG_SRC" >"$TMP/app.log" 2>&1; then
    fail json-log "$LOG_SRC is neither a file nor a container docker can read logs from"
    return
  fi
  verdict=$(EXPECT_VERSION="$EXPECT_VERSION" SEEN_ID="$SEEN_ID" python3 -I -c "$LOG_PY" <"$TMP/app.log") \
    || { fail json-log "$LOG_SRC: validator crashed"; return; }
  case "$verdict" in
    PASS*) pass json-log "$LOG_SRC: ${verdict#PASS }" ;;
    *) fail json-log "$LOG_SRC: ${verdict#FAIL }" ;;
  esac
}

# stdin: one outcome per line; prints those outside $OUTCOMES, space-separated.
foreign_outcomes() {
  local outcome
  while IFS= read -r outcome; do
    case " $OUTCOMES " in
      *" $outcome "*) ;;
      *) printf '%s ' "$outcome" ;;
    esac
  done
}

probe_metrics() {
  local code bad name proxied missing=""
  code=$(curl -s -o "$TMP/metrics.txt" --max-time 10 -w '%{http_code}' "$BASE$METRICS" 2>/dev/null)
  if [ "$code" != 200 ]; then
    fail metrics "$METRICS answered $code, expected 200 (is METRICS_ENABLED set in the boot env?)"
    return
  fi
  bad=$(grep -E '^job_duration_seconds(_bucket|_sum|_count)?\{' "$TMP/metrics.txt" \
    | grep -oE 'outcome="[^"]*"' | sed 's/^outcome="//; s/"$//' | sort -u | foreign_outcomes)
  proxied=$(http_code "$BASE$METRICS" -H "X-Forwarded-For: 203.0.113.7")
  for name in ${REQUIRED_METRICS[@]+"${REQUIRED_METRICS[@]}"}; do
    if [ "$name" = app_info ] && [ -n "$EXPECT_VERSION" ]; then
      awk -v v="version=\"$EXPECT_VERSION\"" '
        index($0, "app_info{") == 1 && index($0, v) && ($NF == "1" || $NF == "1.0") { found = 1 }
        END { exit !found }' "$TMP/metrics.txt" || missing="$missing app_info{version=\"$EXPECT_VERSION\"}"
    else
      grep -qE "^(# TYPE $name |$name(_bucket|_sum|_count|_total)?[{ ])" "$TMP/metrics.txt" \
        || missing="$missing $name"
    fi
  done
  local problems=""
  [ -z "$bad" ] || problems="$problems; job_duration_seconds outcome outside {${OUTCOMES// /,}}: ${bad% }"
  [ "$proxied" = 404 ] || problems="$problems; with X-Forwarded-For it answered $proxied, expected 404"
  [ -z "$missing" ] || problems="$problems; not exported:$missing"
  if [ -z "$problems" ]; then
    pass metrics "$METRICS 200, proxied 404${REQUIRED_METRICS[0]+, required: ${REQUIRED_METRICS[*]}}"
  else
    fail metrics "$METRICS: ${problems#; }"
  fi
}

probe_proxy_404() {
  local code
  code=$(http_code "$PROXY_URL")
  if [ "$code" = 404 ]; then pass proxy-404 "$PROXY_URL 404"; else fail proxy-404 "$PROXY_URL answered $code, expected 404"; fi
}

[ -z "$LIVE" ] || probe_live
[ -z "$HEALTH" ] || probe_health
[ -z "$REQID_PATH" ] || probe_request_id
[ -z "$METRICS" ] || probe_metrics
[ -z "$PROXY_URL" ] || probe_proxy_404
[ -z "$LOG_SRC" ] || probe_json_log

echo "probe summary pass=$PASSED fail=$FAILED"
[ "$FAILED" -eq 0 ]
