# The tools of basecamp/once-campfire-verification that a dev box may lack: Ruby, the sqlite3 CLI,
# FFmpeg (ffprobe), the Rust toolchain that the harness pins (loadgen) and the docker CLI with buildx
# (the Rails image of bin/seed needs BuildKit).
FROM debian:trixie-slim

ARG RUST_VERSION=1.98.1

ENV DEBIAN_FRONTEND=noninteractive \
    RUSTUP_HOME=/opt/rustup \
    PATH=/opt/rustup-bin:$PATH

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl docker-buildx docker-cli ffmpeg git ruby ruby-minitest sqlite3 util-linux \
 && rm -rf /var/lib/apt/lists/*

# A profile without docs: the harness only builds loadgen. CARGO_HOME is chosen at run time (it must be
# writable by the invoking user), so only the proxies of the toolchain live in the image.
RUN curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
 && CARGO_HOME=/opt/cargo sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
      --default-toolchain "${RUST_VERSION}" \
 && mkdir /opt/rustup-bin \
 && cp /opt/cargo/bin/* /opt/rustup-bin/ \
 && rm -rf /opt/cargo /tmp/rustup-init.sh \
 && chmod -R a+rX /opt/rustup /opt/rustup-bin
