#!/usr/bin/env bash
# Build the Rayburst binary. --no-bundle is mandatory: tauri-bundler 2.10.2
# panics on loongarch64-* in Settings::binary_arch() and its deb/rpm match
# arms have no LoongArch64 case. Packaging happens in 06-package-deb.sh.
set -euo pipefail
. "$(dirname -- "$0")/../env.sh"

"$PORT_ROOT/scripts/00-system-deps.sh"

SIDECAR="$SRC/src-tauri/binaries/aria2-next-$TRIPLE"
LAUNCHER="$SRC/src-tauri/generated-binaries/rayburst-browser-launcher-$TRIPLE"
for f in "$SIDECAR" "$LAUNCHER"; do
  test -x "$f" || { echo "[05] FATAL: missing sidecar $f (run 03 + 04 first)"; exit 1; }
done

cd "$SRC"
echo "[05] cargo-tauri build --no-bundle --target $TRIPLE"
"$CARGO_TAURI" build --no-bundle --target "$TRIPLE"

BIN="src-tauri/target/$TRIPLE/release/rayburst"
test -x "$BIN" || { echo "[05] FATAL: $BIN not produced"; exit 1; }
echo "[05] binary: $(ls -lh "$BIN" | awk '{print $5}') $(file -b "$BIN" | cut -c1-100)"
echo "[05] OK"
