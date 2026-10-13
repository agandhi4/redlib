#!/usr/bin/env bash
# Guard: one version string per toolchain per repo. Each toolchain has a single declaration file;
# everything that builds or tests with it must agree, or a dependency bot bumps one copy and the
# image runs an interpreter the tests never saw (finplat's Dockerfile sat on Node 26 while CI
# tested 22, and on python:3.14 while requires-python said 3.13).
# Node (.nvmrc, exact version):
#   - every `FROM node:<tag>` in Dockerfile* has the same major
#   - every setup-node step in .github/workflows uses `node-version-file: .nvmrc`, not `node-version:`
# Python (.python-version, MAJOR.MINOR or MAJOR.MINOR.PATCH; compared on MAJOR.MINOR):
#   - every `FROM python:<tag>` and uv-style `FROM …:python3.13-…` in Dockerfile* has the same MAJOR.MINOR
#   - every `requires-python` in pyproject.toml (root and one level down) has that MAJOR.MINOR as its
#     lower bound; specs outside the simple forms (>=X.Y[,<…], ==X.Y.*, ~=X.Y) warn, not fail
#   - every setup-python step uses `python-version-file: .python-version`, not `python-version:`
# Rust (rust-toolchain.toml or rust-toolchain, exact MAJOR.MINOR.PATCH; parsed by rust_toolchain.sh):
#   - every `FROM rust[:<tag>]` in Dockerfile* has the channel's MAJOR.MINOR (untagged floats: fails)
#   - every `rust-version` (MSRV) in Cargo.toml (root and one level down) is <= the channel
#   - actions-rust-lang/setup-rust-toolchain steps leave `toolchain:` unset (then it reads the file);
#     dtolnay/rust-toolchain cannot read the file at all, so any use of it fails
# A missing declaration file skips that toolchain (Node-only repos have no .python-version).
# Dockerfiles are scanned at the root and one level down (orbit/frontend/Dockerfile).
# Usage: devkit/bin/toolchain_check.sh [repo-root]      (part of ci-quick)
set -uo pipefail
ROOT=${1:-$(git rev-parse --show-toplevel)}
cd "$ROOT" || exit 2
rc=0
checked=()
fail() { echo "toolchain-check: $*" >&2; rc=1; }
warn() { echo "toolchain-check: warning: $*" >&2; }

has_rust() { [ -f rust-toolchain.toml ] || [ -f rust-toolchain ]; }
if [ ! -f .nvmrc ] && [ ! -f .python-version ] && ! has_rust; then
  echo "toolchain-check: no .nvmrc, .python-version or rust-toolchain.toml; nothing to check"; exit 0
fi

dockerfiles() { for f in Dockerfile Dockerfile.* */Dockerfile */Dockerfile.*; do [ -f "$f" ] && echo "$f"; done; }
workflows() { for f in .github/workflows/*.yml .github/workflows/*.yaml; do [ -f "$f" ] && echo "$f"; done; }

# A setup-<lang> step that pins `<key>:` inline inside its `with:` block is a second copy of the
# version; the `<key>-file:` form (or leaving it unset) reads the one declaration. The key is
# matched at the start of a line so `node-version-file:` never counts as `node-version:`.
# Prints offending line numbers.
inline_pins() { # <workflow> <owner/action> <key>
  awk -v action="$2@" -v key="^[[:space:]]*$3:" '
    index($0, "uses:") && index($0, action) { in_step=1; next }
    in_step && /^[[:space:]]*-[[:space:]]/ { in_step=0 }
    in_step && $0 ~ key { print NR }
  ' "$1"
}

FROM_RE='^FROM[[:space:]]+(--platform=[^[:space:]]+[[:space:]]+)?'

check_node() {
  if [ ! -f .nvmrc ]; then echo "toolchain-check: no .nvmrc; node not checked"; return; fi
  local version major df line tag wf lineno
  version=$(tr -d '[:space:]' < .nvmrc); version=${version#v}
  case "$version" in
    [0-9]*.[0-9]*.[0-9]*) major=${version%%.*} ;;
    *) fail ".nvmrc must hold an exact version like 22.23.3 (got '$version')"; return ;;
  esac
  while IFS= read -r df; do
    while IFS= read -r line; do
      tag=$(sed -E "s/${FROM_RE}node:([^[:space:]@]+).*/\\2/" <<< "$line")
      [ "${tag%%[.-]*}" = "$major" ] || fail "$df uses node:$tag; .nvmrc says $version (major $major)"
    done < <(grep -E "${FROM_RE}node:" "$df" || true)
  done < <(dockerfiles)
  while IFS= read -r wf; do
    for lineno in $(inline_pins "$wf" actions/setup-node node-version); do
      fail "$wf:$lineno: setup-node pins node-version inline; use node-version-file: .nvmrc"
    done
  done < <(workflows)
  checked+=("node $version")
}

check_python() {
  if [ ! -f .python-version ]; then echo "toolchain-check: no .python-version; python not checked"; return; fi
  local version mm df line image tag found pp spec raw lower wf lineno
  version=$(tr -d '[:space:]' < .python-version)
  if [[ "$version" =~ ^([0-9]+\.[0-9]+)(\.[0-9]+)?$ ]]; then
    mm=${BASH_REMATCH[1]}
  else
    fail ".python-version must hold MAJOR.MINOR or MAJOR.MINOR.PATCH like 3.13 or 3.13.7 (got '$version')"; return
  fi

  # Official images carry the version as the tag (python:3.13-slim); uv images embed it in the
  # tag of another image (ghcr.io/astral-sh/uv:python3.13-bookworm). Other FROM lines are ignored.
  while IFS= read -r df; do
    while IFS= read -r line; do
      image=$(sed -E "s/${FROM_RE}([^[:space:]]+).*/\\2/" <<< "$line"); image=${image%%@*}
      [[ "$image" == *:* ]] || continue
      tag=${image##*:}; image=${image%:*}
      if [ "${image##*/}" = python ]; then
        [[ "$tag" =~ ^([0-9]+\.[0-9]+) ]] && found=${BASH_REMATCH[1]} || found=
      elif [[ "$tag" =~ (^|[^[:alnum:]])python([0-9]+\.[0-9]+) ]]; then
        found=${BASH_REMATCH[2]}
      else
        continue
      fi
      [ "$found" = "$mm" ] || fail "$df uses $image:$tag; .python-version says $version (python $mm)"
    done < <(grep -E "$FROM_RE" "$df" || true)
  done < <(dockerfiles)

  for pp in pyproject.toml */pyproject.toml; do
    [ -f "$pp" ] || continue
    while IFS= read -r raw; do
      spec=$(sed -E "s/^[[:space:]]*requires-python[[:space:]]*=[[:space:]]*[\"']([^\"']*)[\"'].*/\\1/" <<< "$raw" | tr -d '[:space:]')
      if [[ "$spec" =~ ^(\>=|==|~=)([0-9]+\.[0-9]+)(\.[0-9]+|\.\*)?(,\<[0-9]+(\.[0-9]+)*)?$ ]]; then
        lower=${BASH_REMATCH[2]}
        [ "$lower" = "$mm" ] || fail "$pp requires-python '$spec' has lower bound $lower; .python-version says $version (python $mm)"
      else
        warn "$pp requires-python '$spec' is not a form this check parses; verify it admits python $mm by hand"
      fi
    done < <(grep -E '^[[:space:]]*requires-python[[:space:]]*=' "$pp" || true)
  done

  while IFS= read -r wf; do
    for lineno in $(inline_pins "$wf" actions/setup-python python-version); do
      fail "$wf:$lineno: setup-python pins python-version inline; use python-version-file: .python-version"
    done
  done < <(workflows)
  checked+=("python $version")
}

# Versions as integers for comparison: 1.83 -> 1 83 0.
semver_le() { # <a> <b>: a <= b, each MAJOR.MINOR[.PATCH]
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<< "$1"; IFS=. read -r b1 b2 b3 <<< "$2"
  a3=${a3:-0}; b3=${b3:-0}
  [ "$a1" -lt "$b1" ] || { [ "$a1" -eq "$b1" ] && { [ "$a2" -lt "$b2" ] || { [ "$a2" -eq "$b2" ] && [ "$a3" -le "$b3" ]; }; }; }
}

check_rust() {
  if ! has_rust; then echo "toolchain-check: no rust-toolchain.toml; rust not checked"; return; fi
  local version mm decl df line image tag ct msrv wf lineno
  decl=rust-toolchain.toml; [ -f "$decl" ] || decl=rust-toolchain
  # One parser for the declaration: rust_toolchain.sh's. It names the problem on stderr.
  version=$("$(dirname "${BASH_SOURCE[0]}")/rust_toolchain.sh" --declared . 2>&1) || { fail "${version#rust_toolchain: }"; return; }
  mm=${version%.*}

  # Official images only (rust, docker.io/library/rust); cross builders like
  # messense/rust-musl-cross carry no rustc version in the tag and are not checked.
  while IFS= read -r df; do
    while IFS= read -r line; do
      image=$(sed -E "s/${FROM_RE}([^[:space:]]+).*/\\2/" <<< "$line"); image=${image%%@*}
      tag=
      if [[ "$image" == *:* ]]; then tag=${image##*:}; image=${image%:*}; fi
      case "$image" in rust|library/rust|docker.io/library/rust) ;; *) continue ;; esac
      if [[ "$tag" =~ ^([0-9]+\.[0-9]+)([.-]|$) ]] && [ "${BASH_REMATCH[1]}" = "$mm" ]; then continue; fi
      fail "$df uses $image${tag:+:$tag}; $decl says $version (rust $mm)"
    done < <(grep -E "${FROM_RE}" "$df" || true)
  done < <(dockerfiles)

  # An MSRV above the pinned toolchain is a contradiction cargo only reports at build time.
  for ct in Cargo.toml */Cargo.toml; do
    [ -f "$ct" ] || continue
    while IFS= read -r line; do
      msrv=$(sed -E "s/^[[:space:]]*rust-version[[:space:]]*=[[:space:]]*[\"']([^\"']*)[\"'].*/\\1/" <<< "$line")
      if [[ ! "$msrv" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        warn "$ct rust-version '$msrv' is not a form this check parses"; continue
      fi
      semver_le "$msrv" "$version" || fail "$ct rust-version $msrv is above the pinned toolchain $version in $decl"
    done < <(grep -E "^[[:space:]]*rust-version[[:space:]]*=[[:space:]]*[\"']" "$ct" || true)
  done

  while IFS= read -r wf; do
    for lineno in $(inline_pins "$wf" actions-rust-lang/setup-rust-toolchain toolchain); do
      fail "$wf:$lineno: setup-rust-toolchain pins toolchain inline; leave it unset so $decl applies"
    done
    while IFS= read -r lineno; do
      fail "$wf:$lineno: dtolnay/rust-toolchain cannot read $decl; use actions-rust-lang/setup-rust-toolchain"
    done < <(grep -nE "uses:[[:space:]]*[\"']?dtolnay/rust-toolchain@" "$wf" | cut -d: -f1)
  done < <(workflows)
  checked+=("rust $version")
}

check_node
check_python
check_rust

if [ $rc = 0 ]; then
  summary=$(IFS=,; echo "${checked[*]}"); echo "toolchain-check: ok (${summary//,/, })"
else
  echo "toolchain-check: FAIL" >&2
fi
exit $rc
