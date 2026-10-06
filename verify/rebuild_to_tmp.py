#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证用：重跑 build_quest_index.py，但输出到 verify/evidence/，
不触碰 models/quest_index.json（验证方不改产品产物）。"""
import importlib.util, json, os, sys, hashlib

ROOT = "/Users/dupi/Desktop/自动驾驶系统"
TMP  = f"{ROOT}/verify/evidence/quest_index.rebuilt.json"

spec = importlib.util.spec_from_file_location("bqi", f"{ROOT}/tools/quest/build_quest_index.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.OUT = TMP
doc = m.main()

def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()

print()
print("=== 比对 ===")
cur = f"{ROOT}/models/quest_index.json"
a = json.load(open(cur, encoding="utf-8"))
b = json.load(open(TMP, encoding="utf-8"))
print("现有 stats : %s" % json.dumps(a["stats"], ensure_ascii=False, sort_keys=True))
print("重建 stats : %s" % json.dumps(b["stats"], ensure_ascii=False, sort_keys=True))
print("stats 相等 : %s" % (a["stats"] == b["stats"]))
print("sha256 现有: %s" % sha(cur))
print("sha256 重建: %s" % sha(TMP))
print("字节级相同 : %s" % (sha(cur) == sha(TMP)))
print("doc 相等(除顺序): %s" % (a == b))

# 期望值硬比对
EXPECT = dict(files=39, objectives=3819, with_coord=2938,
              exact_keys=1372, core_keys=1984, name_keys=1128)
bad = {k: (v, b["stats"].get(k)) for k, v in EXPECT.items() if b["stats"].get(k) != v}
print()
print("期望值硬比对 : %s" % ("全部一致 ✅" if not bad else "不一致 ❌ %s" % bad))
sys.exit(0 if (not bad and a["stats"] == b["stats"]) else 1)
