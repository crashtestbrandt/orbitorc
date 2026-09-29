#!/usr/bin/env bash
# Install the OrbitOrc agent into this user's graphical session on Linux.
#
# A systemd USER unit bound to graphical-session.target, not a system service. A system service has no
# DISPLAY and no WAYLAND_DISPLAY: a rendering job launched from one draws nothing and reports success.
# A user unit started with the session inherits the display, which is what the agent's session check
# looks for.
#
#   install/linux-install.sh /path/to/orbitorc_agent   # a release directory, from `mix release orbitorc_agent`
#
# For a box with no display at all (a headless server that only ever runs an authority or a build), a
# system service is fine: the agent reports "headless modes only" and refuses the rendering ones.
set -euo pipefail

RELEASE="${1:?usage: linux-install.sh <release directory>}"
RELEASE="$(cd "$RELEASE" && pwd)"
BIN="$RELEASE/bin/orbitorc_agent"
[ -x "$BIN" ] || { echo "no executable at $BIN" >&2; exit 1; }

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/orbitorc"
mkdir -p "$CONFIG_DIR"
[ -f "$CONFIG_DIR/config.json" ] || { echo "write $CONFIG_DIR/config.json first (see install/config.example.json)" >&2; exit 1; }

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$UNIT_DIR"
cat > "$UNIT_DIR/orbitorc-agent.service" <<EOF
[Unit]
Description=OrbitOrc agent
After=graphical-session.target
PartOf=graphical-session.target

[Service]
ExecStart=$BIN start
Restart=always
RestartSec=5
Environment=LANG=en_US.UTF-8

[Install]
WantedBy=graphical-session.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now orbitorc-agent.service
echo "installed: $UNIT_DIR/orbitorc-agent.service"
echo "logs:      journalctl --user -u orbitorc-agent -f"
echo "If this box should serve while nobody is logged in, run: loginctl enable-linger $USER"
