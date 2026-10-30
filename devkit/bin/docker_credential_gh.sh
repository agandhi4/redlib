#!/usr/bin/env bash
# A docker credential helper that answers with gh's current token, so a docker registry call
# authenticates as gh does and no token is ever written to disk. publish.sh links it into a
# per-run PATH dir as `docker-credential-devkit-gh` and names it in its per-run docker config
# (`{"credHelpers":{"ghcr.io":"devkit-gh"}}`); docker then runs it for each ghcr.io request.
# Protocol (docker-credential-helpers): `get` reads the server URL on stdin and prints
# {"ServerURL","Username","Secret"}; `store` and `erase` are no-ops (nothing is stored, and
# publish.sh never runs docker login); `list` prints {}.
# Env: DEVKIT_GHCR_USER, the Username it answers (publish.sh sets the image owner).
# Exit 0, 1 when gh has no usable token (the reason on stdout, which docker reports), 2 usage.
set -uo pipefail
case "${1:-}" in
  get)
    # docker writes the server with no newline, so read's status is not the test.
    IFS= read -r server || [ -n "$server" ] || server=
    # On failure the reason goes to stdout too: docker reports only the helper's stdout (`out:`).
    token=$(gh auth token 2>/dev/null) || { echo "docker_credential_gh: gh has no token (gh auth login)" | tee /dev/stderr; exit 1; }
    # gh tokens are [A-Za-z0-9_]; anything else would need JSON escaping and is refused instead.
    [[ "$token" =~ ^[A-Za-z0-9_]+$ ]] || { echo "docker_credential_gh: gh's token has an unexpected form" | tee /dev/stderr; exit 1; }
    # The account gh's token belongs to (publish.sh exports it: the image's owner); ghcr checks the
    # token, but the user it is issued to is the one name that is never wrong.
    user=${DEVKIT_GHCR_USER:-devkit}
    printf '{"ServerURL":"%s","Username":"%s","Secret":"%s"}\n' "${server//\"/}" "${user//\"/}" "$token" ;;
  store|erase) cat >/dev/null ;;
  list) echo '{}' ;;
  *) echo "usage: docker-credential-devkit-gh get|store|erase|list" >&2; exit 2 ;;
esac
