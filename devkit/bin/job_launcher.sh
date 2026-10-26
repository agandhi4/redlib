#!/usr/bin/env bash
# The launchd entry of devkit's scheduled jobs: runs devkit main's copy of a job script, never a
# developer checkout's (the 2026-10-23 make merge rule, applied to the jobs themselves). Until
# 2026-10-24 each plist named the main checkout's bin/, so every devkit merge needed a hand
# fast-forward there or the night ran stale code (#225 nearly did), and a checkout on a branch
# or with an edit ran that instead.
#
# Usage: job_launcher.sh <devkit-url> <job-dir> <script> [<arg>...]
#   <script>  a path in devkit, as bin/dependency_merge.sh; run with <arg>s, from the clone.
# Installed by bin/_launchd_job_lib.sh as <job-dir>/launcher.sh beside main's _gate_env.sh
# (fetch_main), copies of main's files, so the entry itself never runs from a checkout either.
# Each job owns <job-dir>/devkit, a clone moved to <devkit-url>'s main at every start: git
# checkout -f and clean -ffd, since nothing else writes there. One clone per job, never shared: launchd starts no second instance of a label
# while one runs, so no run's tree changes under it, but two jobs could overlap.
# A failed fetch (or checkout) runs the last copy it checked out, with one line naming it; with
# none yet, exit 1. stdout carries the commit run, beside the job's own lines.
set -uo pipefail

# shellcheck source=bin/_gate_env.sh  # fetch_main
. "$(dirname "${BASH_SOURCE[0]}")/_gate_env.sh" || exit 1

[ $# -ge 3 ] || { echo "usage: job_launcher.sh <devkit-url> <job-dir> <script> [<arg>...]" >&2; exit 2; }
url=$1 clone=$2/devkit script=$3
shift 3
case "$script" in
  /*|*..*) echo "job_launcher: $script must be a path inside devkit" >&2; exit 2 ;;
esac

if [ ! -d "$clone/.git" ]; then
  rm -rf "$clone.new"
  git init -q "$clone.new" && git -C "$clone.new" remote add origin "$url" && mv "$clone.new" "$clone" || exit 1
fi
# A reinstall may name another URL.
git -C "$clone" remote set-url origin "$url" || exit 1
if fetch_main "$clone" && git -C "$clone" checkout -q -f --detach refs/remotes/origin/main; then
  git -C "$clone" clean -q -ffd
  echo "job_launcher: running $script from devkit main $(git -C "$clone" rev-parse --short HEAD)"
else
  # A checkout that failed part way leaves files of both commits: back to the one HEAD names.
  git -C "$clone" reset -q --hard 2>/dev/null
  last=$(git -C "$clone" rev-parse -q --verify --short HEAD) \
    || { echo "job_launcher: cannot fetch devkit main from $url (git above) and no earlier copy; $script not run" >&2; exit 1; }
  echo "job_launcher: cannot fetch devkit main from $url (git above); running $script from the last good copy, $last" >&2
fi
cd "$clone" || exit 1
exec /bin/bash "$clone/$script" "$@"
