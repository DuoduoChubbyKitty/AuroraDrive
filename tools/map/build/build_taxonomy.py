#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_taxonomy.py — 校验「分类表 ↔ 点位表」一致性（**只校验，不产出任何文件**）

═══════════════════════════════════════════════════════════════════════════
本脚本的历史与现状（**这是它存在的理由，别删**）
═══════════════════════════════════════════════════════════════════════════
它原来是「从 `map_locations.json` 生成 `models/marker_taxonomy.json` 的 byMarker 映射」。

2026-10-04 **合并真源**后，那份映射被证明是**多余且危险**的：
  · 点位表 `map_locations.json` 里每个点位**已内嵌** `group` / `groupLabel`
    （`MapWiring.parseLocation` 直接读它们）⟹ 运行时**不需要**按 id 反查任何词表
  · 而那份映射是从旧数据源派生的副本，与数据源 **id 交集为 0**
    （旧 `imapp-phone-booth-17180` vs 新 `phonebooth-001`）——
    一度让所有点位的 group 变成 nil、分类筛选与配色全部失效，且**不报错**。
  · ⟹ `models/marker_taxonomy.json` **已删除**，`MarkerTaxonomy` 只读
    `models/map_categories.json` 的 7 组定义。真源从 3 个降到 2 个。

所以本脚本不再生成任何文件，只做一件事：**断言两个真源互相一致**。
「能自动派生的东西手写就会脱节」—— 现在没有可派生的东西了，
但「两个真源之间仍可能不一致」（比如有人手改了分类表的 count），
所以这条校验必须留着，并且**要能被 CI 调用**。

═══════════════════════════════════════════════════════════════════════════
两个真源的分工
═══════════════════════════════════════════════════════════════════════════
  models/map_categories.json  42 类 → 7 组；组定义（id/label/order/defaultOn/color）
                              UI 图例 / 筛选条 / 配色 都看它
  models/map_locations.json   1777 点位；每个点位内嵌 category / group / groupLabel
                              运行时地图绘制看它

用法：
    python3 tools/map/build/build_taxonomy.py          # 校验（默认，唯一模式）
退出码：0 = 一致；非 0 = 有不一致项（逐条打印）
"""

import collections
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(_HERE, "..", "..", ".."))

SRC_LOCATIONS = os.path.join(ROOT, "models", "map_locations.json")
SRC_CATEGORIES = os.path.join(ROOT, "models", "map_categories.json")

EXPECT_GROUPS = 7
EXPECT_CATEGORIES = 42
EXPECT_LOCATIONS = 1777

# 实测基线（2026-10-04，与 AuroraDriveApp.swift 的「组数量冻结基线」同一套数）
EXPECT_GROUP_COUNTS = {
    "explore": 450, "resource": 1045, "travel": 28,
    "monster": 254, "shop": 0, "service": 0, "landmark": 0,
}


def read_json(p):
    with open(p, "r", encoding="utf-8") as f:
        return json.load(f)


def main():
    ok_all = True

    def ck(name, cond, detail=""):
        nonlocal ok_all
        ok_all &= bool(cond)
        print(f"  {'✅' if cond else '❌'} {name}" + (f"  {detail}" if detail else ""))

    print("═══ 分类表 ↔ 点位表 一致性校验 ═══")
    for p in (SRC_LOCATIONS, SRC_CATEGORIES):
        if not os.path.exists(p):
            print(f"✗ 缺文件：{p}")
            return 1
    locs = read_json(SRC_LOCATIONS)["locations"]
    cats = read_json(SRC_CATEGORIES)
    categories = cats["categories"]
    groups = cats["groups"]

    # ① 计数
    ck(f"点位 = {EXPECT_LOCATIONS}", len(locs) == EXPECT_LOCATIONS, f"实得 {len(locs)}")
    ck(f"分类 = {EXPECT_CATEGORIES}", len(categories) == EXPECT_CATEGORIES,
       f"实得 {len(categories)}")
    ck(f"组 = {EXPECT_GROUPS}", len(groups) == EXPECT_GROUPS, f"实得 {len(groups)}")

    gids = {g["id"] for g in groups}
    cat_group = {c["id"]: c["group"] for c in categories}

    # ② 点位的 category / group 必须都在表里，且**两者互相自洽**
    bad_cat = [m["id"] for m in locs if m.get("category") not in cat_group]
    bad_grp = [m["id"] for m in locs if m.get("group") not in gids]
    ck("每个点位的 category 都在分类表里", not bad_cat,
       f"越界 {len(bad_cat)}" + (f"：{bad_cat[:3]}" if bad_cat else ""))
    ck("每个点位的 group 都在 7 组里", not bad_grp,
       f"越界 {len(bad_grp)}" + (f"：{bad_grp[:3]}" if bad_grp else ""))
    # ★ 核心不变量：点位的 group 必须等于「它的 category 在分类表里所属的组」。
    #   这一条断了 = 两个真源对同一个分类的归属有分歧 —— 正是本次事故的形态。
    conflict = [(m["id"], m.get("group"), cat_group.get(m.get("category")))
                for m in locs if m.get("group") != cat_group.get(m.get("category"))]
    ck("点位内嵌 group == 分类表里该 category 的 group（核心不变量）", not conflict,
       f"冲突 {len(conflict)}" + (f"：{conflict[:3]}" if conflict else ""))

    # ③ 组分布：点位现算 vs 分类表声明
    dist = collections.Counter(m["group"] for m in locs if m.get("group"))
    declared = {g["id"]: g["count"] for g in groups}
    mism = {g: (dist.get(g, 0), declared.get(g, 0))
            for g in declared if dist.get(g, 0) != declared.get(g, 0)}
    ck("组分布 == 分类表声明的 count", not mism, f"不符 {mism}" if mism else "")
    ck("组分布 == 冻结基线",
       all(dist.get(k, 0) == v for k, v in EXPECT_GROUP_COUNTS.items()),
       " ".join(f"{g['label']}={dist.get(g['id'], 0)}"
                for g in sorted(groups, key=lambda x: x["order"])))
    ck(f"合计 == {EXPECT_LOCATIONS}", sum(dist.values()) == EXPECT_LOCATIONS,
       f"实得 {sum(dist.values())}")

    # ④ 每类计数：点位现算 vs 分类表声明
    cdist = collections.Counter(m["category"] for m in locs)
    cmism = [(c["id"], cdist.get(c["id"], 0), c["count"])
             for c in categories if cdist.get(c["id"], 0) != c["count"]]
    ck("每类计数 == 分类表声明的 count", not cmism, f"不符 {cmism[:3]}" if cmism else "")
    empty = [c["id"] for c in categories if cdist.get(c["id"], 0) == 0]
    ck("没有空分类（每类至少 1 个点位）", not empty, f"空 {empty}" if empty else "")

    # ⑤ 空组必须写明理由（UI 图例要据此隐藏，不能显示一个说不清的 0）
    no_reason = [g["id"] for g in groups if g["count"] == 0 and not g.get("emptyReason")]
    ck("空组都带 emptyReason", not no_reason,
       "空组 " + str([g["id"] for g in groups if g["count"] == 0]))

    print("═══ " + ("全部通过 ✅" if ok_all else "有失败项 ❌") + " ═══")
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())
