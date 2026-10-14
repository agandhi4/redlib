# shellcheck shell=bash
# Sourced from the repo root, never run. Dockerfile readers shared by the guards.
# Used by: release_check.sh (APP_VERSION lines, privileged ports) and toolchain_check.sh (FROM tags).
#
#   dockerfiles            Dockerfile and Dockerfile.* at the root and one level down
#                          (orbit/frontend/Dockerfile, redlib's Dockerfile.alpine), one per line
#   final_stage <file>     the logical lines (`\` continuations joined) after the last FROM:
#                          only the final stage's instructions reach the image

dockerfiles() {
  local f
  for f in Dockerfile Dockerfile.* */Dockerfile */Dockerfile.*; do [ -f "$f" ] && echo "$f"; done
}

final_stage() {
  awk '
    { line = (cont ? cont " " : "") $0; cont = "" }
    line ~ /\\[[:space:]]*$/ { sub(/\\[[:space:]]*$/, "", line); cont = line; next }
    line ~ /^[[:space:]]*FROM[[:space:]]/ { n = 0; next }
    { stage[++n] = line }
    END { for (i = 1; i <= n; i++) print stage[i] }
  ' "$1"
}
