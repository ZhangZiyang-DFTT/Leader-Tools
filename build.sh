#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
python3 Tools/generate-third-party-notices.py --check
mkdir -p build "build/Leader Tools.app/Contents/MacOS" "build/Leader Tools.app/Contents/Resources"
if [ "$(uname -m)" != "arm64" ]; then
    printf 'This build requires an Apple Silicon Mac and Xcode Command Line Tools.\n' >&2
    exit 1
fi
swiftc -O -target arm64-apple-macosx13.0 -module-cache-path build/ModuleCache \
    Tools/make-icon.swift -o build/make-icon
ICONSET="build/AppIcon.generated.iconset"
build/make-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
clang -O3 -mmacosx-version-min=13.0 -I Vendor/include -I Sources/CLeader/include \
    -c Sources/CLeader/LeaderTIFF.c -o build/LeaderTIFF.o
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macosx13.0 \
    -module-cache-path build/ModuleCache -I Sources/CLeader/include \
    Sources/LeaderTools/*.swift build/LeaderTIFF.o Vendor/lib/libtiff.a -lz \
    -framework AppKit -framework SwiftUI -framework CoreText -framework ImageIO \
    -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework AudioToolbox \
    -o "build/Leader Tools.app/Contents/MacOS/LeaderTools"
cp Resources/Info.plist "build/Leader Tools.app/Contents/Info.plist"
cp Resources/Guide.html "build/Leader Tools.app/Contents/Resources/Guide.html"
cp Resources/ThirdPartyNotices.txt "build/Leader Tools.app/Contents/Resources/ThirdPartyNotices.txt"
cp Resources/LeaderTools_Resolve_Full_ProRes_Q10.dctl Resources/Resolve_Full_Readme.txt "build/Leader Tools.app/Contents/Resources/"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "build/Leader Tools.app/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - --timestamp=none "build/Leader Tools.app"
printf 'Built: %s/build/Leader Tools.app\n' "$PWD"
