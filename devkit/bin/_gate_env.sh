# shellcheck shell=bash
# Gate settings shared by gate.sh and remote_gate.sh. Sourced; defines functions and runs nothing.
#
#   gate_env_load <who> <apply-keys> <ignore-keys>
#       Parse ${XDG_CONFIG_HOME:-$HOME/.config}/devkit/gate.env, the per-machine gate config.
#       It is parsed, never sourced: `KEY=value` lines, blank lines and full-line `#` comments.
#       Keys are `|`-separated names. An apply-key sets the variable unless the environment
#       already has a non-empty value (env wins, so `GATE_REMOTE=0 make gate …` still works).
#       An ignore-key belongs to another reader of the same file and is left alone here (that
#       reader validates it). Any other line, or a value with quotes, `$`, `;`, `#` or other
#       shell syntax, is exit 2 naming the line.
#       Used by: gate.sh and remote_gate.sh (GATE_REMOTE*, ignoring local_gate.sh's keys in
#       GATE_LOCAL_KEYS). local_gate.sh parses the same file for its own keys and must ignore
#       the GATE_REMOTE* lines, or one file cannot configure both.
#   gate_remote_settings_check
#       Validate GATE_REMOTE / GATE_REMOTE_HOST / GATE_REMOTE_ROOT / GATE_REMOTE_SSH_OPTS from
#       whichever source set them; exit 2 on junk.
#   gate_plan_literal <plan> <NAME>
#       Print the value of a literal `NAME=value` line in a gate plan without sourcing it (the
#       dispatcher must not run plan code just to learn the slug). Empty when absent.

# shellcheck disable=SC2034  # read by gate.sh and remote_gate.sh, which source this file
GATE_REMOTE_KEYS='GATE_REMOTE|GATE_REMOTE_HOST|GATE_REMOTE_ROOT|GATE_REMOTE_SSH_OPTS'
# shellcheck disable=SC2034  # same
GATE_LOCAL_KEYS='GATE_SLOTS|GATE_SILENT_MINUTES|GATE_CLEANUP_SECONDS|GATE_JOB_BUDGET_MINUTES|GATE_BUDGET_MINUTES|GATE_BUDGET_ENFORCE|GATE_LOAD_MAX|GATE_LOAD_WAIT_MINUTES'

gate_env_load() { # <who> <apply-keys> <ignore-keys>
  local who=$1 apply=$2 ignore=$3 file line key value n=0
  local value_re='^[[:space:]]*([A-Z_]+)=([A-Za-z0-9@%+=:,./~ _-]*)$'
  file="${XDG_CONFIG_HOME:-$HOME/.config}/devkit/gate.env"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%$'\r'}
    if [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]]; then continue; fi
    if [[ "$line" =~ $value_re ]]; then
      key=${BASH_REMATCH[1]}
      value=${BASH_REMATCH[2]}   # captured now: the key matches below overwrite BASH_REMATCH
      value=${value%"${value##*[![:space:]]}"}   # trailing blanks are not part of a value
      if [[ "$key" =~ ^($apply)$ ]]; then
        [ -n "${!key:-}" ] || printf -v "$key" '%s' "$value"
        continue
      fi
      if [[ "$key" =~ ^($ignore)$ ]]; then continue; fi
    fi
    echo "$who: $file:$n: expected one of ${apply//|/, }, ${ignore//|/, } as KEY=value (got '$line')" >&2
    exit 2
  done <"$file"
}

gate_remote_settings_check() {
  case "${GATE_REMOTE:-}" in
    ''|0|1) ;;
    *) echo "gate: GATE_REMOTE must be 0 or 1 (got '$GATE_REMOTE')" >&2; exit 2 ;;
  esac
  [[ "${GATE_REMOTE_HOST:-}" =~ ^[A-Za-z0-9@._-]*$ ]] \
    || { echo "gate: GATE_REMOTE_HOST must be [user@]host (got '$GATE_REMOTE_HOST')" >&2; exit 2; }
  # The root travels inside a single-quoted remote command: no quotes, no spaces.
  [[ "${GATE_REMOTE_ROOT:-}" =~ ^[A-Za-z0-9@%+=:,./~_-]*$ ]] \
    || { echo "gate: GATE_REMOTE_ROOT must be a plain path (got '$GATE_REMOTE_ROOT')" >&2; exit 2; }
  [[ "${GATE_REMOTE_SSH_OPTS:-}" =~ ^[A-Za-z0-9@%+=:,./~\ _-]*$ ]] \
    || { echo "gate: GATE_REMOTE_SSH_OPTS must be plain ssh options (got '$GATE_REMOTE_SSH_OPTS')" >&2; exit 2; }
}

gate_plan_literal() { # <plan> <NAME>
  sed -n "s/^$2=\\([A-Za-z0-9._\\/-]*\\)[[:space:]]*\\(#.*\\)\\{0,1\\}\$/\\1/p" "$1" | head -1
}
