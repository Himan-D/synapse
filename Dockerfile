# syntax=docker/dockerfile:1
# ── Stage 1: build ────────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS builder

ARG ZIG_VERSION=0.16.0
ARG TARGETARCH=amd64

# Install build deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    xz-utils \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Zig 0.16 tarball naming is zig-<arch>-linux-<ver>, not zig-linux-<arch>-<ver>.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) ZIG_ARCH=x86_64 ;; \
      arm64) ZIG_ARCH=aarch64 ;; \
      *) echo "unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac; \
    ZIG_DIR="zig-${ZIG_ARCH}-linux-${ZIG_VERSION}"; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/${ZIG_DIR}.tar.xz" \
      -o /tmp/zig.tar.xz; \
    tar -C /opt -xf /tmp/zig.tar.xz; \
    ln -s "/opt/${ZIG_DIR}/zig" /usr/local/bin/zig; \
    rm /tmp/zig.tar.xz; \
    zig version

WORKDIR /build
COPY . .

# Cross-compile a musl binary for the container arch (static-friendly).
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) ZIG_TARGET=x86_64-linux-musl ;; \
      arm64) ZIG_TARGET=aarch64-linux-musl ;; \
      *) echo "unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac; \
    zig build -Doptimize=ReleaseSafe \
      -Dtarget=${ZIG_TARGET} \
      --prefix /build/dist

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

RUN useradd --system --create-home --shell /bin/false synapse

RUN mkdir -p /data && chown synapse:synapse /data

COPY --from=builder /build/dist/bin/synapse /usr/local/bin/synapse
# Admin console + playground assets (served from process cwd).
COPY --from=builder /build/web /home/synapse/web
WORKDIR /home/synapse

# Runtime config — auth is required by cloud serve off-loopback; set at run time
# in CI/compose rather than baking secrets into image metadata.
ENV PORT=8787
ENV SYNAPSE_HOST=0.0.0.0
ENV SYNAPSE_DATA_ROOT=/data

EXPOSE 8787

VOLUME ["/data"]

USER synapse

# Pass SYNAPSE_REQUIRE_AUTH=1 (and optional SYNAPSE_RATE_LIMIT) via docker run / Render.
CMD ["synapse", "cloud", "serve"]
