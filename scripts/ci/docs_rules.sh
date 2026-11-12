# shellcheck shell=bash
# redlib's extra docs rules, sourced by devkit/bin/docs_check.sh after its standard checks; contract
# in that script's header (rule 11). Uses its docs_fail.
#
# The public tree names no homelab topology (2026-11-12, "Homelab topology lives in the homelab
# repo"): this repo is a public fork, and the owner's hosts, NAS paths, home paths and private DNS
# suffixes belong in homelab's stacks/redlib/README.md; docs here use role words ("the publisher
# host", "the NAS"). Skipped: devkit/ (vendored: a hit there is fixed in devkit and synced),
# docs/decisions.md (dated history,
# never rewritten; a new entry must not add a hit), and this file, which quotes the patterns.
while IFS= read -r redlib_leak; do
  docs_fail "public tree names homelab topology: $redlib_leak (move it to homelab stacks/redlib/README.md)"
done < <(git grep -nIoE 'linux-box|nas\.box|bug\.box|/volume1/|/(home|Users)/aakash|\.dedyn\.io|\.ts\.net|192\.168\.' \
  -- . ':!devkit' ':!docs/decisions.md' ':!scripts/ci/docs_rules.sh' | cut -d: -f1,2)
