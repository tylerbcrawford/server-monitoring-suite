#!/bin/bash
# cron-run.sh - run a cron job so that a failure gets noticed.
#
# Usage: cron-run.sh <job-name> <command> [args...]
#
# Without a mail server, cron discards job output and exit codes. This wrapper:
#   - keeps non-empty output in $CRON_RUN_LOG_DIR/cron-<job-name>.log (size-capped)
#   - records the last success in $CRON_RUN_STATE_DIR/<job-name>.last-ok
#   - alerts once after CRON_RUN_FAIL_AFTER consecutive failures (default 2)
#   - sends "resolved" when the job recovers
#   - exits with the job's own exit code
#
# Set CRON_RUN_FAIL_AFTER=1 for daily jobs, where waiting for a second failure
# would delay the alert by a day. It only sees jobs that end: a hung job needs
# its own timeout, and the last-ok timestamp shows how long it has been stale.
#
# Notifications use the same settings as the other scripts in this suite:
# NOTIFY_COMMAND from the environment or .env, otherwise ADMIN_WEBHOOK_URL.

set -u

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <job-name> <command> [args...]" >&2
    exit 64
fi

JOB_NAME="$1"
shift
if [[ ! "$JOB_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "ERROR: job name must be lowercase letters, digits and dashes: $JOB_NAME" >&2
    exit 64
fi

LOG_DIR="${CRON_RUN_LOG_DIR:-$HOME/.local/share/vps-monitoring-logs}"
STATE_DIR_ROOT="${STATE_DIR:-$HOME/.local/state/server-monitoring-suite}"
CRON_STATE_DIR="${CRON_RUN_STATE_DIR:-$STATE_DIR_ROOT/cron-run}"
FAIL_AFTER="${CRON_RUN_FAIL_AFTER:-2}"
LOG_MAX_BYTES="${CRON_RUN_LOG_MAX_BYTES:-1048576}"
ENV_FILE="${ENV_FILE:-$(dirname "$0")/.env}"

LOG_FILE="$LOG_DIR/cron-$JOB_NAME.log"
COUNT_FILE="$CRON_STATE_DIR/$JOB_NAME.fail-count"
FAILING_FILE="$CRON_STATE_DIR/$JOB_NAME.failing"
LAST_OK_FILE="$CRON_STATE_DIR/$JOB_NAME.last-ok"
# Alert and resolve must share this exact title: the notifier may key on it.
ALERT_TITLE="Cron job failing: $JOB_NAME"

umask 077
mkdir -p "$LOG_DIR" "$CRON_STATE_DIR"

env_value() {
    [[ -f "$ENV_FILE" ]] || return 0
    grep -m1 "^$1=" "$ENV_FILE" | cut -d= -f2- | sed -E 's/^(["'"'"'])(.*)\1$/\2/'
}

NOTIFY_COMMAND="${NOTIFY_COMMAND:-}"
[[ -n "$NOTIFY_COMMAND" ]] || NOTIFY_COMMAND="$(env_value NOTIFY_COMMAND)"

notify() {
    local status="$1" body="$2" webhook
    if [[ -n "$NOTIFY_COMMAND" ]]; then
        bash -c "$NOTIFY_COMMAND \"\$@\"" _ "$status" "$ALERT_TITLE" "$body"
        return
    fi
    webhook="$(env_value ADMIN_WEBHOOK_URL)"
    if [[ -z "$webhook" ]]; then
        echo "no NOTIFY_COMMAND or ADMIN_WEBHOOK_URL configured" >&2
        return 1
    fi
    python3 - "$webhook" "$ALERT_TITLE: $body" <<'PY'
import json, sys, urllib.request
req = urllib.request.Request(
    sys.argv[1],
    data=json.dumps({"content": sys.argv[2][:1900]}).encode(),
    headers={"Content-Type": "application/json", "User-Agent": "server-monitoring-suite"},
)
urllib.request.urlopen(req, timeout=15)
PY
}

log_line() {
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG_FILE"
}

# Keep the newest half once the log passes the cap.
trim_log() {
    local size
    size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
    if (( size > LOG_MAX_BYTES )); then
        tail -c $(( LOG_MAX_BYTES / 2 )) "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

OUTPUT_FILE=$(mktemp "$CRON_STATE_DIR/.$JOB_NAME.XXXXXX") || exit 70
trap 'rm -f "$OUTPUT_FILE"' EXIT

"$@" > "$OUTPUT_FILE" 2>&1
EXIT_CODE=$?

if [[ -s "$OUTPUT_FILE" || $EXIT_CODE -ne 0 ]]; then
    log_line "--- exit=$EXIT_CODE"
    cat "$OUTPUT_FILE" >> "$LOG_FILE"
    trim_log
fi

if (( EXIT_CODE == 0 )); then
    date -u +%FT%TZ > "$LAST_OK_FILE"
    rm -f "$COUNT_FILE"
    if [[ -f "$FAILING_FILE" ]]; then
        # Keep the marker if delivery fails, so the next good run tries again.
        if notify resolved "Job succeeded again." >> "$LOG_FILE" 2>&1; then
            rm -f "$FAILING_FILE"
        else
            log_line "resolved notification failed"
        fi
    fi
    exit 0
fi

COUNT=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$COUNT" > "$COUNT_FILE"

if (( COUNT >= FAIL_AFTER )) && [[ ! -f "$FAILING_FILE" ]]; then
    LAST_OK=$(cat "$LAST_OK_FILE" 2>/dev/null || echo unknown)
    BODY="Failed $COUNT time(s) in a row, last exit code $EXIT_CODE. Last success: $LAST_OK. Log: $LOG_FILE"
    # The marker is set only after delivery, so a failed alert is retried.
    if notify down "$BODY" >> "$LOG_FILE" 2>&1; then
        date -u +%FT%TZ > "$FAILING_FILE"
    else
        log_line "alert notification failed"
    fi
fi

exit "$EXIT_CODE"
