#!/bin/bash
# Stop and remove the tactiond LaunchAgent and its files. Keeps config.json unless --purge is given.
set -euo pipefail

LABEL="org.jorj.tactiond"
DEST="$HOME/Library/Application Support/Taction"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "agent stopped" || echo "agent was not running"
rm -f "$PLIST" && echo "removed $PLIST"
rm -rf "$DEST/bin" "$DEST/status.json" "$DEST/calibrating.lock"
rm -f "$HOME/Library/Logs/tactiond.out.log" "$HOME/Library/Logs/tactiond.err.log"
if [ "${1:-}" = "--purge" ]; then
    rm -rf "$DEST"
    echo "removed $DEST including config.json"
else
    echo "kept $DEST/config.json (use --purge to remove)"
fi
echo "Privacy grants for org.jorj.tactiond remain in System Settings > Privacy & Security; remove them there or with:"
echo "  tccutil reset Accessibility org.jorj.tactiond; tccutil reset ListenEvent org.jorj.tactiond"
