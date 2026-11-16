#!/bin/zsh
# usage: scripts/launch-detour.sh <path/to/Detour.app> <DETOUR_DATA_DIR name> [logfile] [extra args...]
# Refuses to run without a data-dir name. Prints the PID. Never use for /Applications/Detour.app.
APP="$1"; DIR="$2"; LOG="${3:-/dev/null}"; shift 3 2>/dev/null
[[ -z "$APP" || -z "$DIR" ]] && { echo "usage: launch-detour.sh <app> <data-dir-name> [log]"; exit 2; }
[[ "$APP" == /Applications/* ]] && { echo "refusing to launch the production app"; exit 2; }
[[ "$DIR" == "Detour" ]] && { echo "refusing the real profile name"; exit 2; }
DETOUR_DATA_DIR="$DIR" "$APP/Contents/MacOS/Detour" "$@" > "$LOG" 2>&1 &
echo $!
