# syntax=docker/dockerfile:1
# ── Stage 1: build ────────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS builder

ARG ZIG_VERSION=0.16.0
ARG TARGETARCH

# Install build deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    xz-utils \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Download and install Zig 0.16
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) ZIG_ARCH=x86_64 ;; \
      arm64) ZIG_ARCH=aarch64 ;; \
      *) echo "unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz" \
      -o /tmp/zig.tar.xz; \
    tar -C /opt -xf /tmp/zig.tar.xz; \
    ln -s "/opt/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}/zig" /usr/local/bin/zig; \
    rm /tmp/zig.tar.xz

WORKDIR /build
COPY . .

# Build release binary targeting Linux (static-ish; no external dynamic deps in Zig std)
RUN zig build -Doptimize=ReleaseSafe \
    -Dtarget=native-linux-musl \
    --prefix /build/dist

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

# Create non-root user for the process
RUN useradd --system --create-home --shell /bin/false synapse

# Persistent data volume mount point
RUN mkdir -p /data && chown synapse:synapse /data

COPY --from=builder /build/dist/bin/synapse /usr/local/bin/synapse

# Render (and Docker) will set $PORT; default to 8787 for local docker run
ENV PORT=8787
ENV SYNAPSE_HOST=0.0.0.0
ENV SYNAPSE_DATA_ROOT=/data

# Auth is always required when binding 0.0.0.0
ENV SYNAPSE_REQUIRE_AUTH=1

EXPOSE 8787

VOLUME ["/data"]

USER synapse

# synapse cloud serve reads SYNAPSE_DATA_ROOT, SYNAPSE_HOST, PORT, SYNAPSE_REQUIRE_AUTH
# and SYNAPSE_RATE_LIMIT from environment — no flags needed in production.
CMD ["synapse", "cloud", "serve"]
