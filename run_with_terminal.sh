#!/bin/bash
# LEGACY / NOT USED BY launchd ANY MORE.
#
# This wrapper used to exist so the export inherited Terminal.app's Full Disk
# Access, which is required to read the protected Apple Notes database. After
# the macOS "Golden Gate" update, scheduled runs through this wrapper failed at
# the database copy while runs with the screen unlocked succeeded. Screen lock
# was the suspected cause but was never confirmed.
# See docs/full_notes_export_with_colima.md.
#
# launchd now runs bin/notes-export-launcher (built from launcher/), which holds
# the Full Disk Access grant and starts run_combined_export.sh. This wrapper is
# kept only for opening the export in a visible Terminal window, and only works
# if Terminal itself still has Full Disk Access. For a manual run that uses the
# launcher's grant, prefer:
#   launchctl kickstart gui/$(id -u)/com.maciver.notes-indexer.colima
/usr/bin/osascript -e "tell application \"Terminal\" to do script \"$HOME/NotesIndex/run_combined_export.sh; exit\""
