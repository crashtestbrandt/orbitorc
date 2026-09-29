#!/usr/bin/env bash
# Install the OrbitOrc control plane on this Mac, as a LaunchAgent that outlives any terminal.
#
#   install/macos-control-plane.sh /path/to/orbitorc   # a release directory, from `mix release orbitorc`
#                                                      # or the orbitorc-<os>-<arch> archive of a release
#
# Its environment lives in ~/Library/Application Support/orbitorc/control-plane.env, one KEY=value per
# line; write ORBITORC_AGENT_TOKENS (name=token,...) and PHX_HOST (the address the dashboard is opened
# at) there first. SECRET_KEY_BASE is generated on first install and kept. The database lives beside it.
#
# THE FILE LIMIT IS RAISED. launchd starts a process with 256 open files; a control plane with a fleet
# on WebSockets, a dashboard, and a database exhausts that and answers nothing.
set -euo pipefail

RELEASE="${1:?usage: macos-control-plane.sh <release directory>}"
RELEASE="$(cd "$RELEASE" && pwd)"
BIN="$RELEASE/bin/orbitorc"
[ -x "$BIN" ] || { echo "no executable at $BIN" >&2; exit 1; }

CONFIG_DIR="$HOME/Library/Application Support/orbitorc"
ENV_FILE="$CONFIG_DIR/control-plane.env"
mkdir -p "$CONFIG_DIR"
[ -f "$ENV_FILE" ] || { echo "write $ENV_FILE first: ORBITORC_AGENT_TOKENS=name=token,... and PHX_HOST=<address the dashboard is opened at>" >&2; exit 1; }
grep -q '^ORBITORC_AGENT_TOKENS=' "$ENV_FILE" || { echo "$ENV_FILE needs ORBITORC_AGENT_TOKENS=name=token,..." >&2; exit 1; }
grep -q '^SECRET_KEY_BASE=' "$ENV_FILE" || { echo "SECRET_KEY_BASE=$(openssl rand -base64 64 | tr -d '\n')" >> "$ENV_FILE"; echo "generated SECRET_KEY_BASE into $ENV_FILE"; }
grep -q '^DATABASE_PATH=' "$ENV_FILE" || echo "DATABASE_PATH=$CONFIG_DIR/control-plane.db" >> "$ENV_FILE"
grep -q '^PORT=' "$ENV_FILE" || echo "PORT=4000" >> "$ENV_FILE"
grep -q '^PHX_HOST=' "$ENV_FILE" || echo "PHX_HOST=localhost" >> "$ENV_FILE"
chmod 600 "$ENV_FILE"

# The env file becomes the plist's environment, each value XML-escaped.
env_xml="$(while IFS='=' read -r key value; do
	[ -n "$key" ] && [ "${key#\#}" = "$key" ] || continue
	value="${value//&/&amp;}"; value="${value//</&lt;}"; value="${value//>/&gt;}"
	printf '    <key>%s</key><string>%s</string>\n' "$key" "$value"
done < "$ENV_FILE")"

PLIST="$HOME/Library/LaunchAgents/net.orbitorc.control-plane.plist"
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>net.orbitorc.control-plane</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string><string>start</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$CONFIG_DIR/control-plane.out.log</string>
  <key>StandardErrorPath</key><string>$CONFIG_DIR/control-plane.err.log</string>
  <key>SoftResourceLimits</key><dict><key>NumberOfFiles</key><integer>32768</integer></dict>
  <key>HardResourceLimits</key><dict><key>NumberOfFiles</key><integer>32768</integer></dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>LANG</key><string>en_US.UTF-8</string>
$env_xml
  </dict>
</dict>
</plist>
PLIST_EOF
chmod 600 "$PLIST"
plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/$(id -u)/net.orbitorc.control-plane" 2>/dev/null || true
sleep 2
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/net.orbitorc.control-plane"
echo "installed: $PLIST"
echo "env:       $ENV_FILE"
echo "logs:      $CONFIG_DIR/control-plane.err.log"
echo "The dashboard is at http://$(grep '^PHX_HOST=' "$ENV_FILE" | cut -d= -f2):$(grep '^PORT=' "$ENV_FILE" | cut -d= -f2) once it is up; agents dial ws://<that>/agent/websocket."
