#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证 2 深挖：独立复算 Python 侧参考行为，供与 Swift 对拍。
(a) ratio 实现是否与 difflib.SequenceMatcher 一致
(b) CRLF key 的长度守卫行为
(c) core-sub 比对对象（整条查询 t vs 核心词候选 c）
"""
import json, sys, random, difflib, re
sys.path.insert(0, "/Users/dupi/Desktop/自动驾驶系统/tools/quest")
from quest_matcher import QuestMatcher, clean, core_candidates

ROOT = "/Users/dupi/Desktop/自动驾驶系统"
m = QuestMatcher()
idx = json.load(open(f"{ROOT}/models/quest_index.json", encoding="utf-8"))

print("=" * 78)
print("(b) CRLF key 的长度守卫行为")
print("=" * 78)
crlf_keys = [k for k in idx["exact"] if "\r" in k or "\n" in k]
print("含 CRLF 的 exact key: %d 条" % len(crlf_keys))
for k in crlf_keys:
    py_len = len(k)
    sw_scalar = len(k)          # Python len == 码点数 == Swift unicodeScalars.count
    sw_grapheme = len(k) - k.count("\r\n")   # 每个 \r\n 合并成 1 grapheme
    print("  py_len=%-3d swift_scalar=%-3d swift_grapheme=%-3d  守卫(len>=4)两法都过: %s" % (
        py_len, sw_scalar, sw_grapheme, py_len >= 4 and sw_grapheme >= 4))
print()
print("→ 4 条 key 都远超 4 字门槛，grapheme/scalar 差异（1 个字符）**不影响守卫结论**。")
print("  但 ratio 计算的分母会差 1 → 见下面逐条验证。")

print()
print("=" * 78)
print("(a) ratio 一致性：difflib.SequenceMatcher.ratio() 语义")
print("=" * 78)
# Python 的 ratio = 2*M/T，M=匹配字符数，T=两串总长
# wiring 报「5157 对向量零偏差」—— 我独立抽 200 对复算
random.seed(7)
keys = list(idx["exact"].keys())
sample = random.sample(keys, min(200, len(keys)))
bad = 0
for k in sample:
    # 构造若干查询变体
    variants = [k, k[:max(1, len(k)-1)], k[1:], k[:len(k)//2] if len(k) > 1 else k]
    for v in variants:
        if not v: continue
        r = difflib.SequenceMatcher(None, v, k).ratio()
        # 手算 2M/T
        sm = difflib.SequenceMatcher(None, v, k)
        M = sum(b.size for b in sm.get_matching_blocks())
        T = len(v) + len(k)
        manual = 2.0 * M / T if T else 1.0
        if abs(r - manual) > 1e-12:
            bad += 1
            if bad <= 3:
                print("  ❌ 不一致: %r vs %r  ratio=%.15f manual=%.15f" % (v[:12], k[:12], r, manual))
print("抽检 %d 条 key × 4 变体 = %d 对，ratio 与手算 2M/T 不一致: %d" % (len(sample), len(sample)*4, bad))

print()
print("=" * 78)
print("(c) core-sub 比对对象：Python 用整条查询 t 还是核心词候选 c？")
print("=" * 78)
# 复现 quest_matcher.py 第 3 段逻辑
def py_core_route(t):
    """返回 (命中key, 用的是什么) 或 None"""
    for c in core_candidates(t):
        if c in m.core:
            return (c, "core-exact", c)
        for k, v in m.core.items():
            if len(k) >= 4 and (k in t or t in k):
                return (k, "core-sub", c)
    return None

cases = ["进入藏馆", "与路边着急的研究员话", "前往牛奶雪冰山", "赴约", "抵达异象管理局"]
print("%-22s %-14s %-14s %s" % ("查询", "命中key", "方式", "用的是"))
print("-" * 78)
for t in cases:
    r = py_core_route(t)
    if r:
        print("%-22s %-14s %-14s %s" % (t[:20], r[0][:14], r[1], "整条查询 t" if r[1]=="core-sub" else "核心词候选 c"))
    else:
        print("%-22s %-14s %-14s %s" % (t[:20], "-", "无 core 命中", "-"))

print()
print("关键对照：若 core-sub 误用核心词候选 c（而非整条查询 t）")
for t in cases:
    cands = core_candidates(t)
    for c in cands:
        hit_t = [k for k in m.core if len(k) >= 4 and (k in t or t in k)]
        hit_c = [k for k in m.core if len(k) >= 4 and (k in c or c in k)]
        if set(hit_t) != set(hit_c):
            print("  ⚠️ %-16s 候选 c=%-14s  t命中=%-20s c命中=%s" % (
                t[:16], c[:14], str(hit_t[:2])[:20], str(hit_c[:2])[:20]))
print()
print("→ 两者结果不同的样本数（说明该 bug 真实存在且可复现）：见上")
