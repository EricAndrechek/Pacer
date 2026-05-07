#!/bin/bash
# Emit the dev-mode LaunchAgent plist to stdout. Hard-codes the
# absolute Program path because launchd does not expand variables
# inside plist values, and SMAppService's BundleProgram approach
# requires registering through the SMAppService API (which gates on
# System Settings approval — not what we want for a dev iteration
# loop).
#
# Distinct label from the bundled plist (.dev suffix) so a developer
# who has BOTH this dev plist AND clicked "Register" in the Debug tab
# doesn't end up with two daemons racing.
#
# Output goes to stdout so the caller can pipe it (`> ~/Library/...`).
# Reads $HOME for log paths; everything else is a literal.
set -euo pipefail

cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ericandrechek.pacer.daemon.dev</string>

    <key>Program</key>
    <string>/Applications/Pacer.app/Contents/Library/LaunchServices/PacerDaemon</string>

    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Background</string>

    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/Pacer/PacerDaemon.err.log</string>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/Pacer/PacerDaemon.out.log</string>
</dict>
</plist>
EOF
