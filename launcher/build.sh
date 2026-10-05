#!/bin/bash
# Build and ad-hoc sign the launcher that launchd runs and that holds the
# Full Disk Access grant. The binary goes to ~/NotesIndex/bin/, which the
# whitelist .gitignore keeps out of the repo.
#
# Rebuilding changes the code signature, and macOS ties the Full Disk Access
# grant to that signature. After every rebuild, re-grant it in System Settings
# (remove the old entry, add the new binary).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HOME/NotesIndex/bin/notes-export-launcher"
mkdir -p "$(dirname "$OUT")"
cc -O2 -Wall -Wextra -o "$OUT" "$HERE/notes-export-launcher.c"
codesign --force --sign - --identifier com.maciver.notes-export-launcher "$OUT"
codesign -dv "$OUT" 2>&1 | grep -E "^(Identifier|Signature)="
echo "Built $OUT"
echo "Now grant it Full Disk Access (System Settings > Privacy & Security > Full Disk Access)."
