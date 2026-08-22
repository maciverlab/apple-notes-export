#!/bin/bash
set -euo pipefail

########################################################################
#  WEEKEND‑WINDOW + 7‑DAY GUARD
#  Run once between Saturday 00:00  ➜  Monday 04:59
########################################################################

LAST_RUN_FILE="$HOME/NotesIndex/.last_successful_export"

NOW_EPOCH=$(date +%s)
CUR_DAY=$(date +%u)     # 1=Mon … 6=Sat 7=Sun
CUR_HOUR=$(date +%H)

############################
# 7‑DAY COOL‑DOWN CHECK
############################
if [ -f "$LAST_RUN_FILE" ]; then
    LAST_EPOCH=$(cat "$LAST_RUN_FILE")
    SECONDS_SINCE=$(( NOW_EPOCH - LAST_EPOCH ))
    if [ "$SECONDS_SINCE" -lt 604800 ]; then            # 7 days × 24 h × 3600 s
        echo "Already ran $(($SECONDS_SINCE/86400)) days ago — skipping."
        exit 0
    fi
fi

#########################################
# TIME‑WINDOW CHECK   (Sat 00:00 – Mon 04:59)
#########################################
IN_WINDOW=false
#if [ "$CUR_DAY" -eq 6 ] || [ "$CUR_DAY" -eq 7 ]; then          # Saturday or Sunday
if [ "$CUR_DAY" -eq 1 ] || [ "$CUR_DAY" -eq 7 ]; then          # Saturday or Sunday
    IN_WINDOW=true
elif [ "$CUR_DAY" -eq 1 ] && [ "$CUR_HOUR" -lt 5 ]; then       # Monday before 05:00
    IN_WINDOW=true
fi

if [ "$IN_WINDOW" = false ]; then
    echo "Outside weekend window — skipping."
    exit 0
fi

echo "Ready to run"
