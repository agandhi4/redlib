# shellcheck shell=bash
# The topology rules a public repo is held to, and the one grep that applies them. Sourced;
# defines variables and functions and runs nothing.
# Used by: devkit-check.sh's check_public_topology (a devkit checkout, and a plan with the literal
# GATE_PUBLIC=1) and docs_check.sh (a GATE_PUBLIC=1 plan: a docs-only commit runs docs-check
# alone and a docs-only PR owes no review, so devkit-check never sees a doc's leak there).
#
#   topology_hits <who> <staged 0|1>
#       Prints `<file>:<line>:<text>` once per tracked line (the index with 1) any rule matches,
#       in file then line order, outside devkit/, docs/reports/ and docs/audits/ and without the
#       lines carrying the exemption. Nothing when clean. On a malformed rule or a git grep
#       failure, prints `<who>: …` on stderr and returns 2: a pattern this platform's regex
#       rejects must fail the caller, never read as a clean tree. Run it in the repo's root.
#
# The homelab topology a public repo must never name: one rule per line,
# `<where> <ERE>`, where <where> is `all` or comma-separated git pathspecs (`*.md` matches at any
# depth). Generic shapes only, never a fleet name: this file is vendored into the public repos it
# guards, so a list of the real names would publish them (devkit #478). POSIX ERE with no `\b`
# (macOS git grep has none), so a name's or an address's ends are spelled as classes, and matched
# with case: case-blind, `/Users/` is every `/api/users/` route.
#   - a `<name>.box` or `<name>-box` host: bare after a boundary in prose, scripts and config
#     (Markdown, shell and bats, YAML and compose, TOML/INI/.env, systemd units, Makefiles,
#     Dockerfiles), where code's lookalikes do not live; in any other file (code) only in a URL or
#     an ssh target (after `://` or `@`), and a `.box` one also in a code span (after a backtick:
#     a JS template literal opens with one, and its CSS classes end in `-box`). Code holds
#     property accesses on a `box` field and classes ending in `-box` (daisyUI's, the box-sizing
#     value). A prose compound on -box is the known false positive: its line carries the marker.
#   - NAS volume paths; a macOS home anywhere; a Linux home only as a path into it (`/home/<u>/…`)
#     in Markdown and shell (not bats: a test's fixture is data): a Dockerfile's or a doc's bare
#     `/home/node` is the image user's HOME.
#   - dynamic-DNS and tailnet suffixes.
#   - a private host address after a left boundary (inside a longer dotted number, a version, is
#     none), never a CIDR range (`/<bits>` after it names a class, as a trusted-proxy list does):
#     192.168/16 and the tailnet's CGNAT 100.64/10 anywhere; 10/8 and 172.16/12 only in Markdown
#     and shell, since code, its tests and compose networks use them as data.
# The env override (same format) is for the tests, as DEVKIT_RETIRED_OWNERS is.
DEVKIT_TOPOLOGY_PATTERNS=${DEVKIT_TOPOLOGY_PATTERNS:-'all (://|@)[A-Za-z0-9][A-Za-z0-9.-]*[.-]box([^A-Za-z0-9_-]|$)
all `[A-Za-z0-9][A-Za-z0-9.-]*\.box([^A-Za-z0-9_-]|$)
*.md,*.sh,*.bash,*.zsh,*.bats,*.yml,*.yaml,*.toml,*.conf,*.ini,*.cfg,*.env,*.env.*,*.service,*.timer,*Makefile,*.mk,*Dockerfile* (^|[^A-Za-z0-9_.-])[A-Za-z0-9][A-Za-z0-9.-]*[.-]box([^A-Za-z0-9_-]|$)
all /volume[0-9]+/
all (^|[^A-Za-z0-9_.-])/Users/[a-z][a-z0-9_-]*
*.md,*.sh,*.bash,*.zsh (^|[^A-Za-z0-9_.-])/home/[a-z][a-z0-9_-]*/
all \.(dedyn\.io|duckdns\.org|ts\.net)([^A-Za-z0-9_-]|$)
all (^|[^0-9.])192\.168\.[0-9]{1,3}\.[0-9]{1,3}([^0-9/]|/[^0-9]|$)
all (^|[^0-9.])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}([^0-9/]|/[^0-9]|$)
*.md,*.sh,*.bash,*.zsh (^|[^0-9.])(10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}([^0-9/]|/[^0-9]|$)'}
# The exemption: a line ending `topology example` in its language's comment (`#`, `//`, `--`,
# `<!-- … -->`, `/* … */`), so a test's private-address fixture in TS or SQL can carry it too.
readonly TOPOLOGY_EXAMPLE='(#|//|--|<!--|/\*) *topology example *(-->|\*/)? *$'
topology_hits() { # <who> <staged 0|1>
  local who=$1 hits='' found where pattern extra rc
  local -a specs
  local grep_args=(-I -n -E)
  [ "$2" = 0 ] || grep_args=(--cached "${grep_args[@]}")
  while read -r where pattern extra; do
    [ -n "$where" ] || continue
    if [ -z "$pattern" ] || [ -n "$extra" ]; then
      echo "$who: DEVKIT_TOPOLOGY_PATTERNS line '$where${pattern:+ $pattern}${extra:+ $extra}' is not '<where> <ERE>'" >&2
      return 2
    fi
    if [ "$where" = all ]; then specs=(.); else IFS=, read -ra specs <<<"$where"; fi
    # git grep is 1 on no match and more on its own failure.
    rc=0
    found=$(git grep "${grep_args[@]}" -e "$pattern" -- "${specs[@]}" ':!devkit/' ':!docs/reports/' \
      ':!docs/audits/') || rc=$?
    if [ "$rc" -gt 1 ]; then
      echo "$who: the topology check could not run (git grep exit $rc above; DEVKIT_TOPOLOGY_PATTERNS must be POSIX ERE)" >&2
      return 2
    fi
    hits+=${found:+$found$'\n'}
  done <<<"$DEVKIT_TOPOLOGY_PATTERNS"
  # One line per file:line, however many rules it hit.
  sort -t: -k1,1 -k2,2n -u <<<"$hits" | grep -vE "^$|$TOPOLOGY_EXAMPLE" || true
}
