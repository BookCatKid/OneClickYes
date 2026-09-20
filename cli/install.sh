#!/bin/sh
# Install GKOpenAnyway into CoreServicesUIAgent for the current GUI session.
# Requires SIP disabled. Takes effect for launchd-spawned processes created
# after this runs; the dylib self-gates to CoreServicesUIAgent only.
DYLIB="$(cd "$(dirname "$0")/.." && pwd)/GKOpenAnyway.dylib"
[ -f "$DYLIB" ] || { echo "dylib not found: $DYLIB"; exit 1; }
launchctl setenv DYLD_INSERT_LIBRARIES "$DYLIB"
launchctl kickstart -k "gui/$(id -u)/com.apple.coreservices.uiagent"
echo "installed: $DYLIB"
