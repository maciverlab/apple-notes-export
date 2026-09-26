# 🗂️ Documentation: Automated Apple Notes Export via Colima + Docker + `launchd`

## 📋 Overview

This system automatically exports Apple Notes once each weekend, using:

- A cron-like job via `launchd` to periodically check whether it's
  time to do the note export
- The `apple_cloud_notes_parser` container
- The **Colima** Docker runtime (not Docker Desktop)
- A custom shell script to copy and process the `NoteStore.sqlite` file

It is designed to be:
- Headless (no GUI automation)
- Fully scriptable
- Reliable across reboots and user sessions

---

## ⚠️ Status & change history

**Last verified working: 2026-09-26** (2938 notes, 54 folders).

### 2026-09-26 — macOS "Golden Gate" upgrade broke access while locked/asleep
After updating to macOS Golden Gate, the scheduled 1:30am/5:30am weekend runs failed at the
`cp` of `NoteStore.sqlite` with `authorization denied` / `Operation not permitted`, while
manually running the export in an already-unlocked session succeeded every time — including
through the identical Terminal+AppleScript wrapper. The power log confirmed the display was
off through both failure windows.

Root cause: Full Disk Access granted to **Terminal.app** no longer covers a window Terminal
opens via an AppleScript Apple Event while the screen is locked or asleep. The Apple Event
itself succeeds and the script runs, but the protected file read is denied until there is an
active, unlocked session — and with `displaysleep` at 5 minutes, the screen is reliably off
by the time `launchd`'s 4-hourly interval fires overnight.

Fix: **Full Disk Access is now granted directly to `run_combined_export.sh`** (added by path
in System Settings, not via Terminal), and the `launchd` job calls that script directly. See
*Full Disk Access is granted to the script, not Terminal* under Required Permissions, and the
`Operation not permitted` entry under Troubleshooting. `run_with_terminal.sh` is no longer
part of the permission chain and is no longer referenced by the LaunchAgent; it is kept only
as an optional manual helper that opens the export in a visible window.

Also worth knowing: this was on top of two other post-upgrade issues seen the same week —
Colima came back from the upgrade in a `Broken` state (`vz driver is running but host agent
is not`), fixed with `colima stop --force && colima start --runtime docker --memory 8 --cpu
4`; and Full Disk Access itself needed re-granting to Terminal once (toggle it off/on in
System Settings, fully quit Terminal with Cmd-Q, then retry) before the locked-screen issue
above was even visible. If you hit this after an OS upgrade, check all three: Full Disk
Access grant, Colima VM state, and screen-lock timing.

### 2026-08-22 — the export had been failing silently for months
Three compounding bugs, all now fixed. Read this before changing anything:

1. **Colima VM was too small (the actual killer).** The parser loads the whole note store
   into RAM. The VM had **2 GB**; peak demand was >1.9 GB, so the Linux OOM killer SIGKILLed
   it — surfacing as **Docker exit 137**. The VM is now **8 GB / 4 CPU**, persisted in
   `~/.colima/default/colima.yaml`. This is *not* a Docker or Colima connectivity problem,
   which is how it kept getting misdiagnosed.
2. **The cooldown was stamped before the export ran.** A failed run still burned the full
   5.25-day cooldown, so failures were indistinguishable from successes. The timestamp is
   now written *only* on success.
3. **The error branch was unreachable.** `DOCKER_RC=$?` sat after a `docker run` under
   `set -euo pipefail`, so a failure exited the script before the check. Across 90 recorded
   starts the log contained **0** `Docker completed OK` lines. The `docker run` is now
   wrapped in `set +e` / `set -e`.

Also added: a concurrency lock, a peak-memory sampler that logs headroom every run, and
failure alerts (notification + critical modal).

### Known limitation — a weekend powered off skips the whole week
The gates are a weekend window (Sat 00:00 → Mon 04:59) plus a 5.25-day cooldown, with **no
catch-up logic**. On one occasion the Mac was powered off for over a week, so that
weekend was missed entirely and 13 days elapsed between exports. If you are away for a weekend, expect a
gap and run it manually via `run_combined_export.sh` (or `run_with_terminal.sh` for a visible window).

### Growth / future OOM risk
2429 notes (May 2025) → 2904 notes (Aug 2026), roughly 32 notes/month. At 8 GB there is
about 3× headroom, but memory tracks attachments and images too, not just note count.
Every run now logs `Peak container memory: N% of VM limit`; at ≥60% it prints a NOTICE and
at ≥75% a WARNING telling you to raise the VM.

## 📁 File Structure

```bash
~/NotesIndex/
├── run_combined_export.sh         # Main export script; has Full Disk Access granted directly; this is what launchd runs
├── run_with_terminal.sh           # Legacy manual-run helper (visible Terminal window); not used by launchd, not needed for permissions
├── NoteStore.sqlite               # Copied Notes database (refreshed weekly after Friday 4am)
├── output/                        # Output folder for extracted HTML files
~/Library/Logs/
├── notes-export-full.log         # Daily combined export logs
├── notes-indexer-colima.out      # Colima status log
~/Library/LaunchAgents/
├── com.maciver.notes-indexer.colima.plist  # LaunchAgent for calling
run_combined_export.sh directly, every 4 hours
├── com.maciver.colima.autostart.plist      # LaunchAgent for starting Colima on logging in
```

## 🐳 Docker Runtime

This setup uses [**Colima**](https://github.com/abiosoft/colima) as a replacement for Docker Desktop.

### Startup

Ensure Colima is installed via:

```bash
brew install colima
```

Start Colima with Docker runtime:

```bash
colima start --runtime docker --memory 8 --cpu 4
```

Enable autostart (optional):

```bash
colima autostart enable
```

### Confirming Colima is active:

```bash
docker context ls
docker info | grep -i colima
```

You should see:
- Current context: `colima`
- Docker socket: `~/.colima/default/docker.sock`

## 📦 Obtaining the parser image

The parser is [`apple_cloud_notes_parser`](https://github.com/threeplanetssoftware/apple_cloud_notes_parser),
run as a prebuilt container from GitHub Container Registry. There is nothing to
install: the `docker run` in the export script references the image **by digest**,
so Docker pulls it automatically the first time it is needed.

Two reasons to pull it once by hand before the first scheduled run:

- It is about **500 MB**. Left to the schedule, that download happens inside the
  weekend export window, at whatever hour `launchd` fires. If the network or
  `ghcr.io` is unavailable, the run fails and raises the critical alert.
- Pulling it deliberately lets you confirm the digest *before* a container is
  handed a full copy of your Notes database. See the security notes below.

```bash
docker pull ghcr.io/threeplanetssoftware/apple_cloud_notes_parser@sha256:63e2523be8aa23e06de34a6c1aaa112e004a01599bc602c4f1657949d186131d
```

Verify what you got:

```bash
docker images --digests | grep apple_cloud_notes_parser
```

The digest shown must match the one in `run_combined_export.sh`. Docker refuses a
mismatch, so a successful pull is itself the check — but confirm the script and
the pull reference the same digest, not merely that *some* image is present.

The pinned image never changes on its own. Moving to a newer build is a
deliberate, testable step — see *Update the parser container* under Maintenance
Notes before doing it.

## 🔧 Export Script

📄 `~/NotesIndex/run_combined_export.sh`

```bash
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
```

Make it executable:

```bash
chmod +x ~/NotesIndex/run_combined_export.sh
```

## Wrapper Script: `run_with_terminal.sh` (legacy, optional)

Full Disk Access is now granted directly to `run_combined_export.sh` (see *Required
Permissions* below), and `launchd` calls that script directly. This wrapper is **not** part
of the permission chain any more and is **not** referenced by the LaunchAgent. It is kept
only so you can open the export in a visible Terminal window for a manual run:

```bash
#!/bin/bash
# LEGACY / NOT USED BY launchd ANY MORE. See docs above and the Status & change
# history entry for 2026-09-26 for why this stopped being how permissions work.
/usr/bin/osascript -e "tell application \"Terminal\" to do script \"$HOME/NotesIndex/run_combined_export.sh; exit\""
```

Make it executable:

```bash
chmod +x ~/NotesIndex/run_with_terminal.sh
```



## ⏰ `launchd` Scheduled Job

📄 `~/Library/LaunchAgents/com.maciver.notes-indexer.colima.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.maciver.notes-indexer.colima</string>

    <key>ProgramArguments</key>
    <array>
        <string>/Users/<you>/NotesIndex/run_combined_export.sh</string>
    </array>

    <key>StartInterval</key>
    <integer>14400</integer> <!-- Run every 4 hours -->
    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/Users/<you>/Library/Logs/notes-indexer-colima.out</string>
    <key>StandardErrorPath</key>
    <string>/Users/<you>/Library/Logs/notes-indexer-colima.err</string>
</dict>
</plist>
```

### Load or reload the job:

```bash
launchctl unload ~/Library/LaunchAgents/com.maciver.notes-indexer.colima.plist 2>/dev/null
launchctl load ~/Library/LaunchAgents/com.maciver.notes-indexer.colima.plist
```

### Manually trigger a run:

```bash
launchctl kickstart -k gui/$(id -u)/com.maciver.notes-indexer.colima
```

## 🧪 Verification

```bash
tail -n 20 ~/Library/Logs/notes-export-full.log
tail -n 20 ~/Library/Logs/notes-indexer-colima.out
```

```bash
open ~/NotesIndex/output/
```

## 📝 Paths in this document

Paths are written as `/Users/<you>/...`. Substitute your own account name.
The `launchd` plists in `launchd/` are **templates** — `launchd` does not expand
`$HOME` or `~`, so those files require absolute paths and you must edit them
before installing into `~/Library/LaunchAgents/`. The shell scripts need no
editing; they use `$HOME` throughout.

The `launchd` labels (`com.maciver.notes-indexer.colima`,
`com.maciver.colima.autostart`) are a reverse-DNS namespace, not a path. If you
adopt this setup, rename them to your own namespace — the label must match the
`Label` key, the plist filename, and whatever you pass to `launchctl`.

## 🛡️ Required Permissions

- **`run_combined_export.sh` must be granted Full Disk Access directly** (not Terminal.app):
  - System Settings ▸ Privacy & Security ▸ Full Disk Access ▸ **+** ▸ navigate to
    `~/NotesIndex/run_combined_export.sh` (Cmd+Shift+G in the file picker to type the path,
    since it isn't an app) ▸ add it ▸ toggle it **on**.
  - This must be redone if the script is ever moved or replaced with a new file (a copy gets
    a new identity for TCC purposes); editing it in place is fine.
  - Do this once, with the screen unlocked. See below for why this replaced granting Full
    Disk Access to Terminal.


## 🔐 Security notes

Read these before copying this setup.

### Full Disk Access is granted to the script, not Terminal
The export reads `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`,
which macOS protects. Full Disk Access is granted directly to `run_combined_export.sh`,
which `launchd` runs directly — no Terminal.app, no AppleScript, in the loop.

This setup originally ran the export through Terminal.app (granted Full Disk Access) via an
AppleScript wrapper, `run_with_terminal.sh`, so the export inherited Terminal's grant. That
broke after a macOS upgrade ("Golden Gate"): Terminal's grant stopped covering a window it
opened via Apple Event once the screen was locked or asleep, so the 1:30am/5:30am scheduled
runs failed while manual, screen-unlocked runs kept working. See the 2026-09-26 entry in
*Status & change history* for the full diagnosis.

Granting Full Disk Access to the script directly is actually **narrower** than the old
approach, not broader: the old grant to Terminal.app meant *everything* you ran in any
Terminal window, and anything that could drive Terminal via AppleScript, inherited access to
all protected data — Mail, Messages, Safari history, every app's container, not just this
script. A grant to `run_combined_export.sh` covers only that one script.

### The parser container is pinned and network-isolated
The container receives a **full copy of your Notes database** on a machine where the export
script has Full Disk Access. Two deliberate mitigations:

- **Pinned by digest**, not `:latest`. An unpinned tag means every run trusts whatever the
  registry serves that day. Update the digest as a conscious decision.
- **`--network none`.** The parser only reads a local SQLite file and writes local output,
  so it needs no network. This is what prevents a compromised image from exfiltrating notes.
  Do not remove it without a specific reason.

`/data` is intentionally mounted read-write: the parser mutates the database (it adds
`ZICNOTEDATA.ZPLAINTEXT` columns), so `:ro` breaks it. It only ever receives a disposable
copy — never the live Notes store.

### Do not put container output into the alert text
`notify_failure()` builds an AppleScript program by string interpolation. It is safe only
because every value passed to it originates from this script or the Docker daemon. Adding
parser or container output to that message would make it attacker-controlled and turn it
into AppleScript injection. Pass such text through a file instead.

### No secrets belong in this repository
`.gitignore` is a whitelist. The working directory holds the Notes database and every
exported note; none of it may be committed. Add tracked files explicitly.

## 🚨 Troubleshooting

### `Docker FAILED with exit code 137`
SIGKILL = the Linux OOM killer inside the Colima VM. The parser outgrew the VM's RAM.

```bash
colima ssh -- sudo dmesg | grep -i oom-kill          # confirm
grep "Peak container memory" ~/Library/Logs/notes-export-full.log | tail -5
colima stop && colima start --runtime docker --memory 16 --cpu 4   # fix: raise it
```

### The export "ran" but produced nothing / stale output
Check for the success markers, not just `[START]`:

```bash
grep -c "\[START\]"           ~/Library/Logs/notes-export-full.log
grep -c "Docker completed OK"  ~/Library/Logs/notes-export-full.log
```
A `[START]` with no matching `Docker completed OK` is a failed run. Also check the JSON is
not 0 bytes: `ls -la ~/NotesIndex/output/notes_rip/json/`.

### It hasn't run in more than a week
```bash
date -r $(cat ~/NotesIndex/.last_successful_export)   # last SUCCESSFUL run
last reboot | head -5                                  # was the Mac off all weekend?
```
A weekend spent powered off is skipped with no catch-up. See Status & change history above.

### `Operation not permitted` / `authorization denied` on the `cp`
Full Disk Access is granted directly to `run_combined_export.sh` (see *Required
Permissions*). Two distinct causes produce this error, and it matters which one you have:

1. **The grant is missing or was reset**, e.g. after a macOS upgrade. Fix: System Settings ▸
   Privacy & Security ▸ Full Disk Access ▸ re-add `run_combined_export.sh` by path (or toggle
   it off and on if it's already listed), then run `~/NotesIndex/run_combined_export.sh`
   directly to confirm.
2. **The grant is present, but the screen was locked or asleep** when a `launchd`-triggered
   run fired. Check `pmset -g log | grep -E "Sleep|Wake|Display is turned"` around the
   failure time — if the display was off, that is almost certainly it, not a missing grant.
   A grant made directly to the script (rather than to Terminal.app via an AppleScript
   wrapper) is not supposed to depend on lock state; if you still see this while the screen
   is verifiably unlocked and awake, the grant itself needs re-adding (see 1).

`run_with_terminal.sh` no longer has anything to do with permissions; it is an optional,
manual way to see the export's output in a Terminal window and is not run by `launchd`.

### Colima won't start: `vz driver is running but host agent is not`
Stale VM state, usually after an unclean shutdown.
```bash
colima stop --force && colima start --runtime docker --memory 8 --cpu 4
```

## 🧼 Maintenance Notes

- Start Colima after reboot:
  ```bash
  colima start
  ```

- Update the parser container — **only if you actually want a newer build.**
  The script pins the image by digest, so it runs identical bits every time and
  will never change on its own. That is the point: a working export stays
  working. Pulling the `:latest` tag changes nothing about what runs; only the
  digest in `run_combined_export.sh` does.

  **Updating is a change with consequences, not routine housekeeping.** A newer
  parser can rearrange the output layout or JSON fields that anything downstream
  reads, change how it rewrites the copied database, guess a different Notes
  version, or need more memory than the one you tested — and memory is exactly
  what broke this export silently for months (see *Status & change history*).
  Have a reason: a bug fix you need, a format you want, or a security fix.
  "It is newer" is not a reason.

  To check whether a newer build exists:

  ```bash
  docker pull ghcr.io/threeplanetssoftware/apple_cloud_notes_parser:latest
  docker inspect --format '{{index .RepoDigests 0}}' \
    ghcr.io/threeplanetssoftware/apple_cloud_notes_parser:latest
  ```

  If that digest matches the one already in `run_combined_export.sh`, upstream
  has not published anything new and there is nothing to do. If it differs and
  you have decided you want it:

  1. **Record the current digest before changing it.** Digests are immutable, so
     the old one stays your rollback for as long as upstream keeps that image
     published.
  2. Replace the digest in the `docker run` line of `run_combined_export.sh`.
  3. Run a manual export: `~/NotesIndex/run_combined_export.sh`.
  4. Check the results against the previous run *before* leaving it on the
     schedule — a clean exit alone is not enough:

     ```bash
     grep "Docker completed OK"        ~/Library/Logs/notes-export-full.log | tail -2
     grep "Updated AppleNoteStore"     ~/Library/Logs/notes-export-full.log | tail -2
     grep "Peak container memory"      ~/Library/Logs/notes-export-full.log | tail -2
     ls -la ~/NotesIndex/output/notes_rip/json/
     ```

     The note and folder counts should be close to the last good run (a sudden
     drop means notes were silently missed, not that they vanished); peak memory
     should not have jumped; the JSON directory should exist and be non-empty;
     and anything you have built on top of the export should still read it.

  5. If any of that looks wrong, put the old digest back and run again.

  The pin does not follow upstream and nothing warns you when upstream moves.
  That is deliberate — but it also means an upstream security fix will not reach
  you on its own, so the check is worth making about once a year.

- Check failures:
  ```bash
  tail -n 50 ~/Library/Logs/notes-export-full.log
  ```

---

## 🐳 Installing and Initializing Colima

Install Colima (via Homebrew):

```bash
brew install colima
```

Start Colima with Docker runtime support:

```bash
colima start --runtime docker --memory 8 --cpu 4
```

Confirm it's working:

```bash
docker ps
```

If you'd like Colima to autostart on login without Docker Desktop, see the section below.

## 🔁 Enabling Colima Autostart via LaunchAgent

Since Homebrew’s `brew services start colima` can silently fail, a reliable alternative is to use a custom `launchd` LaunchAgent.

📄 `~/Library/LaunchAgents/com.maciver.colima.autostart.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.maciver.colima.autostart</string>

  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/colima</string>
    <string>start</string>
    <string>--runtime</string>
    <string>docker</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <false/>

  <key>StandardOutPath</key>
  <string>/tmp/colima-autostart.out</string>
  <key>StandardErrorPath</key>
  <string>/tmp/colima-autostart.err</string>
</dict>
</plist>
```

Then load it:

```bash
launchctl load ~/Library/LaunchAgents/com.maciver.colima.autostart.plist
```

This ensures Colima is automatically started each time you log in, without relying on Homebrew’s service layer.
