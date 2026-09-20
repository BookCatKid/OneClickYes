#!/bin/sh
# Build GKOpenAnyway.app: installer app + payload dylib + test app.
set -e
cd "$(dirname "$0")"
OUT="$PWD/GKOpenAnyway.app"

# --- payload dylib (must have a slice for every arch in the domain:
#     dyld aborts the whole process if an inserted dylib has no matching
#     slice — arm64e for platform binaries, arm64e.x1 for x1-ABI apps like
#     Mail/Messages, x86_64 for Rosetta apps, arm64 for anything else)
clang -arch arm64 -arch arm64e -arch arm64e.x1 -arch x86_64 -dynamiclib \
  -o GKOpenAnyway.dylib dylib/GKOpenAnyway.m \
  -framework Foundation -framework AppKit
codesign -f -s - GKOpenAnyway.dylib

# --- test app (unsigned on purpose)
mkdir -p /tmp/gkbuild/GKTest.app/Contents/MacOS
clang -arch arm64 -o /tmp/gkbuild/GKTest.app/Contents/MacOS/GKTest app/GKTest-main.c
cp app/GKTest-Info.plist /tmp/gkbuild/GKTest.app/Contents/Info.plist
# no signature -> triggers "could not verify" dialog when quarantined

# --- installer app
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
clang -fobjc-arc -arch arm64 -o "$OUT/Contents/MacOS/GKOpenAnyway" app/main.m \
  -framework Cocoa -framework ServiceManagement
cp app/Info.plist "$OUT/Contents/Info.plist"
cp GKOpenAnyway.dylib "$OUT/Contents/Resources/"
cp -R /tmp/gkbuild/GKTest.app "$OUT/Contents/Resources/"

codesign -f -s - "$OUT/Contents/Resources/GKTest.app"
codesign -f -s - "$OUT/Contents/Resources/GKOpenAnyway.dylib"
codesign -f -s - "$OUT"

echo "built: $OUT"
