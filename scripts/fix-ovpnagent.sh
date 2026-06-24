#!/bin/bash
# Verifies ovpnagent is running and restores it if crashed/stuck

PLIST="/Library/LaunchDaemons/org.openvpn.client.plist"
SOCKET="/var/run/agent_ovpnconnect.sock"

if pgrep -x ovpnagent > /dev/null && [ -S "$SOCKET" ]; then
    echo "ovpnagent is running and socket is present — nothing to do."
    exit 0
fi

echo "ovpnagent is down. Restarting..."

plutil -remove Crashed "$PLIST" 2>/dev/null
launchctl unload "$PLIST" 2>/dev/null
launchctl load "$PLIST"

sleep 2

if [ -S "$SOCKET" ]; then
    echo "Done — socket restored at $SOCKET"
else
    echo "ERROR: socket still missing after restart. Check: sudo cat /var/log/ovpnagent.log"
    exit 1
fi
