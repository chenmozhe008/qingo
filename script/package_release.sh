#!/usr/bin/env bash
# Builds the downloadable release: ad-hoc signed (no personal certificate name inside),
# debug symbols stripped (they carry the build machine's paths), zipped for GitHub Releases.
# Output: tmp/release/Qingo-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."

CODESIGN_IDENTITY=- ./script/build_and_run.sh --package
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/小清.app/Contents/Info.plist)
OUT=tmp/release
rm -rf "$OUT" && mkdir -p "$OUT"
ditto dist/小清.app "$OUT/小清.app"
strip -S -x "$OUT/小清.app/Contents/MacOS/Qingo" 2>/dev/null
codesign --force --sign - --identifier io.github.chenmozhe008.qingo "$OUT/小清.app"
codesign --verify --strict "$OUT/小清.app"

# Refuse to ship anything that names the build machine.
if strings -a "$OUT/小清.app/Contents/MacOS/Qingo" | grep -E "/Users/|Coding Project" >/dev/null; then
  echo "error: binary still contains local paths" >&2; exit 1
fi

ditto -c -k --sequesterRsrc --keepParent "$OUT/小清.app" "$OUT/Qingo-$VERSION.zip"
echo "$OUT/Qingo-$VERSION.zip"
