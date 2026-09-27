#!/usr/bin/env python3
"""Summarize a `sample` file of the simulator app: the main thread's busy share
and where it went (inclusive), with the app's own frames listed.
usage: scripts/sample-report.py <sample.txt> [top]"""
import re, sys
rows=[]; started=False
for l in open(sys.argv[1]).read().split('\n'):
    if l.startswith('Call graph:'): started=True; continue
    if started and l.startswith('Total number in stack'): break
    if not started: continue
    m=re.match(r'^    ([+!:| ]*)(\d+) (.*)$', l)
    if not m: continue
    name=re.sub(r'\s+\(in .*$','',m.group(3)); name=re.sub(r'\s+\+ \d+.*$','',name)
    rows.append((len(m.group(1))//2,int(m.group(2)),name))
IDLE=('mach_msg2_trap','__psynch_cvwait','__semwait_signal','__ulock_wait','kevent','__workq_kernreturn','__select','__sigsuspend','mach_msg_trap','__accept','__recvfrom','__read','poll','__sleep','__usleep','__psynch_mutexwait','__CFRunLoopServiceMachPort')
top=int(sys.argv[2]) if len(sys.argv)>2 else 14
for i,(d,n,name) in enumerate(rows):
    if d!=0 or 'Main Thread' not in name: continue
    sub=[rows[i]]
    for r in rows[i+1:]:
        if r[0]<=0: break
        sub.append(r)
    total=sub[0][1]; idle=[0]*len(sub); stack=[]
    for j,(dd,nn,nm) in enumerate(sub):
        while stack and sub[stack[-1]][0]>=dd: stack.pop()
        if any(nm.startswith(k) for k in IDLE):
            for s in stack: idle[s]+=nn
            idle[j]+=nn
        stack.append(j)
    busy=total-idle[0]
    print(f'main thread: {total} samples, busy {busy} ({100*busy/total:.0f}%)')
    agg={}
    for j,(dd,nn,nm) in enumerate(sub):
        b=nn-idle[j]
        if b>0: agg[nm]=max(agg.get(nm,0),b)
    items=sorted(agg.items(), key=lambda x:-x[1])
    def show(pred, label, limit):
        print(f'-- {label}:'); k=0
        for nm,b in items:
            if pred(nm) and b>=busy*0.01:
                print(f'{b:5d} {100*b/busy:5.1f}%  {nm[:110]}'); k+=1
                if k>=limit: break
    show(lambda s: any(x in s for x in ('SurfGameView.body','Studio.','SurfRenderer','PartialJSON','StreamedField','Syntax','CodeView','StudioView','PaperGrain','GlyphCache','LayoutEngineBox.childGeometries','ViewGraphRootValueUpdater.render','GraphHost.flushTransactions','Sequence.sorted','__NSStringDrawingEngine','GraphicsContext.resolve')), 'app + key SwiftUI frames', top)
