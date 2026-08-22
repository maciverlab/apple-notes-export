#!/bin/bash
# This wrapper exists solely so the export inherits Terminal.app's Full Disk
# Access, which is required to read the protected Apple Notes database.
# Running run_combined_export.sh directly fails at the cp with
# "Operation not permitted".
/usr/bin/osascript -e "tell application \"Terminal\" to do script \"$HOME/NotesIndex/run_combined_export.sh; exit\""
