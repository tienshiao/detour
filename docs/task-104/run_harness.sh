#!/bin/zsh
# TASK-104: launch the harness build in an isolated profile and sample the GPU
# process's IOSurface count every 5 s while the in-app harness cycles tabs.
S=/private/tmp/claude-501/-Users-tma-Projects-browser-MyBrowser/199c0aa9-da49-4e03-a532-fc024459231e/scratchpad
APP=/tmp/claude/detour-dd/Build/Products/Debug/Detour.app
LOG=$S/harness.log
CSV=$S/${RUN:-samples}.csv
: > $CSV
rm -f $LOG
T0=$(date +%s)
open -n "$APP" --env DETOUR_DATA_DIR=DetourVerify \
  --env DETOUR_IOSURFACE_HARNESS=http://127.0.0.1:8765/ \
  --env DETOUR_HARNESS_LOG=$LOG \
  --env DETOUR_HARNESS_TABS=${TABS:-4} \
  --env DETOUR_HARNESS_SWITCHES=${SWITCHES:-150} \
  --env DETOUR_HARNESS_INTERVAL=${INTERVAL:-0.7} \
  --env DETOUR_HARNESS_SETTLE=${SETTLE:-45} \
  --env DETOUR_HARNESS_URLS="${URLS:-}"
# wait for the harness to announce itself
for i in {1..60}; do [ -f $LOG ] && grep -q 'PHASE seed' $LOG && break; sleep 1; done
APPPID=$(grep -m1 -oE 'pid=[0-9]+' $LOG | cut -d= -f2)
echo "app pid $APPPID"
# newest GPU process started after launch
GPU=""
for i in {1..30}; do
  GPU=$(ps -axo pid,lstart,command | grep 'WebKit.GPU' | grep -v grep | while read pid rest; do
    st=$(ps -o lstart= -p $pid | xargs -I{} date -j -f '%a %b %d %T %Y' '{}' +%s 2>/dev/null)
    [ -n "$st" ] && [ "$st" -ge $((T0-2)) ] && echo $pid
  done | tail -1)
  [ -n "$GPU" ] && break; sleep 1
done
echo "gpu pid $GPU"
echo "time,phase,total,purged,ui_total" >> $CSV
while true; do
  phase=$(grep 'PHASE' $LOG | tail -1 | awk '{print $3}')
  total=$(vmmap --summary $GPU 2>/dev/null | awk '/^IOSurface/{print $NF}')
  purged=$(vmmap $GPU 2>/dev/null | grep -E '^IOSurface' | grep -c 'PURGE=E')
  ui=$(vmmap --summary $APPPID 2>/dev/null | awk '/^IOSurface/{print $NF}')
  echo "$(date +%T),$phase,${total:-0},${purged:-0},${ui:-0}" >> $CSV
  [ "$phase" = "done" ] && break
  sleep 5
done
echo "finished; killing harness app $APPPID"
kill $APPPID
