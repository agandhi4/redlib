# --- Stage 0: build. musl, so the binary is static and the release stage is plain Alpine ---
# The minor must equal rust-toolchain.toml's (toolchain-check); the exact patch comes from
# that file below, so this tag floating within 1.99.x never compiles anything.
FROM rust:1.99-alpine AS build

RUN apk add --no-cache musl-dev

WORKDIR /app
# Before any cargo call, in its own cached layer: rustup installs the exact pinned toolchain
# (redlib's recipe). Copying the file later would compile with the image's rustc first.
COPY rust-toolchain.toml ./
RUN rustup toolchain install && rustc --version

# Dependencies in their own layer, rebuilt only when Cargo.toml or Cargo.lock change.
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo 'fn main() {}' > src/main.rs \
    && cargo build --release --locked \
    && rm -rf src

COPY src ./src
# touch: cargo rebuilds by mtime, and the real main.rs may be older than the dummy's artefact.
RUN touch src/main.rs && cargo build --release --locked

# --- Stage 1: runtime ---
FROM alpine:3.23

RUN adduser -D -H -u 1000 app
COPY --from=build /app/target/release/__NAME__ /usr/local/bin/__NAME__

EXPOSE 8080
# Readiness, not liveness: /health/live answers 200 unconditionally (observability.md).
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=10s \
  CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/health/ready"]

# Release identity, last so a new version never invalidates a cached layer. The build passes
# it once (publish.yml: sha-<7>; Makefile: ci-<7> / gate-<n>); /health/ready reports it.
# devkit/bin/release_check.sh requires all three lines in this final stage.
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION
LABEL org.opencontainers.image.version=$APP_VERSION

# The binary is PID 1, so `docker stop`'s SIGTERM reaches main.rs, which drains and exits.
USER app
CMD ["__NAME__"]
