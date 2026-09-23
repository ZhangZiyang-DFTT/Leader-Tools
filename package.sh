#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
OUTPUT="${1:-$ROOT/dist/Leader_Tools_1.1.6.dmg}"
mkdir -p "$(dirname "$OUTPUT")"
if [ -e "$OUTPUT" ]; then
    printf 'Refusing to overwrite existing DMG: %s\n' "$OUTPUT" >&2
    exit 1
fi
STAGE=$(mktemp -d "$ROOT/build/DMG.XXXXXX")
ditto "build/Leader Tools.app" "$STAGE/Leader Tools.app"
ln -s /Applications "$STAGE/Applications"
cp Resources/Guide.html "$STAGE/Guide.html"
cp "build/Leader Tools.app/Contents/Resources/ThirdPartyNotices.txt" "$STAGE/ThirdPartyNotices.txt"
codesign --verify --deep --strict "$STAGE/Leader Tools.app"
hdiutil create -volname "Leader Tools" -srcfolder "$STAGE" -format UDZO \
    -fs HFS+ -imagekey zlib-level=9 "$OUTPUT"
hdiutil verify "$OUTPUT"
printf 'DMG: %s\n' "$OUTPUT"
