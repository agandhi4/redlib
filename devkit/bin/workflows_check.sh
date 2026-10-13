#!/usr/bin/env bash
# Guard: GitHub Actions workflows follow the delivery rules (standardization drafts/delivery.md,
# "GitHub Actions"). Minutes are a shared budget billed per job rounded up to a minute, and a
# moved action tag is an unreviewed supply-chain change. Over .github/workflows/*.yml|yaml:
#   1. Every `uses: owner/repo@ref` is a 40-hex commit SHA with a `# vX.Y.Z` comment. Exempt:
#      local `./…` actions; devkit's reusable workflows (`agandhi4/devkit/.github/workflows/…`),
#      which must be `@main` or a SHA. `docker://` images must be pinned by `@sha256:` digest.
#   2. A workflow triggered on pull_request (or pull_request_target) has, for every job that can
#      run on it: a draft skip in the job or a step (`github.event.pull_request.draft == false`,
#      `!github.event.pull_request.draft`, or `pull_request.merged == true`, which no draft is),
#      unless `types:` is only ready_for_review; a `concurrency:` (job or workflow level) with
#      `cancel-in-progress: true`; and `paths-ignore` covering `**.md` (or `**/*.md`).
#      A workflow_call-only workflow gets a warning: its caller owns all three.
#   3. At most one job can run on pull_request (the one quick-check), unless a top-level comment
#      says `# workflows-check: multi-job ok: <reason>`.
#   4. A job that pushes an image on a push to main runs under `cancel-in-progress: false`: a run
#      cancelled mid-push leaves a half-tagged image. Push steps come from _workflows_lib.sh,
#      shared with release_check.sh.
# Which jobs "can run" on an event is read from the job-level `if:`: no `github.event_name` in it
# means every event; otherwise the event must be named (and not as `!= '<event>'`). A
# cancel-in-progress expression is understood only as `${{ github.event_name == 'pull_request' }}`
# (true on PRs, false on pushes); any other expression fails as unevaluable.
# Usage: devkit/bin/workflows_check.sh [repo-root]      (part of ci-quick)
set -uo pipefail
# Before the cd: the script's own path may be relative.
# shellcheck source=/dev/null  # bin/_workflows_lib.sh: workflow_files, image_push_steps
. "$(dirname "${BASH_SOURCE[0]}")/_workflows_lib.sh"
ROOT=${1:-$(git rev-parse --show-toplevel)}
cd "$ROOT" || exit 2
rc=0
fail() { echo "workflows-check: $*" >&2; rc=1; }
warn() { echo "workflows-check: warning: $*" >&2; }

# Rule 1, line by line. Bash regex, not awk: BSD awk's interval support ({40}) is unreliable.
USES_RE='^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*["'"'"']?([^"'"'"'[:space:]]+)["'"'"']?[[:space:]]*(#[[:space:]]*(.*))?$'
SHA_RE='^[0-9a-f]{40}$'
check_pins() { # <workflow>
  local wf=$1 hit n line target ref comment
  while IFS= read -r hit; do
    n=${hit%%:*}; line=${hit#*:}
    [[ "$line" =~ $USES_RE ]] || { fail "$wf:$n: cannot parse this uses: line"; continue; }
    target=${BASH_REMATCH[2]}; comment=${BASH_REMATCH[4]}
    case "$target" in
      ./*) continue ;;
      docker://*)
        [[ "$target" =~ @sha256:[0-9a-f]{64}$ ]] || fail "$wf:$n: $target is not pinned by @sha256: digest"
        continue ;;
      *@*) ref=${target##*@} ;;
      *) fail "$wf:$n: $target has no @ref; pin it to a commit SHA"; continue ;;
    esac
    case "$target" in
      agandhi4/devkit/.github/workflows/*)
        [ "$ref" = main ] || [[ "$ref" =~ $SHA_RE ]] \
          || fail "$wf:$n: devkit reusable workflow must be @main or a commit SHA (got @$ref)"
        continue ;;
    esac
    if ! [[ "$ref" =~ $SHA_RE ]]; then
      fail "$wf:$n: ${target%@*}@$ref is not pinned to a 40-hex commit SHA"
    elif ! [[ "$comment" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
      fail "$wf:$n: ${target%@*} SHA pin needs a '# vX.Y.Z' comment (got '${comment:-none}')"
    fi
  done < <(grep -nE '^[[:space:]]*(-[[:space:]]+)?uses:' "$wf" || true)
}

# Rules 2-4. Reads the workflow's shape (triggers and their filters, workflow and job concurrency,
# job-level `if:`, draft skips anywhere in a job) by indentation, then judges it at END.
# Prints "F|W<TAB><line><TAB><reason>". `pushes` holds the line numbers of image-push steps.
judge_workflow() { # <workflow> <push step lines>
  awk -v pushes="$2" -v Q="'" '
    function indent(s) { match(s, /^[[:space:]]*/); return RLENGTH }
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function unq(s) { s = trim(s); gsub("^[\"" Q "]|[\"" Q "]$", "", s); return s }
    # Sets KEY and VAL for a "key: value" line (not a list item).
    function keyval(s,   t) {
      if (s !~ ("^[[:space:]]*[\"" Q "]?[A-Za-z0-9_.-]+[\"" Q "]?[[:space:]]*:([[:space:]]|$)")) return 0
      t = s; sub(/^[[:space:]]*/, "", t)
      KEY = t; sub(/[[:space:]]*:.*$/, "", KEY); gsub("[\"" Q "]", "", KEY)
      VAL = t; sub(/^[^:]*:[[:space:]]*/, "", VAL); VAL = trim(VAL)
      return 1
    }
    function add_item(ev, k, v) { v = unq(v); subp[ev, k] = 1; if (v != "") subv[ev, k] = subv[ev, k] " " v " " }
    function add_items(ev, k, v,   n, a, i) {
      subp[ev, k] = 1; gsub(/^\[|\]$/, "", v)
      n = split(v, a, ","); for (i = 1; i <= n; i++) add_item(ev, k, a[i])
    }
    function has(ev, k, x) { return index(subv[ev, k], " " x " ") > 0 }
    function add_event(e) { e = unq(e); if (e == "") return; evl[e] = NR; ev_order[++ne] = e }
    # true | false | pr (true only on pull_request) | expr (unevaluable) | "" (unset)
    function classify(v) {
      v = unq(v)
      if (v == "true" || v == "false") return v
      if (v ~ ("^\\$\\{\\{[[:space:]]*github\\.event_name[[:space:]]*==[[:space:]]*" Q "pull_request" Q "[[:space:]]*\\}\\}$")) return "pr"
      return "expr"
    }
    function flow_cancel(v) {
      if (v !~ /^\{/ || !match(v, /cancel-in-progress:[[:space:]]*[^,}]+/)) return ""
      v = substr(v, RSTART, RLENGTH); sub(/^cancel-in-progress:/, "", v); return classify(v)
    }
    function eligible(x, ev,   q) {
      if (x !~ /github\.event_name/) return 1
      q = "[\"" Q "]" ev "[\"" Q "]"
      if (x ~ q) return x !~ ("!=[[:space:]]*" q)
      return x ~ /event_name[[:space:]]*!=/
    }
    function pr_eligible(x,   i) {
      for (i = 1; i <= npr; i++) if (eligible(x, pr_events[i])) return 1
      return 0
    }
    function out(kind, line, msg) { printf "%s\t%d\t%s\n", kind, line, msg }

    BEGIN { draft_re = "pull_request\\.draft[[:space:]]*(==[[:space:]]*false|!=[[:space:]]*true)|![[:space:]]*github\\.event\\.pull_request\\.draft|pull_request\\.merged[[:space:]]*==[[:space:]]*true" }

    /^#[[:space:]]*workflows-check:[[:space:]]*multi-job ok:[[:space:]]*[^[:space:]]/ { exempt = 1 }
    /^[[:space:]]*(#|$)/ { next }
    { line = $0; sub(/[[:space:]]+#.*$/, "", line); ind = indent(line) }

    ind == 0 {
      section = ""
      if (!keyval(line)) next
      if (KEY == "on") {
        section = "on"; on_line = NR; ev_ind = -1
        if (VAL != "") { v = VAL; gsub(/^\[|\]$/, "", v); n = split(v, a, ","); for (i = 1; i <= n; i++) add_event(a[i]) }
      } else if (KEY == "concurrency") {
        section = "concurrency"; wf_cancel = flow_cancel(VAL)
      } else if (KEY == "jobs") {
        section = "jobs"; jobs_ind = -1
      }
      next
    }

    section == "on" {
      if (ev_ind < 0) ev_ind = ind
      if (ind == ev_ind) { if (keyval(line)) { add_event(KEY); ev = KEY; sub_ind = -1; subkey = "" }; next }
      if (sub_ind < 0) sub_ind = ind
      if (ind == sub_ind && keyval(line)) { subkey = KEY; if (VAL != "") add_items(ev, subkey, VAL); else subp[ev, subkey] = 1; next }
      if (ind > sub_ind && line ~ /^[[:space:]]*-/ && subkey != "") { v = line; sub(/^[[:space:]]*-[[:space:]]*/, "", v); add_item(ev, subkey, v) }
      next
    }

    section == "concurrency" { if (keyval(line) && KEY == "cancel-in-progress") wf_cancel = classify(VAL); next }

    section == "jobs" {
      if (jobs_ind < 0) jobs_ind = ind
      if (ind == jobs_ind) {
        if (keyval(line)) { nj++; jname[nj] = KEY; jline[nj] = NR; jchild = -1; in_if = in_conc = 0 }
        next
      }
      if (!nj) next
      if (line ~ draft_re) jdraft[nj] = 1
      if (jchild < 0) jchild = ind
      if (in_if && ind > if_ind) { jif[nj] = jif[nj] " " trim(line); next }
      in_if = 0
      if (in_conc && ind > conc_ind) { if (keyval(line) && KEY == "cancel-in-progress") jcancel[nj] = classify(VAL); next }
      in_conc = 0
      if (ind == jchild && keyval(line)) {
        if (KEY == "if") {
          if (VAL ~ /^[>|]/) { in_if = 1; if_ind = ind } else jif[nj] = VAL
        } else if (KEY == "concurrency") {
          if (VAL == "") { in_conc = 1; conc_ind = ind } else jcancel[nj] = flow_cancel(VAL)
        }
      }
      next
    }

    END {
      if (ne == 1 && ev_order[1] == "workflow_call")
        out("W", on_line, "workflow_call-only: its callers must carry the draft skip, concurrency cancel-in-progress and paths-ignore")
      if ("pull_request" in evl) pr_events[++npr] = "pull_request"
      if ("pull_request_target" in evl) pr_events[++npr] = "pull_request_target"

      if (npr) {
        draft_exempt = 1
        for (i = 1; i <= npr; i++) {
          e = pr_events[i]
          if (!(has(e, "paths-ignore", "**.md") || has(e, "paths-ignore", "**/*.md") || has(e, "paths", "!**.md") || has(e, "paths", "!**/*.md")))
            out("F", evl[e], e " has no paths-ignore for '"'"'**.md'"'"'; docs-only PRs must not bill a run")
          t = subv[e, "types"]; gsub(/ ready_for_review /, "", t)
          if (!subp[e, "types"] || subv[e, "types"] == "" || trim(t) != "") draft_exempt = 0
        }
        names = ""; count = 0; second = 0
        for (j = 1; j <= nj; j++) {
          if (!pr_eligible(jif[j])) continue
          count++; names = names (names == "" ? "" : ", ") jname[j]; if (count == 2) second = jline[j]
          if (!draft_exempt && !jdraft[j])
            out("F", jline[j], "job " jname[j] " runs on pull_request without a draft skip (if: github.event.pull_request.draft == false)")
          if (wf_cancel == "true" || wf_cancel == "pr" || jcancel[j] == "true" || jcancel[j] == "pr") continue
          if (wf_cancel == "expr" || jcancel[j] == "expr")
            out("F", jline[j], "job " jname[j] ": cancel-in-progress is an expression this check cannot evaluate; use true or ${{ github.event_name == " Q "pull_request" Q " }}")
          else
            out("F", jline[j], "job " jname[j] " runs on pull_request without concurrency cancel-in-progress: true (job or workflow level)")
        }
        if (count > 1 && !exempt)
          out("F", second, "pull_request runs " count " jobs (" names "); one quick-check job per PR, or a top-level comment '"'"'# workflows-check: multi-job ok: <reason>'"'"'")
      }

      # A push to main: a push trigger whose branches name main (or match everything), or that
      # filters no branches and is not tags-only.
      push_main = 0
      if ("push" in evl) {
        if (subp["push", "branches"]) push_main = has("push", "branches", "main") || has("push", "branches", "*") || has("push", "branches", "**")
        else if (subp["push", "branches-ignore"]) push_main = !has("push", "branches-ignore", "main")
        else push_main = !subp["push", "tags"]
      }
      if (push_main && pushes != "") {
        n = split(pushes, p, " ")
        for (i = 1; i <= n; i++) {
          j = 0; for (k = 1; k <= nj; k++) if (jline[k] < p[i]) j = k
          if (!j || judged[j]++ || !eligible(jif[j], "push")) continue
          if (wf_cancel == "true" || jcancel[j] == "true")
            out("F", jline[j], "job " jname[j] " pushes an image on push to main under cancel-in-progress: true; a run cancelled mid-push leaves a half-tagged image (use false)")
          else if (wf_cancel == "expr" || jcancel[j] == "expr")
            out("F", jline[j], "job " jname[j] ": cancel-in-progress is an expression this check cannot evaluate; use false")
          else if (!(wf_cancel == "false" || wf_cancel == "pr" || jcancel[j] == "false" || jcancel[j] == "pr"))
            out("F", jline[j], "job " jname[j] " pushes an image on push to main without concurrency cancel-in-progress: false")
        }
      }
    }
  ' "$1"
}

files=()
while IFS= read -r wf; do files+=("$wf"); done < <(workflow_files)
if [ ${#files[@]} = 0 ]; then
  echo "workflows-check: no .github/workflows; nothing to check"; exit 0
fi

for wf in "${files[@]}"; do
  check_pins "$wf"
  push_lines=$(image_push_steps "$wf" | awk '{ printf "%s%s", sep, $1; sep = " " }')
  while IFS=$'\t' read -r kind n reason; do
    case "$kind" in
      F) fail "$wf:$n: $reason" ;;
      W) warn "$wf:$n: $reason" ;;
    esac
  done < <(judge_workflow "$wf" "$push_lines")
done

if [ $rc = 0 ]; then
  echo "workflows-check: ok (${#files[@]} workflows)"
else
  echo "workflows-check: FAIL" >&2
fi
exit $rc
