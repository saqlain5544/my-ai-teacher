#!/bin/zsh
# Repeatable benchmark: cold launch (5 runs), idle footprint, and same-machine RSS comparison.
cd "$(dirname "$0")/.."
APP="build/My AI Teacher.app"; LOG=~/Library/Logs/MyAITeacher.log
times=()
for i in 1 2 3 4 5; do
  pkill -f "$APP/Contents/MacOS/MyAITeacher"; sleep 1.5
  n0=$(grep -c "transcript ready" $LOG 2>/dev/null || echo 0)
  t0=$(python3 -c 'import time;print(time.time())')
  open "$APP"
  while [ "$(grep -c 'transcript ready' $LOG)" -le "$n0" ]; do sleep 0.02; done
  times+=$(python3 -c "import time;print('%.2f'%(time.time()-$t0))")
done
echo "cold launch → transcript ready (s): ${times[*]}"
sleep 3
PID=$(pgrep -f "$APP/Contents/MacOS/MyAITeacher"); footprint -p $PID 2>/dev/null | sed -n 2p
for app in "My AI Teacher" Claude ChatGPT "MiniMax Code" Cursor "Visual Studio Code"; do
  pids=$(pgrep -f "/$app.app/" | paste -sd, -); [ -z "$pids" ] && continue
  ps -o rss= -p $pids | awk -v a="$app" '{s+=$1;n++} END {printf "%-18s %2d procs %6.0f MB RSS\n", a, n, s/1024}'
done
