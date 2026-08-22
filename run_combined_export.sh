#!/bin/bash
set -euo pipefail

########################################################################
#  WEEKEND‑WINDOW + 5.25‑DAY GUARD
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
    if [ "$SECONDS_SINCE" -lt 453600 ]; then            # 5.25 days × 24 h × 3600 s
        echo "Already ran $(($SECONDS_SINCE/86400)) days ago — skipping."
        exit 0
    fi
fi

#########################################
# TIME‑WINDOW CHECK   (Sat 00:00 – Mon 04:59)
#########################################
IN_WINDOW=false
if [ "$CUR_DAY" -eq 6 ] || [ "$CUR_DAY" -eq 7 ]; then          # Saturday or Sunday
    IN_WINDOW=true
elif [ "$CUR_DAY" -eq 1 ] && [ "$CUR_HOUR" -lt 5 ]; then       # Monday before 05:00
    IN_WINDOW=true
fi

if [ "$IN_WINDOW" = false ]; then
    echo "Outside weekend window — skipping."
    exit 0
fi

############################
# FAILURE NOTIFICATION
# Notification for immediacy + modal alert that must be dismissed.
# The lock is released FIRST so a blocking dialog cannot wedge the
# next scheduled run behind it.
############################
notify_failure() {
    # SECURITY: this builds an AppleScript program by string interpolation.
    # SAFE strips only " and \, which is sufficient ONLY because every value
    # passed in comes from the Docker daemon or this script - never from the
    # container. Do NOT extend this message with parser/container output
    # (e.g. the last log line): that is attacker-controlled and would turn
    # this into AppleScript injection. Pass such text via a file instead.
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    SAFE=$(printf '%s' "$1" | tr '\n' ' ' | sed 's/["\\]/ /g')
    /usr/bin/osascript -e "display notification \"${SAFE}\" with title \"Notes Export FAILED\" sound name \"Basso\"" >/dev/null 2>&1 || true
    /usr/bin/osascript -e "display alert \"Notes Export FAILED\" message \"${SAFE}\" as critical" >/dev/null 2>&1 || true
}

# Catches ANY early abort (cp permission denied, Colima start failure,
# etc.) that set -e would otherwise turn into a silent exit.
EXPORT_STARTED=false
cleanup_and_alert() {
    RC=$?
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    if [ "$RC" -ne 0 ] && [ "$EXPORT_STARTED" = "true" ]; then
        notify_failure "Export aborted early (exit $RC) before the parser finished. See ~/Library/Logs/notes-export-full.log"
    fi
}

############################
# CONCURRENCY GUARD
# (the pre-export timestamp write used to serve as a crude lock)
############################
LOCK_DIR="$HOME/NotesIndex/.export.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +180 2>/dev/null)" ]; then
        echo "Stale lock (>3h) - reclaiming."
        rm -rf "$LOCK_DIR"
        mkdir "$LOCK_DIR" 2>/dev/null || { echo "Could not acquire lock - skipping."; exit 0; }
    else
        echo "Another export is already running - skipping."
        exit 0
    fi
fi
trap cleanup_and_alert EXIT
EXPORT_STARTED=true

#######################
#  RUN EXPORT NOW
#######################
# NOTE: cooldown timestamp is written ONLY on success (see end of script).
# Writing it here caused failed runs to burn the full 5.25-day cooldown.
echo "Starting weekly export at $(date)"


LOG="$HOME/Library/Logs/notes-export-full.log"
SRC="$HOME/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
DST="$HOME/NotesIndex/NoteStore.sqlite"
OUT="$HOME/NotesIndex/output"

{
  echo "[START] $(date)"
  mkdir -p "$OUT"

  ############################################################
  # 1.  SAFE COPY OF NOTES DATABASE (checkpoint + copy)
  ############################################################

  /usr/bin/sqlite3 "$SRC" "PRAGMA wal_checkpoint(TRUNCATE);" || true

  # Copy DB + sidecars
  cp "$SRC"          "$DST"
  cp "$SRC-wal"      "$DST-wal"  2>/dev/null || true
  cp "$SRC-shm"      "$DST-shm"  2>/dev/null || true

########################################################################
# 1.5  Docker/Colima preflight: make sure docker can talk to Colima
########################################################################
# robust PATH (launchd/Terminal can be minimal after OS updates)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

COLIMA_BIN="$(command -v colima || echo /opt/homebrew/bin/colima)"
DOCKER_BIN="$(command -v docker || echo /opt/homebrew/bin/docker)"

echo "Checking Colima/Docker..."
# 1) Start Colima if not running
if ! "$COLIMA_BIN" status >/dev/null 2>&1; then
  echo "Colima not running — starting…"
  "$COLIMA_BIN" start --runtime docker >>"$LOG" 2>&1 || {
    echo "ERROR: Colima failed to start"; exit 1;
  }
fi

# 2) Ensure docker talks to Colima: prefer context, then docker-env, then DOCKER_HOST
#    (covers cases where context reset after OS update)
if ! "$DOCKER_BIN" info >/dev/null 2>&1; then
  echo "Docker not connected; trying 'docker context use colima'…"
  "$DOCKER_BIN" context use colima >/dev/null 2>&1 || true
fi

# NOTE: deliberately NOT using `eval "$(colima docker-env)"` here.
# That executes command output as shell code; if the colima binary or its
# PATH entry were tampered with (a user-writable Homebrew prefix is common)
# it becomes arbitrary code execution. Setting DOCKER_HOST directly below
# achieves the same result with no eval.

# last resort: point directly at the socket
if ! "$DOCKER_BIN" info >/dev/null 2>&1; then
  export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
fi

# 3) Wait up to 30s for daemon to be ready (avoids race after start)
for i in {1..30}; do
  "$DOCKER_BIN" info >/dev/null 2>&1 && break
  sleep 1
done

if ! "$DOCKER_BIN" info >/dev/null 2>&1; then
  echo "ERROR: Docker daemon not ready after 30s"; exit 1
fi

echo "Colima/Docker ready."
########################################################################


  ############################################################
  # 2.  RUN PARSER CONTAINER
  ############################################################

  ############################################################
  # 2a. MEMORY HEADROOM SAMPLER
  #     The parser's peak RSS scales with note count. A 2 GB VM
  #     silently OOM-killed it (exit 137) for months. Sample peak
  #     usage every run so the ceiling is visible BEFORE it is hit.
  ############################################################
  MEM_PEAK_FILE="$(mktemp -t notes-export-mem)"
  printf '0 n/a\n' > "$MEM_PEAK_FILE"
  (
    while :; do
      LINE=$("$DOCKER_BIN" stats --no-stream --format '{{.MemPerc}} {{.MemUsage}}' 2>/dev/null \
             | sed 's/%//' | sort -rn | head -1)
      if [ -n "$LINE" ]; then
        OLD=$(cut -d' ' -f1 "$MEM_PEAK_FILE" 2>/dev/null || echo 0)
        NEW=$(printf '%s' "$LINE" | cut -d' ' -f1)
        if awk -v a="$NEW" -v b="$OLD" 'BEGIN{exit !(a+0 > b+0)}'; then
          printf '%s\n' "$LINE" > "$MEM_PEAK_FILE"
        fi
      fi
      sleep 5
    done
  ) >/dev/null 2>&1 &
  MEM_MON_PID=$!

  echo "Running Colima Docker..."
set +e
# Pinned by digest, not :latest. This container is handed a full copy of the
# personal Notes database and runs on a machine where Terminal holds Full Disk
# Access, so an unpinned tag means every run silently trusts whatever the
# upstream registry serves that day. Update this digest deliberately.
#
# --network none: the parser only reads a local SQLite file and writes local
# output, so it needs no network. This is what stops a compromised image from
# exfiltrating the notes. Do not remove it without a specific reason.
#
# NOTE: /data is intentionally read-write. The parser mutates the database
# (it adds ZICNOTEDATA.ZPLAINTEXT columns), so :ro would break it. What it
# gets is a disposable copy, never the live Notes store.
"$DOCKER_BIN" run --rm \
  --network none \
  -v "$HOME/NotesIndex":/data \
  -v "$OUT":/app/output \
  ghcr.io/threeplanetssoftware/apple_cloud_notes_parser@sha256:63e2523be8aa23e06de34a6c1aaa112e004a01599bc602c4f1657949d186131d \
  --file /data/NoteStore.sqlite --output-dir /app/output \
  --one-output-folder --individual-files
DOCKER_RC=$?
set -e

  ############################################################
  # 2b. REPORT MEMORY HEADROOM
  ############################################################
  kill "$MEM_MON_PID" 2>/dev/null || true
  wait "$MEM_MON_PID" 2>/dev/null || true

  PEAK_PCT=$(cut -d' ' -f1 "$MEM_PEAK_FILE" 2>/dev/null || echo 0)
  PEAK_RAW=$(cut -d' ' -f2- "$MEM_PEAK_FILE" 2>/dev/null || echo "n/a")
  rm -f "$MEM_PEAK_FILE"
  VM_TOTAL_H=$("$DOCKER_BIN" info --format '{{.MemTotal}}' 2>/dev/null \
               | awk '{printf "%.1f GiB", $1/1073741824}' || echo "unknown")

  echo "Peak container memory: ${PEAK_PCT}% of VM limit (${PEAK_RAW})"
  if awk -v x="$PEAK_PCT" 'BEGIN{exit !(x+0 >= 75)}'; then
      echo "*** WARNING: peak memory >=75% of the Colima VM limit (${VM_TOTAL_H})."
      echo "*** WARNING: the next OOM kill (exit 137) is close. Raise it now:"
      echo "***          colima stop && colima start --runtime docker --memory 16 --cpu 4"
  elif awk -v x="$PEAK_PCT" 'BEGIN{exit !(x+0 >= 60)}'; then
      echo "NOTICE: peak memory >=60% of the Colima VM limit (${VM_TOTAL_H}) - headroom shrinking."
  fi


  ############################################################
  # 3.  SUCCESS => record timestamp ;  FAILURE => log error
  ############################################################
  if [ "$DOCKER_RC" -eq 0 ]; then
      echo "Docker completed OK"
      date +%s > "$LAST_RUN_FILE"
  else
      echo "Docker FAILED with exit code $DOCKER_RC"
      if [ "$DOCKER_RC" -eq 137 ]; then
          echo "*** DIAGNOSIS: 137 = SIGKILL, almost always the Linux OOM killer."
          echo "*** DIAGNOSIS: the parser outgrew the Colima VM RAM (${VM_TOTAL_H})."
          echo "*** DIAGNOSIS: fix with:"
          echo "***   colima stop && colima start --runtime docker --memory 16 --cpu 4"
          echo "*** DIAGNOSIS: confirm with:  colima ssh -- sudo dmesg | grep -i oom-kill"
          OOM_HINT=" - OOM killed. Raise Colima RAM: colima stop && colima start --runtime docker --memory 16 --cpu 4"
      else
          OOM_HINT=""
      fi
      notify_failure "Parser failed with exit $DOCKER_RC${OOM_HINT}  Peak memory was ${PEAK_PCT}% of the ${VM_TOTAL_H} VM. Log: ~/Library/Logs/notes-export-full.log"
  fi

  echo "[DONE] $(date)"
} >> "$LOG" 2>&1



