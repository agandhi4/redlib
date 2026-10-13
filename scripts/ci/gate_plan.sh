# redlib's gate plan, sourced by devkit/bin/local_gate.sh (contract in its header).
# Which jobs run for which changed paths; every job is a `make` target (Makefile).
#
#   *.md, docs/**                      -> docs (docs-check) only
#   src/**, Cargo.*, build.rs, rust-toolchain.toml
#                                      -> quick + unit
#   Dockerfile.alpine, .dockerignore   -> image
#   anything else (static/, templates/, Makefile, scripts/, .github/, devkit/, ...)
#                                      -> everything. static/ and templates/ are compiled into
#                                         the binary (include_str!, Askama), so they are code.
#   image-affecting paths              -> image (see IMAGE_PATHS)
# There is no smoke job: the listener opens only after OAuth bootstrap against Reddit
# (AGENTS.md "Startup order"), so no health path answers without live Reddit.
GATE_SLUG=agandhi4/redlib
GATE_STATE_NAME=redlib-gate

# Paths that change what the image's builder resolves before compiling: the dependency layer
# (Cargo.lock, Cargo.toml), the pinned toolchain, or the build recipe itself.
IMAGE_PATHS='^(Dockerfile\.alpine|\.dockerignore|Cargo\.lock|Cargo\.toml|rust-toolchain\.toml)$'

IMAGE="redlib:gate-$PR"

gate_cleanup() {
  docker rmi -f "$IMAGE" >/dev/null 2>&1 || true
}

gate_plan() {
  local docs=0 rust=0 image=0 all=0 path
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    case "$path" in
      *.md|docs/*) docs=1 ;;
      src/*|Cargo.toml|Cargo.lock|build.rs|rust-toolchain.toml) rust=1 ;;
      Dockerfile.alpine|.dockerignore) image=1 ;;
      *) all=1 ;;
    esac
  done <<< "$CHANGED"
  [ "$all" = 1 ] && { docs=1; rust=1; image=1; }
  changed "$IMAGE_PATHS" && image=1
  echo "GATE scope docs=$docs rust=$rust image=$image all=$all"
  if [ "$docs" = 0 ] && [ "$rust" = 0 ] && [ "$image" = 0 ]; then nothing_to_run "no changed paths"; fi

  # ci-quick includes docs-check, so a code PR checks docs too.
  if [ "$rust" = 1 ]; then
    job quick ci-quick
    job unit ci-unit
  else
    if [ "$docs" = 1 ]; then job docs docs-check; else skip docs "no docs changes"; fi
    skip quick "no Rust changes"
    skip unit "no Rust changes"
  fi

  if [ "$image" = 1 ]; then
    job image ci-image CI_IMAGE="$IMAGE"
  else
    skip image "no image-affecting paths changed"
  fi
}
