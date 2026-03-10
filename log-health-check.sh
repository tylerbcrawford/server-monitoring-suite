#!/bin/bash
# Log Health Check — monitors key log sizes across Docker and system services
# Created: 2026-02-28

# =============================================================================
# CONFIGURATION — customize these for your environment
# =============================================================================

# Download client log (e.g., NZBGet, SABnzbd)
DOWNLOAD_LOG="${DOWNLOAD_LOG:-}"

# Application log directory (e.g., media server script logs)
APP_LOG_DIR="${APP_LOG_DIR:-}"

# Additional log directories to check (space-separated paths)
EXTRA_LOG_DIRS="${EXTRA_LOG_DIRS:-}"

# *arr services to check (Docker container names)
ARR_SERVICES=(${ARR_SERVICES:-sonarr radarr prowlarr readarr lidarr})

# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "=== Server Log Health Check ==="
echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Docker container logs
DOCKER_LOGS=$(sudo du -sm /var/lib/docker/containers/ 2>/dev/null | awk '{print $1}')
echo -n "Docker JSON logs: ${DOCKER_LOGS}MB "
if [ "${DOCKER_LOGS}" -gt 500 ]; then
    echo -e "${RED}[WARNING: exceeds 500MB]${NC}"
else
    echo -e "${GREEN}[OK]${NC}"
fi

# Journald
JOURNAL_LOGS=$(journalctl --disk-usage 2>&1 | grep -oP '[\d.]+[MG]')
echo -n "Journald: ${JOURNAL_LOGS} "
JOURNAL_MB=$(journalctl --disk-usage 2>&1 | grep -oP '[\d.]+(?=M)|[\d.]+(?=G)' | head -1)
JOURNAL_UNIT=$(journalctl --disk-usage 2>&1 | grep -oP '[MG]' | tail -1)
if [ "$JOURNAL_UNIT" = "G" ]; then
    echo -e "${RED}[WARNING: exceeds 500MB]${NC}"
else
    echo -e "${GREEN}[OK]${NC}"
fi

# Download client log
if [ -n "$DOWNLOAD_LOG" ] && [ -f "$DOWNLOAD_LOG" ]; then
    DL_LOG_MB=$(du -sm "$DOWNLOAD_LOG" 2>/dev/null | awk '{print $1}')
    echo -n "Download log: ${DL_LOG_MB:-0}MB "
    if [ "${DL_LOG_MB:-0}" -gt 100 ]; then
        echo -e "${RED}[WARNING: exceeds 100MB]${NC}"
    else
        echo -e "${GREEN}[OK]${NC}"
    fi
fi

# *arr app logs
echo ""
echo "--- *arr App Logs ---"
for svc in "${ARR_SERVICES[@]}"; do
    count=$(docker exec $svc sh -c 'ls /config/logs/*.txt 2>/dev/null | wc -l' 2>/dev/null)
    size=$(docker exec $svc sh -c 'du -sh /config/logs/ 2>/dev/null' 2>/dev/null | awk '{print $1}')
    echo -n "  $svc: ${count:-?} files, ${size:-?} "
    if [ "${count:-0}" -gt 10 ]; then
        echo -e "${RED}[WARNING: >10 log files]${NC}"
    else
        echo -e "${GREEN}[OK]${NC}"
    fi
done

# Custom script logs
echo ""
echo "--- Custom Script Logs ---"
LOG_DIRS=()
[ -n "$APP_LOG_DIR" ] && LOG_DIRS+=("$APP_LOG_DIR")
for extra_dir in $EXTRA_LOG_DIRS; do
    LOG_DIRS+=("$extra_dir")
done

for dir in "${LOG_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
        count=$(find "$dir" -maxdepth 1 -type f 2>/dev/null | wc -l)
        name=$(basename "$(dirname "$dir")")/$(basename "$dir")
        echo -n "  $name: ${size:-empty} (${count} files) "
        if [ "$count" -gt 30 ]; then
            echo -e "${RED}[WARNING: >30 files]${NC}"
        else
            echo -e "${GREEN}[OK]${NC}"
        fi
    fi
done

# Home directory stray logs
echo ""
echo "--- Home Directory Stray Logs ---"
STRAY_LOGS=$(ls $HOME/*.log 2>/dev/null)
if [ -n "$STRAY_LOGS" ]; then
    echo -e "${RED}[WARNING] Stray logs in home directory:${NC}"
    echo "$STRAY_LOGS" | while read -r f; do
        size=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
        echo "  $(basename "$f"): $size"
    done
else
    echo -e "  No stray logs ${GREEN}[OK]${NC}"
fi

echo ""
echo "=== Done ==="
