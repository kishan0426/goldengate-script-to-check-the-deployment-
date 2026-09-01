#!/bin/bash

# ==============================================================================
# ALL-IN-ONE GOLDENGATE 23ai UNIVERSAL REPLICATION AUDIT SCRIPT
# ==============================================================================
OGG_HOME="/nfs/ggcore/gghome"
DB_USER="admin"
DB_ALIAS="ggadmin"
DB_DOMAIN="OracleGoldenGate"
MAX_CHECKPOINT_LAG_SECS=300   # Alert if checkpoint lag exceeds 5 minutes (300s)

echo "==================================================================="
echo "Oracle GoldenGate 23ai Universal Replication Audit (All-in-One)"
echo "Host: $(hostname) | Execution Time: $(date)"
echo "==================================================================="

run_gg_command() {
    local cmd="$1"
    local url="$2"
    local name="$3"
    
    export EX_CMD="$cmd"
    export EX_URL="$url"
    export EX_NAME="$name"
    export EX_OGG_HOME="$OGG_HOME"
    export EX_DB_USER="$DB_USER"
    export EX_DB_ALIAS="$DB_ALIAS"
    export EX_DB_DOMAIN="$DB_DOMAIN"
    
    expect << 'EOF'
    set timeout 30
    spawn $env(EX_OGG_HOME)/bin/adminclient
    
    expect -re {OGG.*?>}
    
    send "CONNECT $env(EX_URL) DEPLOYMENT $env(EX_NAME) AS $env(EX_DB_USER)\r"
    expect -re {OGG.*?>}
    
    send "DBLOGIN USERIDALIAS $env(EX_DB_ALIAS) DOMAIN $env(EX_DB_DOMAIN)\r"
    expect -re {OGG.*?>}
    
    send "$env(EX_CMD)\r"
    expect -re {OGG.*?>}
    
    send "exit\r"
    expect eof
EOF
}

audit_deployment() {
    local DEP_KEY="$1"
    local DEP_URL="$2"
    local DEP_NAME="$3"

    echo ""
    echo "==================================================================="
    echo "Deployment Key: $DEP_KEY | URL: $DEP_URL | Deployment: $DEP_NAME"
    echo "==================================================================="

    # 1. Query active processes via 'info all'
    DISCOVERY_OUTPUT=$(run_gg_command "info all" "$DEP_URL" "$DEP_NAME")

    if [ -z "$DISCOVERY_OUTPUT" ]; then
        echo "[ERROR] Connection timed out or failed completely for: $DEP_KEY"
        return
    fi

    # 2. Precision parser for Replicat group names ($1=REPLICAT, $3=Group Name)
    REPLICATS=$(echo "$DISCOVERY_OUTPUT" | awk '$1 == "REPLICAT" {print $3}' | grep -v '^$' | sort -u)

    if [ -z "$REPLICATS" ]; then
        echo "[WARNING] Connected successfully, but no active Replicat groups were parsed for: $DEP_KEY"
        echo "--- Raw Output Received ---"
        echo "$DISCOVERY_OUTPUT"
        echo "---------------------------"
        return
    fi

    for REP in $REPLICATS; do
        echo ""
        echo "------------------------------------------------------------------"
        echo "Analyzing Replicat Group: $REP"
        echo "------------------------------------------------------------------"

        # 3. Fetch detailed diagnostics and stats inline
        DIAG_OUTPUT=$(run_gg_command "info replicat $REP detail; stats replicat $REP, totalsonly *.*" "$DEP_URL" "$DEP_NAME")

        # Parse Status (RUNNING vs ABENDED/STOPPED)
        REP_STATUS=$(echo "$DIAG_OUTPUT" | grep -iE "Status\s+" | head -n 1 | awk '{print $2}')
        [ -z "$REP_STATUS" ] && REP_STATUS="UNKNOWN"

        # Parse Checkpoint Lag (Format: HH:MM:SS)
        LAG_STR=$(echo "$DIAG_OUTPUT" | grep -i "Checkpoint Lag" | awk '{print $3}')
        
        TOTAL_LAG_SECS=0
        if [[ "$LAG_STR" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
            TOTAL_LAG_SECS=$(( (${BASH_REMATCH[1]} * 3600) + (${BASH_REMATCH[2]} * 60) + ${BASH_REMATCH[3]} ))
        fi

        # Parse Throughput Statistics (*.* totals)
        TOTAL_OPS=$(echo "$DIAG_OUTPUT" | grep -i "Total operations" | awk '{print $3}' | cut -d'.' -f1)
        [ -z "$TOTAL_OPS" ] && TOTAL_OPS=0

        TOTAL_TXNS=$(echo "$DIAG_OUTPUT" | grep -i "Total transactions" | awk '{print $2}' | cut -d'.' -f1)
        [ -z "$TOTAL_TXNS" ] && TOTAL_TXNS=0

        # Output parsed metrics
        echo "  - Process Status          : $REP_STATUS"
        echo "  - Checkpoint Lag          : ${LAG_STR:-00:00:00} (${TOTAL_LAG_SECS}s)"
        echo "  - Cumulative Transactions : $TOTAL_TXNS"
        echo "  - Cumulative Operations   : $TOTAL_OPS"

        # 4. Health Evaluation & Threshold Rules
        HEALTH="HEALTHY"
        ISSUES=()

        if [[ ! "$REP_STATUS" =~ ^[Rr][Uu][Nn][Nn][Ii][Nn][Gg]$ ]]; then
            HEALTH="CRITICAL"
            ISSUES+=("Process is not running (Status: $REP_STATUS)")
        fi

        if [ "$TOTAL_LAG_SECS" -gt "$MAX_CHECKPOINT_LAG_SECS" ]; then
            HEALTH="DEGRADED"
            ISSUES+=("Lag exceeds threshold (${TOTAL_LAG_SECS}s > ${MAX_CHECKPOINT_LAG_SECS}s)")
        fi

        if [ "$TOTAL_OPS" -eq 0 ]; then
            ISSUES+=("Zero operations processed recorded in stats block.")
        fi

        # Report findings per replicat
        echo "  - Health Verdict          : $HEALTH"
        if [ ${#ISSUES[@]} -gt 0 ]; then
            for issue in "${ISSUES[@]}"; do
                echo "    [ALERT] -> $issue"
            done
        fi
    done
}

# ==============================================================================
# EXECUTE DEPLOYMENTS (Updated with correct OGG Microservices deployment name: BILL)
# ==============================================================================
audit_deployment "abc" "http://host.com:6800" "abc"
audit_deployment "bcd" "http://host.com:6300" "bcd"
audit_deployment "cde" "http://host:6500" "cde"

echo ""
echo "==================================================================="
echo "Universal replication sweep completed."
echo "==================================================================="
