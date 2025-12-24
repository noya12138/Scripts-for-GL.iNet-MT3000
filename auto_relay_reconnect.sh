#!/bin/sh

# ================= CONFIGURATION =================

# 1. Network Targets (Public DNS)
TARGET_IPS="223.5.5.5 119.29.29.29 114.114.114.114"

# 2. Ping Settings
PING_COUNT=3
PING_TIMEOUT=3
MAX_RETRIES=3
RETRY_INTERVAL=5

# 3. Reconnect Strategy
# Time to wait (seconds) for campus network to clear MAC session
WAIT_TIME=180       

# 4. Log & System Settings
LOG_FILE="/root/relay_network.log"
MAX_LOG_LINES=1000
LOCK_FILE="/var/run/auto_relay_reconnect.lock"

# ================= FUNCTIONS =================

log() {
    local level="$1"
    local msg="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
    
    if [ -f "$LOG_FILE" ] && [ $(wc -l < "$LOG_FILE") -gt $MAX_LOG_LINES ]; then
        sed -i '1,100d' "$LOG_FILE"
    fi
}

check_network() {
    for ip in $TARGET_IPS; do
        if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$ip" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

# ================= MAIN LOGIC =================

# 1. Concurrency Check
if [ -f "$LOCK_FILE" ]; then
    old_pid=$(cat "$LOCK_FILE")
    if [ -d "/proc/$old_pid" ]; then
        exit 1
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT TERM INT

# 2. Network Detection
FAIL_COUNTER=0
for i in $(seq 1 $MAX_RETRIES); do
    if check_network; then
        exit 0
    else
        log "WARN" "Network check failed (Attempt $i/$MAX_RETRIES). Retrying..."
        FAIL_COUNTER=$((FAIL_COUNTER + 1))
        sleep "$RETRY_INTERVAL"
    fi
done

# 3. Execution Sequence
if [ "$FAIL_COUNTER" -eq "$MAX_RETRIES" ]; then
    log "ERROR" "Network DOWN. Starting GL-iNet Repeater Reconnect Sequence..."

    # Step 3.1: Disable Repeater via GL-iNet private config
    log "INFO" "Disabling Repeater (repeater.@main[0])..."
    uci set repeater.@main[0].disabled='1'
    uci commit repeater
    
    # Apply changes using Glinet's service manager
    /etc/init.d/repeater restart
    
    # Step 3.2: Wait for MAC release
    log "INFO" "Waiting ${WAIT_TIME}s for MAC session clearance..."
    sleep "$WAIT_TIME"
    
    # Step 3.3: Enable Repeater
    log "INFO" "Enabling Repeater (repeater.@main[0])..."
    uci set repeater.@main[0].disabled='0'
    uci commit repeater
    /etc/init.d/repeater restart

    # Step 3.4: Wait for DHCP and Association
    log "INFO" "Waiting 40s for WiFi association and DHCP..."
    sleep 40
    
    # 4. Final Verification
    if check_network; then
        log "INFO" "SUCCESS: Network recovered via Repeater restart."
    else
        log "ERROR" "FAILED: Network still unreachable. Please check Campus Auth status."
    fi
fi

exit 0