#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_locations.py — 从 MaaNTE 地图数据生成 App 用的「点位 / 分类 / 图标」三张表

═══════════════════════════════════════════════════════════════════════════
为什么需要这个脚本（根因修复）
═══════════════════════════════════════════════════════════════════════════
原生大地图原来读 `models/FINAL_complete_map_database.json`（5677 点，x/y 是
**0~100 百分比**）。实测它与正确数据在 71 个同名点上**中位差 2463px（≈1500 米）**，
0/71 落在 30px 内 —— 这就是用户一直说的「传送点完全不在图层上」的真凶。

本脚本改从 `tools/mapweb/MaaNTE-Map/src/data/map-data.json`（1777 点，**世界坐标**）
出发，用**我们自己的标定**（与 `CoordinateCapture.swift:99-102` 逐位相同的
kCalibA/B/TX/TY）换算成 13056 像素空间。

    px = A·wx + B·wy + TX
    py = A·wy − B·wx + TY

实测：与 `tools/roadnet/web/poi.json` 的 1621 个同名点比，**中位差 0.04px、
最大 0.07px、≤30px 占比 100%** —— 标定与数据双双对得上。

═══════════════════════════════════════════════════════════════════════════
三条硬规矩（改脚本前先读）
═══════════════════════════════════════════════════════════════════════════
① **存像素，不存百分比**。上一版就是百分比（0~100）与像素（0~13056）混用，
   乘以 mapPixels 时少乘一次就整体偏出图层。本脚本输出一律是 13056 像素。
② **标定常量不许在这里改**。Python 与 Swift 两处必须逐位一致，脚本会自己
   解析 `CoordinateCapture.swift` 校验；不一致直接报错退出（防两套坐标悄悄漂移）。
③ `tools/mapweb/` 是**只读**的上游数据（已完成还原的预览站），本脚本只读不写。
   同理 `FINAL_complete_map_database.json` **只读，不删不写**。

═══════════════════════════════════════════════════════════════════════════
产出
═══════════════════════════════════════════════════════════════════════════
  models/map_locations.json   1777 个点位（像素坐标 + 分类 + 组 + 图标）
  models/map_categories.json  7 组 + 42 类（color/icon/count/order/defaultOn）
  models/map_icon_map.json    42 类 → models/map_icons/ 里的文件名（含证据来源）

用法：
    python3 tools/map/build/build_locations.py            # 生成 + 自检
    python3 tools/map/build/build_locations.py --check     # 只自检（CI 用，不写文件）
"""

import argparse
import collections
import json
import math
import os
import re
import statistics
import sys

# ── 路径 ──
_HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(_HERE, "..", "..", ".."))

SRC_MAP = os.path.join(ROOT, "tools", "mapweb", "MaaNTE-Map", "src", "data", "map-data.json")
SRC_POI = os.path.join(ROOT, "tools", "roadnet", "web", "poi.json")
CALIB_SWIFT = os.path.join(ROOT, "Sources", "AuroraDrive", "Capture", "CoordinateCapture.swift")
ICON_DIR = os.path.join(ROOT, "models", "map_icons")

OUT_LOCATIONS = os.path.join(ROOT, "models", "map_locations.json")
OUT_CATEGORIES = os.path.join(ROOT, "models", "map_categories.json")
OUT_ICONS = os.path.join(ROOT, "models", "map_icon_map.json")

# ── 标定（**不许改**；脚本会与 CoordinateCapture.swift 对账）──
KCALIB_A = 0.016394586684750773
KCALIB_B = 5.693519256055879e-08
KCALIB_TX = 6526.474380746091
KCALIB_TY = 5210.664390686138

MAP_PIXELS = 13056

# ═══════════════════════════════════════════════════════════════════════════
# 7 个语义组 —— 与 `models/marker_taxonomy.json` 的 groups **逐字段一致**
# ═══════════════════════════════════════════════════════════════════════════
# 为什么不新造一套：App 的筛选条 / 组色 / 聚类都按这 7 个 id 走（MarkerTaxonomy），
# 这里换了 id 或颜色，UI 就会出现「图例一个色、点另一个色」的错位。
GROUPS = [
    # (id,        中文名,   顺序, 默认开, 主色 hex)
    ("explore",  "探索度",  0, True,  "4CC9FF"),
    ("resource", "资源",    1, True,  "8EE0FF"),
    ("travel",   "传送点",  2, True,  "FFB648"),
    ("monster",  "怪物",    3, False, "FF5468"),
    ("shop",     "商店",    4, False, "34E5AA"),
    ("service",  "服务",    5, False, "A98BFF"),
    ("landmark", "地标",    6, False, "E9F3FF"),
]
GROUP_IDS = [g[0] for g in GROUPS]

# 上游 map-data.json 只有 4 个组（其 Web 参考实现 App.vue 的
# COLLAPSIBLE_CATEGORY_GROUP_LABELS 也是这 4 个），这里做**锚定**映射：
UPSTREAM_TO_APP = {
    "探索度": "explore",
    "资源":   "resource",
    "传送点": "travel",
    "怪物":   "monster",
}

# 逐类覆盖表。默认空 = 完全锚定上游分组。
# 留这张表是为了让「42 类 → 7 组」**一眼可审计、一处可改**：
# 若要把某类挪到别的组（例如按旧库语义把「魔女之家」挪到 service），只在这里加一行。
GROUP_OVERRIDE = {}

# ═══════════════════════════════════════════════════════════════════════════
# 42 类 → 图标（models/map_icons/ 里的 basename，不含扩展名）
# ═══════════════════════════════════════════════════════════════════════════
# 证据分级（provenance）—— **不猜**。每一行都能在旧库
# `FINAL_complete_map_database.json`（5677 点，含 icon 字段）里找到依据：
#
#   legacy-subtype  旧库 subtype 与新分类 id 精确相同（最强）
#   legacy-name     新点位名去「 #NNN」后与旧库某点同名，取该点的 icon（强）
#   legacy-keyword  旧库含该关键词的点位的 icon（中）
#   manual          无旧库依据，按语义从现有游戏素材里手选（已注明理由）
#   group-fallback  无任何依据 → 用该组的通用图标（**这是兜底，不是匹配**）
#
# 旧库的 icon basename 与 models/map_icons/ 的文件名同一套，所以可直接复用。
CATEGORY_ICON = {
    # ── 探索度 ──
    "oracle-stone":     ("YH_UI_mapicon_yushi_1",        "legacy-name"),    # 谕石 ×207
    "gift-21":          ("Icon_Box_Equip_11",            "legacy-name"),    # 「21的赠礼」×89
    "checkin":          ("YH_UI_Mapicon_050",            "manual"),         # 「菲林轨迹」照相馆（打卡=拍照点；上游 Web 用 camera.png）
    "sidequest":        ("UI_mission_zhixian",           "legacy-name"),    # 支线任务 ×6
    "anomaly":          ("YH_UI_Mapicon_084_128",        "legacy-name"),    # 异象委托「深蓝之恸」等 ×4
    # ── 资源 ──
    "street-justice":   ("Icon_Box_Equip_03",            "group-fallback"), # 旧库无同名/同义词
    "figurine":         ("Figure_maskerrider_001_256",   "legacy-subtype"), # subtype=figurine（心猎铁骑手办盒）
    "furniture":        ("woodbox_256",                  "legacy-subtype"), # subtype=furniture（废弃家具）
    "magician-gift":    ("magicline_256",                "legacy-subtype"), # subtype=magician-gift（魔术师的馈赠）
    "category-010":     ("Icon_Box_Equip_03",            "legacy-name"),    # 避役的包裹 ×249
    "sundries":         ("Icon_Box_Equip_03",            "group-fallback"), # 旧库无同名
    "lost-wallet":      ("Lost_wallet",                  "legacy-name"),    # 遗失的钱包 ×533
    # ── 传送点 ──
    "phonebooth":       ("YH_UI_Mapicon_dianhuating",    "legacy-name"),    # ReroRero电话亭 ×14（type=phone-booth）
    "tower":            ("YH_UI_map_icon3",              "legacy-name"),    # 「维特海默塔」×5（subtype=wertheimer）
    "pinkpaw":          ("YH_UI_Mapicon_101_1",          "legacy-name"),    # 粉爪总行 ×1
    "witch":            ("YH_UI_Mapicon_047",            "legacy-name"),    # 魔女之家 ×1（type=service）
    "headless-rider":   ("boss_13",                      "legacy-subtype"), # subtype=headless-rider（无首铁驭）
    # ── 怪物（25 类）──
    "category-014":     ("mon_26",                       "legacy-name"),    # 纸翼战队 ×16
    "feather-doll":     ("mon_41",                       "legacy-name"),    # 羽偶 ×8
    "demon-blade":      ("mon_13_2",                     "legacy-name"),    # 妖刀 ×8
    "category-017":     ("mon_38",                       "legacy-name"),    # 无明众 ×43
    "cardboard-castle": ("mon_48",                       "legacy-subtype"), # subtype=cardboard-castle
    "sunshine-doll":    ("mon_30_2",                     "legacy-name"),    # 扫晴娘 ×51
    "fake-phonebooth":  ("mon_37",                       "legacy-subtype"), # subtype=rerorero-phone-booth（ReroRero电话亭 ×8）
    "record-spirit":    ("mon_29",                       "legacy-keyword"), # 唱片机附电灵 ×29
    "vending-spirit":   ("mon_16",                       "legacy-name"),    # 售货附电灵 ×25
    "dismantler":       ("mon_14",                       "legacy-name"),    # 分解者 ×23
    "possessed":        ("mon_05",                       "legacy-name"),    # 凭依种 ×12
    "sad-bear":         ("mon_19",                       "legacy-name"),    # 伤心英熊 ×6
    "wind-cave":        ("mon_02",                       "legacy-name"),    # 风洞种 ×19
    "rain-man":         ("mon_17",                       "legacy-name"),    # 雨人 ×43
    "eternal-lamp":     ("mon_23",                       "legacy-subtype"), # subtype=eternal-lamp（长明灯 ×26）
    "lost":             ("mon_04",                       "legacy-name"),    # 迷失种 ×12
    "nonos":            ("mon_27",                       "legacy-name"),    # 诺诺斯 ×12
    "mask-kite":        ("mon_24",                       "legacy-name"),    # 诡面筝 ×20
    "dream":            ("mon_33",                       "legacy-name"),    # 流梦种 ×12
    "fish-banner":      ("mon_25",                       "legacy-name"),    # 洄天鱼幡 ×28
    "pop":              ("mon_12",                       "legacy-name"),    # 波普 ×10
    "cotton":           ("mon_18",                       "legacy-name"),    # 棉绒绒 ×44
    "towboat":          ("mon_15",                       "legacy-name"),    # 拖车艄 ×5
    "hug-vine":         ("mon_01",                       "group-fallback"), # 旧库无「抱抱藤」，用怪物通用低语种
    "mosquito":         ("mon_01",                       "group-fallback"), # 旧库无「包包蚊」，用怪物通用低语种
}

# 自检门槛
EXPECT_LOCATIONS = 1777
EXPECT_CATEGORIES = 42
EXPECT_GROUPS = 7
POI_MEDIAN_MAX_PX = 30.0      # 与 poi.json 同名点中位差上限
POI_NEAR_RATIO_MIN = 0.95     # ≤60px 占比下限
POI_NEAR_PX = 60.0


# ═══════════════════════════════════════════════════════════════════════════
# 工具
# ═══════════════════════════════════════════════════════════════════════════

def _fail(msg):
    print(f"✗ {msg}")
    return False


def world_to_pixel(wx, wy):
    """世界坐标（UE5 厘米）→ 13056 地图像素。与 MapWiring.worldToMapPixelX/Y 同式。"""
    px = KCALIB_A * wx + KCALIB_B * wy + KCALIB_TX
    py = KCALIB_A * wy - KCALIB_B * wx + KCALIB_TY
    return px, py


def norm_name(s):
    """去「 #NNN」后缀与书名号，用于跨库同名匹配。"""
    s = re.sub(r"\s*#\s*\d+\s*$", "", s or "")
    return s.strip().strip("「」").strip()


def read_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
        f.write("\n")
    os.replace(tmp, path)   # 原子替换：写一半被 Ctrl-C 不会留下半个文件


def icon_files_on_disk():
    return {f for f in os.listdir(ICON_DIR) if f.lower().endswith(".webp")}


# ═══════════════════════════════════════════════════════════════════════════
# 构建
# ═══════════════════════════════════════════════════════════════════════════

def build():
    src = read_json(SRC_MAP)
    cats_src = src["categories"]
    locs_src = src["locations"]

    # 上游 42 类 → 组（锚定 + 覆盖）
    cat_group, cat_meta = {}, {}
    for c in cats_src:
        cid = c["id"]
        up = c.get("group", "")
        gid = GROUP_OVERRIDE.get(cid) or UPSTREAM_TO_APP.get(up)
        if gid is None:
            raise SystemExit(f"✗ 分类 {cid} 的上游组 {up!r} 不在 UPSTREAM_TO_APP 里，请补映射")
        cat_group[cid] = gid
        cat_meta[cid] = {
            "label": c.get("label", cid),
            "upstreamGroup": up,
            "upstreamColor": c.get("color"),
            "isDefault": bool(c.get("isDefault")),
        }

    # ── 点位 ──
    locations = []
    cat_count = collections.Counter()
    for l in locs_src:
        types = l.get("types") or []
        cid = types[0] if types else "unknown"
        if cid not in cat_group:
            raise SystemExit(f"✗ 点位 {l.get('id')} 的分类 {cid!r} 不在 categories 里")
        px, py = world_to_pixel(float(l["x"]), float(l["y"]))
        gid = cat_group[cid]
        icon_base = CATEGORY_ICON.get(cid, (None, "missing"))[0]
        cat_count[cid] += 1
        locations.append({
            "id": l.get("id") or f"{cid}-{len(locations)+1:04d}",
            "name": l.get("name") or "",
            "mapX": round(px, 3),          # ← 像素（13056 空间），**不是百分比**
            "mapY": round(py, 3),
            "worldX": round(float(l["x"]), 3),
            "worldY": round(float(l["y"]), 3),
            "category": cid,
            "group": gid,
            "groupLabel": dict((g[0], g[1]) for g in GROUPS)[gid],
            "iconName": icon_base,
            "district": l.get("district") or "",
            "tags": l.get("tags") or [],
        })

    # ── 分类（按组顺序 → 点数降序 → id 排序，得到稳定的图例顺序）──
    order_of_group = {g[0]: g[2] for g in GROUPS}
    categories = []
    for cid, m in cat_meta.items():
        gid = cat_group[cid]
        icon_base, prov = CATEGORY_ICON.get(cid, (None, "missing"))
        categories.append({
            "id": cid,
            "label": m["label"],
            "group": gid,
            "groupLabel": dict((g[0], g[1]) for g in GROUPS)[gid],
            "color": dict((g[0], g[4]) for g in GROUPS)[gid],
            "icon": icon_base,
            "iconSource": prov,
            "count": cat_count.get(cid, 0),
            "upstreamGroup": m["upstreamGroup"],
            "upstreamColor": m["upstreamColor"],
            "upstreamDefault": m["isDefault"],
        })
    categories.sort(key=lambda c: (order_of_group[c["group"]], -c["count"], c["id"]))
    for i, c in enumerate(categories):
        c["order"] = i

    group_count = collections.Counter(c["group"] for c in categories for _ in range(c["count"]))
    groups = []
    for gid, label, order, default_on, color in GROUPS:
        members = [c for c in categories if c["group"] == gid]
        groups.append({
            "id": gid,
            "label": label,
            "order": order,
            "defaultOn": default_on,
            "color": color,
            "icon": members[0]["icon"] if members else None,
            "count": group_count.get(gid, 0),
            "categoryCount": len(members),
            "emptyReason": None if members else "本数据集（map-data.json 42 类）无此类",
        })

    # ── 图标表 ──
    icon_map = {}
    icon_prov = {}
    for cid in cat_meta:
        base, prov = CATEGORY_ICON.get(cid, (None, "missing"))
        icon_map[cid] = (base + ".webp") if base else None
        icon_prov[cid] = prov

    meta_common = {
        "source": "tools/mapweb/MaaNTE-Map/src/data/map-data.json",
        "generatedBy": "tools/map/build/build_locations.py",
        "mapPixels": MAP_PIXELS,
        "calibration": {
            "kCalibA": KCALIB_A, "kCalibB": KCALIB_B,
            "kCalibTX": KCALIB_TX, "kCalibTY": KCALIB_TY,
            "formula": "px = A*wx + B*wy + TX ; py = A*wy - B*wx + TY",
            "sourceOfTruth": "Sources/AuroraDrive/Capture/CoordinateCapture.swift:99-102",
        },
        "unit": "map-pixels-13056",
    }

    loc_out = dict(meta_common)
    loc_out.update({
        "schema": "auroradrive.map_locations/v1",
        "count": len(locations),
        "note": "坐标一律为 13056 地图像素（**不是百分比**）；与 DriveState.worldToMapPixel 同系",
        "locations": locations,
    })

    cat_out = dict(meta_common)
    cat_out.update({
        "schema": "auroradrive.map_categories/v1",
        "counts": {"locations": len(locations), "categories": len(categories), "groups": len(groups)},
        "groups": groups,
        "categories": categories,
    })

    icon_out = dict(meta_common)
    icon_out.update({
        "schema": "auroradrive.map_icon_map/v1",
        "iconDir": "models/map_icons",
        "count": len(icon_map),
        "note": "分类 id → models/map_icons/ 下的文件名；provenance 说明该映射的依据（不猜）",
        "map": icon_map,
        "provenance": icon_prov,
    })

    write_json(OUT_LOCATIONS, loc_out)
    write_json(OUT_CATEGORIES, cat_out)
    write_json(OUT_ICONS, icon_out)
    return locations, categories, groups, icon_map, icon_prov


# ═══════════════════════════════════════════════════════════════════════════
# 自检
# ═══════════════════════════════════════════════════════════════════════════

def check_swift_calibration():
    """Python 与 Swift 两处标定必须逐位一致 —— 防「两套坐标悄悄漂移」。"""
    txt = open(CALIB_SWIFT, "r", encoding="utf-8").read()
    want = {
        "kCalibA": KCALIB_A, "kCalibB": KCALIB_B,
        "kCalibTX": KCALIB_TX, "kCalibTY": KCALIB_TY,
    }
    for name, val in want.items():
        m = re.search(rf"let {name}: Double = ([0-9eE.+-]+)", txt)
        if not m:
            return False, f"{name} 未在 CoordinateCapture.swift 中找到"
        got = float(m.group(1))
        if got != val:
            return False, f"{name} 不一致：Swift={got!r} Python={val!r}"
    return True, "4 个常量与 CoordinateCapture.swift:99-102 逐位一致"


def check_poi_agreement(locations):
    """与 tools/roadnet/web/poi.json 的同名点比对（外部标准答案）。"""
    poi = read_json(SRC_POI)
    by_name = collections.defaultdict(list)
    for p in poi:
        by_name[p["n"]].append((p["x"], p["y"]))

    diffs, unmatched = [], 0
    for l in locations:
        cand = by_name.get(l["name"])
        if not cand:
            unmatched += 1
            continue
        diffs.append(min(math.hypot(l["mapX"] - qx, l["mapY"] - qy) for qx, qy in cand))
    if not diffs:
        return False, "没有任何同名点可比对", {}
    diffs.sort()
    n = len(diffs)
    med = statistics.median(diffs)
    near = sum(1 for d in diffs if d <= POI_NEAR_PX) / n
    stats = {
        "matched": n, "unmatched": unmatched,
        "median": med, "mean": statistics.mean(diffs), "max": diffs[-1],
        "le30": sum(1 for d in diffs if d <= 30) / n, "le60": near,
    }
    ok = med < POI_MEDIAN_MAX_PX and near > POI_NEAR_RATIO_MIN
    return ok, f"同名 {n} 点，中位差 {med:.2f}px（<{POI_MEDIAN_MAX_PX:.0f}），≤60px 占比 {near*100:.2f}%（>{POI_NEAR_RATIO_MIN*100:.0f}%）", stats


def run_checks():
    ok_all = True
    print("═══ 自检 ═══")

    loc = read_json(OUT_LOCATIONS)
    cat = read_json(OUT_CATEGORIES)
    ico = read_json(OUT_ICONS)
    locations, categories, groups = loc["locations"], cat["categories"], cat["groups"]

    # ① 标定一致性
    ok, msg = check_swift_calibration()
    ok_all &= ok
    print(f"  {'✅' if ok else '❌'} 标定与 Swift 一致  {msg}")

    # ② 点数
    for name, got, want in [("locations", len(locations), EXPECT_LOCATIONS),
                            ("categories", len(categories), EXPECT_CATEGORIES),
                            ("groups", len(groups), EXPECT_GROUPS)]:
        ok = got == want
        ok_all &= ok
        print(f"  {'✅' if ok else '❌'} {name} = {want}  实得 {got}")

    # ③ 与 poi.json 的同名点比对
    ok, msg, stats = check_poi_agreement(locations)
    ok_all &= ok
    print(f"  {'✅' if ok else '❌'} 与 poi.json 同名点一致  {msg}")
    if stats:
        print(f"       平均差 {stats['mean']:.2f}px  最大 {stats['max']:.2f}px  "
              f"≤30px {stats['le30']*100:.2f}%  （map-data 独有 {stats['unmatched']} 点）")

    # ④ 图标文件真实存在
    on_disk = icon_files_on_disk()
    missing = [(cid, ico["map"][cid]) for cid in ico["map"]
               if ico["map"][cid] and ico["map"][cid] not in on_disk]
    ok = not missing
    ok_all &= ok
    print(f"  {'✅' if ok else '❌'} 42 类图标文件存在  "
          f"命中 {sum(1 for v in ico['map'].values() if v)}/{len(ico['map'])}"
          + (f"，缺失 {missing}" if missing else ""))
    fb = [c for c, p in ico["provenance"].items() if p == "group-fallback"]
    print(f"       证据分布: " + " ".join(
        f"{k}={sum(1 for v in ico['provenance'].values() if v == k)}"
        for k in ["legacy-subtype", "legacy-name", "legacy-keyword", "manual", "group-fallback"]))
    if fb:
        print(f"       ⚠️ 兜底（无旧库依据，用组通用图标）: {', '.join(sorted(fb))}")

    # ⑤ 结构自洽
    cat_ids = {c["id"] for c in categories}
    group_ids = {g["id"] for g in groups}
    bad_cat = [l["id"] for l in locations if l["category"] not in cat_ids]
    bad_grp = [l["id"] for l in locations if l["group"] not in group_ids]
    bad_px = [l["id"] for l in locations
              if not (0 <= l["mapX"] <= MAP_PIXELS and 0 <= l["mapY"] <= MAP_PIXELS)]
    ok = not (bad_cat or bad_grp or bad_px)
    ok_all &= ok
    print(f"  {'✅' if ok else '❌'} 结构自洽（分类/组/像素范围）  "
          f"越界分类 {len(bad_cat)}，越界组 {len(bad_grp)}，越界像素 {len(bad_px)}")

    # ⑥ 计数自洽
    sum_cat = sum(c["count"] for c in categories)
    sum_grp = sum(g["count"] for g in groups)
    empty = [c["id"] for c in categories if c["count"] == 0]
    ok = sum_cat == len(locations) and sum_grp == len(locations) and not empty
    ok_all &= ok
    print(f"  {'✅' if ok else '❌'} 计数自洽  Σ分类={sum_cat} Σ组={sum_grp} 点位={len(locations)}"
          + (f"，空分类 {empty}" if empty else ""))

    # ⑦ 分组概况（如实打印空组）
    print("       组分布: " + " ".join(
        f"{g['label']}({g['id']})={g['count']}" + ("[空]" if g["count"] == 0 else "")
        for g in sorted(groups, key=lambda x: x["order"])))

    print("═══ " + ("全部通过 ✅" if ok_all else "有失败项 ❌") + " ═══")
    return 0 if ok_all else 1


def main():
    ap = argparse.ArgumentParser(description="生成 models/map_locations|categories|icon_map.json")
    ap.add_argument("--check", action="store_true", help="只自检，不重新生成")
    args = ap.parse_args()

    if not args.check:
        print("═══ 生成 ═══")
        locations, categories, groups, icon_map, prov = build()
        print(f"  ✅ models/map_locations.json   {len(locations)} 点")
        print(f"  ✅ models/map_categories.json  {len(categories)} 类 / {len(groups)} 组")
        print(f"  ✅ models/map_icon_map.json    {len(icon_map)} 条映射")
    return run_checks()


if __name__ == "__main__":
    sys.exit(main())
