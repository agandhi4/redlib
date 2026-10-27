# shellcheck shell=bash
# Keep the machine awake while a timed run or Docker work is alive. Sourced; defines
# devkit_stay_awake, devkit_wake_user, devkit_sleep_forced and devkit_on_battery and runs nothing.
# Used by local_gate.sh (the whole gate), tier_guard.sh (a tier run by hand), _timeout_lib.sh's
# devkit_docker_guard (every devkit entry point that talks to Docker: throwaway_pg.sh,
# boot_image.sh, docker_bounded.sh), dependency_merge.sh (devkit_sleep_forced) and
# tests/shards.sh --measure (devkit_on_battery).
#
#   devkit_stay_awake    macOS: hold the machine awake until this process exits
#   devkit_wake_user     macOS: declare user activity for 2 s (blocks 2 s); 1 elsewhere or when off
#   devkit_sleep_forced  macOS: true, setting DEVKIT_SLEEP_REASON, when macOS will sleep the
#                        machine whatever any assertion says; false elsewhere or with
#                        DEVKIT_ALLOW_BATTERY=1
#   devkit_on_battery    macOS: true when the Mac draws from its battery; false elsewhere
#
# Every macOS test is uname, not `command -v caffeinate`: Linux's caffeine package ships a
# `caffeinate` with other flags.
#
# Why (2026-10-19): budgets and the silence watchdog read wall time, and a Mac that idle-sleeps
# mid-run counts the nap as test time. lane-ai's quick job read 1083 s across a deep-idle wake,
# and the fleet sat dark 04:30-12:50 while gates waited on a sleeping box.
# macOS: `caffeinate -i -s -w $$` in the background holds the idle-sleep and (on AC power)
# system-sleep assertions until this process exits, then exits by itself. It waits on the pid
# rather than re-exec'ing the caller under caffeinate, so the caller keeps its pid, its signals
# (remote_gate.sh TERMs the gate's pid) and its exit code. Its fds are /dev/null, so it never
# holds a pipe open (remote_gate.sh reads the gate's output to EOF). A closed lid on battery
# still sleeps: no assertion can stop that (devkit_sleep_forced).
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
  _devkit_on_macos || return 0
  command -v caffeinate >/dev/null 2>&1 || return 0
  caffeinate -i -s -w "$$" </dev/null >/dev/null 2>&1 &
  export DEVKIT_AWAKE=$$
}

_devkit_on_macos() { [ "$(uname -s)" = Darwin ]; }

# Why (2026-10-22): after a Maintenance Sleep the Mac runs DarkWake cycles in which our processes
# run but OrbStack's VM stays asleep (vmgr.log: `msg=sleep`, no `wake`), so `docker version`
# hangs indefinitely. Declaring user activity (-u) is a full wake: Docker answered within
# seconds and 7-hour-old containers survived, where `orbctl stop/start` had killed every one.
devkit_wake_user() {
  [ "${DEVKIT_CAFFEINATE:-1}" != 0 ] || return 1
  _devkit_on_macos || return 1
  command -v caffeinate >/dev/null 2>&1 || return 1
  caffeinate -u -t 2 </dev/null >/dev/null 2>&1 || :
}

# Why (2026-10-24, lead decision): a closed lid on battery sleeps the Mac whatever caffeinate
# holds, and launchd still starts jobs in its DarkWake slivers. A gate begun there reads the nap as
# test time and fails or stalls every queued one; the nightly job logged an error per PR. So the
# gate refuses and the job skips its run, up front. The power log of 2026-10-23..24 shows no idle
# sleep at all with the lid open, on battery included (caffeinate -i held): every sleep from a full
# wake was Clamshell Sleep (3, all on battery), a Thermal Emergency Sleep with the lid closed, or
# Low Power Sleep at 3% charge. A lid open on battery is therefore not refused.
# shellcheck disable=SC2034  # DEVKIT_SLEEP_REASON is this function's output, read by its callers
devkit_sleep_forced() {
  DEVKIT_SLEEP_REASON=""
  [ "${DEVKIT_ALLOW_BATTERY:-0}" != 1 ] || return 1
  _devkit_on_macos || return 1
  ioreg -r -k AppleClamshellState -d 1 2>/dev/null | grep -q '"AppleClamshellState" = Yes' || return 1
  devkit_on_battery || return 1
  DEVKIT_SLEEP_REASON="lid closed on battery: macOS forces sleep; plug in or open the lid"
}

# devkit_on_battery: macOS: true when pmset says the Mac draws from its battery; false elsewhere
# (the fleet's Linux gate host is a server). Also tests/shards.sh --measure: a Mac on battery
# runs slower, so costs measured there are skewed.
devkit_on_battery() {
  _devkit_on_macos && pmset -g batt 2>/dev/null | grep -qF "'Battery Power'"
}
