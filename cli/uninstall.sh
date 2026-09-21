#!/bin/sh
# Remove OneClickYes injection and restart the agent clean.
launchctl unsetenv DYLD_INSERT_LIBRARIES
# A service's inherited env is a snapshot — deleting the dylib file is what
# actually disables the insert on respawn.
rm -rf "$HOME/Library/Application Support/OneClickYes"
rm -rf "$HOME/Library/Application Support/GKOpenAnyway"   # legacy name
launchctl kickstart -k "gui/$(id -u)/com.apple.coreservices.uiagent"
# Also remove the login-time persistence items if installed.
launchctl bootout "gui/$(id -u)/local.oneclickyes" 2>/dev/null
launchctl bootout "gui/$(id -u)/local.gkopenanyway" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/local.oneclickyes.plist"
rm -f "$HOME/Library/LaunchAgents/local.gkopenanyway.plist"
echo "removed"
