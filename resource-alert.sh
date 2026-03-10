#!/bin/bash
# Resource Threshold Alerting — posts to Discord when system resources exceed thresholds
# Runs every 15 minutes via cron

COOLDOWN_DIR="/tmp/resource-alert-cooldown"
COOLDOWN_SECONDS=14400  # 4 hours per issue
ENV_FILE="${ENV_FILE:-$(dirname "$0")/.env}"

# Source webhook URL
WEBHOOK_URL=$(grep '^ADMIN_WEBHOOK_URL=' "$ENV_FILE" | cut -d= -f2-)
if [[ -z "$WEBHOOK_URL" ]]; then
    echo "ERROR: ADMIN_WEBHOOK_URL not found in $ENV_FILE" >&2
    exit 1
fi

mkdir -p "$COOLDOWN_DIR"

send_alert() {
    local message="$1"
    curl -s -H "Content-Type: application/json" \
        -d "{\"content\": \"$message\"}" \
        "$WEBHOOK_URL" > /dev/null
}

in_cooldown() {
    local key="$1"
    local cooldown_file="$COOLDOWN_DIR/$key"
    if [[ -f "$cooldown_file" ]]; then
        local last_alert
        last_alert=$(cat "$cooldown_file")
        local now
        now=$(date +%s)
        if (( now - last_alert < COOLDOWN_SECONDS )); then
            return 0
        fi
    fi
    return 1
}

set_cooldown() {
    local key="$1"
    date +%s > "$COOLDOWN_DIR/$key"
}

# Check swap usage (threshold: 80%)
swap_total=$(free | awk '/Swap:/ {print $2}')
swap_used=$(free | awk '/Swap:/ {print $3}')
if (( swap_total > 0 )); then
    swap_pct=$(( swap_used * 100 / swap_total ))
    if (( swap_pct > 80 )) && ! in_cooldown "swap"; then
        swap_human=$(free -h | awk '/Swap:/ {print $3 "/" $2}')
        send_alert "💾 **Swap usage high:** ${swap_pct}% ($swap_human)"
        set_cooldown "swap"
    fi
fi

# Check root disk usage (threshold: 85%)
disk_pct=$(df / --output=pcent | tail -1 | tr -d ' %')
if (( disk_pct > 85 )) && ! in_cooldown "root-disk"; then
    disk_human=$(df -h / --output=used,size | tail -1 | xargs)
    send_alert "💿 **Root disk usage high:** ${disk_pct}% ($disk_human)"
    set_cooldown "root-disk"
fi

# Check Docker reclaimable space (threshold: 50GB)
reclaimable_bytes=$(docker system df --format '{{.Reclaimable}}' | head -1 | grep -oP '[\d.]+(?=GB)' || echo "0")
# Use awk for float comparison
if echo "$reclaimable_bytes" | awk '{exit !($1 > 50)}' && ! in_cooldown "docker-reclaimable"; then
    send_alert "🐳 **Docker reclaimable space:** ${reclaimable_bytes}GB — consider running image prune"
    set_cooldown "docker-reclaimable"
fi
