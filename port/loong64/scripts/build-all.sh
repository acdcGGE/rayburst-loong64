#!/usr/bin/env bash
# Full loongarch64 port pipeline. Stage 0 requires the system dev packages
# to have been installed once (sudo apt-get install, see README step 0).
set -euo pipefail
. "$(dirname -- "$0")/../env.sh"

step() { printf '\n===== %s =====\n' "$1"; }

step "0/7  system development headers (read-only check)"
"$PORT_ROOT/scripts/00-system-deps.sh" || {
  echo "Run the sudo command printed above, then retry."; exit 1;
}

step "1/7  Node + pnpm userland toolchain"
"$PORT_ROOT/scripts/01-toolchain.sh"

step "2/7  native tauri-cli"
"$PORT_ROOT/scripts/02-tauri-cli.sh"

step "3/7  JS deps + browser launcher + frontend"
"$PORT_ROOT/scripts/03-frontend.sh"

step "4/7  aria2-next loong64 sidecar"
"$PORT_ROOT/scripts/04-engine.sh" "$@"

step "5/7  Rayburst Rust binary (--no-bundle)"
"$PORT_ROOT/scripts/05-build.sh"

step "6/7  .deb (Architecture: loong64)"
"$PORT_ROOT/scripts/06-package-deb.sh"

step "7/7  .pkg.tar.zst (Loong Arch Linux, CARCH=loong64)"
"$PORT_ROOT/scripts/07-package-arch.sh"

printf '\n===== done =====\n'
ls -lh "$PORT_ROOT"/dist/*.deb "$PORT_ROOT"/dist/*.pkg.tar.zst
