#!/usr/bin/env bash
# Refresh ccproxy credentials.
# Strategy:
#   1) Try a real OAuth refresh against Anthropic using the refresh_token from
#      ~/.claude/.credentials.json. On success, write the new tokens back to
#      both the credentials file AND the macOS keychain (so the Claude Code
#      app stays in sync), then exit.
#   2) Fallback: copy whatever token Claude Code wrote to the keychain.
#
# Why this matters: the previous version only did step 2, which means the
# token only got refreshed when the user actually opened Claude Code. With
# step 1, the launchd timer can keep tokens alive indefinitely on its own.

set -euo pipefail

CRED_FILE="$HOME/.claude/.credentials.json"
KEYCHAIN_SERVICE="Claude Code-credentials"
CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
TOKEN_URL="https://console.anthropic.com/v1/oauth/token"

if ! command -v jq >/dev/null 2>&1; then
    echo "[refresh-creds] jq is required (brew install jq)" >&2
    exit 1
fi

_print_expiry() {
    local exp_ms exp_s
    exp_ms=$(jq -r '.claudeAiOauth.expiresAt // empty' "$CRED_FILE" 2>/dev/null || true)
    if [ -n "$exp_ms" ] && [ "$exp_ms" != "null" ]; then
        exp_s=$((exp_ms / 1000))
        echo "[refresh-creds] expires: $(date -r "$exp_s")"
    fi
}

_copy_from_keychain() {
    if security find-generic-password -s "$KEYCHAIN_SERVICE" -w > "$CRED_FILE" 2>/dev/null; then
        chmod 600 "$CRED_FILE"
        echo "[refresh-creds] copied from keychain"
        return 0
    fi
    return 1
}

_write_keychain() {
    # Update keychain with current $CRED_FILE contents so Claude Code app sees
    # the same fresh tokens. -U updates if the entry already exists.
    if security add-generic-password -U \
        -s "$KEYCHAIN_SERVICE" \
        -a "$USER" \
        -w "$(cat "$CRED_FILE")" 2>/dev/null; then
        echo "[refresh-creds] keychain updated"
    else
        echo "[refresh-creds] keychain update skipped (no permission or entry missing)"
    fi
}

_refresh_via_oauth() {
    local refresh_token resp http_code body new_access new_refresh expires_in expires_at

    if [ ! -s "$CRED_FILE" ]; then
        echo "[refresh-creds] $CRED_FILE missing, can't OAuth refresh"
        return 1
    fi

    refresh_token=$(jq -r '.claudeAiOauth.refreshToken // empty' "$CRED_FILE")
    if [ -z "$refresh_token" ]; then
        echo "[refresh-creds] no refreshToken in $CRED_FILE"
        return 1
    fi

    # Single curl that prints body + a trailing line "HTTP_STATUS:NNN".
    resp=$(curl -sS -X POST "$TOKEN_URL" \
        -H 'Content-Type: application/json' \
        -d "$(jq -n --arg rt "$refresh_token" --arg cid "$CLIENT_ID" \
              '{grant_type:"refresh_token", refresh_token:$rt, client_id:$cid}')" \
        -w '\nHTTP_STATUS:%{http_code}' || true)

    http_code=$(printf '%s' "$resp" | tail -n1 | sed 's/^HTTP_STATUS://')
    body=$(printf '%s' "$resp" | sed '$d')

    if [ "$http_code" != "200" ]; then
        echo "[refresh-creds] OAuth refresh failed: HTTP $http_code: $body" >&2
        return 1
    fi

    new_access=$(printf '%s' "$body" | jq -r '.access_token // empty')
    new_refresh=$(printf '%s' "$body" | jq -r '.refresh_token // empty')
    expires_in=$(printf '%s' "$body" | jq -r '.expires_in // 0')

    if [ -z "$new_access" ]; then
        echo "[refresh-creds] OAuth response missing access_token: $body" >&2
        return 1
    fi

    expires_at=$(( ( $(date +%s) + expires_in ) * 1000 ))

    # Update .credentials.json in place, preserving the wrapper structure.
    local tmp
    tmp=$(mktemp)
    jq --arg at "$new_access" \
       --arg rt "${new_refresh:-$refresh_token}" \
       --argjson eat "$expires_at" \
       '.claudeAiOauth.accessToken = $at
        | .claudeAiOauth.refreshToken = $rt
        | .claudeAiOauth.expiresAt = $eat' \
       "$CRED_FILE" > "$tmp" && mv "$tmp" "$CRED_FILE"
    chmod 600 "$CRED_FILE"

    _write_keychain
    echo "[refresh-creds] OAuth refresh OK"
    return 0
}

if _refresh_via_oauth; then
    _print_expiry
    exit 0
fi

echo "[refresh-creds] falling back to keychain copy..."
if _copy_from_keychain; then
    _print_expiry
    exit 0
fi

echo "[refresh-creds] BOTH OAuth refresh AND keychain copy failed" >&2
echo "[refresh-creds] Open the Claude Code app and send a message to re-auth, then re-run." >&2
exit 1
