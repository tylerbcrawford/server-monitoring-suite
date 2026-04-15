#!/bin/bash
# Container Health Monitor — posts to Discord when containers are unhealthy or restarting
# Runs every 5 minutes via cron

COOLDOWN_DIR="/tmp/container-health-cooldown"
COOLDOWN_SECONDS=3600  # 1 hour per container
ENV_FILE="${ENV_FILE:-$(dirname "$0")/.env}"
BRANDING_FILE="${BRANDING_FILE:-$(dirname "$0")/branding.sh}"

# Source webhook URL
WEBHOOK_URL=$(grep '^ADMIN_WEBHOOK_URL=' "$ENV_FILE" | cut -d= -f2-)
if [[ -z "$WEBHOOK_URL" ]]; then
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

in_cooldown() {
    local container="$1"
    local cooldown_file="$COOLDOWN_DIR/$container"
    if [[ -f "$cooldown_file" ]]; then
        local last_alert
        last_alert=$(cat "$cooldown_file")
        local now
        now=$(date +%s)
        if (( now - last_alert < COOLDOWN_SECONDS )); then
            return 0  # still in cooldown
        fi
    fi
    return 1  # not in cooldown
}

set_cooldown() {
    local container="$1"
    date +%s > "$COOLDOWN_DIR/$container"
}

# Check for unhealthy containers
while IFS= read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    [[ -z "$name" ]] && continue
    if ! in_cooldown "$name"; then
        send_alert "⚠️ **Container unhealthy:** \`$name\`"
        set_cooldown "$name"
    fi
done < <(docker ps --filter "health=unhealthy" --format "{{.Names}} {{.Status}}")

# Check for restarting containers
while IFS= read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    [[ -z "$name" ]] && continue
    if ! in_cooldown "${name}-restarting"; then
        send_alert "🔄 **Container restarting:** \`$name\`"
        set_cooldown "${name}-restarting"
    fi
done < <(docker ps --filter "status=restarting" --format "{{.Names}} {{.Status}}")

# Check for high restart counts (>3 in container lifetime)
while IFS= read -r line; do
    name=$(echo "$line" | awk -F'|' '{print $1}')
    count=$(echo "$line" | awk -F'|' '{print $2}')
    [[ -z "$name" || -z "$count" ]] && continue
    if (( count > 3 )) && ! in_cooldown "${name}-restarts"; then
        send_alert "🔁 **High restart count:** \`$name\` has restarted **$count** times"
        set_cooldown "${name}-restarts"
    fi
done < <(docker inspect --format '{{.Name}}|{{.RestartCount}}' $(docker ps -q) 2>/dev/null | sed 's|^/||')
