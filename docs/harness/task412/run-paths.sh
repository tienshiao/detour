#!/bin/zsh
# usage: run-paths.sh <app.path> <tag> <spec>...
# spec: link:<App> | linkvia:<App> (Chrome in front just before) | dock:<App> (Hide All, then <App> in front, then Show All)
S=${QDFRONT_DIR:-${0:a:h}}; APP=$1; TAG=$2; shift 2
DOM=com.detourbrowser.mac.DetourVerifyQDFront
PROD=$(pgrep -f "^/Applications/Detour.app/Contents/MacOS/Detour" | head -1); PROD=${PROD:-0}
export QDFRONT_PROD_PID=$PROD
OTHERS=$(pgrep -f "Detour.app/Contents/MacOS/Detour" | grep -v -x -e $PROD)
[ -n "$OTHERS" ] && { echo "ABORT: other Detour running: $OTHERS"; exit 1; }
DB="$HOME/Library/Application Support/DetourVerifyQDFront/browser.db"
sqlite3 "$DB" "INSERT OR REPLACE INTO linkRouteDefault (id, targetKind, targetSpaceID) VALUES (1, 'quickDetour', NULL); SELECT * FROM linkRouteDefault;"
mkdir -p $S/fixture && echo '<title>QD Fixture</title><h1>fixture</h1>' > $S/fixture/q.html
(cd $S/fixture && exec python3 -m http.server 8932 --bind 127.0.0.1 > $S/server.log 2>&1) &
SPID=$!
cleanup() {
  kill $DPID $SPID 2>/dev/null
  defaults delete $DOM 2>/dev/null
  for k in "NSSplitView Subview Frames BrowserSplitView-DetourVerifyQDFront" "NSWindow Frame BrowserWindow-DetourVerifyQDFront"; do
    defaults delete com.detourbrowser.mac "$k" 2>/dev/null
  done
}
trap cleanup EXIT INT TERM
DPID=$(/Users/tma/Projects/browser/MyBrowser/scripts/launch-detour.sh $APP DetourVerifyQDFront $S/detour-$TAG.log)
echo "Detour pid $DPID"; sleep 6
front() { osascript -e "tell application \"$1\" to activate"; sleep 2; }
N=0
for SPEC in "$@"; do
  N=$((N+1)); KIND=${SPEC%%:*}; TARGET=${SPEC#*:}
  OTHERS=$(pgrep -f "Detour.app/Contents/MacOS/Detour" | grep -v -x -e $DPID -e $PROD)
  [ -n "$OTHERS" ] && { echo "ABORT $N: other Detour running: $OTHERS"; break; }
  case $KIND in
    link|linkvia)
      [ $KIND = linkvia ] && front "Google Chrome"
      front "$TARGET"
      $S/order "$TAG/$N/$KIND/$TARGET before"
      $S/opener "$APP" "http://127.0.0.1:8932/q.html?n=$N"
      sleep 2.5
      $S/order "$TAG/$N/$KIND/$TARGET after+2.5s" ;;
    dock|dockvia)
      $S/dockclick "$APP" "Hide All Quick Detour Windows"; sleep 1.5
      [ $KIND = dockvia ] && front "Google Chrome"
      front "$TARGET"
      $S/order "$TAG/$N/$KIND/$TARGET before"
      $S/dockclick "$APP" "Show All Quick Detour Windows"; sleep 2.5
      $S/order "$TAG/$N/$KIND/$TARGET after+2.5s" ;;
  esac
done
