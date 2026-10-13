ARG ALPINE_VERSION=3.23
# Set by BuildKit from --platform (default: the host's). Global scope, so FROM lines can read it.
ARG TARGETARCH

########################
## builder image
########################
# One builder per target arch, picked by BuildKit's TARGETARCH; only the selected stage builds.
# Each rust-musl-cross image runs on the platform it targets, so an amd64 build (ghcr.yml) and an
# arm64 build (the local gate on Apple Silicon, issue #7) both compile natively, never under QEMU.
# Never build one arch's image on the other arch's builder variant: the x86_64-musl image's
# arm64 variant cross-compiles, and boring-sys2's bindgen then looks for x86_64 glibc headers it
# lacks ('bits/libc-header-start.h' not found). The tags have no version to pin (rust-musl-cross
# publishes per-target tags only); rust-toolchain.toml pins the Rust inside them.
FROM ghcr.io/rust-cross/rust-musl-cross:x86_64-musl AS builder-amd64
ENV RUST_TARGET=x86_64-unknown-linux-musl

FROM ghcr.io/rust-cross/rust-musl-cross:aarch64-musl AS builder-arm64
ENV RUST_TARGET=aarch64-unknown-linux-musl

# Any other TARGETARCH fails here ("builder-<arch>" not found), which is the honest answer.
FROM builder-${TARGETARCH} AS builder

RUN apt-get update \
    && apt-get -y install git cmake perl pkg-config libclang-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /redlib

# The builder image only supplies the musl C cross toolchain; its own rustc floats with the tag.
# rustup (in the image) installs the exact Rust that rust-toolchain.toml pins, plus this stage's
# musl target, here in the cached layer before any cargo build. The target is added here rather
# than listed in rust-toolchain.toml so dev machines and the gate never download musl std for
# both arches. Copying the file later would compile dependencies with the image's rustc and
# then recompile them all.
COPY rust-toolchain.toml ./
RUN rustup toolchain install && rustup target add "$RUST_TARGET" && rustc --version

# download (most) dependencies in their own layer
COPY Cargo.lock Cargo.toml ./
RUN mkdir src && echo "fn main() { panic!(\"why am i running?\") }" > src/main.rs
RUN cargo build --release --locked --bin redlib --target "$RUST_TARGET"
RUN rm ./src/main.rs && rmdir ./src

# copy the source and build the redlib binary
COPY . ./
# Copied out to an arch-free path so the release stage needs no knowledge of the target triple.
RUN cargo build --release --locked --bin redlib --target "$RUST_TARGET" \
    && install -D "target/$RUST_TARGET/release/redlib" /out/redlib

########################
## release image
########################
# alpine is multi-arch; BuildKit resolves it for the same TARGETPLATFORM as the builder.
FROM alpine:${ALPINE_VERSION} AS release

COPY --from=builder /out/redlib /usr/local/bin/redlib

# Add non-root user for running redlib
RUN adduser --home /nonexistent --no-create-home --disabled-password redlib
RUN mkdir -p /data && chown redlib:redlib /data
VOLUME /data
USER redlib

# Document that we intend to expose port 8080 to whoever runs the container
EXPOSE 8080

# Run a healthcheck every minute to make sure redlib is functional
HEALTHCHECK --interval=1m --timeout=3s CMD wget --spider -q http://localhost:8080/settings || exit 1

# Release identity: the build passes APP_VERSION once (CI the bare `<sha7>`, the gate `gate-<pr>`, a bare
# local build `dev`); the app reads it at runtime for the footer and /info, and the OCI label
# carries the same string (devkit/bin/release_check.sh asserts all three are in this stage).
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION
LABEL org.opencontainers.image.version=$APP_VERSION

CMD ["redlib"]
