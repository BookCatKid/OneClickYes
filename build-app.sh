#!/bin/sh
# Build OneClickYes.app: installer app + payload dylib + test apps.
set -e
cd "$(dirname "$0")"
OUT="$PWD/OneClickYes.app"

# --- payload dylib (must have a slice for every arch in the domain:
#     dyld aborts the whole process if an inserted dylib has no matching
#     slice — arm64e for platform binaries, arm64e.x1 for x1-ABI apps like
#     Mail/Messages, x86_64 for Rosetta apps, arm64 for anything else)
clang -arch arm64 -arch arm64e -arch arm64e.x1 -arch x86_64 -dynamiclib \
  -o OneClickYes.dylib dylib/OneClickYes.m \
  -framework Foundation -framework AppKit
codesign -f -s - OneClickYes.dylib

# --- Gatekeeper test app (unsigned on purpose)
mkdir -p /tmp/gkbuild/OCYTest.app/Contents/MacOS
clang -arch arm64 -o /tmp/gkbuild/OCYTest.app/Contents/MacOS/OCYTest app/OCYTest-main.c
cp app/OCYTest-Info.plist /tmp/gkbuild/OCYTest.app/Contents/Info.plist
# no signature -> triggers "could not verify" dialog when quarantined

# --- TCC probe app (requests Accessibility, polls for grant)
mkdir -p /tmp/gkbuild/OCYProbe.app/Contents/MacOS
clang -arch arm64 -o /tmp/gkbuild/OCYProbe.app/Contents/MacOS/ocyprobe \
  app/OCYProbe-main.m -framework Cocoa -framework ApplicationServices
cp app/OCYProbe-Info.plist /tmp/gkbuild/OCYProbe.app/Contents/Info.plist
codesign -f -s - /tmp/gkbuild/OCYProbe.app

# --- installer app
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
clang -fobjc-arc -arch arm64 -o "$OUT/Contents/MacOS/OneClickYes" app/main.m \
  -framework Cocoa -framework ServiceManagement
cp app/Info.plist "$OUT/Contents/Info.plist"
cp OneClickYes.dylib "$OUT/Contents/Resources/"
cp -R /tmp/gkbuild/OCYTest.app "$OUT/Contents/Resources/"
cp -R /tmp/gkbuild/OCYProbe.app "$OUT/Contents/Resources/"

codesign -f -s - "$OUT/Contents/Resources/OCYTest.app"
codesign -f -s - "$OUT/Contents/Resources/OCYProbe.app"
codesign -f -s - "$OUT/Contents/Resources/OneClickYes.dylib"
codesign -f -s - "$OUT"

echo "built: $OUT"
