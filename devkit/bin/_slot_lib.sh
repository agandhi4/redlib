# shellcheck shell=bash
# The machine-wide admission pool: how much test work this box runs at once, across every repo,
# every vendored devkit copy and the nightly job. Sourced; defines functions and runs nothing.
# Callers source _load_lib.sh first (devkit_ncpu) and load gate.env's GATE_CAPACITY before
# slot_pool_init (_gate_env.sh).
# Used by: local_gate.sh (one admission per job, for that job's cost) and tier_guard.sh (one per
# tier run outside a gate).
#
# Why weighted and per job (devkit decisions 2026-10-26): the pool used to be GATE_SLOTS equal
# slots, one per whole gate. It did cap the holders (2026-10-25/26 ledgers: never more than the
# two slots held at once; the third and fourth gates a lead saw were waiting), but one slot was
# no unit of load: locus #155's xcodebuild beside closet's Docker db tier ran the box at 36-53 on
# 10 cores with every gate failing its budgets, while two lint jobs left it idle. A job now asks
# for its cost; a gate holds nothing between jobs, so a lint job slips in beside an iOS build and
# two iOS builds never overlap.
#
#   slot_pool_init <who>       sets SLOT_DIR (the pool, below) and SLOT_CAPACITY (GATE_CAPACITY,
#                              default max(4, ceil(cores / 2))); exit 2 naming <who> on a bad
#                              GATE_CAPACITY or no flock(1)
#   slot_costs_check <who>     exit 2 on a GATE_JOB_COSTS entry that is not <job>=<units>
#   slot_cost <name> [<make target>]
#                              prints the units a job asks for: its GATE_JOB_COSTS entry (the
#                              plan's `name=units ...`), else the heaviest word of the target (or
#                              the name) in the table at _slot_word_cost; never above the capacity
#   slot_acquire <prefix> <label> <cost> [<order>]
#                              blocks until <cost> units are free and this waiter is first in
#                              line (lowest <order>, default now in epoch seconds; the gate passes
#                              its own start, so its later jobs queue ahead of a newer gate's),
#                              printing `<prefix> waiting for capacity: <label> needs <c> of <cap>,
#                              <u> in use (<holder> <c>, ...)[; queued behind <label>, ...]` at
#                              once and, as a heartbeat ending ` (waited <n>s)`, every 30 s,
#                              polling each second (Notices, below). Then sets SLOT_QUEUED
#                              (whole seconds waited) and SLOT_USED (units in use once admitted)
#   slot_release               gives back this process's units (and its place in line); callers
#                              also run it from their EXIT trap
#   slot_held_count            how many runs hold units now, the caller's own included: the
#                              budgets' stretch (bin/_load_lib.sh, Slots)
#   slot_notice <line>         prints a waiting line (Notices, below)
#   slot_others_units          the units held now by runs other than DEVKIT_SLOT_HOLDER's (every
#                              holder's, outside one): tests/shards.sh's contention sample
#   slot_held_above            true when DEVKIT_SLOT_HOLDER names a live process: this run is
#                              inside one that already holds units (a tier inside a gate job, or
#                              a tier inside a tier) and must not ask again, which would count its
#                              cost twice and, at full capacity, wait on itself forever
#   run_lock_acquire <prefix> <file> <what>
#                              blocks until fd 7 holds <file>, an exclusive lock on one thing
#                              (local_gate: one PR of one repo), printing `<prefix> waiting for
#                              <what> (<holder line>)` at once and, ending ` (waited <n>s)`, every
#                              30 s (Notices); then writes
#                              `pid <pid> since <utc>` into it. Released when this process exits;
#                              close fd 7 (`7>&-`) for any child that may outlive it.
#
# Notices: the waiting lines (both acquires') go to fd 6 when DEVKIT_NOTICE_FD=6, else stdout.
# bin/quiet_run.sh opens it on its caller's stdout for a step whose output it captures, so a
# pre-push tier queued for admission says so instead of sitting silent (rollcall #96: ~7 min, and
# `make pr` looked hung). 6 is the one fd devkit uses for it; tier_guard.sh closes it for its
# command, so a server or daemon the tier leaves running cannot hold the hook's output open.
#
# The pool is a FIXED path, ${XDG_STATE_HOME:-~/.local/state}/devkit/gate-slots/, so every vendored
# copy of any rev shares it (DEVKIT_SLOT_DIR, environment only, is the test hook):
#   lock         flock(1) mutex around every look at held/ and queue/; held for milliseconds
#   held/<pid>   one admitted run, line 1 `<cost> <pid> <order> <utc since> <label>`, line 2 the
#                pid's start time (ps lstart)
#   queue/<order>.<pid>   one waiter, the same two lines
# Stale entries are reclaimed: whoever takes the mutex next deletes an entry whose pid is gone, or
# now names another process (its start time differs), so a gate killed with -9 frees its units
# within a second. No fd is held while a job runs, so a job's stray child (a dev server) holds
# nothing either.
#
# Compat, until 2026-11-09 (two weeks of nightly devkit syncs; then delete _slot_legacy): a gate or
# tier vendored before this file holds a flock on $GATE_LOCK or $GATE_LOCK.<n> (default
# /tmp/linux-box-local-gate.lock, also the merge queues' and linux-box's) for its whole run. Each
# held one counts SLOT_LEGACY_COST units here, labelled `<its holder line's first word> (older
# devkit)`. The older copy does not see this pool, so until its repo syncs it can still start
# beside a full one.

readonly SLOT_LEGACY_COST=2

slot_pool_init() { # <who>
  local n
  SLOT_DIR=${DEVKIT_SLOT_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/devkit/gate-slots}
  SLOT_LEGACY_LOCK=${GATE_LOCK:-/tmp/linux-box-local-gate.lock}
  n=$(devkit_ncpu)
  SLOT_CAPACITY=${GATE_CAPACITY:-$(( (${n:-1} + 1) / 2 ))}
  [[ "$SLOT_CAPACITY" =~ ^[1-9][0-9]*$ ]] \
    || { echo "$1: GATE_CAPACITY must be an integer >= 1 (got '$SLOT_CAPACITY')" >&2; exit 2; }
  # The default is never below the heaviest class (a native build, 4): one must fit alone.
  [ -n "${GATE_CAPACITY:-}" ] || [ "$SLOT_CAPACITY" -ge 4 ] || SLOT_CAPACITY=4
  command -v flock >/dev/null || { echo "$1: flock not found (macOS: brew install flock)" >&2; exit 2; }
  mkdir -p "$SLOT_DIR/held" "$SLOT_DIR/queue" || { echo "$1: cannot create $SLOT_DIR" >&2; exit 2; }
}

# slot_costs_check <who>: exit 2 naming <who> on a GATE_JOB_COSTS entry that is not <job>=<units>.
slot_costs_check() {
  local entry
  for entry in ${GATE_JOB_COSTS:-}; do
    [[ "$entry" =~ ^[A-Za-z0-9_-]+=[1-9][0-9]*$ ]] \
      || { echo "$1: GATE_JOB_COSTS entries are <job>=<units >= 1> (got '$entry')" >&2; exit 2; }
  done
}

# _slot_word_cost <word>: the units one word of a job's target or name asks for, or nothing for a
# word that says nothing. Words are split on `-` and `_` (ci-unit-ios: ci, unit, ios), never
# substrings: `feedback` holds no db. A word no row names leaves the job at 2, a test tier.
#   1  lint, type checks, docs, dependency installs, the metrics ratchet: a core or two, briefly
#   3  Docker: a throwaway Postgres, an image build, a smoke boot, a browser suite
#   4  native: xcodebuild and swift compile on every core
_slot_word_cost() {
  case $1 in
    lint | quick | docs | check | deps | metrics | drift) echo 1 ;;
    db | pg | image | smoke | e2e | docker) echo 3 ;;
    ios | swift | xcode | macos) echo 4 ;;
  esac
}

slot_cost() { # <name> [<make target>]
  local entry word c cost=0
  for entry in ${GATE_JOB_COSTS:-}; do
    [ "${entry%%=*}" != "$1" ] || { _slot_clamp "${entry#*=}"; return; }
  done
  for word in $(tr '_-' '  ' <<<"${2:-$1}"); do
    c=$(_slot_word_cost "$word")
    [ -z "$c" ] || [ "$c" -le "$cost" ] || cost=$c
  done
  [ "$cost" -gt 0 ] || cost=2
  _slot_clamp "$cost"
}

# _slot_clamp <units>: a job costlier than the whole pool asks for all of it, so it runs alone.
_slot_clamp() { if [ "$1" -gt "$SLOT_CAPACITY" ]; then echo "$SLOT_CAPACITY"; else echo "$1"; fi; }

# _slot_start <pid>: the process's start time, which a reused pid does not share. In UTC and the
# C locale: ps renders lstart in the caller's TZ, so a holder recorded by a gate under one TZ read
# as reused to a caller under another, which reaped it live and over-admitted (Codex, devkit #240).
# tests/slot_helpers.bash proc_start renders it the same way.
_slot_start() { TZ=UTC LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'; }

# _slot_live <entry file>: true while the entry's pid is the process that wrote it; sets
# SLOT_ENTRY_COST, SLOT_ENTRY_PID and SLOT_ENTRY_LABEL from the same read. One read only: slot_release removes
# its entries without the mutex (it runs from EXIT traps), so a second read of a file seen live
# can find it gone (devkit #240's gate: `cost: unbound variable` under set -u).
_slot_live() {
  local start
  SLOT_ENTRY_COST="" SLOT_ENTRY_PID="" SLOT_ENTRY_LABEL=""
  { read -r SLOT_ENTRY_COST SLOT_ENTRY_PID _ _ SLOT_ENTRY_LABEL && read -r start; } <"$1" 2>/dev/null || return 1
  [[ "$SLOT_ENTRY_COST" =~ ^[0-9]+$ ]] && [[ "$SLOT_ENTRY_PID" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$SLOT_ENTRY_PID" 2>/dev/null && [ "$(_slot_start "$SLOT_ENTRY_PID")" = "$start" ]
}

# _slot_locked <command...>: the command with the pool's mutex held; 1 when it cannot be had in 30 s.
_slot_locked() { { flock -w 30 9 && "$@"; } 9>>"$SLOT_DIR/lock"; }

# _slot_legacy: one `<label> (older devkit)` line per legacy slot lock held now (header, Compat).
# The probe takes a free file's lock for an instant; an older gate racing it retries next second.
_slot_legacy() {
  local f label
  for f in "$SLOT_LEGACY_LOCK" "$SLOT_LEGACY_LOCK".[0-9]*; do
    case $f in *.holder) continue ;; esac
    [ -f "$f" ] || continue
    flock -n "$f" true 2>/dev/null && continue
    label=$(awk 'NR == 1 { print $1 }' "$f" "$f.holder" 2>/dev/null | head -n 1)
    echo "${label:-?} (older devkit)"
  done
}

# _slot_scan: under the mutex. Deletes stale entries, then sets SLOT_USED (units held),
# SLOT_OTHERS (those not held by DEVKIT_SLOT_HOLDER), SLOT_HOLDERS (`<label> <cost>, ...`),
# SLOT_HOLDER_COUNT, SLOT_HEAD (the first live waiter's file name) and SLOT_AHEAD (`<label>, ...`
# of the waiters before $SLOT_TICKET, if any).
_slot_scan() {
  local f line
  SLOT_USED=0 SLOT_OTHERS=0 SLOT_HOLDERS="" SLOT_HOLDER_COUNT=0 SLOT_HEAD="" SLOT_AHEAD=""
  for f in "$SLOT_DIR"/held/*; do
    [ -f "$f" ] || continue
    _slot_live "$f" || { rm -f "$f"; continue; }
    SLOT_USED=$((SLOT_USED + SLOT_ENTRY_COST))
    [ "$SLOT_ENTRY_PID" = "${DEVKIT_SLOT_HOLDER:-}" ] || SLOT_OTHERS=$((SLOT_OTHERS + SLOT_ENTRY_COST))
    SLOT_HOLDER_COUNT=$((SLOT_HOLDER_COUNT + 1))
    SLOT_HOLDERS="$SLOT_HOLDERS${SLOT_HOLDERS:+, }$SLOT_ENTRY_LABEL $SLOT_ENTRY_COST"
  done
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    SLOT_USED=$((SLOT_USED + SLOT_LEGACY_COST)) SLOT_OTHERS=$((SLOT_OTHERS + SLOT_LEGACY_COST))
    SLOT_HOLDER_COUNT=$((SLOT_HOLDER_COUNT + 1))
    SLOT_HOLDERS="$SLOT_HOLDERS${SLOT_HOLDERS:+, }${line% (older devkit)} $SLOT_LEGACY_COST (older devkit)"
  done <<<"$(_slot_legacy)"
  # Waiters in line order: <order>.<pid>, numeric on both parts.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _slot_live "$SLOT_DIR/queue/$f" || { rm -f "$SLOT_DIR/queue/$f"; continue; }
    [ -n "$SLOT_HEAD" ] || SLOT_HEAD=$f
    [ "$f" != "${SLOT_TICKET:-}" ] || break
    SLOT_AHEAD="$SLOT_AHEAD${SLOT_AHEAD:+, }$SLOT_ENTRY_LABEL"
  done <<<"$(for f in "$SLOT_DIR"/queue/*; do [ -f "$f" ] && echo "${f##*/}"; done | sort -t. -k1,1n -k2,2n)"
}

# _slot_try <cost>: under the mutex. Admits this waiter when it heads the line and its cost fits.
# A head that does not fit blocks the lighter waiters behind it: strict order, so a native build
# is never starved by a stream of lint jobs.
_slot_try() {
  _slot_scan
  [ "$SLOT_HEAD" = "$SLOT_TICKET" ] && [ $((SLOT_USED + $1)) -le "$SLOT_CAPACITY" ] || return 1
  mv "$SLOT_DIR/queue/$SLOT_TICKET" "$SLOT_DIR/held/$$" || return 1
  SLOT_USED=$((SLOT_USED + $1))
}

slot_acquire() { # <prefix> <label> <cost> [<order>]
  local t0=$SECONDS said="" order=${4:-$(date +%s)}
  SLOT_TICKET=$order.$$
  # Written beside queue/, then renamed in: a scan that saw a half-written ticket would reap it
  # as stale, and this waiter would wait for a ticket that no longer exists (Codex, devkit #240).
  if ! printf '%s %s %s %s %s\n%s\n' "$3" "$$" "$order" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" \
      "$(_slot_start $$)" >"$SLOT_DIR/ticket.$$" || ! mv "$SLOT_DIR/ticket.$$" "$SLOT_DIR/queue/$SLOT_TICKET"; then
    echo "$1: cannot queue in $SLOT_DIR" >&2
    exit 2
  fi
  until _slot_locked _slot_try "$3"; do
    if [ -z "$said" ] || [ $((SECONDS - said)) -ge 30 ]; then
      slot_notice "$1 waiting for capacity: $2 needs $3 of $SLOT_CAPACITY, $SLOT_USED in use${SLOT_HOLDERS:+ ($SLOT_HOLDERS)}${SLOT_AHEAD:+; queued behind $SLOT_AHEAD}$(_slot_waited "$said" "$t0")"
      said=$SECONDS
    fi
    sleep 1
  done
  SLOT_TICKET=""
  # 0 when admitted at the first look: SECONDS ticks on the wall clock, so a lookup that straddled
  # a tick would otherwise read as a second queued.
  # shellcheck disable=SC2034  # read by the callers (the job's queued note, the tier's line)
  if [ -n "$said" ]; then SLOT_QUEUED=$((SECONDS - t0)); else SLOT_QUEUED=0; fi
}

slot_release() {
  [ -z "${SLOT_DIR:-}" ] && return 0
  rm -f "$SLOT_DIR/held/$$" ${SLOT_TICKET:+"$SLOT_DIR/queue/$SLOT_TICKET"}
  SLOT_TICKET=""
}

slot_held_count() { _slot_locked _slot_scan; echo "$SLOT_HOLDER_COUNT"; }

slot_others_units() { _slot_locked _slot_scan || return 1; echo "$SLOT_OTHERS"; }

# slot_notice <line>: one waiting line, to the notice fd when the caller's output is captured
# (header, Notices), else stdout. tier_guard.sh's `admitted` line after a wait goes here too.
slot_notice() {
  if [ "${DEVKIT_NOTICE_FD:-}" = 6 ] && { true >&6; } 2>/dev/null; then echo "$1" >&6; else echo "$1"; fi
}

# _slot_waited <said> <t0>: nothing for a wait's first line, ` (waited <n>s)` for its heartbeats.
_slot_waited() { [ -z "$1" ] || echo " (waited $((SECONDS - $2))s)"; }

run_lock_acquire() { # <prefix> <file> <what>
  local said="" t0=$SECONDS
  exec 7>>"$2"
  until flock -n 7; do
    if [ -z "$said" ] || [ $((SECONDS - said)) -ge 30 ]; then
      slot_notice "$1 waiting for $3 ($(head -n 1 "$2" 2>/dev/null || true))$(_slot_waited "$said" "$t0")"
      said=$SECONDS
    fi
    sleep 1
  done
  printf 'pid %s since %s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$2"
}

slot_held_above() {
  [ -n "${DEVKIT_SLOT_HOLDER:-}" ] && kill -0 "$DEVKIT_SLOT_HOLDER" 2>/dev/null
}
