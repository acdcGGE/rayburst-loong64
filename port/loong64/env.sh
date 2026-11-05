#!/bin/sh
# Source this file from every script:  . "$(dirname "$0")/../env.sh"
# All paths stay user-local; nothing here needs root.

PORT_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
WORKSPACE="$(dirname -- "$PORT_ROOT")"

SRC="${SRC:-$WORKSPACE/rayburst}"
ENGINE_SRC="${ENGINE_SRC:-$WORKSPACE/aria2-next}"
TOOLCHAIN="${TOOLCHAIN:-$WORKSPACE/.toolchain}"

NODE_VERSION="${NODE_VERSION:-24.22.2}"
NODE_HOME="$TOOLCHAIN/node-v${NODE_VERSION}-linux-loong64"
PNPM_HOME="$TOOLCHAIN/pnpm"
PNPM_BIN="$PNPM_HOME/node_modules/.bin/pnpm"
CARGO_ROOT="$TOOLCHAIN/cargo-root"
CARGO_TAURI="$CARGO_ROOT/bin/cargo-tauri"

# Rust toolchain: tauri-cli 2.12.2 and Tauri 2.12.x need rustc >= 1.90.
RUST_TOOLCHAIN_VERSION="${RUST_TOOLCHAIN_VERSION:-1.93.0}"
export RUSTUP_TOOLCHAIN="$RUST_TOOLCHAIN_VERSION"

TRIPLE="loongarch64-unknown-linux-gnu"
DEB_ARCH="loong64"

# The Rust CLI is built locally because @tauri-apps/cli publishes no loong64 binary.
export PATH="$NODE_HOME/bin:$CARGO_ROOT/bin:$PNPM_HOME/node_modules/.bin:$PATH"
export TRIPLE DEB_ARCH SRC ENGINE_SRC TOOLCHAIN PORT_ROOT WORKSPACE \
       NODE_HOME PNPM_HOME PNPM_BIN CARGO_ROOT CARGO_TAURI

# NOTE: do NOT set CARGO_TARGET_DIR globally here. Both
# scripts/build-native-messaging-launcher.mjs and 05-build.sh expect artifacts
# under src-tauri/target/<triple>/release/. A global override silently breaks
# the launcher sidecar lookup.
