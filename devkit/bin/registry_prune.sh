#!/usr/bin/env bash
# GHCR retention for one image: keep the newest <keep> `sha-*` images, everything pushed since
# the oldest of them, the version `latest` names, and every manifest a kept one references;
# delete the rest. Run by bin/publish.sh after each publish (replaces
# actions/delete-package-versions fleet-wide).
#
# Usage: devkit/bin/registry_prune.sh <ghcr.io/owner/name> [--keep N] [--dry-run]
#   --keep     sha-* images kept (default 10); fewer than N of them deletes nothing
#   --dry-run  print what would be deleted, delete nothing
# Output: one `PRUNE delete <id> <digest> <tags|untagged>` line per deletion, then one
#   `PRUNE <name>: deleted <n> of <total> versions (…)` line. Exit 0 ok, 1 a gh/registry
#   failure (nothing more is deleted once one fails), 2 usage or a missing tool.
#
# Why it is shaped this way:
# - Counted in images, not package versions. delete-package-versions counted versions, and a
#   buildx push makes three (index, platform manifest, attestation), so its keep-10 kept 3-4
#   images (local-publish-design.md). Untagged versions are such children: one goes only when
#   no kept version references it, so a kept index never loses its platform manifest. The
#   children are read from each kept version's raw manifest (every sha256 in it; a layer digest
#   never names a package version, so over-reading keeps nothing extra). A manifest that cannot
#   be read stops the run before any delete.
# - The cutoff is the oldest kept sha-* image's created_at, and everything newer stays (a
#   date-tagged finplat image, a child pushed with its parent), so a run never deletes what a
#   concurrent push just made.
# - `gh api` with the token's delete:packages scope (homelab docs/credentials, linux-box).
set -uo pipefail

usage() { echo "usage: $0 <ghcr.io/owner/name> [--keep N] [--dry-run]" >&2; exit 2; }
die() { echo "registry_prune: $*" >&2; exit 1; }

IMAGE='' KEEP=10 DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) [ $# -ge 2 ] || usage; KEEP=$2; shift ;;
    --dry-run) DRY=1 ;;
    -h|--help) usage ;;
    -*) echo "registry_prune: unknown option $1" >&2; usage ;;
    *) [ -z "$IMAGE" ] || usage; IMAGE=$1 ;;
  esac
  shift
done
[[ "$IMAGE" =~ ^ghcr\.io/([a-z0-9_.-]+)/([a-z0-9_.-]+)$ ]] || usage
OWNER=${BASH_REMATCH[1]} PKG=${BASH_REMATCH[2]}
[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || { echo "registry_prune: --keep must be a whole number >= 1 (got '$KEEP')" >&2; usage; }
command -v gh >/dev/null || { echo "registry_prune: gh not found (brew install gh / apt install gh)" >&2; exit 2; }
command -v docker >/dev/null || { echo "registry_prune: docker not found (it reads the kept manifests)" >&2; exit 2; }
API="users/$OWNER/packages/container/$PKG/versions"

# Every version as `<created_at>\t<id>\t<digest>\t<tags, comma-joined>`, newest first.
VERSIONS=$(gh api --paginate "$API" \
  --jq '.[] | [.created_at, (.id | tostring), .name, ((.metadata.container.tags // []) | join(","))] | @tsv' \
  | LC_ALL=C sort -r) || die "cannot list $IMAGE's versions (gh above)"
TOTAL=$(grep -c . <<<"$VERSIONS")

CUTOFF=$(awk -F'\t' -v keep="$KEEP" '$4 ~ /(^|,)sha-/ && ++n == keep { print $1; exit }' <<<"$VERSIONS")
if [ -z "$CUTOFF" ]; then
  echo "PRUNE $PKG: deleted 0 of $TOTAL versions (fewer than $KEEP sha-* images)"
  exit 0
fi

# kept_digests: the digests of the versions kept outright (created at or after the cutoff, or
# tagged latest), one per line.
kept_digests() {
  awk -F'\t' -v cutoff="$CUTOFF" '$1 >= cutoff || $4 ~ /(^|,)latest(,|$)/ { print $3 }' <<<"$VERSIONS"
}

# The kept set: kept_digests plus every digest their manifests reference.
KEPT=$(kept_digests)
REFERENCED=''
for digest in $KEPT; do
  raw=$(docker buildx imagetools inspect --raw "$IMAGE@$digest") \
    || die "cannot read the manifest of kept $IMAGE@$digest (docker above); deleted nothing"
  REFERENCED+=$(grep -oE 'sha256:[0-9a-f]{64}' <<<"$raw")$'\n'
done
KEPT+=$'\n'$REFERENCED

deleted=0
while IFS=$'\t' read -r _ id digest tags; do
  [ -n "$id" ] || continue
  grep -qxF "$digest" <<<"$KEPT" && continue
  echo "PRUNE delete $id ${digest:0:19} ${tags:-untagged}"
  if [ "$DRY" = 0 ]; then
    gh api -X DELETE "$API/$id" >/dev/null \
      || die "deleting version $id ($digest) failed (gh above); $deleted deleted before it"
  fi
  deleted=$((deleted + 1))
done <<<"$VERSIONS"

what=deleted
[ "$DRY" = 0 ] || what='would delete'
echo "PRUNE $PKG: $what $deleted of $TOTAL versions (kept the newest $KEEP sha-* images, all since $CUTOFF, latest, and what they reference)"
