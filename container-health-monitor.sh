#!/bin/bash
# Container Health Monitor — posts to Discord when containers are unhealthy or restarting
# Runs every 5 minutes via cron

COOLDOWN_DIR="${STATE_DIR:-$HOME/.local/state/server-monitoring-suite}/container-health-cooldown"
COOLDOWN_SECONDS=3600  # 1 hour per container
RESTART_COUNT_MAX="${RESTART_COUNT_MAX:-3}"   # alert when RestartCount exceeds this
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
    local container="$1"
    local cooldown_file="$COOLDOWN_DIR/$container"
    if [[ -f "$cooldown_file" ]]; then
        local last_alert
        last_alert=$(head -1 "$cooldown_file")
        local now
        now=$(date +%s)
        if (( now - last_alert < COOLDOWN_SECONDS )); then
            return 0  # still in cooldown
        fi
    fi
    return 1  # not in cooldown
}

set_cooldown() {
    local container="$1" title="${2:-}"
    { date +%s; [[ -n "$title" ]] && echo "$title"; } > "$COOLDOWN_DIR/$container"
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


# Keys with an active condition on this run (used for recovery below)
active_keys=" "
docker_ok=true

# Check for unhealthy containers
if unhealthy=$(docker ps --filter "health=unhealthy" --format "{{.Names}} {{.Status}}" 2>/dev/null); then
    while IFS= read -r line; do
        name=$(echo "$line" | awk '{print $1}')
        [[ -z "$name" ]] && continue
        active_keys+="$name "
        if ! in_cooldown "$name"; then
            notify down "Container unhealthy: $name" "$name is reporting unhealthy" \
                "⚠️ **Container unhealthy:** \`$name\`"
            set_cooldown "$name" "Container unhealthy: $name"
        fi
    done <<< "$unhealthy"
else
    docker_ok=false
fi

# Check for restarting containers
if restarting=$(docker ps --filter "status=restarting" --format "{{.Names}} {{.Status}}" 2>/dev/null); then
    while IFS= read -r line; do
        name=$(echo "$line" | awk '{print $1}')
        [[ -z "$name" ]] && continue
        active_keys+="${name}-restarting "
        if ! in_cooldown "${name}-restarting"; then
            notify down "Container restarting: $name" "$name is in a restart loop" \
                "🔄 **Container restarting:** \`$name\`"
            set_cooldown "${name}-restarting" "Container restarting: $name"
        fi
    done <<< "$restarting"
else
    docker_ok=false
fi

# Check for high restart counts (> RESTART_COUNT_MAX in container lifetime)
if running_ids=$(docker ps -q 2>/dev/null); then
    # shellcheck disable=SC2086
    counts=$(docker inspect --format '{{.Name}}|{{.RestartCount}}' $running_ids 2>/dev/null | sed 's|^/||')
    while IFS= read -r line; do
        name=$(echo "$line" | awk -F'|' '{print $1}')
        count=$(echo "$line" | awk -F'|' '{print $2}')
        [[ -z "$name" || -z "$count" ]] && continue
        if (( count > RESTART_COUNT_MAX )); then
            active_keys+="${name}-restarts "
            if ! in_cooldown "${name}-restarts"; then
                notify warn "High restart count: $name" "$name has restarted $count times" \
                    "🔁 **High restart count:** \`$name\` has restarted **$count** times"
                set_cooldown "${name}-restarts" "High restart count: $name"
            fi
        fi
    done <<< "$counts"
else
    docker_ok=false
fi

# Recovery: a marker exists but its condition no longer holds. Only judged when
# Docker answered every query and the container is still running (a removed
# container is not a recovery, so its marker is left alone).
if $docker_ok; then
    running_names=" $(docker ps --format '{{.Names}}' 2>/dev/null | tr '\n' ' ') "
    for marker in "$COOLDOWN_DIR"/*; do
        [[ -f "$marker" ]] || continue
        key=$(basename "$marker")
        [[ "$active_keys" == *" $key "* ]] && continue
        cname="${key%-restarting}"; cname="${cname%-restarts}"
        [[ "$running_names" == *" $cname "* ]] || continue
        resolve_marker "$key" "$cname is healthy again"
    done
fi
