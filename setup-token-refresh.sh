#!/usr/bin/env bash
# setup-token-refresh.sh
# 一键完成：刷新 Claude OAuth token + 安装/更新 launchd plist + 重启 ccproxy
#
# 用法:
#   ./setup-token-refresh.sh          # 完整安装（首次或重装）
#   ./setup-token-refresh.sh refresh  # 仅刷新 token + 重启 ccproxy（不重装 plist）
#   ./setup-token-refresh.sh status   # 查看 plist 状态和 token 剩余时间

set -euo pipefail

CCPROXY="$HOME/.local/bin/ccproxy"
CREDS="$HOME/.claude/.credentials.json"
REFRESH_SCRIPT="$HOME/.local/bin/ccproxy-refresh-token.sh"
PLIST_LABEL="com.evoscientist.ccproxy-refresh"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
LOG="/tmp/ccproxy-token-refresh.log"
PORT=18080

# ── helpers ──────────────────────────────────────────────────────────────────

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
logf() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

die() { echo "ERROR: $*" >&2; exit 1; }

# ── step: refresh token ───────────────────────────────────────────────────────

do_refresh_token() {
    log "刷新 Claude OAuth token..."
    logf "=== token refresh start ==="

    # 1) 通过 Anthropic OAuth 刷新
    if "$CCPROXY" auth refresh claude_api >> "$LOG" 2>&1; then
        logf "ccproxy auth refresh succeeded"
        log "  ✓ Anthropic OAuth 刷新成功"
    else
        logf "ccproxy auth refresh failed — syncing existing keychain token"
        log "  ⚠ OAuth 刷新失败（限流/已过期），将同步 keychain 现有 token"
    fi

    # 2) 把 keychain 最新 token 写到 .credentials.json
    if NEW_RAW=$(security find-generic-password \
            -s "Claude Code-credentials" -a "$(id -un)" -w 2>/dev/null); then
        python3 - <<'PYEOF' "$NEW_RAW" "$CREDS"
import sys, json, pathlib
raw, dest_path = sys.argv[1], pathlib.Path(sys.argv[2])
dest_path.parent.mkdir(parents=True, exist_ok=True)
d = json.loads(raw)
if "claudeAiOauth" in d:
    creds = {"claude_ai_oauth": d["claudeAiOauth"]}
elif "claude_ai_oauth" in d:
    creds = d
else:
    print("ERROR: unrecognized keychain format", file=sys.stderr); sys.exit(1)
dest_path.write_text(json.dumps(creds, indent=2))
PYEOF
        logf "synced keychain → $CREDS"
        log "  ✓ token 已写入 $CREDS"
    else
        log "  ✗ keychain 读取失败，保留现有文件"
        logf "WARNING: keychain read failed"
    fi

    logf "=== token refresh done ==="
}

# ── step: restart ccproxy ─────────────────────────────────────────────────────

do_restart_ccproxy() {
    log "重启 ccproxy..."
    pkill -f "ccproxy serve" 2>/dev/null || true
    sleep 1
    nohup "$CCPROXY" serve --port "$PORT" >> "$LOG" 2>&1 &
    local pid=$!

    # 等待健康检查通过（最多 25s，ccproxy 冷启动约 8s）
    local i=0
    while (( i < 25 )); do
        if curl -s "http://127.0.0.1:${PORT}/health/live" > /dev/null 2>&1; then
            log "  ✓ ccproxy 已启动 (pid $pid, port $PORT)"
            return 0
        fi
        sleep 1; (( i++ ))
    done
    log "  ✗ ccproxy 启动超时，请检查 $LOG"
    return 1
}

# ── step: install plist ───────────────────────────────────────────────────────

do_install_plist() {
    log "安装 launchd plist..."

    # 写刷新脚本到 ~/.local/bin/
    mkdir -p "$(dirname "$REFRESH_SCRIPT")"
    cat > "$REFRESH_SCRIPT" <<'SCRIPT'
#!/usr/bin/env bash
# 由 launchd 每 7.5 小时自动调用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$(dirname "$0")/setup-token-refresh.sh" refresh 2>&1
SCRIPT

    # 指向本脚本（相对路径替换为绝对路径）
    THIS_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    cat > "$REFRESH_SCRIPT" <<SCRIPT
#!/usr/bin/env bash
# 由 launchd (${PLIST_LABEL}) 每 7.5 小时自动调用
"${THIS_SCRIPT}" refresh >> "$LOG" 2>&1
SCRIPT
    chmod +x "$REFRESH_SCRIPT"
    log "  ✓ 刷新脚本: $REFRESH_SCRIPT"

    # 卸载旧 plist（若存在）
    if launchctl list "$PLIST_LABEL" > /dev/null 2>&1; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        log "  旧 plist 已卸载"
    fi

    # 写 plist
    cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${REFRESH_SCRIPT}</string>
    </array>

    <!-- 每 27000 秒 = 7.5 小时 -->
    <key>StartInterval</key>
    <integer>27000</integer>

    <!-- 登录后立即运行一次 -->
    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>${LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LOG}</string>

    <key>ThrottleInterval</key>
    <integer>60</integer>
</dict>
</plist>
PLIST

    # 加载
    launchctl load "$PLIST_PATH"
    log "  ✓ plist 已加载: $PLIST_PATH"
    log "  ✓ 每 7.5 小时自动刷新 token + 重启 ccproxy"
}

# ── step: status ──────────────────────────────────────────────────────────────

do_status() {
    echo "──────────────────────────────────────"
    echo " ccproxy-token-refresh 状态"
    echo "──────────────────────────────────────"

    # plist 状态
    if launchctl list "$PLIST_LABEL" > /dev/null 2>&1; then
        echo "  plist:   ✓ 已加载 ($PLIST_LABEL)"
    else
        echo "  plist:   ✗ 未加载"
    fi

    # ccproxy 状态
    if curl -s "http://127.0.0.1:${PORT}/health/live" > /dev/null 2>&1; then
        echo "  ccproxy: ✓ 运行中 (port $PORT)"
    else
        echo "  ccproxy: ✗ 未运行"
    fi

    # token 剩余时间
    if [[ -f "$CREDS" ]]; then
        python3 - <<'PYEOF' "$CREDS"
import sys, json, time, pathlib
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
oauth = d.get("claude_ai_oauth", {})
exp_ms = oauth.get("expiresAt", 0)
if exp_ms:
    remaining = exp_ms / 1000 - time.time()
    if remaining > 0:
        h, m = divmod(int(remaining), 3600)
        m //= 60
        print(f"  token:   ✓ 有效，剩余 {h}h {m}m")
    else:
        print(f"  token:   ✗ 已过期 {int(-remaining/60)} 分钟前")
else:
    print("  token:   ? 无法读取过期时间")
PYEOF
    else
        echo "  token:   ✗ $CREDS 不存在"
    fi

    echo ""
    echo "  日志: tail -20 $LOG"
    echo "  手动刷新: launchctl start $PLIST_LABEL"
    echo "──────────────────────────────────────"
}

# ── main ──────────────────────────────────────────────────────────────────────

CMD="${1:-install}"

case "$CMD" in
    install)
        log "=== 完整安装 ==="
        do_refresh_token
        do_restart_ccproxy
        do_install_plist
        echo ""
        do_status
        ;;
    refresh)
        do_refresh_token
        do_restart_ccproxy
        ;;
    status)
        do_status
        ;;
    *)
        echo "用法: $0 [install|refresh|status]"
        exit 1
        ;;
esac
