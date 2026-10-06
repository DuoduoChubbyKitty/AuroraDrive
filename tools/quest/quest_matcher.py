#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
quest_matcher.py —— 任务面板文字 → 坐标 匹配器（含模糊匹配 + 投票 + 链消歧）

用法:
  python3 tools/quest/quest_matcher.py --selftest          # 用真实截图回归测试
  python3 tools/quest/quest_matcher.py "与龙叔交谈"         # 单条查询

设计:
  1. 精确匹配 → 命中即返回
  2. 模糊匹配（difflib.SequenceMatcher，阈值可调）→ 取最高分
  3. 歧义消解：用 NextQuests/PreQuests 链 + 当前状态
  4. 投票缓冲：连续 N 次相同结果才确认（抗 OCR 抖动）
"""
import json, os, re, sys, difflib, collections, argparse

ROOT = "/Users/dupi/Desktop/自动驾驶系统"
INDEX = f"{ROOT}/models/quest_index.json"
DT    = f"{ROOT}/tools/nte_datatables"

TAGS = re.compile(r"<[^>]+>")

# ---------- 面板前缀剥离（与 build_quest_index.py 保持一致）----------
PREFIX_PATTERNS = [
    r"^与(.+?)(对话|交谈|交流|会合|碰面|见面)$",
    r"^和(.+?)(对话|交谈|交流|会合)$",
    r"^向(.+?)(对话|询问|打听)$",
    r"^跟随(.+?)(前往|来到|抵达)?(.+)?$",
    r"^前往(.+)$", r"^抵达(.+)$", r"^进入(.+)$", r"^走进(.+)$",
    r"^离开(.+)$", r"^找到(.+)$", r"^寻找(.+)$", r"^调查(.+)$",
    r"^击败(.+)$", r"^收集(.+)$", r"^取得(.+)$", r"^使用(.+)$",
    r"^搭乘(.+)$", r"^等待(.+)$", r"^聆听(.+)$", r"^查看(.+)$",
    r"^完成(.+)$",
    r"^\[(.+?)\](.+)$", r"^【(.+?)】(.+)$",
]

def clean(s):
    return TAGS.sub("", s or "").strip()

def core_candidates(desc):
    s = clean(desc)
    if not s: return []
    cands = {s}
    for pat in PREFIX_PATTERNS:
        m = re.match(pat, s)
        if m:
            for grp in m.groups():
                if grp and len(grp) >= 2:
                    cands.add(grp.strip())
    out = []
    for c in cands:
        c = re.sub(r"[，。！？、,.!?…·—\-]+$", "", c).strip()
        if len(c) >= 2: out.append(c)
    return sorted(set(out), key=len, reverse=True)


class QuestMatcher:
    def __init__(self, index_path=INDEX, fuzzy_threshold=0.62):
        self.doc = json.load(open(index_path, encoding="utf-8"))
        self.exact  = self.doc["exact"]
        self.core   = self.doc["core"]
        self.byname = self.doc["byname"]
        self.thr = fuzzy_threshold
        self._chain = None          # 懒加载任务链
        # 投票缓冲
        self._last_text = None
        self._votes = 0
        self._confirmed = None

    # ---------------- 任务链 ----------------
    def chain(self):
        """构建 qid -> {next:[], pre:[], chapter, progress} 图"""
        if self._chain is not None: return self._chain
        ch = {}
        import glob
        for f in glob.glob(f"{DT}/**/DT_Quest*.json", recursive=True):
            try: d = json.load(open(f, encoding="utf-8"))
            except Exception: continue
            if isinstance(d, list): d = d[0] if d else {}
            if not isinstance(d, dict): continue
            rows = d.get("Rows") or {}
            if not isinstance(rows, dict): continue
            for qid, v in rows.items():
                if not isinstance(v, dict): continue
                nxt = v.get("NextQuests") or []
                pre = v.get("PreQuests") or []
                ch[str(qid)] = dict(
                    next=[str(x) for x in nxt if x and x != "None"],
                    pre=[str((p or {}).get("PreQuestName")) for p in pre
                         if isinstance(p, dict) and (p or {}).get("PreQuestName")],
                    chapter=str(v.get("ChapterID") or ""),
                    progress=v.get("ChapterProgress"),
                    qtype=str(v.get("QuestType") or ""),
                )
        self._chain = ch
        return ch

    # ---------------- 匹配 ----------------
    def _fuzzy(self, text, pool, topk=3):
        scored = []
        for k in pool:
            r = difflib.SequenceMatcher(None, text, k).ratio()
            if r >= self.thr:
                scored.append((r, k))
        scored.sort(reverse=True)
        return scored[:topk]

    def match(self, text, cur_qid=None):
        """返回 (entries, how, score, ambiguous)"""
        t = clean(text)
        if not t:
            return [], "empty", 0.0, False

        # 1. 精确
        if t in self.exact:
            e = self.exact[t]
            return e, "exact", 1.0, len(e) > 1

        # 2. 子串（OCR 丢前缀时最有效）
        #    守卫：查询串本身必须够长，否则「对话」会误命中「S1113对话」这种长 key
        subs = []
        if len(t) >= 4:
            for k, v in self.exact.items():
                if len(k) < 4: continue
                if k in t or t in k:
                    # 长度比不能太悬殊（短串套长串容易误命中）
                    ratio = min(len(k), len(t)) / max(len(k), len(t))
                    if ratio < 0.5: continue
                    subs.append((ratio, len(k), k, v))
            subs.sort(reverse=True)
        if subs:
            e = subs[0][3]
            return e, "substr:" + subs[0][2][:16], 0.95, len(e) > 1

        # 3. 核心词
        for c in core_candidates(t):
            if c in self.core:
                e = self.core[c]
                return e, "core:" + c[:16], 0.9, len(e) > 1
            for k, v in self.core.items():
                if len(k) >= 4 and (k in t or t in k):
                    return v, "core-sub:" + k[:16], 0.85, len(v) > 1

        # 4. 模糊
        best = self._fuzzy(t, list(self.exact.keys()), 1)
        if best:
            r, k = best[0]
            return self.exact[k], "fuzzy:%.2f:%s" % (r, k[:16]), r, len(self.exact[k]) > 1

        # 5. 任务名
        #    ⚠️ 2026-10-06 修复（验证方报 HIGH 假阳性）：
        #    原实现是裸 `in`，没有长度守卫 → 单字查询「的」「E」「异」都能假报唯一。
        #    实测索引里 1591 个单汉字有 892 个假报唯一（56%）。
        #    真实面板文字以 4~7 字为主，短查询本来就该判存疑。
        #    现在加：查询长度 >=4 且长度比 >=0.5，与 substr 分支同标准。
        if len(t) >= 4:
            for nm, v in self.byname.items():
                if len(nm) < 4: continue
                if nm in t or t in nm:
                    ratio = min(len(nm), len(t)) / max(len(nm), len(t))
                    if ratio < 0.5: continue
                    return v, "name:" + nm[:16], 0.8, len(v) > 1

        return [], "miss", 0.0, False

    # ---------------- 统一置信门槛 ----------------
    def match_confident(self, text, cur_qid=None, min_len=4):
        """带置信判定的匹配 —— **接线方应该用这个，不要直接用 match()**。

        返回 (entries, how, score, verdict)
          verdict: "ok"        唯一且可信 → 可直接用于寻路
                   "ambiguous" 多候选    → 需链消歧或等下一帧
                   "low"       文本太短/太弱 → 丢弃，不要用
                   "miss"      没匹配上
        """
        e, how, sc, amb = self.match(text, cur_qid)
        t = clean(text)
        if not e:
            return e, how, sc, "miss"
        if len(t) < min_len:
            return e, how, sc, "low"
        if how.startswith("fuzzy") and sc < 0.75:
            return e, how, sc, "low"
        if amb:
            return e, how, sc, "ambiguous"
        return e, how, sc, "ok"

    # ---------------- 投票 ----------------
    def feed(self, text, need=3):
        """投喂一帧 OCR 结果，连续 need 次相同才确认。
        返回 (confirmed_text, result) 或 (None, None)"""
        t = clean(text)
        if not t:
            return None, None
        if t == self._last_text:
            self._votes += 1
        else:
            self._last_text = t
            self._votes = 1
        if self._votes == need:
            self._confirmed = t
            return t, self.match(t)
        return None, None

    # ---------------- 链消歧 ----------------
    def resolve_ambiguous(self, entries, cur_qid=None):
        """多候选时用任务链 + 当前 qid 消歧"""
        if len(entries) <= 1:
            return entries, "unique"
        ch = self.chain()
        # a) 若已知当前任务，找它的 NextQuests 里出现的候选
        if cur_qid and cur_qid in ch:
            nxt = set(ch[cur_qid]["next"])
            pref = [e for e in entries if e["qid"] in nxt]
            if len(pref) == 1:
                return pref, "chain-next"
            if pref:
                return pref, "chain-next-multi"
        # b) 按 ChapterProgress 排序（同一章节内序号大的更靠后）
        with_p = [(e, (ch.get(e["qid"]) or {}).get("progress")) for e in entries]
        vals = [(e, p) for e, p in with_p if isinstance(p, (int, float))]
        if len(vals) == len(entries) and len(set(p for _, p in vals)) == len(vals):
            vals.sort(key=lambda x: x[1])
            return [e for e, _ in vals], "chapter-order"
        return entries, "ambiguous"


# ---------------- 自测 ----------------
def selftest():
    m = QuestMatcher()
    print("索引: %s" % INDEX)
    print("统计: %s" % m.doc["stats"])
    print()
    cases = [
        # (文本, 备注, 期望verdict)
        ("与路边着急的研究员对话", "真实截图", "ok"),
        ("路边着急的研究员对话",   "OCR 丢「与」", "ok"),
        ("与路边着急的研究员话",   "OCR 丢「对」", "ok"),
        ("与龙叔交谈",             "真实截图", "ambiguous"),
        ("龙叔交谈",               "OCR 丢「与」", "ambiguous"),
        ("与薄荷对话",             "多候选", "ambiguous"),
        ("搭乘电梯",               "唯一", "ok"),
        ("走进局长办公室",         "唯一", "ok"),
        ("与艾尔菲德交流",         "唯一", "ok"),
        ("向眼前之人对话",         "唯一", "ok"),
        ("进入电话亭",             "唯一", "ok"),
        ("聆听奈丽的介绍",         "唯一", "ok"),
        ("对话",                   "歧义 364", "low"),
        ("[剧情HeroicApearan",     "OCR 切错行", "miss"),
        ("",                       "空", "miss"),
    ]
    print("%-24s %-14s %-8s %-10s %s" % ("输入", "匹配方式", "候选", "verdict", "期望/结果"))
    print("-" * 100)
    ok = 0
    for t, note, want in cases:
        e, how, sc, verdict = m.match_confident(t)
        good = (verdict == want)
        if good: ok += 1
        coord = ""
        if e:
            r = e[0]
            coord = "(%.0f,%.0f,%.0f)" % (r["x"] or 0, r["y"] or 0, r["z"] or 0)
        print("%s %-22s %-14s %-8d %-10s want=%-10s %s %s" % (
            "✅" if good else "❌", t[:20], how[:12], len(e), verdict, want, coord, note))
    print()
    print("verdict 正确: %d / %d" % (ok, len(cases)))
    return 0 if ok == len(cases) else 1


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("text", nargs="*", help="要查询的面板文字")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--threshold", type=float, default=0.62)
    a = ap.parse_args()

    if a.selftest or not a.text:
        sys.exit(selftest())
    else:
        m = QuestMatcher(fuzzy_threshold=a.threshold)
        for t in a.text:
            e, how, sc, amb = m.match(t)
            print("=== %s" % t)
            print("    方式=%s  分数=%.2f  候选=%d" % (how, sc, len(e)))
            for r in e[:6]:
                print("      %-14s %-16s (%.0f, %.0f, %.0f)  %s" % (
                    r["qid"][:12], r["quest"][:14], r["x"] or 0, r["y"] or 0, r["z"] or 0, r["src"][:22]))
