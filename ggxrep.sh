#!/bin/bash

# ==============================================================================
# ADVANCED GOLDENGATE 23ai REPLICATION REPORT & AUDIT SCRIPT
# ==============================================================================
OGG_HOME="/nfs/ggcore/gghome"
DB_USER="admin"
DB_ALIAS="ggadmin"
DB_DOMAIN="OracleGoldenGate"
MAX_CHECKPOINT_LAG_SECS=300

HOST_NAME=$(hostname)
EXEC_TIME=$(date)

echo "==================================================================="
echo "Oracle GoldenGate 23ai Advanced Replication & Backlog Dashboard"
echo "Host: $HOST_NAME | Execution Time: $EXEC_TIME"
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
    
    expect << 'EOF' 2>&1
    set timeout 90
    spawn $env(EX_OGG_HOME)/bin/adminclient
    
    expect {
        -re {[Oo][Gg][Gg].*?>} { }
        -re {>} { }
        timeout { puts "EXPECT_ERROR: Timeout waiting for initial prompt"; exit 1 }
        eof { puts "EXPECT_ERROR: adminclient terminated unexpectedly"; exit 1 }
    }
    
    send "CONNECT $env(EX_URL) DEPLOYMENT $env(EX_NAME) AS $env(EX_DB_USER)\r"
    expect {
        -re {[Oo][Gg][Gg].*?>} { }
        -re {>} { }
        timeout { puts "EXPECT_ERROR: Timeout after CONNECT"; exit 1 }
        eof { puts "EXPECT_ERROR: Connection dropped after CONNECT"; exit 1 }
    }
    
    send "DBLOGIN USERIDALIAS $env(EX_DB_ALIAS) DOMAIN $env(EX_DB_DOMAIN)\r"
    expect {
        -re {[Oo][Gg][Gg].*?>} { }
        -re {>} { }
        timeout { puts "EXPECT_ERROR: Timeout after DBLOGIN"; exit 1 }
    }
    
    send "$env(EX_CMD)\r"
    
    expect {
        -re {[Oo][Gg][Gg].*?>} { }
        -re {>} { }
        timeout {
            puts "EXPECT_ERROR: Timeout executing command: $env(EX_CMD)"
            exit 1
        }
    }
    
    puts "---RAW_START---"
    puts $expect_out(buffer)
    puts "---RAW_END---"
    
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
    echo "Deployment: $DEP_NAME | Key: $DEP_KEY | URL: $DEP_URL"
    echo "==================================================================="

    RAW_FULL_LOG=$(run_gg_command "info all" "$DEP_URL" "$DEP_NAME")
    
    RAW_OUTPUT=$(echo "$RAW_FULL_LOG" | sed -n '/---RAW_START---/,/---RAW_END---/p' | sed '/---RAW_/d' | awk '/info all/{flag=1; next} flag')

    if [ -z "$RAW_OUTPUT" ] || echo "$RAW_FULL_LOG" | grep -q "EXPECT_ERROR"; then
        echo "[ERROR] Connection or command execution failed for: $DEP_KEY"
        echo "$RAW_FULL_LOG" | grep -- "EXPECT_ERROR"
        return
    fi

    # Print Infrastructure / Admin Server status
    echo ""
    echo "--- Infrastructure Services ---"
    printf "%-15s | %-10s\n" "PROCESS" "STATUS"
    echo "---------------------------------"
    echo "$RAW_OUTPUT" | grep -E '^\s*(ADMINSRVR|DISTSRVR|PMSRVR|RECVSRVR)' | while read -r pstat; do
        pname=$(echo "$pstat" | awk '{print $1}')
        pstatus=$(echo "$pstat" | awk '{print $2}')
        printf "%-15s | %-10s\n" "$pname" "$pstatus"
    done

    # Parse Replication Processes (Extract / Replicat)
    DISCOVERY_OUTPUT=$(echo "$RAW_OUTPUT" | grep -E '^\s*(EXTRACT|REPLICAT)')
    PROCS=$(echo "$DISCOVERY_OUTPUT" | awk '{print $1, $2, $3, $4}' | grep -v '^$')

    if [ -z "$PROCS" ]; then
        echo ""
        echo "[WARNING] No active Extract/Replicat groups found."
        return
    fi

    echo ""
    echo "--- Advanced Replication Process Analysis ---"

    echo "$PROCS" | while read -r PROC_TYPE PROC_STATUS PROC_NAME PROC_SUBTYPE; do
        [ -z "$PROC_NAME" ] && continue
        
        echo ""
        echo "------------------------------------------------------------------"
        echo "Process: $PROC_NAME ($PROC_TYPE) | Subtype: ${PROC_SUBTYPE:-N/A} | Status: $PROC_STATUS"
        echo "------------------------------------------------------------------"

        # 1. Detailed Info (Lag, Trail Files, Sequence, RBA)
        DIAG_FULL=$(run_gg_command "info $PROC_TYPE $PROC_NAME detail" "$DEP_URL" "$DEP_NAME")
        DIAG_OUTPUT=$(echo "$DIAG_FULL" | sed -n '/---RAW_START---/,/---RAW_END---/p' | sed '/---RAW_/d')

        # 2. Stats Total / Totalsonly (Throughput, Operations, Transactions processed)
        STATS_FULL=$(run_gg_command "stats $PROC_TYPE $PROC_NAME total" "$DEP_URL" "$DEP_NAME")
        STATS_OUTPUT=$(echo "$STATS_FULL" | sed -n '/---RAW_START---/,/---RAW_END---/p' | sed '/---RAW_/d')

        # 3. Runtime Status Check (via send command)
        SEND_FULL=$(run_gg_command "send $PROC_TYPE $PROC_NAME status" "$DEP_URL" "$DEP_NAME")
        SEND_OUTPUT=$(echo "$SEND_FULL" | sed -n '/---RAW_START---/,/---RAW_END---/p' | sed '/---RAW_/d')

        # Extract Metrics safely using targeted awk lines to avoid buffer overwrite artifacts
        LAG_STR=$(echo "$DIAG_OUTPUT" | grep -i "Checkpoint Lag" | head -n 1 | awk '{print $3}')
        TIME_SINCE=$(echo "$DIAG_OUTPUT" | grep -i "Checkpoint Lag" | head -n 1 | awk '{print $5}')
        TRAIL_FILE=$(echo "$DIAG_OUTPUT" | grep -iE "(Trail Filename|Remote Trail|Local Trail)" | head -n 1 | sed 's/^[ \t]*//')
        SEQ_RBA=$(echo "$DIAG_OUTPUT" | grep -iE "(Seqno|Sequence Number|RBA)" | head -n 1 | sed 's/^[ \t]*//')

        TOTAL_OPS=$(echo "$STATS_OUTPUT" | grep -iE "(Total operations|Operations)" | tail -n 1 | awk '{print $NF}' | cut -d'.' -f1)
        [[ ! "$TOTAL_OPS" =~ ^[0-9]+$ ]] && TOTAL_OPS=0

        TOTAL_TXNS=$(echo "$STATS_OUTPUT" | grep -iE "(Total transactions|Transactions)" | tail -n 1 | awk '{print $NF}' | cut -d'.' -f1)
        [[ ! "$TOTAL_TXNS" =~ ^[0-9]+$ ]] && TOTAL_TXNS=0

        # Calculate lag seconds securely with base-10 conversion
        TOTAL_LAG_SECS=0
        if [[ "$LAG_STR" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
            TOTAL_LAG_SECS=$(( (10#${BASH_REMATCH[1]} * 3600) + (10#${BASH_REMATCH[2]} * 60) + 10#${BASH_REMATCH[3]} ))
        fi

        # Activity Detection (Is it processing data?)
        ACTIVITY_STATUS="IDLE / NO NEW DATA"
        if [ "$TOTAL_OPS" -gt 0 ]; then
            ACTIVITY_STATUS="ACTIVELY PROCESSING ($TOTAL_OPS operations recorded)"
        fi

        # Health & Backlog Verdict
        HEALTH="HEALTHY"
        BACKLOG_STATUS="NORMAL"
        if [[ ! "$PROC_STATUS" =~ ^[Rr][Uu][Nn][Nn][Ii][Nn][Gg]$ ]]; then
            HEALTH="CRITICAL"
            BACKLOG_STATUS="STOPPED / UNKNOWN"
        elif [ "$TOTAL_LAG_SECS" -gt "$MAX_CHECKPOINT_LAG_SECS" ]; then
            HEALTH="DEGRADED"
            BACKLOG_STATUS="HIGH LAG BACKLOG (${TOTAL_LAG_SECS}s)"
        fi

        # Display Metrics Block
        printf "  %-25s : %s\n" "Checkpoint Lag" "${LAG_STR:-00:00:00} (${TOTAL_LAG_SECS}s)"
        printf "  %-25s : %s\n" "Time Since Checkpoint" "${TIME_SINCE:-00:00:00}"
        printf "  %-25s : %s\n" "Trail / Target Mapping" "${TRAIL_FILE:-N/A}"
        printf "  %-25s : %s\n" "Sequence / RBA Info" "${SEQ_RBA:-N/A}"
        printf "  %-25s : %s Transactions / %s Operations\n" "Cumulative Stats" "$TOTAL_TXNS" "$TOTAL_OPS"
        printf "  %-25s : %s\n" "Data Processing State" "$ACTIVITY_STATUS"
        printf "  %-25s : %s\n" "Backlog Evaluation" "$BACKLOG_STATUS"
        printf "  %-25s : %s\n" "Process Health" "$HEALTH"

        # Clean isolation of runtime send status to prevent option parsing errors
        CLEAN_SEND=$(echo "$SEND_OUTPUT" | grep -v "adminclient" | grep -v "Successfully logged" | grep -v "OGG (" | grep -v -- "---" | grep -v "^$" | head -n 2 | xargs)
        if [ -n "$CLEAN_SEND" ]; then
            printf "  %-25s : %s\n" "Runtime Send Status" "$CLEAN_SEND"
        fi
    done
}

# ==============================================================================
# EXECUTE DEPLOYMENT AUDITS
# ==============================================================================
audit_deployment "rep" "http://host.com:6800" "REP"
audit_deployment "usage" "http://host.com:6300" "USG"
audit_deployment "billrep_trg" "http://pd10sclbildb.i.jaspersystems.com:6500" "BILL"

echo ""
echo "==================================================================="
echo "Advanced replication & backlog report completed successfully."
echo "==================================================================="
