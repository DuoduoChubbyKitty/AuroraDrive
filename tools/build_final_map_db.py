#!/usr/bin/env python3
"""快速抓取 interactivemap.app 的真实API + 搜索海蜇等材料 + 整合最终数据库"""
import json
import time
import urllib.request
import urllib.error
from pathlib import Path

OUT = Path("/Users/dupi/Desktop/自动驾驶系统/models")
OUT.mkdir(exist_ok=True)

HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Referer': 'https://interactivemap.app/neverness-to-everness/maps/nte',
    'Accept': 'application/json, text/plain, */*',
}

def http_get(url, timeout=30):
    req = urllib.request.Request(url, headers=HEADERS)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, b''
    except Exception as e:
        return 0, b''

def save_json(name, data):
    with open(OUT / name, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f"  ✓ {name}: {len(json.dumps(data, ensure_ascii=False))//1024}KB")

def fetch_imap():
    print("=" * 60)
    print("🌐 interactivemap.app 真实API抓取")
    print("=" * 60)
    base = "https://interactivemap.app/neverness-to-everness/maps/imapp/api"

    # 已经从浏览器验证的API路径
    apis = [
        ("imap_map_areas_1.json",    f"{base}/map_areas/1"),      # 海特洛市
        ("imap_version_1.json",      f"{base}/version/1"),
        ("imap_map_areas_2.json",    f"{base}/map_areas/2"),      # Warren
        ("imap_version_2.json",      f"{base}/version/2"),
        ("imap_map_areas_list.json", f"{base}/map_areas"),
        ("imap_categories.json",     f"{base}/categories"),
    ]

    results = {}
    for name, url in apis:
        print(f"  → {name}")
        status, content = http_get(url)
        if status == 200 and len(content) > 50:
            try:
                data = json.loads(content.decode('utf-8', errors='replace'))
                save_json(name, data)
                # 展示结构
                if isinstance(data, dict):
                    info = []
                    for k, v in data.items():
                        if isinstance(v, list):
                            info.append(f"{k}:{len(v)}")
                        elif isinstance(v, dict):
                            info.append(f"{k}:dict({len(v)})")
                        else:
                            info.append(f"{k}:{type(v).__name__}")
                    print(f"    结构: {', '.join(info[:12])}")
                elif isinstance(data, list):
                    print(f"    列表: {len(data)} 项")
                    if data and isinstance(data[0], dict):
                        print(f"    字段: {list(data[0].keys())[:15]}")
                results[name] = data
            except Exception as e:
                print(f"    解析失败: {e}, 原始保存")
                with open(OUT / name, 'wb') as f:
                    f.write(content)
        else:
            print(f"    ✗ HTTP {status}")

    return results

def search_materials_and_jellyfish():
    """在已有的5677标记中搜索海蜇/材料/采集物"""
    print("\n" + "=" * 60)
    print("🔍 搜索材料点、海蜇等采集物 (5677中文标记)")
    print("=" * 60)

    all_markers = []
    region_map = {
        'new-herland': '新赫兰德',
        'bridge-crossings': '桥间地',
        'unheard-shores': '未闻浦',
        'miguel-district': '米格尔区',
        'illusion-town': '幻镇',
    }
    for key, cn in region_map.items():
        p = OUT / f'nteguide_markers_{key}.json'
        if p.exists():
            d = json.loads(p.read_text(encoding='utf-8'))
            for m in d:
                m['_region_cn'] = cn
                m['_region_key'] = key
                all_markers.append(m)

    # 读取markerTypes获取类型中文名
    core = json.loads((OUT / 'nteguide_map-core.json').read_text(encoding='utf-8'))
    marker_types = core.get('markerTypes', {})
    type_cn = {}
    for k, v in marker_types.items():
        type_cn[k] = v.get('label', k)

    # 按类型统计详细
    print("\n📋 所有标记类型详细统计（含中文名）:")
    type_count = {}
    for m in all_markers:
        t = m.get('type', 'unknown')
        st = m.get('subtype', '')
        key = f"{t}/{st}" if st else t
        type_count[key] = type_count.get(key, 0) + 1
    for k, c in sorted(type_count.items(), key=lambda x: -x[1]):
        t = k.split('/')[0]
        cn = type_cn.get(t, t)
        print(f"   {cn:<10} {k:<30} {c:>5}")

    # 搜索"海蜇"/"水母"/材料相关关键词
    keywords = ['海蜇', '水母', 'jelly', '材料', '采集', '矿', '花', '草', '蘑菇', '果实', '叶', '鱼', '肉', '食材', '药', '素材']
    print("\n🐚 关键词搜索:")
    found_materials = []
    for m in all_markers:
        hit = False
        text = f"{m.get('name','')} {m.get('nameEn','')} {m.get('type','')} {m.get('subtype','')}"
        for kw in keywords:
            if kw.lower() in text.lower():
                hit = True
                break
        # 也匹配 currency/collectible/materials/gathering 这些类型
        t = (m.get('type','') or '').lower()
        if t in ('currency', 'collectible', 'mystery-box', 'oracle-stone', 'gift-21', 'arc-plate', 'chest', 'viewpoint'):
            hit = True
        if hit:
            found_materials.append(m)

    print(f"    匹配材料/收集/采集相关: {len(found_materials)} 个")
    # 按子类型分组显示
    subtype_group = {}
    for m in found_materials:
        key = f"{m.get('type')}/{m.get('subtype','')}"
        subtype_group.setdefault(key, []).append(m.get('name', m.get('nameEn', '?')))
    for k, names in sorted(subtype_group.items(), key=lambda x: -len(x[1])):
        samples = ', '.join(list(dict.fromkeys(names))[:8])
        t_cn = type_cn.get(k.split('/')[0], k.split('/')[0])
        print(f"    [{t_cn}] {k:<30} {len(names):>4}  示例: {samples}")

    return all_markers, marker_types

def build_final_database(all_markers, marker_types, imap_results):
    """整合最终完整数据库"""
    print("\n" + "=" * 60)
    print("🏗️  构建最终完整地图数据库")
    print("=" * 60)

    core = json.loads((OUT / 'nteguide_map-core.json').read_text(encoding='utf-8'))

    # 计算坐标范围
    xs = [m['x'] for m in all_markers if 'x' in m]
    ys = [m['y'] for m in all_markers if 'y' in m]
    bounds = {
        'x_min': min(xs) if xs else 0,
        'x_max': max(xs) if xs else 100,
        'y_min': min(ys) if ys else 0,
        'y_max': max(ys) if ys else 100,
    }

    # 整理所有传送点、电话亭、维特海默塔、材料、服务点
    waypoints = [m for m in all_markers if m.get('type') == 'waypoint']
    phone_booths = [m for m in all_markers if m.get('type') == 'phone-booth']
    towers = [m for m in all_markers if m.get('type') == 'tower']
    services = [m for m in all_markers if m.get('type') == 'service']
    shops = [m for m in all_markers if m.get('type') == 'shop']
    bosses = [m for m in all_markers if m.get('type') == 'boss']
    monsters = [m for m in all_markers if m.get('type') == 'monster']
    regions = [m for m in all_markers if m.get('type') == 'region']
    materials = [m for m in all_markers if m.get('type') in ('currency', 'collectible', 'oracle-stone', 'gift-21', 'arc-plate', 'mystery-box', 'chest')]
    quests = [m for m in all_markers if m.get('type') in ('quest', 'activity')]

    summary = {
        'generated_at': time.strftime('%Y-%m-%d %H:%M:%S'),
        'sources': ['nteguide.com (中文主数据:5677标记)', 'interactivemap.app (国际站补充)'],
        'total_markers': len(all_markers),
        'bounds_percent': bounds,
        'image_source': {
            'nteguide': 'https://nteguide.com/images/maps/tiles/',
            'interactivemap': 'https://interactivemap.app/neverness-to-everness/maps/imapp/uploads/images/nte-game.jpg',
            'local_hd': 'nte-game-hd.jpg (3840x2160)',
        },
        'by_category': {
            'waypoints_传送点': len(waypoints),
            'phone_booths_电话亭': len(phone_booths),
            'towers_维特海默塔': len(towers),
            'services_服务点': len(services),
            'shops_商店': len(shops),
            'bosses_异象BOSS': len(bosses),
            'monsters_怪物': len(monsters),
            'regions_区域地名': len(regions),
            'materials_材料收集物': len(materials),
            'quests_任务活动': len(quests),
        },
        'marker_types_cn': {k: v.get('label') for k, v in marker_types.items()},
        'regions_cn': core.get('regions', {}),
    }

    # 区域索引
    by_region = {}
    for m in all_markers:
        rk = m.get('_region_key', 'unknown')
        by_region.setdefault(rk, []).append(m)

    final = {
        'summary': summary,
        'markers_all': all_markers,
        'by_region': {rk: ms for rk, ms in by_region.items()},
        'waypoints': waypoints,
        'phone_booths': phone_booths,
        'towers': towers,
        'services': services,
        'shops': shops,
        'bosses': bosses,
        'monsters': monsters,
        'regions': regions,
        'materials': materials,
        'quests_activities': quests,
        'marker_types': marker_types,
        'core_map_info': core.get('maps', [])[0] if core.get('maps') else None,
        'interactivemap_supplement': imap_results,
    }

    out = OUT / 'FINAL_complete_map_database.json'
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(final, f, ensure_ascii=False)
    size_kb = out.stat().st_size // 1024
    print(f"\n✅ 最终数据库已保存: {out.name} ({size_kb}KB)")
    print(f"\n📊 分类汇总:")
    for k, v in summary['by_category'].items():
        print(f"   {k:<30} {v:>5}")
    return final

def main():
    # 1. 抓interactivemap
    imap = fetch_imap()

    # 2. 搜索材料点
    markers, mtypes = search_materials_and_jellyfish()

    # 3. 整合
    build_final_database(markers, mtypes, imap)

    print("\n" + "=" * 60)
    print("🎯 全部完成！")
    print("=" * 60)
    print("\n生成的关键文件在 models/ 目录:")
    key_files = [
        'FINAL_complete_map_database.json (整合最终版)',
        'nteguide_map-core.json (核心配置+类型中文名)',
        'nteguide_markers_*.json (5个区域共5677标记)',
        'nteguide_search-index.json (搜索索引)',
        'imap_*.json (国际站API补充数据)',
        'nte-game.jpg / nte-game-hd.jpg (高清底图)',
        'map_tiles_nteguide/ (瓦片金字塔)',
    ]
    for f in key_files:
        print(f"  📄 {f}")

if __name__ == '__main__':
    main()
