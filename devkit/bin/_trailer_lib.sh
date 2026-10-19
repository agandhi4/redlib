# shellcheck shell=bash
# The fleet's commit trailer: the line an agent's commit must carry, and whether this commit is an
# agent's. Sourced; defines functions and runs nothing. Used by: devkit-sync.sh (its own commits
# end with it), devkit-new.sh (the scaffold's first commit) and hook_steps.sh (the commit-msg
# `trailer` step requires it), so all three read one chain and a sync's commit passes its hook.

DEVKIT_DEFAULT_TRAILER="Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"

# devkit_commit_trailer: DEVKIT_COMMIT_TRAILER when set (set and empty wins: no trailer), else
# `git config devkit.trailer` (empty likewise), else the fleet default. Prints it, or nothing.
devkit_commit_trailer() {
  if [ -n "${DEVKIT_COMMIT_TRAILER+x}" ]; then
    printf '%s\n' "$DEVKIT_COMMIT_TRAILER"
    return
  fi
  git config --get devkit.trailer || printf '%s\n' "$DEVKIT_DEFAULT_TRAILER"
}

# devkit_is_agent: true when an agent is committing: Claude Code's environment (CLAUDECODE or any
# CLAUDE_CODE_* variable) or `git config devkit.agent true` (another agent harness opts in).
devkit_is_agent() {
  env | grep -qE '^(CLAUDECODE|CLAUDE_CODE_[A-Za-z0-9_]*)=' && return 0
  [ "$(git config --bool --get devkit.agent 2>/dev/null)" = true ]
}
