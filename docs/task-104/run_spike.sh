#!/bin/zsh
# TASK-104 control: run the standalone WKWebView spike and sample its GPU process.
S=/private/tmp/claude-501/-Users-tma-Projects-browser-MyBrowser/199c0aa9-da49-4e03-a532-fc024459231e/scratchpad
MODE=${MODE:-remove}
LOG=$S/spike-$MODE.log
CSV=$S/spike-$MODE.csv
: > $CSV; rm -f $LOG
T0=$(date +%s)
$S/spike/spike "${URLS:-https://www.youtube.com/watch?v=dQw4w9WgXcQ,https://www.youtube.com/,https://github.com/WebKit/WebKit,https://www.apple.com/}" ${SWITCHES:-150} ${INTERVAL:-0.7} ${SETTLE:-45} $LOG $MODE > $S/spike-$MODE.out 2>&1 &
SPIKEPID=$!
for i in {1..60}; do [ -f $LOG ] && grep -q 'PHASE seed' $LOG && break; sleep 1; done
GPU=""
for i in {1..30}; do
  GPU=$(ps -axo pid,command | grep 'WebKit.GPU' | grep -v grep | while read pid rest; do
    st=$(ps -o lstart= -p $pid | xargs -I{} date -j -f '%a %b %d %T %Y' '{}' +%s 2>/dev/null)
    [ -n "$st" ] && [ "$st" -ge $((T0-2)) ] && echo $pid
  done | tail -1)
  [ -n "$GPU" ] && break; sleep 1
done
echo "spike pid $SPIKEPID gpu pid $GPU"
echo "time,phase,total,purged,ui_total" >> $CSV
while true; do
  phase=$(grep 'PHASE' $LOG | tail -1 | awk '{print $3}')
  total=$(vmmap --summary $GPU 2>/dev/null | awk '/^IOSurface/{print $NF}')
  purged=$(vmmap $GPU 2>/dev/null | grep -E '^IOSurface' | grep -c 'PURGE=E')
  ui=$(vmmap --summary $SPIKEPID 2>/dev/null | awk '/^IOSurface/{print $NF}')
  echo "$(date +%T),$phase,${total:-0},${purged:-0},${ui:-0}" >> $CSV
  [ "$phase" = "done" ] && break
  sleep 5
done
kill $SPIKEPID
echo "spike $MODE finished"
awk -F, 'NR>1{if($2!=p){print; p=$2} last=$0} END{print last}' $CSV
