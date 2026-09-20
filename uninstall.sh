#!/bin/sh
# Remove GKOpenAnyway injection and restart the agent clean.
launchctl unsetenv DYLD_INSERT_LIBRARIES
launchctl kickstart -k "gui/$(id -u)/com.apple.coreservices.uiagent"
# Also remove the login-time persistence item if installed.
rm -f "$HOME/Library/LaunchAgents/local.gkopenanyway.plist"
echo "removed"
