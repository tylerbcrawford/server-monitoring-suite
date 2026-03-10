#!/bin/bash
# Certbot Renewal Monitor — posts to Discord if any cert expires within configured threshold
# Runs daily via cron

COOLDOWN_DIR="/tmp/cert-expiry-cooldown"
COOLDOWN_SECONDS=86400  # 1 day per cert
ENV_FILE="${ENV_FILE:-$(dirname "$0")/.env}"
WARN_DAYS=30

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

warn_threshold=$(( $(date +%s) + WARN_DAYS * 86400 ))

# Parse certbot certificates output
while IFS= read -r line; do
    if [[ "$line" =~ "Certificate Name:" ]]; then
        cert_name=$(echo "$line" | awk -F': ' '{print $2}')
    fi
    if [[ "$line" =~ "Expiry Date:" ]]; then
        expiry_str=$(echo "$line" | awk -F': ' '{print $2}' | awk '{print $1, $2, $3}')
        expiry_epoch=$(date -d "$expiry_str" +%s 2>/dev/null)
        if [[ -n "$expiry_epoch" ]] && (( expiry_epoch < warn_threshold )); then
            days_left=$(( (expiry_epoch - $(date +%s)) / 86400 ))
            cooldown_key=$(echo "$cert_name" | tr '.' '-')
            if ! in_cooldown "$cooldown_key"; then
                send_alert "🔒 **SSL cert expiring soon:** \`$cert_name\` expires in **${days_left} days** ($expiry_str)"
                set_cooldown "$cooldown_key"
            fi
        fi
    fi
done < <(sudo ${CERTBOT_BIN:-/usr/bin/certbot} certificates 2>/dev/null)
