################################################################
#   Reproducible kona prestate build — thin environment wrapper #
#                                                               #
#   Build logic lives in rust/justfile.                         #
#   This Dockerfile provides a fixed environment and calls it.  #
#   Cannon binary is provided via a named build context.        #
################################################################

ARG CANNON_BUILDER_VERSION=v2.0.0
FROM us-docker.pkg.dev/oplabs-tools-artifacts/images/cannon-builder:${CANNON_BUILDER_VERSION} AS builder
SHELL ["/bin/bash", "-c"]

ARG VARIANT=kona-client

# --- Layer 1: mise (changes rarely) ---
# Install mise using the monorepo's pinned version script (same as CI)
COPY --from=monorepo ops/scripts/install_mise.sh /tmp/install_mise.sh
RUN chmod +x /tmp/install_mise.sh && /tmp/install_mise.sh
ENV PATH="/root/.local/bin:${PATH}"

# Install only the tools needed for this build from mise.toml
COPY --from=monorepo mise.toml /app/mise.toml
COPY rust-toolchain.toml /app/rust/rust-toolchain.toml
WORKDIR /app
RUN mise trust && mise install go rust just jq

# Ensure mise-installed tools are on PATH
ENV PATH="/root/.local/share/mise/shims:${PATH}"

# --- Layer 2: Rust nightly (changes when NIGHTLY pin changes) ---
COPY justfile /app/rust/justfile
RUN cd /app/rust && just install-nightly

# --- Layer 3: Rust workspace source ---
COPY Cargo.toml Cargo.lock /app/rust/
COPY .cargo/ /app/rust/.cargo/
COPY kona/ /app/rust/kona/
COPY op-alloy/ /app/rust/op-alloy/
COPY alloy-op-evm/ /app/rust/alloy-op-evm/
COPY alloy-op-hardforks/ /app/rust/alloy-op-hardforks/
# op-reth is a workspace member but not a kona-client dependency.
# We need its Cargo.toml files so the workspace resolves.
COPY op-reth/ /app/rust/op-reth/

# --- Layer 4: Build kona-client ELF ---
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/app/rust/target \
    cd /app/rust && just build-kona-client-elf ${VARIANT}

# --- Layer 5: Generate prestate using cannon from named context ---
COPY --from=cannon /usr/local/bin/cannon /app/cannon
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

COPY --from=builder /app/prestate.bin.gz .
COPY --from=builder /app/prestate-proof.json .
COPY --from=builder /app/meta.json .
