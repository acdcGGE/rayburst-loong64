#!/usr/bin/env bash
# Build the aria2-next sidecar for loongarch64 and install it under the
# externalBin name Tauri expects: binaries/aria2-next-<target-triple>.
#
# The upstream releases only cover 6 targets. aria2-next is a CMake superbuild
# that compiles all vendored deps from third_party/ with no network access.
# Only one source change is needed: the OpenSSL target selection falls through
# to linux-x86_64 on LoongArch (see patches/).
#
# Usage: 04-engine.sh [--fallback]
#   --fallback  link the system aria2c instead (functional downgrade, see PORTING.md)
set -euo pipefail
. "$(dirname -- "$0")/../env.sh"

PATCH="$PORT_ROOT/patches/aria2-next-loongarch64-openssl.patch"
DEST="$SRC/src-tauri/binaries/aria2-next-$TRIPLE"
JOBS="${JOBS:-$(nproc)}"
PRESET="${PRESET:-default}"

if [ "${1:-}" = "--fallback" ]; then
  echo "[04] FALLBACK MODE: using system aria2c as a stand-in sidecar"
  echo "[04] WARNING: no native ED2K/Kad, HLS/DASH, state-dir resume or aria2-next RPC extensions"
  command -v aria2c >/dev/null || { echo "[04] FATAL: aria2c not installed"; exit 1; }
  cp "$(command -v aria2c)" "$DEST"
  chmod +x "$DEST"
  echo "[04] wrote $DEST (from $(command -v aria2c), $(aria2c --version | head -1))"
  exit 0
fi

if [ ! -d "$ENGINE_SRC/.git" ]; then
  echo "[04] cloning aria2-next into $ENGINE_SRC"
  git clone --depth 1 https://github.com/AnInsomniacy/aria2-next.git "$ENGINE_SRC"
fi

cd "$ENGINE_SRC"
if ! grep -q "linux64-loongarch64" cmake/superbuild/Dependencies.cmake; then
  echo "[04] applying $PATCH"
  git apply --check "$PATCH" && git apply "$PATCH"
else
  echo "[04] loongarch64 OpenSSL branch already present"
fi

echo "[04] cmake --preset $PRESET"
cmake --preset "$PRESET"
# Fail early if the generated OpenSSL Configure command still targets x86_64.
if grep -q "Configure linux-x86_64" "build/$PRESET/build.ninja"; then
  echo "[04] FATAL: generated build still uses OpenSSL linux-x86_64 target"; exit 1
fi
echo "[04] confirmed OpenSSL target: $(grep -o 'Configure linux[0-9a-z-]*' "build/$PRESET/build.ninja" | head -1)"

echo "[04] cmake --build --preset $PRESET -j $JOBS  (long: full vendored dependency stack)"
cmake --build --preset "$PRESET" -j "$JOBS"

BIN="build/$PRESET/aria2-next"
test -x "$BIN" || { echo "[04] FATAL: $BIN not produced"; exit 1; }
"$BIN" --version | head -2
cp "$BIN" "$DEST"
chmod +x "$DEST"
echo "[04] wrote $DEST ($(du -h "$DEST" | cut -f1))"
echo "[04] OK"
