#!/usr/bin/env bash
# Check (never install) system dev packages. Root is deliberately not invoked:
# the operator runs the printed sudo command once, with their own password.
set -euo pipefail
. "$(dirname -- "$0")/../env.sh"

MODULES="webkit2gtk-4.1 javascriptcoregtk-4.1 gtk+-3.0 libsoup-3.0 ayatana-appindicator3-0.1"
MISSING=""
for m in $MODULES; do
  if pkg-config --exists "$m"; then
    printf '[00] OK      %-28s %s\n' "$m" "$(pkg-config --modversion "$m")"
  else
    printf '[00] MISSING %-28s\n' "$m"
    MISSING="$MISSING $m"
  fi
done

if [ -n "$MISSING" ]; then
  cat <<'EOF'

[00] Tauri/wry needs WebKitGTK 4.1 development headers to link the Rust app.
     Run this once (needs root), then re-run this script:

  sudo apt-get update && sudo apt-get install -y \
    libwebkit2gtk-4.1-dev libgtk-3-dev libsoup-3.0-dev \
    libayatana-appindicator3-dev librsvg2-dev \
    patchelf xdg-utils dpkg-dev

EOF
  echo "[00] missing modules:$MISSING"
  exit 1
fi
echo "[00] OK: all pkg-config modules present"
