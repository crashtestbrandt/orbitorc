#!/usr/bin/env bash
# Install the OrbitOrc agent into this Mac's graphical login session.
#
# A LaunchAgent, not a LaunchDaemon. A daemon runs in the System domain and can never present a window:
# a rendering job launched from one draws nothing and reports success. A LaunchAgent runs in the Aqua
# session of the logged-in user, which is what `launchctl managername` answers "Aqua" for and what the
# agent's session check looks for.
#
#   install/macos-install.sh /path/to/orbitorc_agent   # a release directory, from `mix release orbitorc_agent`
set -euo pipefail

RELEASE="${1:?usage: macos-install.sh <release directory>}"
RELEASE="$(cd "$RELEASE" && pwd)"
BIN="$RELEASE/bin/orbitorc_agent"
[ -x "$BIN" ] || { echo "no executable at $BIN" >&2; exit 1; }

CONFIG_DIR="$HOME/Library/Application Support/orbitorc"
mkdir -p "$CONFIG_DIR"
[ -f "$CONFIG_DIR/config.json" ] || { echo "write $CONFIG_DIR/config.json first (see install/config.example.json)" >&2; exit 1; }

PLIST="$HOME/Library/LaunchAgents/net.orbitorc.agent.plist"
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>net.orbitorc.agent</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string><string>start</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$CONFIG_DIR/agent.out.log</string>
  <key>StandardErrorPath</key><string>$CONFIG_DIR/agent.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>LANG</key><string>en_US.UTF-8</string>
  </dict>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/net.orbitorc.agent" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/net.orbitorc.agent"
echo "installed: $PLIST"
echo "logs:      $CONFIG_DIR/agent.err.log"
echo "The agent will appear in the fleet within a few seconds if the control plane is reachable."
