#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_taxonomy.py — 词表门禁（可重跑、可进 CI）

为什么要有独立的检查脚本，而不是让 build 自己打印：
  「生成脚本自己说自己没问题」不是证据。门禁脚本独立读产物 + 独立读源数据，
  交叉核对。任何一条不满足就非 0 退出，可用于拦截回归。

检查项：
  1. 覆盖：每个标记都有分类，一个不漏
  2. 无孤儿：词表里不能有源数据中不存在的 id
  3. 组量：7 组计数与冻结基线一致（±0 容忍 —— 数字是实测钉死的）
  4. 结构：groups/categories/byMarker 齐备，组 id 合法
  5. 语义抽查：若干「曾经出过错」的标记必须落在正确的组
     （这些是回归测试，不是随便挑的）

用法：
    python tools/roadnet/check_taxonomy.py
"""

import collections
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(_HERE, "..", ".."))
SRC = os.path.join(ROOT, "models", "FINAL_complete_map_database.json")
TAX = os.path.join(ROOT, "models", "marker_taxonomy.json")

# ── 冻结基线：2026-10-03 实测，type 优先于 icon 的版本 ──
EXPECT_GROUPS = {
    "explore":  2434,
    "resource":  964,
    "travel":    106,
    "monster":   725,
    "shop":      677,
    "service":   269,
    "landmark":  502,
}
EXPECT_TOTAL = 5677
VALID_GROUPS = set(EXPECT_GROUPS)

fail = 0


def ck(name, cond, detail=""):
    global fail
    if not cond:
        fail += 1
    print(f"  {'✓' if cond else '✗'} {name}{'  — ' + detail if detail else ''}")


def main():
    print("═══ 标记词表自检 ═══")
    for p in (SRC, TAX):
        if not os.path.exists(p):
            print(f"  ✗ 文件不存在：{os.path.relpath(p, ROOT)}")
            return 1

    with open(SRC, encoding="utf-8") as f:
        src = json.load(f)
    with open(TAX, encoding="utf-8") as f:
        tax = json.load(f)

    markers = src.get("markers_all") or []
    by_marker = tax.get("byMarker") or {}
    groups = tax.get("groups") or []
    categories = tax.get("categories") or []

    # ── 1. 结构 ──
    print("  ── 结构 ──")
    ck("groups 非空", len(groups) > 0, f"{len(groups)} 组")
    ck("categories 非空", len(categories) > 0, f"{len(categories)} 类")
    ck("byMarker 非空", len(by_marker) > 0, f"{len(by_marker)} 条")
    ck("schema 版本存在", tax.get("schema") == 1, f"schema={tax.get('schema')}")
    gids = {g.get("id") for g in groups}
    ck("7 组 id 合法", gids == VALID_GROUPS,
       f"实测 {sorted(gids)}")
    ck("每组有中文名与颜色",
       all(g.get("label") and g.get("color") for g in groups))

    # ── 2. 覆盖 ──
    print("  ── 覆盖 ──")
    src_ids = [m.get("id") for m in markers]
    src_set = set(src_ids)
    ck("源数据 id 唯一", len(src_set) == len(src_ids),
       f"{len(src_ids)} 个 / {len(src_set)} 唯一")
    missing = [i for i in src_ids if i not in by_marker]
    ck("每个标记都有分类", not missing,
       f"缺 {len(missing)} 个" + (f"，例：{missing[:3]}" if missing else ""))
    orphan = [i for i in by_marker if i not in src_set]
    ck("无孤儿条目", not orphan,
       f"多 {len(orphan)} 个" + (f"，例：{orphan[:3]}" if orphan else ""))
    ck("总数 = 5677", len(by_marker) == EXPECT_TOTAL, f"{len(by_marker)}")

    # ── 3. 分类值合法 ──
    print("  ── 分类值 ──")
    bad_g = collections.Counter()
    for cat in by_marker.values():
        g = cat.split(":")[0]
        if g not in VALID_GROUPS:
            bad_g[g] += 1
    ck("所有分类前缀是合法组", not bad_g,
       f"非法 {dict(bad_g)}" if bad_g else "")

    # ── 4. 组量（冻结基线）──
    print("  ── 组量（冻结基线，±0 容忍）──")
    cnt = collections.Counter(c.split(":")[0] for c in by_marker.values())
    ok_all = True
    for g, want in sorted(EXPECT_GROUPS.items(), key=lambda kv: -kv[1]):
        got = cnt.get(g, 0)
        ok = got == want
        ok_all = ok_all and ok
        ck(f"{g} = {want}", ok, f"实测 {got}")
    ck("合计 = 5677", sum(cnt.values()) == EXPECT_TOTAL, f"{sum(cnt.values())}")

    # ── 5. 语义回归抽查 ──
    # 这几条是**真实踩过的坑**，钉在这里防复发：
    #   · magicline_256 的 129 个标记 type=currency，曾被 icon 规则抢成「服务」
    #   · 计程车站 80 个，曾因硬编码刷满屏幕
    #   · 电话亭 type 是 phone-booth（连字符），曾因下划线不匹配而丢色
    print("  ── 语义回归抽查 ──")
    by_id = {m.get("id"): m for m in markers}

    def group_of(pred, limit=200):
        """对满足 pred 的标记统计它们所属的组"""
        c = collections.Counter()
        n = 0
        for m in markers:
            if pred(m):
                n += 1
                if n <= limit:
                    c[by_marker[m["id"]].split(":")[0]] += 1
        return c, n

    # ① currency 类必须全在 resource
    c, n = group_of(lambda m: (m.get("type") or "").lower() == "currency")
    ck("currency 全归「资源」", set(c) == {"resource"} and n > 0,
       f"{n} 个 → {dict(c)}")

    # ② magicline 贴图曾是误分类元凶
    c, n = group_of(lambda m: (m.get("icon") or "").split("/")[-1].split(".")[0].lower() == "magicline_256")
    ck("magicline_256 全归「资源」（曾是「服务」）",
       set(c) == {"resource"}, f"{n} 个 → {dict(c)}")

    # ③ 计程车站必须全在 travel
    c, n = group_of(lambda m: (m.get("name") or "") == "计程车站")
    ck("计程车站 全归「传送点」", set(c) == {"travel"}, f"{n} 个 → {dict(c)}")

    # ④ 电话亭必须全在 service（且数量对得上 17）
    c, n = group_of(lambda m: (m.get("type") or "") == "phone-booth")
    ck("phone-booth 全归「服务」", set(c) == {"service"}, f"{n} 个 → {dict(c)}")
    ck("phone-booth 数量 = 17", n == 17, f"{n}")

    # ⑤ waypoint/tower 必须全在 travel
    c, n = group_of(lambda m: (m.get("type") or "") in ("waypoint", "tower"))
    ck("waypoint+tower 全归「传送点」", set(c) == {"travel"}, f"{n} 个 → {dict(c)}")

    # ⑥ 怪物（monster/boss）必须全在 monster
    c, n = group_of(lambda m: (m.get("type") or "") in ("monster", "boss"))
    ck("monster+boss 全归「怪物」", set(c) == {"monster"}, f"{n} 个 → {dict(c)}")

    # ⑦ shop 全在 shop
    c, n = group_of(lambda m: (m.get("type") or "") == "shop")
    ck("shop 全归「商店」", set(c) == {"shop"}, f"{n} 个 → {dict(c)}")

    # ⑧ 不得有 fallback 兜底（当前版本应全命中明确规则）
    fb = sum(1 for v in by_marker.values() if v.endswith(":fallback"))
    ck("无兜底条目", fb == 0, f"{fb} 个")

    print()
    if fail == 0:
        print("词表自检 PASS —— 全部通过")
    else:
        print(f"词表自检 FAIL —— {fail} 项未通过")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
