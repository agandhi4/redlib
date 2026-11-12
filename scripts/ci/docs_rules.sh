# shellcheck shell=bash
# redlib's extra docs rules, sourced by devkit/bin/docs_check.sh after its standard checks; contract
# in that script's header (rule 11). Uses its docs_fail.
#
# The public tree names no homelab topology (2026-11-12, "Homelab topology lives in the homelab
# repo"): this repo is a public fork, and the owner's hosts, the instance hostname, NAS paths, home
# paths and private DNS suffixes belong in homelab's stacks/redlib/README.md; docs here use role
# words ("the publisher host", "the NAS", "the instance"). Skipped: devkit/ (vendored: a hit there
# is fixed in devkit and synced), extensions/firefox/ (its default target host is behaviour, left
# to the owner), this file (it quotes the patterns), and docs/decisions.md, which is checked below
# instead.
redlib_topology='linux-box|nas\.box|bug\.box|reddit\.box|/volume1/|/(home|Users)/aakash|\.dedyn\.io|\.ts\.net|192\.168\.'
while IFS= read -r redlib_leak; do
  docs_fail "public tree names homelab topology: $redlib_leak (move it to homelab stacks/redlib/README.md)"
done < <(git grep -nIoE "$redlib_topology" \
  -- . ':!devkit' ':!extensions/firefox' ':!docs/decisions.md' ':!scripts/ci/docs_rules.sh' | cut -d: -f1,2)

# decisions.md history is never rewritten, so entries dated before the move may keep their hits;
# an entry dated 2026-11-12 or later may not add one. ISO dates compare as strings.
while IFS= read -r redlib_leak; do
  docs_fail "public tree names homelab topology: $redlib_leak (a decisions entry from 2026-11-12 on)"
done < <(awk -v re="$redlib_topology" '
  /^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ { date = $2 }
  date >= "2026-11-12" && $0 ~ re { print FILENAME ":" FNR }
' docs/decisions.md)
