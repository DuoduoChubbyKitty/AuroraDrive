#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证方独立复验：quest_matcher 假阳性修复（lead 报 HIGH 已修）"""
import sys, json, random, itertools, collections
sys.path.insert(0, "/Users/dupi/Desktop/自动驾驶系统/tools/quest")
from quest_matcher import QuestMatcher

m = QuestMatcher()
FAIL = []

def check(name, cond, detail=""):
    print("%s %s%s" % ("✅" if cond else "❌", name, ("  → " + detail) if detail else ""))
    if not cond: FAIL.append(name)

print("=" * 78)
print("A) 穷举：索引里出现的全部单个汉字 → 判 ok 必须 = 0（修复前 892）")
print("=" * 78)
chars = set()
for k in list(m.exact.keys()) + list(m.core.keys()) + list(m.byname.keys()):
    for ch in k:
        if '\u4e00' <= ch <= '\u9fff': chars.add(ch)
chars = sorted(chars)
vc = collections.Counter()
okc = []
for c in chars:
    e, how, sc, v = m.match_confident(c)
    vc[v] += 1
    if v == "ok": okc.append((c, how, e[0]['quest'][:16] if e else ''))
print("汉字总数: %d" % len(chars))
print("verdict 分布: %s" % dict(vc))
check("单汉字判 ok 数量 = 0", vc["ok"] == 0, "实测 ok=%d" % vc["ok"])
if okc[:10]: print("   仍假报唯一的样例:", okc[:10])

print()
print("=" * 78)
print("B) 随机 3000 个双字组合 → 判 ok 必须 = 0")
print("=" * 78)
random.seed(20261006)
allchars = chars
combos = ["".join(random.sample(allchars, 2)) for _ in range(3000)]
vc2 = collections.Counter(); okc2 = []
for c in combos:
    e, how, sc, v = m.match_confident(c)
    vc2[v] += 1
    if v == "ok": okc2.append((c, how))
print("组合数: %d" % len(combos))
print("verdict 分布: %s" % dict(vc2))
check("双字组合判 ok 数量 = 0", vc2["ok"] == 0, "实测 ok=%d" % vc2["ok"])
if okc2[:10]: print("   仍假报唯一的样例:", okc2[:10])

print()
print("=" * 78)
print("C) 8 条真实面板文字 → 必须全部 verdict=ok")
print("=" * 78)
REAL = ["与路边着急的研究员对话", "路边着急的研究员对话", "与路边着急的研究员话",
        "搭乘电梯", "走进局长办公室", "与艾尔菲德交流", "向眼前之人对话",
        "进入电话亭", "聆听奈丽的介绍"]
allok = True
for t in REAL:
    e, how, sc, v = m.match_confident(t)
    mark = "✅" if v == "ok" else "❌"
    if v != "ok": allok = False
    print("%s %-24s %-16s 候选=%-4d verdict=%s" % (mark, t, how[:14], len(e), v))
check("9 条真实面板文字全部 verdict=ok", allok)

print()
print("=" * 78)
print("D) 指定反向用例")
print("=" * 78)
EXPECT = [
    ("与薄荷对话", "ambiguous"),
    ("与龙叔交谈", "ambiguous"),
    ("对话",       "low"),
    ("前往",       "low"),
    ("的",         "low"),
    ("E",          "low"),
    ("异",         "low"),
    ("[剧情HeroicApearan", "miss"),
    ("",           "miss"),
]
allok2 = True
for t, want in EXPECT:
    e, how, sc, v = m.match_confident(t)
    ok = (v == want)
    if not ok: allok2 = False
    print("%s %-22s 期望=%-10s 实测=%-10s 候选=%-4d how=%s" % (
        "✅" if ok else "❌", repr(t)[:20], want, v, len(e), how[:16]))
check("反向用例全部符合预期", allok2)

print()
print("=" * 78)
print("E) 原任务要求的 3 条反向测试（不得回归）")
print("=" * 78)
e, how, sc, amb = m.match("对话")
check("「对话」match() 仍报 364 候选", len(e) == 364 and amb, "实测候选=%d ambiguous=%s" % (len(e), amb))
e, how, sc, amb = m.match("[剧情HeroicApearan")
check("「[剧情HeroicApearan」仍 miss", how == "miss" and not e, "how=%s" % how)
e, how, sc, amb = m.match("")
check("空串仍 empty", how == "empty" and not e, "how=%s" % how)

print()
print("=" * 78)
print("F) 原 9 条唯一命中是否被修复误伤（不得回归）")
print("=" * 78)
UNIQ = ["与路边着急的研究员对话", "路边着急的研究员对话", "与路边着急的研究员话",
        "搭乘电梯", "走进局长办公室", "与艾尔菲德交流", "向眼前之人对话",
        "进入电话亭", "聆听奈丽的介绍"]
still = 0
for t in UNIQ:
    e, how, sc, amb = m.match(t)
    if len(e) == 1 and not amb: still += 1
    else: print("   ❌ %s 候选=%d ambiguous=%s" % (t, len(e), amb))
check("9 条唯一命中未被误伤", still == 9, "实测 %d/9" % still)

print()
print("=" * 78)
print("G) 修复强度：随机采样真实面板文字的前 2/3 字（爆炸半径复测）")
print("=" * 78)
keys = [k for k in m.exact if len(k) >= 6]
random.seed(42)
sample = random.sample(keys, min(300, len(keys)))
for n in (2, 3):
    c = 0
    for k in sample:
        e, how, sc, v = m.match_confident(k[:n])
        if v == "ok": c += 1
    print("  取真实面板文字前 %d 字 → 判 ok %d/300   (修复前: %d/300)" % (
        n, c, 237 if n == 2 else 222))

print()
print("=" * 78)
print("H) 4 字及以上真实文本是否仍可正常匹配（功能未退化）")
print("=" * 78)
ok4 = 0
tot4 = 0
for k in sample[:200]:
    tot4 += 1
    e, how, sc, v = m.match_confident(k)
    if v == "ok": ok4 += 1
print("  200 条真实面板文字(≥6字) → verdict=ok %d/200 (%.0f%%)" % (ok4, 100.0*ok4/tot4))

print()
print("=" * 78)
print("结论: %s" % ("全部通过 ✅" if not FAIL else "存在失败项 ❌ %s" % FAIL))
print("=" * 78)
sys.exit(1 if FAIL else 0)
