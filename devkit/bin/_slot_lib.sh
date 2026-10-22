# shellcheck shell=bash
# The machine-wide slot pool: how many full test runs this box carries at once, across every
# repo. Sourced; defines functions and runs nothing. Callers source _load_lib.sh first
# (devkit_ncpu) and load gate.env's GATE_SLOTS before slot_pool_init (_gate_env.sh).
# Used by: local_gate.sh (one slot per gate, and its PR's run lock) and tier_guard.sh (one slot
# per tier run outside a gate).
#
# Why tiers too (2026-10-21): #175 found loads of 169 and 42 on 10 cores while at most 2 gates
# held slots; the rest was lanes' hand-run `make ci-unit`/`ci-db` in their worktrees, which no
# pool bounded. A tier run by hand now queues for the same slots a gate does.
#
#   slot_pool_init <who>       sets SLOT_LOCK (GATE_LOCK, default /tmp/linux-box-local-gate.lock,
#                              the file the merge queues and linux-box share) and SLOTS
#                              (GATE_SLOTS, default ceil(cores / 4), at least 1); exit 2 naming
#                              <who> on a bad GATE_SLOTS or no flock(1)
#   slot_acquire <prefix> <label>
#                              blocks until fd 9 holds a free slot, printing
#                              `<prefix> waiting for a gate slot (<n> running: <label>, ...)` at
#                              once and every 30 s, polling each second; then sets SLOT, writes
#                              `<label> pid <pid> since <utc>` into the slot file and exports
#                              DEVKIT_SLOT_HOLDER=$$. The lock lives until this process exits
#                              (flock is released by the kernel, so a crash leaves no stale slot).
#   run_lock_acquire <prefix> <file> <what>
#                              blocks until fd 7 holds <file>, an exclusive lock on one thing
#                              (local_gate: one PR of one repo), printing `<prefix> waiting for
#                              <what> (<holder line>)` at once and every 30 s; then writes
#                              `pid <pid> since <utc>` into it. Take it BEFORE slot_acquire, so
#                              a waiter holds no pool slot. Released when this process exits;
#                              like fd 9, close fd 7 (`7>&-`) for any child that may outlive it.
#   slot_held_above            true when DEVKIT_SLOT_HOLDER names a live process: this run is
#                              inside one that already holds a slot (a tier inside the gate, or
#                              a tier inside a tier) and must not take a second, which with one
#                              slot would wait on itself forever
#
# Pool shape: with SLOTS=1 the lock is exactly $SLOT_LOCK; with N > 1 the slots are
# $SLOT_LOCK.1 .. $SLOT_LOCK.N. The holder count reads every held $SLOT_LOCK* file whatever its
# owner's GATE_SLOTS, so a caller with another setting is still named; runs with different
# GATE_SLOTS lock different files and do not bound each other (set it once per machine, gate.env).
# Gotcha: the slot fd (9) is inherited by children. A child left running after its parent exits
# (a stray dev server) keeps the slot held; callers run their command with `9>&-`.

slot_pool_init() { # <who>
  local n
  SLOT_LOCK=${GATE_LOCK:-/tmp/linux-box-local-gate.lock}
  n=$(devkit_ncpu)
  SLOTS=${GATE_SLOTS:-$(( (${n:-1} + 3) / 4 ))}
  [[ "$SLOTS" =~ ^[1-9][0-9]*$ ]] \
    || { echo "$1: GATE_SLOTS must be an integer >= 1 (got '$SLOTS')" >&2; exit 2; }
  command -v flock >/dev/null || { echo "$1: flock not found (macOS: brew install flock)" >&2; exit 2; }
}

# _slot_file <n>: one slot keeps the plain $SLOT_LOCK path, so the queues and linux-box share it.
_slot_file() { if [ "$SLOTS" = 1 ]; then echo "$SLOT_LOCK"; else echo "$SLOT_LOCK.$1"; fi; }

# _slot_try <label>: fd 9 on the first free slot, without waiting. Reopening fd 9 on a miss drops
# nothing held. `>>`, never `>`: a waiter must not truncate a holder's line.
_slot_try() {
  local n=1
  while [ "$n" -le "$SLOTS" ]; do
    exec 9>>"$(_slot_file "$n")"
    if flock -n 9; then
      # shellcheck disable=SC2034  # read by the callers (their `slot <n>/<slots>` line)
      SLOT=$n
      printf '%s pid %s since %s\n' "$1" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        | tee "$(_slot_file "$n").holder" >"$(_slot_file "$n")"
      return 0
    fi
    n=$((n + 1))
  done
  return 1
}

# _slot_holders: "<n> running[: <label>, ...]"; a holder that wrote no line (an older devkit,
# a bare flock) is `?`. The probe takes a free slot's lock for an instant; a caller racing it
# for that slot retries next second.
# The holder's line is also in <slot file>.holder, read when the slot file is empty and its pid
# still lives (a slot is held until its holder exits, so a live pid there is the holder). Why: a
# waiter vendored before #175 opens slot files with `>` as it polls, emptying every
# holder's line, so a mixed fleet printed `2 running: ?, ?` (locus, redlib's waiter).
_slot_holders() {
  local f n=0 who="" label
  for f in "$SLOT_LOCK" "$SLOT_LOCK".[0-9]*; do
    case $f in *.holder) continue ;; esac
    [ -f "$f" ] || continue
    flock -n "$f" true 2>/dev/null && continue
    n=$((n + 1))
    label=$(awk 'NR == 1 { print $1 }' "$f" 2>/dev/null)
    [ -n "$label" ] || label=$(awk 'NR == 1 && $2 == "pid" { print $1, $3 }' "$f.holder" 2>/dev/null \
      | { read -r l p && kill -0 "$p" 2>/dev/null && echo "$l"; })
    who="$who${who:+, }${label:-?}"
  done
  echo "$n running${who:+: $who}"
}

slot_acquire() { # <prefix> <label>
  local said=""
  until _slot_try "$2"; do
    if [ -z "$said" ] || [ $((SECONDS - said)) -ge 30 ]; then
      echo "$1 waiting for a gate slot ($(_slot_holders))"
      said=$SECONDS
    fi
    sleep 1
  done
  export DEVKIT_SLOT_HOLDER=$$
}

run_lock_acquire() { # <prefix> <file> <what>
  local said=""
  exec 7>>"$2"
  until flock -n 7; do
    if [ -z "$said" ] || [ $((SECONDS - said)) -ge 30 ]; then
      echo "$1 waiting for $3 ($(head -n 1 "$2" 2>/dev/null || true))"
      said=$SECONDS
    fi
    sleep 1
  done
  printf 'pid %s since %s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$2"
}

slot_held_above() {
  [ -n "${DEVKIT_SLOT_HOLDER:-}" ] && kill -0 "$DEVKIT_SLOT_HOLDER" 2>/dev/null
}
