#!/usr/bin/env bash
# Install JS deps, build the native-messaging launcher sidecar, build the UI.
# esbuild 0.25.12 and rollup 4.59.0 both ship linux-loong64 binaries, so this
# stage needs no source patch.
set -euo pipefail
. "$(dirname -- "$0")/../env.sh"

cd "$SRC"

# Upstream pins supportedArchitectures.cpu to [x64, arm64]; pnpm 11 then skips
# every loong64 optional native package even though they are in the lockfile.
# Symptom: vite build dies with "Cannot find module @rollup/rollup-linux-loong64-gnu".
PATCH="$PORT_ROOT/patches/rayburst-pnpm-workspace-loong64.patch"
if ! grep -q "loong64" pnpm-workspace.yaml; then
  echo "[03] applying $PATCH"
  git apply --check "$PATCH" && git apply "$PATCH"
else
  echo "[03] loong64 cpu entry already present"
fi

echo "[03] pnpm install --frozen-lockfile"
"$PNPM_BIN" install --frozen-lockfile

native_ok() {
  ls node_modules/.pnpm 2>/dev/null | grep -q '^@rollup+rollup-linux-loong64-gnu' &&
  ls node_modules/.pnpm 2>/dev/null | grep -q '^@esbuild+linux-loong64'
}
# pnpm caches the resolved optional-dependency set in node_modules/.modules.yaml;
# changing supportedArchitectures on an existing tree yields "Already up to date".
if ! native_ok && [ -d node_modules ]; then
  echo "[03] loong64 native packages missing -> clean reinstall"
  rm -rf node_modules
  "$PNPM_BIN" install --frozen-lockfile
fi
if ! native_ok; then
  echo "[03] FATAL: loong64 rollup/esbuild native packages absent after reinstall"; exit 1
fi
echo "[03] loong64 native packages present"

echo "[03] pnpm build:native-launcher  (target triple: $TRIPLE)"
"$PNPM_BIN" build:native-launcher
LAUNCHER="src-tauri/generated-binaries/rayburst-browser-launcher-$TRIPLE"
test -x "$LAUNCHER" || { echo "[03] FATAL: $LAUNCHER was not produced"; exit 1; }
echo "[03] launcher: $(ls -lh "$LAUNCHER" | awk '{print $5}') $(file -b "$LAUNCHER" | cut -c1-80)"

echo "[03] pnpm build  (vue-tsc + vite)"
"$PNPM_BIN" build
test -f dist/index.html || { echo "[03] FATAL: dist/index.html missing"; exit 1; }
echo "[03] OK: dist/index.html"
