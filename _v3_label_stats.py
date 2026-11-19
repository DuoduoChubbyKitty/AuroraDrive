import csv, glob, os
from pathlib import Path
root=Path('data/lean_clips_clean')
tot={'W':0,'NONE':0,'S':0}
none_runs=[]      # 连续 NONE 的游程长度
restart=0         # NONE游程后紧跟 W 的次数（=人类“从停住重新起步”样本数）
long_none=0       # 长度>=5 的 NONE 游程个数
frames_total=0
def vert(w,s):
    if w: return 'W'
    if s: return 'S'
    return 'NONE'
for clip in sorted(root.glob('clip_*')):
    f=clip/'controls_clean.csv'
    if not f.exists(): continue
    rows=list(csv.DictReader(open(f,encoding='utf-8')))
    seq=['W' if r['w'].strip() not in ('','0') else ('S' if r['s'].strip() not in ('','0') else 'NONE') for r in rows]
    frames_total+=len(seq)
    for v in seq: tot[v]+=1
    # 游程分析
    i=0; n=len(seq)
    prev_run=None
    while i<n:
        j=i
        while j<n and seq[j]==seq[i]: j+=1
        run=seq[i]; length=j-i
        if run=='NONE':
            none_runs.append(length)
            if length>=5: long_none+=1
            # 之后是否 W（起步）
            if j<n and seq[j]=='W' and length>=2:  # 停>=2帧后起步
                restart+=1
        i=j
print("总帧:",frames_total)
print("纵向真值分布 W/NONE/S:",tot, " 占比 W=%.1f%% NONE=%.1f%% S=%.1f%%"%(100*tot['W']/frames_total,100*tot['NONE']/frames_total,100*tot['S']/frames_total))
import statistics as st
if none_runs:
    print(f"NONE(停/滑行)连续游程: 共{len(none_runs)}段, 中位={st.median(none_runs):.0f}帧, 最长={max(none_runs)}帧, >=5帧的长停{long_none}段")
print(f"人类'停>=2帧后再起步(W)'事件(restart) 全库合计: {restart} 次  <- 这就是模型最缺的'从停住重新起步'样本")
