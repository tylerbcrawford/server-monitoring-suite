#!/bin/bash
# Resource Threshold Alerting — posts to Discord when system resources exceed thresholds
# Runs every 15 minutes via cron

COOLDOWN_DIR="${STATE_DIR:-$HOME/.local/state/server-monitoring-suite}/resource-alert-cooldown"
COOLDOWN_SECONDS=14400  # 4 hours per issue
SWAP_THRESHOLD="${SWAP_THRESHOLD:-80}"           # percent
DISK_THRESHOLD="${DISK_THRESHOLD:-85}"           # percent
DOCKER_RECLAIM_GB="${DOCKER_RECLAIM_GB:-50}"     # GB
ENV_FILE="${ENV_FILE:-$(dirname "$0")/.env}"
BRANDING_FILE="${BRANDING_FILE:-$(dirname "$0")/branding.sh}"

# Optional custom notifier: NOTIFY_COMMAND from the environment or $ENV_FILE
# (when set, it replaces the webhook; see README "Custom notifier hook")
if [[ -z "${NOTIFY_COMMAND:-}" && -f "$ENV_FILE" ]]; then
    NOTIFY_COMMAND=$(grep -m1 '^NOTIFY_COMMAND=' "$ENV_FILE" | cut -d= -f2- | sed -E 's/^(["'"'"'])(.*)\1$/\2/')
fi
NOTIFY_COMMAND="${NOTIFY_COMMAND:-}"

# Source webhook URL
WEBHOOK_URL=$(grep '^ADMIN_WEBHOOK_URL=' "$ENV_FILE" | cut -d= -f2-)
if [[ -z "$WEBHOOK_URL" && -z "$NOTIFY_COMMAND" ]]; then
    echo "ERROR: ADMIN_WEBHOOK_URL not found in $ENV_FILE" >&2
    exit 1
fi

if [[ -f "$BRANDING_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$BRANDING_FILE"
fi

BOT_USERNAME="${BOT_USERNAME:-Boo Bot}"
BOT_AVATAR_URL="${BOT_AVATAR_URL:-}"

mkdir -p "$COOLDOWN_DIR"

send_alert() {
    local message="$1"
    curl -s -H "Content-Type: application/json" \
        -d "{\"username\":\"$BOT_USERNAME\",\"avatar_url\":\"$BOT_AVATAR_URL\",\"content\":\"$message\"}" \
        "$WEBHOOK_URL" > /dev/null
}

# Deliver a notification. With NOTIFY_COMMAND set, runs
#   $NOTIFY_COMMAND <status> <title> <body>     (status: warn | down | resolved)
# otherwise posts the plain message to the webhook.
notify() {
    local status="$1" title="$2" body="$3" message="$4"
    if [[ -n "$NOTIFY_COMMAND" ]]; then
        bash -c "$NOTIFY_COMMAND \"\$@\"" _ "$status" "$title" "$body" || true
    else
        send_alert "$message"
    fi
}

in_cooldown() {
    local key="$1"
    local cooldown_file="$COOLDOWN_DIR/$key"
    if [[ -f "$cooldown_file" ]]; then
        local last_alert
        last_alert=$(head -1 "$cooldown_file")
        local now
        now=$(date +%s)
        if (( now - last_alert < COOLDOWN_SECONDS )); then
            return 0
        fi
    fi
    return 1
}

set_cooldown() {
    local key="$1" title="${2:-}"
    { date +%s; [[ -n "$title" ]] && echo "$title"; } > "$COOLDOWN_DIR/$key"
}

# If a marker exists for this key and the condition has cleared, send a recovery
# notification (status "resolved") and remove the marker.
resolve_marker() {
    local key="$1" body="$2" file="$COOLDOWN_DIR/$1" title
    [[ -f "$file" ]] || return 0
    title=$(sed -n 2p "$file")
    title="${title:-$key}"
    notify resolved "$title" "$body" "✅ **Recovered:** $title"
    rm -f "$file"
}


# Check swap usage (threshold: SWAP_THRESHOLD, default 80%)
swap_total=$(free | awk '/Swap:/ {print $2}')
swap_used=$(free | awk '/Swap:/ {print $3}')
if (( swap_total > 0 )); then
    swap_pct=$(( swap_used * 100 / swap_total ))
    swap_human=$(free -h | awk '/Swap:/ {print $3 "/" $2}')
    if (( swap_pct > SWAP_THRESHOLD )); then
        if ! in_cooldown "swap"; then
            notify warn "Swap usage high" "${swap_pct}% ($swap_human)" \
                "💾 **Swap usage high:** ${swap_pct}% ($swap_human)"
            set_cooldown "swap" "Swap usage high"
        fi
    else
        resolve_marker "swap" "Swap usage is back to ${swap_pct}% ($swap_human)"
    fi
fi

# Check root disk usage (threshold: DISK_THRESHOLD, default 85%)
disk_pct=$(df / --output=pcent | tail -1 | tr -d ' %')
disk_human=$(df -h / --output=used,size | tail -1 | xargs)
if (( disk_pct > DISK_THRESHOLD )); then
    if ! in_cooldown "root-disk"; then
        notify warn "Root disk usage high" "${disk_pct}% ($disk_human)" \
            "💿 **Root disk usage high:** ${disk_pct}% ($disk_human)"
        set_cooldown "root-disk" "Root disk usage high"
    fi
else
    resolve_marker "root-disk" "Root disk usage is back to ${disk_pct}% ($disk_human)"
fi

# Check Docker reclaimable space (threshold: DOCKER_RECLAIM_GB, default 50GB)
if docker_df=$(docker system df --format '{{.Reclaimable}}' 2>/dev/null); then
    reclaimable_bytes=$(echo "$docker_df" | head -1 | grep -oP '[\d.]+(?=GB)' || echo "0")
    # Use awk for float comparison
    if echo "$reclaimable_bytes" | awk -v t="$DOCKER_RECLAIM_GB" '{exit !($1 > t)}'; then
        if ! in_cooldown "docker-reclaimable"; then
            notify warn "Docker reclaimable space" "${reclaimable_bytes}GB reclaimable, consider running image prune" \
                "🐳 **Docker reclaimable space:** ${reclaimable_bytes}GB — consider running image prune"
            set_cooldown "docker-reclaimable" "Docker reclaimable space"
        fi
    else
        resolve_marker "docker-reclaimable" "Docker reclaimable space is down to ${reclaimable_bytes}GB"
    fi
fi
