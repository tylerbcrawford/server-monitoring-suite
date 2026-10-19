#!/bin/bash
# Certbot Renewal Monitor — posts to Discord if any cert expires within configured threshold
# Runs daily via cron

COOLDOWN_DIR="${STATE_DIR:-$HOME/.local/state/server-monitoring-suite}/cert-expiry-cooldown"
COOLDOWN_SECONDS=86400  # 1 day per cert
ENV_FILE="${ENV_FILE:-$(dirname "$0")/.env}"
WARN_DAYS="${WARN_DAYS:-30}"
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


warn_threshold=$(( $(date +%s) + WARN_DAYS * 86400 ))

# Parse certbot certificates output
active_keys=" "
seen_certs=0
while IFS= read -r line; do
    if [[ "$line" =~ "Certificate Name:" ]]; then
        cert_name=$(echo "$line" | awk -F': ' '{print $2}')
        seen_certs=$(( seen_certs + 1 ))
        cooldown_key=$(echo "$cert_name" | tr '.' '-')
    fi
    if [[ "$line" =~ "Expiry Date:" ]]; then
        expiry_str=$(echo "$line" | awk -F': ' '{print $2}' | awk '{print $1, $2, $3}')
        expiry_epoch=$(date -d "$expiry_str" +%s 2>/dev/null)
        if [[ -n "$expiry_epoch" ]] && (( expiry_epoch < warn_threshold )); then
            days_left=$(( (expiry_epoch - $(date +%s)) / 86400 ))
            active_keys+="$cooldown_key "
            if ! in_cooldown "$cooldown_key"; then
                notify warn "SSL cert expiring soon: $cert_name" "$cert_name expires in ${days_left} days ($expiry_str)" \
                    "🔒 **SSL cert expiring soon:** \`$cert_name\` expires in **${days_left} days** ($expiry_str)"
                set_cooldown "$cooldown_key" "SSL cert expiring soon: $cert_name"
            fi
        fi
    fi
done < <(sudo ${CERTBOT_BIN:-/usr/bin/certbot} certificates 2>/dev/null)

# Recovery: only judged when certbot listed at least one certificate
if (( seen_certs > 0 )); then
    for marker in "$COOLDOWN_DIR"/*; do
        [[ -f "$marker" ]] || continue
        key=$(basename "$marker")
        [[ "$active_keys" == *" $key "* ]] && continue
        resolve_marker "$key" "Certificate renewed or no longer expiring within ${WARN_DAYS} days"
    done
fi
