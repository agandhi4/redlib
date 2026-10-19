# shellcheck shell=bash
# Keep the machine awake while a timed run is alive. Sourced; defines devkit_stay_awake and runs
# nothing. Used by local_gate.sh (the whole gate) and tier_guard.sh (a tier run by hand).
#
#   devkit_stay_awake
#
# Why (2026-10-19): budgets and the silence watchdog read wall time, and a Mac that idle-sleeps
# mid-run counts the nap as test time. lane-ai's quick job read 1083 s across a deep-idle wake,
# and the fleet sat dark 04:30-12:50 while gates waited on a sleeping box.
# macOS: `caffeinate -i -s -w $$` in the background holds the idle-sleep and (on AC power)
# system-sleep assertions until this process exits, then exits by itself. It waits on the pid
# rather than re-exec'ing the caller under caffeinate, so the caller keeps its pid, its signals
# (remote_gate.sh TERMs the gate's pid) and its exit code. Its fds are /dev/null, so it never
# holds a pipe open (remote_gate.sh reads the gate's output to EOF). A closed lid on battery
# still sleeps: no assertion can stop that.
# Linux: nothing is done. The equivalent is to run the gate under
# `systemd-inhibit --what=idle:sleep --who=devkit --why=gate make gate PR=<n>`, which needs a
# logind session and polkit's consent; the fleet's Linux gate host is a server that never sleeps.
# One holder per process tree: DEVKIT_AWAKE names the pid being held for, and a nested call (a
# tier inside the gate) under a live holder does nothing. DEVKIT_CAFFEINATE=0 turns it off.
devkit_stay_awake() {
  [ "${DEVKIT_CAFFEINATE:-1}" != 0 ] || return 0
  if [ -n "${DEVKIT_AWAKE:-}" ] && kill -0 "$DEVKIT_AWAKE" 2>/dev/null; then
    return 0
  fi
  command -v caffeinate >/dev/null 2>&1 || return 0
  caffeinate -i -s -w "$$" </dev/null >/dev/null 2>&1 &
  export DEVKIT_AWAKE=$$
}
