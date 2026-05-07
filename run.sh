#!/usr/bin/env bash
# Run ccproxy in background. Survives terminal close.
# Usage:
#   ./run.sh start | stop | restart | status | logs

set -euo pipefail

cd "$(dirname "$0")"

PORT="${CCPROXY_PORT:-18080}"
PID_FILE="/tmp/ccproxy.pid"
LOG_FILE="/tmp/ccproxy.log"

export NO_PROXY="127.0.0.1,localhost"
export no_proxy="127.0.0.1,localhost"
export PATH="/usr/local/Caskroom/miniconda/base/bin:/usr/local/Caskroom/miniconda/base/envs/EvoSci/bin:$HOME/.local/bin:$PATH"

_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

# Kill anything else listening on $PORT so bind doesn't fail.
# Common culprits: stale EvoSci process (*:8080), a previous ccproxy without PID_FILE.
_clear_port() {
    local pids pid cmd
    pids=$(lsof -tiTCP:"$PORT" -sTCP:LISTEN -nP 2>/dev/null || true)
    [ -z "$pids" ] && return 0

    for pid in $pids; do
        cmd=$(ps -p "$pid" -o command= 2>/dev/null || echo "?")
        echo "[ccproxy] clearing port $PORT: killing pid=$pid ($(echo "$cmd" | cut -c1-80))"
        kill "$pid" 2>/dev/null || true
    done

    # Wait up to 5s for port release
    for _ in 1 2 3 4 5; do
        sleep 1
        if ! lsof -tiTCP:"$PORT" -sTCP:LISTEN -nP >/dev/null 2>&1; then
            return 0
        fi
    done

    # Still there — force kill
    pids=$(lsof -tiTCP:"$PORT" -sTCP:LISTEN -nP 2>/dev/null || true)
    for pid in $pids; do
        echo "[ccproxy] force-killing pid=$pid on port $PORT"
        kill -9 "$pid" 2>/dev/null || true
    done
    sleep 1
}

start() {
    if _running; then
        echo "[ccproxy] already running (pid $(cat "$PID_FILE"))"
        return 0
    fi
    _clear_port
    echo "[ccproxy] starting on port $PORT..."
    nohup ccproxy serve --port "$PORT" > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    # ccproxy can take 50-60s on first start because it runs Claude/Codex
    # CLI detection (bunx/uvx pulls deps). Wait up to 90s.
    for i in $(seq 1 90); do
        if curl -sf --noproxy '*' "http://localhost:$PORT/health" >/dev/null 2>&1; then
            echo "[ccproxy] ready (pid $(cat "$PID_FILE")), log: $LOG_FILE"
            return 0
        fi
        # If the process died, fail fast instead of waiting the full 90s.
        if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            echo "[ccproxy] process exited prematurely, check $LOG_FILE"
            rm -f "$PID_FILE"
            return 1
        fi
        sleep 1
    done
    echo "[ccproxy] still not ready after 90s — likely still in CLI-detection startup;"
    echo "[ccproxy] check $LOG_FILE for 'server_ready' or run: curl http://localhost:$PORT/health"
    return 1
}

stop() {
    if _running; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -f "$PID_FILE"
        echo "[ccproxy] stopped (from PID_FILE)"
    else
        rm -f "$PID_FILE"
        # Fallback: also clear any stray listener on the port
        if lsof -tiTCP:"$PORT" -sTCP:LISTEN -nP >/dev/null 2>&1; then
            echo "[ccproxy] PID_FILE missing but port $PORT still in use, clearing..."
            _clear_port
        else
            echo "[ccproxy] not running"
        fi
    fi
}

status() {
    if _running; then
        echo "[ccproxy] running (pid $(cat "$PID_FILE"), port $PORT)"
    else
        echo "[ccproxy] not running"
    fi
}

case "${1:-start}" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 1; start ;;
    status)  status ;;
    logs)    tail -f "$LOG_FILE" ;;
    *)       echo "Usage: $0 {start|stop|restart|status|logs}"; exit 1 ;;
esac
