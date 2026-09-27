#!/bin/bash
# Token Surfers perf benchmark: replays a recorded feed in the simulator with the
# perf meter on, samples the process, and averages CPU / main-thread CPU / fps
# over the replay. Usage: scripts/perf-replay.sh <feed.json> <label> [sample-at-s]
set -e
FEED=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); LABEL=$2; AT=${3:-25}
APP=/Users/bart/Documents/code/hilma/apps/tokensurfers
OUT=$APP/.shots/perf; mkdir -p "$OUT"
SIM="iPhone 17 Pro"
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl terminate "$SIM" com.bartdecrem.tokensurfers 2>/dev/null || true
xcrun simctl install "$SIM" "$APP/build/dd/Build/Products/Debug-iphonesimulator/TokenSurfers.app"
LOG="$OUT/replay-$LABEL.log"
(SIMCTL_CHILD_TS_PERF=1 SIMCTL_CHILD_TS_REPLAY="$FEED" SIMCTL_CHILD_TS_AUTORUN="benchmark" \
  xcrun simctl launch --console-pty --terminate-running-process "$SIM" com.bartdecrem.tokensurfers > "$LOG" 2>&1 &)
sleep "$AT"
PID=$(pgrep -f "Containers/Bundle/Application/.*/TokenSurfers.app/TokenSurfers" | head -1)
sample "$PID" 12 -mayDie -file "$OUT/sample-$LABEL.txt" >/dev/null 2>&1 || true
for i in $(seq 1 60); do grep -q "replay done" "$LOG" && break; sleep 2; done
xcrun simctl io "$SIM" screenshot "$OUT/replay-$LABEL.png" >/dev/null 2>&1 || true
xcrun simctl terminate "$SIM" com.bartdecrem.tokensurfers 2>/dev/null || true
python3 - "$LOG" "$LABEL" <<'PY'
import re,sys
lines=open(sys.argv[1]).read().split('\n')
perf=[l for l in lines if l.startswith('[perf]')]
# the replay window: between "replay:" and "replay done"
try:
    a=next(i for i,l in enumerate(lines) if 'replay:' in l); b=next(i for i,l in enumerate(lines) if 'replay done' in l)
except StopIteration:
    a,b=0,len(lines)
win=[l for l in lines[a:b] if l.startswith('[perf]')]
def nums(l):
    m=re.search(r'cpu (\d+)% of one core.*?main (\d+)%.*?mem (\d+) MB.*?(\d+) fps', l)
    return tuple(int(x) for x in m.groups()) if m else None
vals=[v for v in map(nums,win) if v][1:]   # the first tick's fps is bogus (frames since launch)
if vals:
    n=len(vals); med=lambda xs: sorted(xs)[len(xs)//2]
    print(f"{sys.argv[2]}: {n} samples during the replay — cpu {sum(v[0] for v in vals)/n:.0f}% of a core (median {med([v[0] for v in vals])}) · main thread {sum(v[1] for v in vals)/n:.0f}% (median {med([v[1] for v in vals])}) · mem {max(v[2] for v in vals)} MB peak · {med([v[3] for v in vals])} fps median")
else:
    print('no perf lines in window'); print('\n'.join(perf[-5:]))
PY
