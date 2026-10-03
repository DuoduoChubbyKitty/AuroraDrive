#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_taxonomy.py — 从原始标记库生成 App 用的分类词表

═══════════════════════════════════════════════════════════════════════════════
为什么需要这个脚本
═══════════════════════════════════════════════════════════════════════════════
App 原来只认 3 个 `type` 值（waypoint/shop/service），而数据源有 **42 个类**。
实测匹配率只有 376/5677 = **6.6%** —— 剩下的全落 `default` 分支，于是：
  · 地图上一大片一模一样的冰蓝点，看不出类别
  · `waypoint` 被硬编码成「唯一显示名字的类别」，而 100 个 waypoint 里
    80 个叫「计程车站」→ 满屏「计程车站」
  · 「快速旅行点」的图标其实是 `dianhuating`（电话亭），名与实不符

本脚本产出 `models/marker_taxonomy.json`，把 5677 个标记归入 7 个语义组。
**原始库自始至终只读** —— 7.2 MB 的主数据不动，词表是独立文件。

═══════════════════════════════════════════════════════════════════════════════
匹配优先级 —— 这是准确率的命门
═══════════════════════════════════════════════════════════════════════════════
    type  ──>  icon  ──>  name

**`type` 必须优先于 `icon`。** 第一版把 icon 放前面，结果 129 个
`type=currency`（货币点「魔术师的馈赠」）因为贴图是 `magicline_256`
被抢成「服务」组 —— 覆盖率照样 100%，但**语义是错的**。
覆盖率会骗人，准确率不会。故此处用 type 权威映射打底。

`icon` 只在 `type` 缺失/未知时兜底（数据里 icon 比 type 更细，
例如 `mon_XX` 系列能细分怪物，`fork_*` 系列是残片）。

用法：
    tools/ayolom/.venv/bin/python tools/roadnet/build_taxonomy.py
    tools/ayolom/.venv/bin/python tools/roadnet/build_taxonomy.py --check
"""

import argparse
import collections
import json
import os
import sys

# ── 路径 ──
_HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(_HERE, "..", ".."))
SRC = os.path.join(ROOT, "models", "FINAL_complete_map_database.json")
OUT = os.path.join(ROOT, "models", "marker_taxonomy.json")

# ═══════════════════════════════════════════════════════════════════════════
# 7 个语义组
# ═══════════════════════════════════════════════════════════════════════════
#  颜色沿用 Aurora 既有调色板（AuroraTheme.swift），**不引入新色**：
#    ice    0x4CC9FF   冰蓝
#    iceHi  0x8EE0FF   亮冰蓝
#    ok     0x34E5AA   青绿
#    amber  0xFFB648   琥珀
#    danger 0xFF5468   红
#    violet 0xA98BFF   紫
#    t3     0xE9F3FF @36%  灰
#
#  defaultOn 的取舍：
#    怪物 **默认关** —— 725 个点会糊满整张图，把真正有用的传送点/资源盖住。
#    这是**故意不抄** maante 的默认值（它把「怪物」设成唯一默认开启组）。
GROUPS = [
    # (id,        中文名,   顺序, 默认开, 主色 hex, 说明)
    ("explore",  "探索度",  0, True,  "4CC9FF"),
    ("resource", "资源",    1, True,  "8EE0FF"),
    ("travel",   "传送点",  2, True,  "FFB648"),
    ("monster",  "怪物",    3, False, "FF5468"),
    ("shop",     "商店",    4, False, "34E5AA"),
    ("service",  "服务",    5, False, "A98BFF"),
    ("landmark", "地标",    6, False, "E9F3FF"),
]
GROUP_LABEL = {g[0]: g[1] for g in GROUPS}
GROUP_ORDER = {g[0]: g[2] for g in GROUPS}
GROUP_COLOR = {g[0]: g[4] for g in GROUPS}

# ═══════════════════════════════════════════════════════════════════════════
# ① type → 组（权威映射）
# ═══════════════════════════════════════════════════════════════════════════
# 依据数据源实测的 19 个 type 值全覆盖，无遗漏、无重复。
TYPE_MAP = {
    # ── 探索度：收集/解谜/任务/箱 ──
    "mystery-box": "explore",
    "chest":       "explore",
    "gift-21":     "explore",
    "collectible": "explore",
    "arc-plate":   "explore",
    "oracle-stone": "explore",
    "quest":       "explore",
    # ── 资源：货币/素材（注意 currency 归资源，不是服务）──
    "currency":    "resource",
    # ── 怪物 ──
    "monster":     "monster",
    "boss":        "monster",
    # ── 商店 ──
    "shop":        "shop",
    # ── 服务 ──
    "service":     "service",
    "activity":    "service",
    "phone-booth": "service",
    # ── 传送点 ──
    "waypoint":    "travel",
    "tower":       "travel",
    # ── 地标 ──
    "viewpoint":   "landmark",
    "region":      "landmark",
}

# ═══════════════════════════════════════════════════════════════════════════
# ② icon basename → (组, 细分标签)
# ═══════════════════════════════════════════════════════════════════════════
# 只在 type 缺失/未知时使用。顺序**敏感**（先匹配到的胜出）。
ICON_RULES = [
    # 怪物：mon_18 / mon_30_2 / mon_38 …
    (lambda b: b.startswith("mon_"), "monster", "怪物"),
    # 资源：装备箱 / 遗失的钱包
    (lambda b: b.startswith("icon_box_equip"), "resource", "装备箱"),
    (lambda b: b == "lost_wallet", "resource", "遗失的钱包"),
    (lambda b: b.startswith("magicline"), "resource", "魔术师的馈赠"),
    # 传送点：计程车 / 电话亭图标（电话亭在游戏里兼具传送功能）
    (lambda b: b.startswith("yh_ui_taxi"), "travel", "计程车站"),
    (lambda b: b.startswith("yh_ui_mapicon_dianhuating"), "travel", "传送亭"),
    # 谕石 → 探索度
    (lambda b: b.startswith("yh_ui_mapicon_yushi"), "explore", "谕石"),
    # 面具骑手 → 探索度
    (lambda b: b.startswith("figure_maskerrider"), "explore", "面具骑手"),
]

# ═══════════════════════════════════════════════════════════════════════════
# ③ name 关键词 → 组（最后兜底）
# ═══════════════════════════════════════════════════════════════════════════
NAME_RULES = [
    (("计程", "车站", "出租车", "taxi"), "travel"),
    (("快速旅行", "传送", "传送点"), "travel"),
    (("电话亭",), "service"),
    (("便利店", "商店", "商人", "铺子", "shop"), "shop"),
    (("雅哈哈", "神秘箱", "宝箱", "钱包", "谕石", "收集"), "explore"),
    (("怪物", "首领", "头目", "boss"), "monster"),
]


def icon_base(raw):
    """`a/b/Name.webp` → `name`（小写、去扩展名、去目录）"""
    if not raw:
        return ""
    return raw.split("/")[-1].split(".")[0].lower()


def classify(marker):
    """返回 (groupId, categoryId, label)。

    优先级 type → icon → name，理由见文件头注释。
    """
    t = (marker.get("type") or "").strip().lower()
    b = icon_base(marker.get("icon") or marker.get("iconUrl") or "")
    n = marker.get("name") or ""

    # ── ① type 权威 ──
    if t in TYPE_MAP:
        g = TYPE_MAP[t]
        return g, f"{g}:type:{t}", t

    # ── ② icon 兜底 ──
    for pred, g, label in ICON_RULES:
        if b and pred(b):
            return g, f"{g}:icon:{b}", label

    # ── ③ name 兜底 ──
    low = n.lower()
    for keys, g in NAME_RULES:
        for k in keys:
            if k in low:
                return g, f"{g}:name", g

    # ── ④ 实在认不出：归探索度（数量最大的一组），并标记出来供审查 ──
    return "explore", "explore:fallback", "未分类"


def main():
    ap = argparse.ArgumentParser(description="生成标记分类词表")
    ap.add_argument("--check", action="store_true",
                    help="生成后立即自检并打印统计（等价于再跑一次 check_taxonomy.py）")
    ap.add_argument("--out", default=OUT, help=f"输出路径（默认 {OUT}）")
    args = ap.parse_args()

    if not os.path.exists(SRC):
        print(f"✗ 找不到源数据：{SRC}", file=sys.stderr)
        return 1

    with open(SRC, encoding="utf-8") as f:
        db = json.load(f)
    markers = db.get("markers_all") or []
    if not markers:
        print("✗ markers_all 为空", file=sys.stderr)
        return 1

    by_marker = {}
    cat_count = collections.Counter()
    cat_label = {}
    group_count = collections.Counter()
    fallback = []

    for m in markers:
        mid = m.get("id")
        if not mid:
            # 没有稳定 id 就无法键控 —— 如实报错，不静默跳过
            print(f"✗ 标记缺少 id：{m.get('name')!r}", file=sys.stderr)
            return 1
        g, cat, label = classify(m)
        by_marker[mid] = cat
        cat_count[cat] += 1
        cat_label[cat] = GROUP_LABEL[g] + "·" + str(label)
        group_count[g] += 1
        if cat.endswith(":fallback"):
            fallback.append((mid, m.get("name"), m.get("type"), icon_base(m.get("icon") or "")))

    # ── 组装输出 ──
    groups = [{
        "id": gid, "label": cn, "order": order,
        "defaultOn": default_on, "color": color,
    } for (gid, cn, order, default_on, color) in GROUPS]

    categories = []
    for cat, cnt in sorted(cat_count.items(), key=lambda kv: (-kv[1], kv[0])):
        g = cat.split(":")[0]
        categories.append({
            "id": cat,
            "group": g,
            "label": cat_label[cat],
            "color": GROUP_COLOR.get(g, "4CC9FF"),
            "icon": None,          # 图标名留空：App 用「组色圆点」即可，
                                   # 需要图标时按 marker.icon 现取（models/map_icons/）
            "count": cnt,
            "order": GROUP_ORDER.get(g, 99),
        })

    out = {
        "_comment": "由 tools/roadnet/build_taxonomy.py 生成，勿手改。"
                    "原始数据 models/FINAL_complete_map_database.json 保持只读。",
        "schema": 1,
        "source": os.path.relpath(SRC, ROOT),
        "total": len(markers),
        "groups": groups,
        "categories": categories,
        "byMarker": by_marker,
    }

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))

    size = os.path.getsize(args.out)
    print(f"✓ 已写出 {os.path.relpath(args.out, ROOT)}  {size:,} B")
    print(f"  标记 {len(markers)} 个 → {len(by_marker)} 条映射"
          f"（{len(set(by_marker))} 唯一，{'无重复 id' if len(by_marker)==len(markers) else '⚠️ 有重复 id'}）")
    print()
    print(f"  {'组':<8}{'数量':>7}  {'占比':>7}  默认")
    for gid, cn, order, default_on, _ in GROUPS:
        c = group_count[gid]
        print(f"  {cn:<6}{c:>7}  {c/len(markers)*100:>6.1f}%  {'开' if default_on else '关'}")
    print(f"  {'合计':<6}{sum(group_count.values()):>7}")
    print()
    print(f"  最粗分类 {len(cat_count)} 类")
    if fallback:
        print(f"  ⚠️ 兜底（认不出）{len(fallback)} 个：")
        for mid, name, t, ib in fallback[:15]:
            print(f"      {name!r} type={t!r} icon={ib!r}")
    else:
        print("  ✓ 无兜底：全部标记都命中明确规则")

    if args.check:
        import subprocess
        chk = os.path.join(_HERE, "check_taxonomy.py")
        if os.path.exists(chk):
            print()
            return subprocess.call([sys.executable, chk])
    return 0


if __name__ == "__main__":
    sys.exit(main())
