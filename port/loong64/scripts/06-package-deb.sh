#!/usr/bin/env bash
# Reproduce tauri-bundler's Linux .deb layout by hand, with Architecture: loong64.
# Reference (tauri-bundler 2.10.2 src/bundle/linux/debian.rs::generate_data):
#   /usr/bin/<main binary>                    main binary
#   /usr/bin/<externalBin minus -<triple>>   sidecars
#   /usr/lib/<productName>/<resource path>   resources
#   /usr/share/applications/*.desktop, /usr/share/icons/hicolor/**/apps/*.png
set -euo pipefail
. "$(dirname -- "$0")/../env.sh"

VERSION="$(node -e "console.log(require('$SRC/package.json').version)")"
PRODUCT="Rayburst"
OUT="$PORT_ROOT/dist"
STAGE="$OUT/deb-stage"
DEB="$OUT/rayburst_${VERSION}_${DEB_ARCH}.deb"

BIN="$SRC/src-tauri/target/$TRIPLE/release/rayburst"
SIDECAR="$SRC/src-tauri/binaries/aria2-next-$TRIPLE"
LAUNCHER="$SRC/src-tauri/generated-binaries/rayburst-browser-launcher-$TRIPLE"
for f in "$BIN" "$SIDECAR" "$LAUNCHER"; do
  test -x "$f" || { echo "[06] FATAL: missing $f (run 03/04/05 first)"; exit 1; }
done

rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/bin" \
         "$STAGE/usr/lib/$PRODUCT" \
         "$STAGE/usr/share/applications" \
         "$STAGE/usr/share/icons/hicolor" \
         "$OUT"

install -m 0755 "$BIN"      "$STAGE/usr/bin/rayburst"
install -m 0755 "$SIDECAR"  "$STAGE/usr/bin/aria2-next"
install -m 0755 "$LAUNCHER" "$STAGE/usr/bin/rayburst-browser-launcher"

# bundle.resources from src-tauri/tauri.conf.json, keeping their relative paths.
node - "$SRC" "$STAGE/usr/lib/$PRODUCT" <<'NODE'
const fs = require('fs');
const path = require('path');
const [src, dest] = process.argv.slice(2);
const conf = JSON.parse(fs.readFileSync(path.join(src, 'src-tauri/tauri.conf.json'), 'utf8'));
for (const rel of conf.bundle.resources) {
  const from = path.join(src, 'src-tauri', rel);
  const to = path.join(dest, rel);
  fs.mkdirSync(path.dirname(to), { recursive: true });
  fs.copyFileSync(from, to);
  console.log(`[06] resource ${rel}`);
}
NODE

# Desktop entry and icons.
sed -e 's/{{exec}}/rayburst/g' \
    -e 's/{{icon}}/rayburst/g' \
    -e 's/{{name}}/Rayburst/g' \
    -e 's/{{comment}}/Redefining the open-source download manager/g' \
    "$SRC/src-tauri/linux/rayburst.desktop.hbs" \
    > "$STAGE/usr/share/applications/rayburst.desktop"

for size in 32x32 128x128 128x128@2x; do
  case "$size" in
    32x32)      dir="32x32";     file="32x32.png" ;;
    128x128)    dir="128x128";   file="128x128.png" ;;
    128x128@2x) dir="256x256";   file="128x128@2x.png" ;;
  esac
  mkdir -p "$STAGE/usr/share/icons/hicolor/$dir/apps"
  install -m 0644 "$SRC/src-tauri/icons/$file" \
                  "$STAGE/usr/share/icons/hicolor/$dir/apps/rayburst.png" 2>/dev/null || true
done

INSTALLED_SIZE="$(du -sk "$STAGE/usr" | cut -f1)"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: rayburst
Version: $VERSION
Section: net
Priority: optional
Architecture: $DEB_ARCH
Installed-Size: $INSTALLED_SIZE
Maintainer: loong64 port <port@localhost>
Depends: libwebkit2gtk-4.1-0, libgtk-3-0, libsoup-3.0-0, libayatana-appindicator3-1, librsvg2-2, libgl1, libgbm1
Homepage: https://github.com/AnInsomniacy/rayburst
Description: Rayburst download manager (LoongArch64 port)
 Modern download manager built with Tauri 2. Built from source for
 loongarch64 / Deepin; the aria2-next sidecar is compiled from the
 same source tree.
EOF

dpkg-deb --build --root-owner-group "$STAGE" "$DEB"
echo "[06] package: $DEB"
dpkg-deb -I "$DEB" | head -20
echo "[06] OK"
