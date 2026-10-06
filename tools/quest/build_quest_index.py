#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_quest_index.py —— 任务面板文字 → 坐标 索引

数据源: tools/nte_datatables/**/DT_Quest*.json 等 39 个任务表
产出:   models/quest_index.json  （Swift 直接读）

索引结构:
{
  "version": 1,
  "source": "...",
  "stats": {...},
  "exact":   { "完整描述文本": [entry...] },
  "core":    { "剥掉前缀的核心词": [entry...] },
  "byname":  { "任务名": [entry...] }
}
entry = {qid, quest, desc, core, otype, x, y, z, force, src}
"""
import json, glob, os, re, sys, collections

ROOT = "/Users/dupi/Desktop/自动驾驶系统"
DT   = f"{ROOT}/tools/nte_datatables"
OUT  = f"{ROOT}/models/quest_index.json"

def g(o, *ks):
    for k in ks:
        if not isinstance(o, dict): return None
        o = o.get(k)
    return o

# 面板前缀：动词/介词/类型标签 —— 剥掉后剩核心词
PREFIX_PATTERNS = [
    r"^与(.+?)(对话|交谈|交流|会合|碰面|见面)$",
    r"^和(.+?)(对话|交谈|交流|会合)$",
    r"^向(.+?)(对话|询问|打听)$",
    r"^跟随(.+?)(前往|来到|抵达)?(.+)?$",
    r"^前往(.+)$",
    r"^抵达(.+)$",
    r"^进入(.+)$",
    r"^走进(.+)$",
    r"^离开(.+)$",
    r"^找到(.+)$",
    r"^寻找(.+)$",
    r"^调查(.+)$",
    r"^击败(.+)$",
    r"^收集(.+)$",
    r"^取得(.+)$",
    r"^使用(.+)$",
    r"^搭乘(.+)$",
    r"^等待(.+)$",
    r"^聆听(.+)$",
    r"^查看(.+)$",
    r"^完成(.+)$",
    r"^\[(.+?)\](.+)$",      # [日常]迷星叫
    r"^【(.+?)】(.+)$",
]

TAGS = re.compile(r"<[^>]+>")          # <blue>异象管理局</>

def strip_tags(s):
    return TAGS.sub("", s or "").strip()

def core_of(desc):
    """剥掉装饰性前缀，返回核心词（可能多个候选）"""
    s = strip_tags(desc)
    if not s: return []
    cands = {s}
    for pat in PREFIX_PATTERNS:
        m = re.match(pat, s)
        if m:
            for grp in m.groups():
                if grp and len(grp) >= 2:
                    cands.add(grp.strip())
    # 去掉标点
    out = set()
    for c in cands:
        c = re.sub(r"[，。！？、,.!?…·—\-]+$", "", c).strip()
        if len(c) >= 2: out.add(c)
    return sorted(out, key=len, reverse=True)

def main():
    files = sorted(set(glob.glob(f"{DT}/**/*Quest*.json", recursive=True)))
    exact  = collections.defaultdict(list)
    core   = collections.defaultdict(list)
    byname = collections.defaultdict(list)

    n_obj = n_coord = n_desc = 0
    for f in files:
        try:
            d = json.load(open(f, encoding="utf-8"))
        except Exception:
            continue
        if isinstance(d, list): d = d[0] if d else {}
        if not isinstance(d, dict): continue
        rows = d.get("Rows") or {}
        if not isinstance(rows, dict): continue
        base = os.path.basename(f)

        for qid, v in rows.items():
            if not isinstance(v, dict): continue
            qname = strip_tags(g(v, "QuestName", "SourceString") or "")
            objs = v.get("ObjectivesInfo") or []
            if not isinstance(objs, list): continue
            for o in objs:
                if not isinstance(o, dict): continue
                n_obj += 1
                desc = strip_tags(g(o, "Description", "SourceString") or "")
                ti = o.get("TrackInfo") or {}
                tl = (ti.get("TrackLocation") or {}) if isinstance(ti, dict) else {}
                x, y, z = tl.get("X"), tl.get("Y"), tl.get("Z")
                has_c = bool(x or y or z)
                if has_c: n_coord += 1
                if desc: n_desc += 1
                if not has_c: continue          # 只要带坐标的

                ent = dict(
                    qid=str(qid), quest=qname, desc=desc,
                    otype=str(o.get("ObjectiveType") or ""),
                    x=x, y=y, z=z,
                    force=bool(ti.get("bForceTrackLocation")) if isinstance(ti, dict) else False,
                    src=base,
                )
                if desc:
                    exact[desc].append(ent)
                    for c in core_of(desc):
                        core[c].append(ent)
                if qname:
                    byname[qname].append(ent)

    def dedup(m):
        out = {}
        for k, lst in m.items():
            seen, uniq = set(), []
            for e in lst:
                sig = (e["qid"], e["desc"], e["x"], e["y"])
                if sig in seen: continue
                seen.add(sig); uniq.append(e)
            out[k] = uniq
        return out

    doc = dict(
        version=1,
        source="tools/nte_datatables (Waifus-Grace/NTE_Assets, tagged 1.4.5)",
        stats=dict(files=len(files), objectives=n_obj,
                   with_coord=n_coord, with_desc=n_desc,
                   exact_keys=len(exact), core_keys=len(core), name_keys=len(byname)),
        exact=dedup(exact), core=dedup(core), byname=dedup(byname),
    )
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
    print("✅ %s  %.2f MB" % (OUT, os.path.getsize(OUT) / 1048576))
    print("   统计: %s" % doc["stats"])
    return doc

if __name__ == "__main__":
    doc = main()

    # ---- 回归测试：用真实截图里的面板文字 ----
    tests = [
        "与路边着急的研究员对话",
        "抵达异象管理局",
        "与薄荷对话",
        "搭乘电梯",
        "赴约",
        "与龙叔交谈",
        "走进局长办公室",
        "与艾尔菲德交流",
    ]
    print()
    print("=== 回归测试（面板文字 → 坐标）===")
    print("%-24s %-8s %s" % ("面板文字", "命中", "结果"))
    print("-" * 88)
    hit_n = 0
    for t in tests:
        got = doc["exact"].get(t)
        how = "exact"
        if not got:
            for c in core_of(t):
                if c in doc["core"]:
                    got = doc["core"][c]; how = "core:" + c; break
        if not got:
            for nm, lst in doc["byname"].items():
                if nm and nm in t:
                    got = lst; how = "name:" + nm; break
        if got:
            hit_n += 1
            e = got[0]
            print("✅ %-22s %-8s %-12s (%.0f, %.0f, %.0f) %s" % (
                t, how, e["qid"][:12], e["x"] or 0, e["y"] or 0, e["z"] or 0, e["quest"][:14]))
        else:
            print("❌ %-22s %-8s 无命中" % (t, "-"))
    print()
    print("命中 %d / %d" % (hit_n, len(tests)))
