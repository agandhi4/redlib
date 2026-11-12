# shellcheck shell=bash
# redlib's extra docs rules, sourced by devkit/bin/docs_check.sh after its standard checks; contract
# in that script's header (rule 11). Uses its docs_fail.
#
# The public tree names no homelab topology (2026-11-12, "Homelab topology lives in the homelab
# repo"): this repo is a public fork, and the owner's hosts, the instance hostname, NAS paths, home
# paths and private DNS suffixes belong in homelab's stacks/redlib/README.md; docs here use role
# words ("the publisher host", "the NAS", "the instance"). devkit-check's check_public_topology
# (GATE_PUBLIC=1 in gate_plan.sh) guards the same tree, but only in ci-quick; this copy covers a
# docs-only PR, whose gate runs docs-check alone. It goes when a devkit sync brings docs_check.sh's
# own GATE_PUBLIC guard. Skipped as devkit-check skips: devkit/ (vendored: a hit there is fixed in
# devkit and synced), docs/reports/, docs/audits/, and this file (it quotes the patterns).
redlib_topology='linux-box|nas\.box|bug\.box|reddit\.box|/volume1/|/(home|Users)/aakash|\.dedyn\.io|\.ts\.net|192\.168\.' # topology example
while IFS= read -r redlib_leak; do
  docs_fail "public tree names homelab topology: $redlib_leak (move it to homelab stacks/redlib/README.md)"
done < <(git grep -nIoE "$redlib_topology" \
  -- . ':!devkit' ':!docs/reports' ':!docs/audits' ':!scripts/ci/docs_rules.sh' | cut -d: -f1,2)
