# shellcheck shell=bash
# The fleet's commit trailer: the line devkit writes on its own commits, the lines an agent's
# commit may carry, and whether this commit is an agent's. Sourced; defines functions and runs
# nothing. Used by: devkit-sync.sh (its own commits end with devkit_commit_trailer),
# devkit-new.sh (the scaffold's first commit) and hook_steps.sh (the commit-msg `trailer` step
# accepts any devkit_trailer_ok line).
#
# Two rules, kept apart on purpose (lead ruling 2026-10-19): the trailer names the model that
# actually ran the agent, as the harness attribution instructs. So the hook accepts every Claude
# trailer and never compares against the configured one: an agent can set DEVKIT_COMMIT_TRAILER
# or devkit.trailer to anything, so a configured value cannot be the check. A shell script cannot
# know the model, so the written default is the model-agnostic form.

DEVKIT_DEFAULT_TRAILER="Co-Authored-By: Claude <noreply@anthropic.com>"
# Optional model words (Fable 5.1, Opus 5.5, Sonnet 5.5) between "Claude" and the address.
DEVKIT_TRAILER_RE='^Co-Authored-By: Claude( [A-Za-z0-9.-]+)* <noreply@anthropic\.com>$'

# devkit_commit_trailer: the line devkit's own commits end with. DEVKIT_COMMIT_TRAILER when set
# (set and empty wins: no trailer), else `git config devkit.trailer` (empty likewise), else the
# model-agnostic default. Prints it, or nothing.
devkit_commit_trailer() {
  if [ -n "${DEVKIT_COMMIT_TRAILER+x}" ]; then
    printf '%s\n' "$DEVKIT_COMMIT_TRAILER"
    return
  fi
  git config --get devkit.trailer || printf '%s\n' "$DEVKIT_DEFAULT_TRAILER"
}

# devkit_trailer_ok <message file>: true when a line of its own is a Claude co-author trailer.
# CR and trailing blanks are dropped first: an editor's line ending is not a different trailer.
devkit_trailer_ok() {
  tr -d '\r' <"$1" | sed 's/[[:space:]]*$//' | grep -qE -- "$DEVKIT_TRAILER_RE"
}

# devkit_is_agent: true when an agent is committing: Claude Code's environment (CLAUDECODE or any
# CLAUDE_CODE_* variable) or `git config devkit.agent true` (another agent harness opts in).
devkit_is_agent() {
  env | grep -qE '^(CLAUDECODE|CLAUDE_CODE_[A-Za-z0-9_]*)=' && return 0
  [ "$(git config --bool --get devkit.agent 2>/dev/null)" = true ]
}
