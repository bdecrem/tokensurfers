#!/usr/bin/env python3
"""Turn a recorded feed (a saved GET events?after=0 response, v1 shape) into a
stress feed: the first Write becomes a 40 KB file streamed over 45 s in 120 ms
ticks (the shape that made the phone sluggish). Every `file` event's content is
padded too, so only the FIRST 'decoder ok' line of a replay is meaningful.
usage: make-stress-feed.py <feed.json> <out.json> [bytes] [seconds]"""
import json, sys, copy
src, out = sys.argv[1], sys.argv[2]
size = int(sys.argv[3]) if len(sys.argv) > 3 else 40000
secs = float(sys.argv[4]) if len(sys.argv) > 4 else 45
feed = json.load(open(src)); ev = feed['events']
html = max((e.get('content', '') for e in ev if e['type'] == 'file'), key=len, default='<!doctype html><p>hi</p>')
big = ((html + '\n<!-- pad -->\n') * (size // max(1, len(html)) + 1))[:size]
wid = next(e['id'] for e in ev if e['type'] == 'tool_start' and e['name'] == 'Write')
ti = [e for e in ev if e['type'] == 'tool_input' and e['id'] == wid]
first, last = ti[0], ti[-1]
content = json.dumps(big)[1:-1]
prefix = '{"file_path": "/Users/admin/surf-apps/surf-stress/index.html", "content": "'
n = int(secs / 0.12); seq = first['seq']; synth = []
for k in range(n):
    frac = (k + 1) / n; cut = int(len(content) * frac)
    synth.append({'seq': seq, 't': int(first['t'] + secs * 1000 * frac), 'type': 'tool_input', 'id': wid, 'name': 'Write',
                  'json': prefix + content[:cut] + ('"}' if k == n - 1 else '')})
    seq += 1
res = [e for e in ev if e['seq'] < first['seq']] + synth
shift = first['t'] + secs * 1000 - last['t']
for e in ev:
    if e['seq'] <= last['seq']: continue
    e = copy.deepcopy(e); e['t'] += shift; e['seq'] = seq; seq += 1
    if e['type'] == 'file' and 'content' in e: e['content'] = big; e['size'] = len(big)
    res.append(e)
json.dump({'events': res, 'seq': seq - 1, 'state': feed.get('state', {}), 'gap': False}, open(out, 'w'))
print(len(res), 'events,', round(sum(len(json.dumps(e)) for e in res) / 1e6, 1), 'MB')
