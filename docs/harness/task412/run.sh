#!/bin/zsh
# usage: run.sh <app.path> <tag> <label:App name>...   One Detour process; per trial: activate app, hotkey, type URL, Return.
# S: the directory holding the compiled input and order tools (and where logs go).
S=${QDFRONT_DIR:-${0:a:h}}; APP=$1; TAG=$2; shift 2
DOM=com.detourbrowser.mac.DetourVerifyQDFront
# The production app, at run time: its windows are labelled Dprod and it is not "another Detour".
PROD=$(pgrep -f "^/Applications/Detour.app/Contents/MacOS/Detour" | head -1); PROD=${PROD:-0}
export QDFRONT_PROD_PID=$PROD
mkdir -p $S/fixture && echo '<title>QD Fixture</title><h1>fixture</h1>' > $S/fixture/q.html
cleanup() {
  kill $DPID $LP $SPID 2>/dev/null
  defaults delete $DOM 2>/dev/null
  for k in "NSSplitView Subview Frames BrowserSplitView-DetourVerifyQDFront" "NSWindow Frame BrowserWindow-DetourVerifyQDFront"; do
    defaults delete com.detourbrowser.mac "$k" 2>/dev/null
  done
}
trap cleanup EXIT INT TERM
defaults write $DOM QuickDetourHotKeyEnabled -bool true
defaults write $DOM QuickDetourHotKeyShortcut -dict keyCode -int 111 modifiers -int 6400 character ""
(cd $S/fixture && exec python3 -m http.server 8932 --bind 127.0.0.1 > $S/server.log 2>&1) &
SPID=$!
/usr/bin/log stream --style compact --level debug --predicate '(process == "WindowServer" AND (subsystem BEGINSWITH "com.apple.SkyLight" OR category == "front")) OR (process == "launchservicesd" AND category == "front") OR (process == "Detour" AND (category == "front" OR subsystem BEGINSWITH "com.apple.AppKit" OR eventMessage CONTAINS "QDFRONT"))' > $S/act-$TAG.log 2>&1 &
LP=$!
DPID=$(DETOUR_GLOBAL_HOTKEY=1 /Users/tma/Projects/browser/MyBrowser/scripts/launch-detour.sh $APP DetourVerifyQDFront $S/detour-$TAG.log)
sleep 6
N=0
for SPEC in "$@"; do
  V=${SPEC%%:*}; TARGET=${SPEC#*:};
  N=$((N+1))
  OTHERS=$(pgrep -f "Detour.app/Contents/MacOS/Detour" | grep -v -x -e $DPID -e $PROD)
  if [ -n "$OTHERS" ]; then echo "ABORT $N: other Detour running: $OTHERS"; break; fi
  # label "viachrome": Chrome is the app in front just before the target.
  [ "$V" = viachrome ] && { osascript -e "tell application \"Google Chrome\" to activate"; sleep 1.5; }
  osascript -e "tell application \"$TARGET\" to activate"; sleep 2
  $S/order "$TAG/$N/$V/$TARGET before"
  echo "TRIAL $N $TARGET hotkey $(date +%T.%N)"
  $S/input key 111 cotf; sleep 1.2
  P=$($S/order "$TAG/$N/$V/$TARGET panel")
  if ! echo "$P" | grep -q ":: D([0-9x]*@L3)"; then echo "$P"; echo "ABORT $N: panel not in front"; continue; fi
  $S/input type "127.0.0.1:8932/q.html"; sleep 0.5
  echo "TRIAL $N $TARGET return $(date +%T)"
  $S/input key 36 -; sleep 2.5
  $S/order "$TAG/$N/$V/$TARGET return+2.5s"
done
sleep 1  # cleanup (trap) stops Detour, the log stream and the server, and removes the defaults
