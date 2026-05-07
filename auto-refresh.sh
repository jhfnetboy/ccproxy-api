#!/usr/bin/env bash
# Auto-refresh Claude OAuth credentials and keep ccproxy alive.
# Run once to install as launchd job (survives reboots, no cron needed).
# Usage:
#   ./auto-refresh.sh install   — install launchd agent (runs every 4h)
#   ./auto-refresh.sh uninstall — remove launchd agent
#   ./auto-refresh.sh run       — refresh now (called by launchd)
#   ./auto-refresh.sh status    — show launchd status

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
PLIST="$HOME/Library/LaunchAgents/com.jhf.ccproxy-refresh.plist"
LOG="/tmp/ccproxy-refresh.log"

REFRESH_SCRIPT="$(cd "$(dirname "$0")" && pwd)/refresh-creds.sh"
RUN_SCRIPT="$(cd "$(dirname "$0")" && pwd)/run.sh"

export PATH="/usr/local/Caskroom/miniconda/base/bin:/usr/local/Caskroom/miniconda/base/envs/EvoSci/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

_refresh_and_restart() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] refreshing credentials..."
    if bash "$REFRESH_SCRIPT"; then
        # Only restart if ccproxy is NOT already running; just refresh creds otherwise.
        # Unconditional restart causes 90s timeout failures in the launchd environment.
        if bash "$RUN_SCRIPT" status 2>/dev/null | grep -q "running"; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] credentials ok, ccproxy already running — no restart needed"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] credentials ok, ccproxy not running — starting..."
            bash "$RUN_SCRIPT" start || true
        fi
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] done"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: credential refresh failed" >&2
        exit 1
    fi
}

install_launchd() {
    mkdir -p "$(dirname "$PLIST")"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.jhf.ccproxy-refresh</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT</string>
        <string>run</string>
    </array>
    <key>StartInterval</key>
    <integer>14400</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/Caskroom/miniconda/base/bin:/usr/local/Caskroom/miniconda/base/envs/EvoSci/bin:/Users/jason/.local/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>/Users/jason</string>
    </dict>
</dict>
</plist>
EOF
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load -w "$PLIST"
    echo "[auto-refresh] installed launchd agent (every 4h), log: $LOG"
    echo "[auto-refresh] running once now..."
    _refresh_and_restart
}

uninstall_launchd() {
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "[auto-refresh] launchd agent removed"
}

status_launchd() {
    if launchctl list | grep -q "com.jhf.ccproxy-refresh"; then
        echo "[auto-refresh] launchd agent is loaded"
        echo "last log:"
        tail -5 "$LOG" 2>/dev/null || echo "(no log yet)"
    else
        echo "[auto-refresh] launchd agent is NOT loaded"
    fi
}

case "${1:-install}" in
    install)   install_launchd ;;
    uninstall) uninstall_launchd ;;
    run)       _refresh_and_restart ;;
    status)    status_launchd ;;
    *)         echo "Usage: $0 {install|uninstall|run|status}"; exit 1 ;;
esac
