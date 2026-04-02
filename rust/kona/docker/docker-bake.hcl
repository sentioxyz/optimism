////////////////////////////////////////////////////////////////
//                          Globals                           //
////////////////////////////////////////////////////////////////

variable "REGISTRY" {
  default = "ghcr.io"
}

variable "REPOSITORY" {
  default = "ethereum-optimism/kona"
}

// The tag to use for the built image.
variable "DEFAULT_TAG" {
  default = "kona:local"
}

// The platforms to build the image for, separated by commas.
variable "PLATFORMS" {
  default = "linux/amd64,linux/arm64"
}

// The git reference name. This is typically the branch name, commit hash, or tag.
variable "GIT_REF_NAME" {
  default = "main"
}

// The UID of the host user for volume permissions.
variable "HOST_UID" {
  default = "1000"
}

// The GID of the host user for volume permissions.
variable "HOST_GID" {
  default = "1000"
}

// Special target: https://github.com/docker/metadata-action#bake-definition
target "docker-metadata-action" {
  tags = ["${DEFAULT_TAG}"]
}

////////////////////////////////////////////////////////////////
//                         App Images                         //
////////////////////////////////////////////////////////////////

// The location of the repository to build in the kona-app-generic target. Valid options: local (uses local repo, ignores `GIT_REF_NAME`), remote (clones `kona`, checks out `GIT_REF_NAME`)
variable "REPO_LOCATION" {
  default = "remote"
}

// The binary target to build in the kona-app-generic target.
variable "BIN_TARGET" {
  default = "kona-host"
}

// The cargo build profile to use when building the binary in the kona-app-generic target.
variable "BUILD_PROFILE" {
  default = "release-perf"
}

// Generic kona app image
target "generic" {
  inherits = ["docker-metadata-action"]
  context = "."
  dockerfile = "kona/docker/apps/kona_app_generic.dockerfile"
  args = {
    REPO_LOCATION = "${REPO_LOCATION}"
    REPOSITORY = "${REPOSITORY}"
    TAG = "${GIT_REF_NAME}"
    BIN_TARGET = "${BIN_TARGET}"
    BUILD_PROFILE = "${BUILD_PROFILE}"
  }
  platforms = split(",", PLATFORMS)
}

////////////////////////////////////////////////////////////////
//                        Proof Images                        //
////////////////////////////////////////////////////////////////

// The `kona-client` binary variant to build.
// Valid options: `kona-client` (single-chain), `kona-client-int` (interop)
variable "CLIENT_BIN" {
  default = "kona-client"
}

// The path to the monorepo root, used to access shared files (mise.toml, install_mise.sh).
variable "MONOREPO_CONTEXT" {
  default = ".."
}

// The cannon Docker image to use for prestate generation.
// Set by the justfile to reference the root docker-bake cannon target output.
variable "CANNON_CONTEXT" {
  default = "docker-image://us-docker.pkg.dev/oplabs-tools-artifacts/images/cannon:latest"
}

// The cannon-builder Docker image providing the MIPS64 cross-compilation toolchain.
// Defaults to building from local source via the cannon-builder target.
// Override with a registry image for CI when the image has been pre-published.
variable "CANNON_BUILDER_CONTEXT" {
  default = "target:cannon-builder"
}

// Rust build environment for bare-metal MIPS64r1 (Cannon FPVM ISA).
// Contains only apt-level MIPS64 cross-compilation packages.
// Rust, Go, mise, and just are installed on top from pinned version sources.
target "cannon-builder" {
  inherits = ["docker-metadata-action"]
  context = "kona/docker/cannon"
  dockerfile = "cannon.dockerfile"
  args = {
    HOST_UID = "${HOST_UID}"
    HOST_GID = "${HOST_GID}"
  }
  platforms = split(",", PLATFORMS)
}

// Reproducible prestate builder for kona-client with Cannon FPVM.
// Build logic lives in rust/justfile; the Dockerfile is a thin environment wrapper.
// Cannon binary is provided via a named context from the root docker-bake cannon target.
target "kona-cannon-prestate" {
  inherits = ["docker-metadata-action"]
  context = "."
  dockerfile = "kona/docker/fpvm-prestates/cannon-repro.dockerfile"
  contexts = {
    cannon = "${CANNON_CONTEXT}"
    cannon-builder = "${CANNON_BUILDER_CONTEXT}"
    monorepo = "${MONOREPO_CONTEXT}"
  }
  args = {
    VARIANT = "${CLIENT_BIN}"
  }
  # Only build on linux/amd64 for a single source of reproducibility.
  platforms = ["linux/amd64"]
}
