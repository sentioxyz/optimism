################################################################
#   Reproducible kona prestate build — thin environment wrapper #
#                                                               #
#   Build logic lives in rust/justfile.                         #
#   This Dockerfile provides a fixed environment and calls it.  #
################################################################

################################################################
#              Build Cannon from local monorepo                #
################################################################

FROM golang:1.24.13-alpine3.22 AS cannon-build

RUN apk add --no-cache bash just

COPY go.mod go.sum /app/
COPY cannon/ /app/cannon/
COPY op-service/ /app/op-service/
COPY op-preimage/ /app/op-preimage/
COPY justfiles/ /app/justfiles/

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    cd /app/cannon && just cannon

################################################################
#    Build kona-client ELF + generate prestate                 #
################################################################

FROM us-docker.pkg.dev/oplabs-tools-artifacts/images/cannon-builder:v1.0.0 AS kona-build-env
SHELL ["/bin/bash", "-c"]

ARG VARIANT=kona-client

# --- Layer 1: mise (changes rarely) ---
COPY ops/scripts/install_mise.sh /tmp/install_mise.sh
RUN chmod +x /tmp/install_mise.sh && /tmp/install_mise.sh
ENV PATH="/root/.local/bin:${PATH}"

# Install only the tools needed for this build from mise.toml
COPY mise.toml /app/mise.toml
COPY rust/rust-toolchain.toml /app/rust/rust-toolchain.toml
WORKDIR /app
RUN mise trust && mise install go rust just jq

# Ensure mise-installed tools are on PATH.
# MISE_GLOBAL_CONFIG_FILE is set so shims resolve tool versions even when
# the working directory is changed (e.g. via `docker run -w /workdir`).
ENV PATH="/root/.local/share/mise/shims:${PATH}"
ENV MISE_GLOBAL_CONFIG_FILE="/app/mise.toml"

# --- Layer 2: Rust nightly (changes when NIGHTLY pin changes) ---
COPY rust/justfile /app/rust/justfile
RUN cd /app/rust && just install-nightly
# Set nightly as the default toolchain so that -Zbuild-std works in docker run
RUN rustup default "$(cd /app/rust && just --evaluate NIGHTLY)"

# --- Layer 3: Rust workspace source ---
COPY rust/Cargo.toml rust/Cargo.lock /app/rust/
COPY rust/.cargo/ /app/rust/.cargo/
COPY rust/kona/ /app/rust/kona/
COPY rust/op-alloy/ /app/rust/op-alloy/
COPY rust/alloy-op-evm/ /app/rust/alloy-op-evm/
COPY rust/alloy-op-hardforks/ /app/rust/alloy-op-hardforks/
# op-reth is a workspace member but not a kona-client dependency.
# We need its Cargo.toml files so the workspace resolves.
COPY rust/op-reth/ /app/rust/op-reth/

# --- Layer 4: Build kona-client ELF ---
# Override the target spec baked into the cannon-builder image (which has
# target-c-int-width: 64) with the corrected one from the source tree.
COPY rust/kona/docker/cannon/mips64-unknown-none.json /mips64-unknown-none.json
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/app/rust/target \
    cd /app/rust && just build-kona-client-elf ${VARIANT}

################################################################
#   Generate prestate                                          #
################################################################

FROM kona-build-env AS prestate-build

COPY --from=cannon-build /app/cannon/bin/cannon /app/cannon
RUN /app/cannon load-elf \
      --path=/app/rust/target/mips64-unknown-none/release-client-lto/${VARIANT} \
      --out=/app/prestate.bin.gz \
      --type multithreaded64-5 && \
    /app/cannon run \
      --proof-at "=0" \
      --stop-at "=1" \
      --input /app/prestate.bin.gz \
      --meta /app/meta.json \
      --proof-fmt "/app/%d.json" \
      --output "" && \
    mv /app/0.json /app/prestate-proof.json

################################################################
#                       Export Artifacts                       #
################################################################

FROM scratch AS export-stage

COPY --from=prestate-build /app/prestate.bin.gz .
COPY --from=prestate-build /app/prestate-proof.json .
COPY --from=prestate-build /app/meta.json .
