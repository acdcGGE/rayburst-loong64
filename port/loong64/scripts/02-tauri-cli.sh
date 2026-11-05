#!/usr/bin/env bash
# Build the Tauri CLI as a native LoongArch64 binary and shim `pnpm tauri`.
# @tauri-apps/cli 2.12.2 has 11 platform packages, none for loong64, so the
# npm shim throws "Cannot find native binding" on this machine.
set -euo pipefail
. "$(dirname -- "$0")/../env.sh"

CLI_VERSION="$(node -e "const p=require('$SRC/package.json');console.log(p.devDependencies['@tauri-apps/cli'].replace(/[^0-9.]/g,''))")"
echo "[02] tauri-cli target version: $CLI_VERSION (rustup toolchain $RUST_TOOLCHAIN_VERSION)"

if [ ! -x "$CARGO_TAURI" ] || ! "$CARGO_TAURI" --version 2>/dev/null | grep -q "$CLI_VERSION"; then
  echo "[02] cargo install tauri-cli --version $CLI_VERSION --locked"
  # Scoped CARGO_TARGET_DIR keeps this long build cached across runs. Do not
  # export it globally: the project's own builds must stay in src-tauri/target.
  CARGO_TARGET_DIR="$TOOLCHAIN/cargo-target" \
    cargo install tauri-cli --version "$CLI_VERSION" --locked --root "$CARGO_ROOT"
fi
echo "[02] cargo-tauri: $("$CARGO_TAURI" --version | head -1)"

# pnpm regenerates .bin on install, so re-apply the shim every run.
SHIM="$SRC/node_modules/.bin/tauri"
if [ -d "$(dirname "$SHIM")" ]; then
  rm -f "$SHIM"
  cat > "$SHIM" <<EOF
#!/bin/sh
# loong64 port shim -> locally built Rust CLI (see scripts/02-tauri-cli.sh)
exec "$CARGO_TAURI" "\$@"
EOF
  chmod +x "$SHIM"
  echo "[02] shim installed: $SHIM"
  echo "[02] pnpm tauri: $(cd "$SRC" && "$PNPM_BIN" tauri --version | head -1)"
fi
echo "[02] OK"
