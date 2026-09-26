#!/bin/bash
# LEGACY / NOT USED BY launchd ANY MORE.
#
# This wrapper used to exist so the export inherited Terminal.app's Full Disk
# Access, which is required to read the protected Apple Notes database. Since
# a macOS update ("Golden Gate"), that access is denied whenever the screen is
# locked or asleep, even though Terminal itself has the grant - so the
# 1:30am/5:30am scheduled runs failed while the interactive ones (run with the
# screen already unlocked) succeeded. See docs/full_notes_export_with_colima.md.
#
# Full Disk Access is now granted directly to run_combined_export.sh (added by
# path in System Settings > Privacy & Security > Full Disk Access), and
# launchd calls that script directly - no Terminal, no AppleScript, no
# dependency on screen lock state. This wrapper is kept only for opening the
# export in a visible Terminal window for manual/interactive runs; it is not
# needed for permissions any more and is not referenced by the launchd plist.
/usr/bin/osascript -e "tell application \"Terminal\" to do script \"$HOME/NotesIndex/run_combined_export.sh; exit\""
