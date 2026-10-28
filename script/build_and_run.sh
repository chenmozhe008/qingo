#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="小清"
EXECUTABLE_NAME="Qingo"
BUNDLE_ID="io.github.chenmozhe008.qingo"
MIN_SYSTEM_VERSION="14.0"
APP_VERSION="1.10.0"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Apple Development}"
# Without that certificate (e.g. a fresh clone), fall back to ad-hoc signing so the build still runs locally.
if [[ "$CODESIGN_IDENTITY" != "-" ]] && ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$CODESIGN_IDENTITY"; then
  CODESIGN_IDENTITY="-"
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
APP_BINARY="$APP_MACOS/$EXECUTABLE_NAME"

cd "$ROOT_DIR"
# Release build: the debug build is several times slower and made long lists stutter while scrolling.
swift build -c release
BUILD_BINARY="$(swift build -c release --show-bin-path)/$EXECUTABLE_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
if [[ ! -f "$ROOT_DIR/Resources/AppIcon.icns" || "$ROOT_DIR/Resources/AppIcon-source.png" -nt "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  "$ROOT_DIR/script/build_icon.sh"
fi
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$ROOT_DIR/Resources/AppIcon-source.png" "$APP_BUNDLE/Contents/Resources/AppIcon-source.png"
cp "$ROOT_DIR/CHANGELOG.md" "$APP_BUNDLE/Contents/Resources/CHANGELOG.md"
BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"

cat >"$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>NSHumanReadableCopyright</key><string>小清 Qingo，作者 @沉默者之二，MIT 开源</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# A stable signing identity lets macOS recognize updated builds as the same app.
# Ad-hoc signatures change with the binary and can cause repeated privacy prompts.
codesign --force --sign "$CODESIGN_IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"

open_app() {
  pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  --package|package) ;;
  run) open_app ;;
  --debug|debug) lldb -- "$APP_BINARY" ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$EXECUTABLE_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--package|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
