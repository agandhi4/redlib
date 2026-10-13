ARG ALPINE_VERSION=3.23

########################
## builder image
########################
# Runs as linux/amd64 even on an arm64 host (emulated, slow). Not --platform=$BUILDPLATFORM:
# the image's arm64 variant cross-compiles, and boring-sys2's bindgen then looks for x86_64 glibc
# headers the arm64 image lacks ('bits/libc-header-start.h' not found).
FROM ghcr.io/rust-cross/rust-musl-cross:x86_64-musl AS builder

RUN apt-get update \
    && apt-get -y install git cmake perl pkg-config libclang-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /redlib

# The builder image only supplies the musl C cross toolchain; its own rustc floats with the tag.
# rustup (in the image) installs the exact Rust that rust-toolchain.toml pins, with the musl
# target that file lists, here in the cached layer before any cargo build. Copying the file
# later would compile dependencies with the image's rustc and then recompile them all.
COPY rust-toolchain.toml ./
RUN rustup toolchain install && rustc --version

# download (most) dependencies in their own layer
COPY Cargo.lock Cargo.toml ./
RUN mkdir src && echo "fn main() { panic!(\"why am i running?\") }" > src/main.rs
RUN cargo build --release --locked --bin redlib --target x86_64-unknown-linux-musl
RUN rm ./src/main.rs && rmdir ./src

# copy the source and build the redlib binary
COPY . ./
RUN cargo build --release --locked --bin redlib --target x86_64-unknown-linux-musl
RUN echo "finished building redlib!"

########################
## release image
########################
FROM alpine:${ALPINE_VERSION} AS release

# Import redlib binary from builder
COPY --from=builder /redlib/target/x86_64-unknown-linux-musl/release/redlib /usr/local/bin/redlib

# Add non-root user for running redlib
RUN adduser --home /nonexistent --no-create-home --disabled-password redlib
RUN mkdir -p /data && chown redlib:redlib /data
VOLUME /data
USER redlib

# Document that we intend to expose port 8080 to whoever runs the container
EXPOSE 8080

# Run a healthcheck every minute to make sure redlib is functional
HEALTHCHECK --interval=1m --timeout=3s CMD wget --spider -q http://localhost:8080/settings || exit 1

# Release identity: the build passes APP_VERSION once (CI `sha-<7>`, the gate `gate-<pr>`, a bare
# local build `dev`); the app reads it at runtime for the footer and /info, and the OCI label
# carries the same string (devkit/bin/release_check.sh asserts all three are in this stage).
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION
LABEL org.opencontainers.image.version=$APP_VERSION

CMD ["redlib"]
