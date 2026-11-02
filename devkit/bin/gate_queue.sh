#!/usr/bin/env bash
# The machine-wide admission pool, now: who holds units, who waits and in what order, so an agent
# whose gate or tier prints `waiting for capacity` can see what it waits on (owner, 2026-10-28).
# Read-only, apart from reaping entries whose process is gone, which any look at the pool does
# (bin/_slot_lib.sh).
#
# Usage: devkit/bin/gate_queue.sh   (or: make gate-queue in devkit)
#
# Output, one header line and one line per run, holders first, then waiters in admission order:
#   gate queue: <u> of <cap> units in use, <n> waiting; load <1m> on <cpus> cpus
#     held  <units>  <age>  <label>  pid <pid>
#     #<k>  <units>  <age>  <label>  pid <pid>[  needs <c>, <f> free]
# <label> is `<repo>#<pr> <job>` for a gate job and `<repo>:<tier>` for a tier run by hand (a
# pre-push hook's included); a copy vendored before the pool shows `<holder> (older devkit)` with no
# age or pid. A holder's age is since its admission, a waiter's since it joined the line. Only
# the first waiter can be admitted next (strict order, so a heavy job is never starved), and its
# line says how far the free units are from its cost.
#
# Exit: 0, or 2 when the pool cannot be read (no flock, a bad GATE_CAPACITY, the mutex held 30 s).
set -uo pipefail

# shellcheck source=bin/_gate_env.sh
. "$(dirname "${BASH_SOURCE[0]}")/_gate_env.sh"
# shellcheck source=bin/_load_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_load_lib.sh"
# shellcheck source=bin/_slot_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_slot_lib.sh"

case "${1:-}" in
  "") ;;
  -h|--help) echo "usage: $0   (the live admission pool; see the header)"; exit 0 ;;
  *) echo "usage: $0" >&2; exit 2 ;;
esac

# The capacity the gates use: gate.env's GATE_CAPACITY, as tier_guard.sh reads it.
gate_env_load gate_queue GATE_CAPACITY "$GATE_LOCAL_KEYS|$GATE_REMOTE_KEYS"
slot_pool_init gate_queue
_slot_locked _slot_scan || { echo "gate_queue: the pool's mutex ($SLOT_DIR/lock) stayed held for 30 s" >&2; exit 2; }

# GNU stat first: BSD has no -c, while GNU `stat -f` is the file-system form (metrics_collect.sh).
if stat -c %Y / >/dev/null 2>&1; then STAT_TIMES=(stat -c '%Y %Z'); else STAT_TIMES=(stat -f '%m %c'); fi
NOW=$(date +%s)

# age <seconds>: `12m03s`, or `1h05m` past an hour.
age() {
  if [ "$1" -ge 3600 ]; then
    printf '%dh%02dm' $(($1 / 3600)) $(($1 % 3600 / 60))
  else
    printf '%dm%02ds' $(($1 / 60)) $(($1 % 60))
  fi
}

# entry_age held|wait <file>: a holder's file was renamed in at admission, which sets its ctime
# (every copy's, older ones included); a waiter's mtime is when its ticket was written.
entry_age() {
  local mtime ctime
  read -r mtime ctime <<<"$("${STAT_TIMES[@]}" "$2" 2>/dev/null)"
  [ -n "$ctime" ] || { echo -; return; }
  if [ "$1" = held ]; then age $((NOW - ctime)); else age $((NOW - mtime)); fi
}

read -r load _ <<<"$(devkit_loadavg)"
echo "gate queue: $SLOT_USED of $SLOT_CAPACITY units in use, $SLOT_WAITERS waiting; load ${load:-?} on $(devkit_cpu_capacity) cpus"
k=0
while IFS=$'\t' read -r kind cost pid file label; do
  [ -n "$kind" ] || continue
  if [ "$kind" = held ]; then
    tag=held
  else
    k=$((k + 1))
    tag="#$k"
  fi
  when=-
  [ "$file" = - ] || when=$(entry_age "$kind" "$file")
  if [ "$pid" = - ]; then
    line=$(printf '  %-5s %2s  %7s  %s' "$tag" "$cost" "$when" "$label")
  else
    line=$(printf '  %-5s %2s  %7s  %-30s  pid %s' "$tag" "$cost" "$when" "$label" "$pid")
  fi
  if [ "$tag" = "#1" ]; then
    free=$((SLOT_CAPACITY - SLOT_USED))
    [ "$free" -ge 0 ] || free=0
    line="$line  needs $cost, $free free"
  fi
  echo "$line"
done <<<"$SLOT_ROWS"
