#!/usr/bin/env bash
# Userland Node >= 22.13 + pnpm 11 for LoongArch64.
# Deepin 25 apt ships Node 20. Node.js upstream publishes no linux-loong64
# tarball; loong64/node does, and its glibc build runs on glibc >= 2.38.
set -euo pipefail
. "$(dirname -- "$0")/../env.sh"

NODE_VERSION="${NODE_VERSION:-24.22.2}"
BASE_URL="https://github.com/loong64/node/releases/download/v${NODE_VERSION}"
NAME="node-v${NODE_VERSION}-linux-loong64"
TARBALL="$TOOLCHAIN/downloads/${NAME}.tar.xz"

mkdir -p "$TOOLCHAIN/downloads" "$PNPM_HOME"

if [ ! -x "$NODE_HOME/bin/node" ]; then
  echo "[01] downloading $NAME"
  curl -fL --retry 3 --retry-delay 2 -o "$TARBALL" "$BASE_URL/${NAME}.tar.xz"
  curl -fsSL -o "$TARBALL.sha256" "$BASE_URL/${NAME}.tar.xz.sha256"
  ( cd "$(dirname "$TARBALL")" && printf '%s  %s\n' \
      "$(cut -d' ' -f1 < "$(basename "$TARBALL.sha256")")" "$(basename "$TARBALL")" \
      | sha256sum -c - )
  tar -xf "$TARBALL" -C "$TOOLCHAIN"
fi

echo "[01] node:    $("$NODE_HOME/bin/node" --version)"
echo "[01] npm:     $("$NODE_HOME/bin/npm" --version)"

# pnpm 11.5.2 is pinned by package.json's packageManager field. It imports
# node:sqlite, so it cannot run on the system Node 20.
PNPM_VERSION="$(node -e "const p=require('$SRC/package.json');console.log(p.packageManager.split('@')[1])")"
if [ ! -x "$PNPM_BIN" ] || [ "$("$PNPM_BIN" --version)" != "$PNPM_VERSION" ]; then
  echo "[01] installing pnpm@$PNPM_VERSION into $PNPM_HOME"
  npm install --no-audit --no-fund --prefix "$PNPM_HOME" "pnpm@$PNPM_VERSION"
fi
echo "[01] pnpm:    $("$PNPM_BIN" --version)"
echo "[01] OK"
