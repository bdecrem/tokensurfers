#!/usr/bin/env python3
"""The simulator app's console into a file, line by line, from a shell whose
stdin is not a terminal (Claude's Bash tool: `script` refuses there).
Wraps `simctl launch --console-pty` in a pseudo-terminal of its own.

    SIMCTL_CHILD_TS_PERF=1 SIMCTL_CHILD_TS_SOLO=1 SIMCTL_CHILD_TS_BOT=1 \
      nohup python3 apps/tokensurfers/scripts/sim-console.py /tmp/run.log "iPhone 17 Pro" &
    grep '\[perf\]' /tmp/run.log

Set SIMCTL_CHILD_* env vars for the app (TS_PERF prints CPU/mem/fps every 2 s,
TS_AUTORUN starts a build, TS_SOLO/TS_BOT play the game). Kill it with
`pkill -f sim-console.py`; the app keeps running.
"""
import os, pty, sys, select
out = open(sys.argv[1], 'ab', buffering=0)
device = sys.argv[2] if len(sys.argv) > 2 else 'iPhone 17 Pro'
bundle = sys.argv[3] if len(sys.argv) > 3 else 'com.bartdecrem.tokensurfers'
pid, fd = pty.fork()
if pid == 0:
    os.execvp('xcrun', ['xcrun', 'simctl', 'launch', '--console-pty', device, bundle])
while True:
    r, _, _ = select.select([fd], [], [], 5)
    if fd in r:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        out.write(data)
