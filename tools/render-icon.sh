#!/bin/bash
# Renders assets/AppIcon.iconset from the SVG masters with headless Chrome
# (they use gradients and a drop shadow). Sizes up to 32 px use the simplified
# assets/icon-small.svg. Run after editing the SVGs and commit the PNGs: the
# build only needs iconutil, not Chrome.
#
# Usage: tools/render-icon.sh
#   CHROME overrides the browser binary.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
CHROME=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
FULL=$REPO_DIR/assets/icon.svg
SMALL=$REPO_DIR/assets/icon-small.svg
ICONSET=$REPO_DIR/assets/AppIcon.iconset
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# render <svg> <size> <name>: Chrome does not make windows that small, so the
# icon is drawn in the middle of a fixed canvas and cropped out (sips crops
# around the center).
render() {
  cat > "$WORK/page.html" <<EOF
<!doctype html><html><body style="margin:0;background:transparent;height:100vh;
display:flex;align-items:center;justify-content:center">
<img src="file://$1" width="$2" height="$2" style="display:block">
</body></html>
EOF
  rm -f "$WORK/shot.png"
  # Own profile, so it never waits on the lock of a running Chrome.
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run \
    --user-data-dir="$WORK/profile" --virtual-time-budget=2000 \
    --default-background-color=00000000 --window-size=1024,1024 \
    --screenshot="$WORK/shot.png" "file://$WORK/page.html" >/dev/null 2>&1 &
  local chrome=$!
  for _ in $(seq 60); do  # give it 30 s, then kill a hung Chrome
    kill -0 "$chrome" 2>/dev/null || break
    sleep 0.5
  done
  kill -9 "$chrome" 2>/dev/null || true
  wait "$chrome" 2>/dev/null || true
  [ -f "$WORK/shot.png" ] || { echo "Chrome did not render $3"; exit 1; }
  sips --cropToHeightWidth "$2" "$2" "$WORK/shot.png" --out "$ICONSET/$3" >/dev/null
  echo "$3"
}

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
render "$SMALL" 16 icon_16x16.png
render "$SMALL" 32 icon_16x16@2x.png
render "$SMALL" 32 icon_32x32.png
render "$FULL" 64 icon_32x32@2x.png
render "$FULL" 128 icon_128x128.png
render "$FULL" 256 icon_128x128@2x.png
render "$FULL" 256 icon_256x256.png
render "$FULL" 512 icon_256x256@2x.png
render "$FULL" 512 icon_512x512.png
render "$FULL" 1024 icon_512x512@2x.png
