#!/bin/sh
# Remove GKOpenAnyway injection and restart the agent clean.
launchctl unsetenv DYLD_INSERT_LIBRARIES
# A service's inherited env is a snapshot — deleting the dylib file is what
# actually disables the insert on respawn.
rm -rf "$HOME/Library/Application Support/GKOpenAnyway"
launchctl kickstart -k "gui/$(id -u)/com.apple.coreservices.uiagent"
# Also remove the login-time persistence item if installed.
launchctl bootout "gui/$(id -u)/local.gkopenanyway" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/local.gkopenanyway.plist"
echo "removed"
