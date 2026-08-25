#!/usr/bin/env python3
"""
完整的异环地图数据抓取脚本
来源:
  1. nteguide.com (中文站，高质量中文数据)
  2. interactivemap.app (国际站，6800+标记点)
"""
import os
import json
import time
import urllib.request
import urllib.error
from pathlib import Path

OUTPUT_DIR = Path("/Users/dupi/Desktop/自动驾驶系统/models")
OUTPUT_DIR.mkdir(exist_ok=True)

HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
}

def _http_get(url, timeout=60, extra_headers=None):
    """内部HTTP GET，返回(status_code, content_bytes, final_url)"""
    headers = dict(HEADERS)
    if extra_headers:
        headers.update(extra_headers)
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read(), resp.geturl()
    except urllib.error.HTTPError as e:
        return e.code, b'', url
    except Exception as e:
        return 0, b'', url

def download(url, output_path, retries=3, extra_headers=None):
    """带重试的下载"""
    for attempt in range(retries):
        try:
            print(f"  下载: {url} -> {output_path.name}")
            status, content, _ = _http_get(url, timeout=60, extra_headers=extra_headers)
            if status == 200 and len(content) > 0:
                with open(output_path, 'wb') as f:
                    f.write(content)
                print(f"  ✓ 成功 ({len(content)} bytes)")
                return True
            else:
                print(f"  ✗ 状态码 {status} (attempt {attempt+1}/{retries})")
        except Exception as e:
            print(f"  ✗ 失败 (attempt {attempt+1}/{retries}): {e}")
        if attempt < retries - 1:
            time.sleep(2)
    return False

def fetch_json(url, timeout=30, extra_headers=None):
    """获取JSON并解析"""
    status, content, _ = _http_get(url, timeout=timeout, extra_headers=extra_headers)
    if status == 200 and content:
        try:
            return json.loads(content.decode('utf-8', errors='replace'))
        except:
            return None
    return None

def fetch_nteguide():
    """从nteguide.com抓取中文地图数据"""
    print("=" * 60)
    print("📦 从 nteguide.com 抓取中文地图数据...")
    print("=" * 60)

    base = "https://nteguide.com"

    # 1. 核心数据文件
    core_files = {
        "nteguide_map-core.json": f"{base}/data/map-core.json",
        "nteguide_search-index.json": f"{base}/search-index.json",
    }

    # 2. 5个区域的标记数据 (5677个标记)
    regions = [
        "new-herland",      # 新赫兰德
        "bridge-crossings", # 桥间地
        "unheard-shores",   # 未闻浦
        "miguel-district",  # 米格尔区
        "illusion-town",    # 幻镇
    ]
    for region in regions:
        core_files[f"nteguide_markers_{region}.json"] = f"{base}/data/map-markers-{region}.json"

    results = {}
    for name, url in core_files.items():
        out = OUTPUT_DIR / name
        ok = download(url, out)
        results[name] = ok

    # 3. 下载地图瓦片 (尝试多级别)
    print("\n🗺️  下载地图瓦片...")
    tile_dir = OUTPUT_DIR / "map_tiles_nteguide"
    tile_dir.mkdir(exist_ok=True)

    # 尝试不同缩放级别的瓦片 (z=0,1,2,3)
    tiles_found = 0
    for z in range(4):
        for x in range(-2, 4):
            for y in range(-2, 4):
                tile_url = f"{base}/images/maps/tiles/{z}/{x}/{y}.webp"
                tile_path = tile_dir / f"z{z}_x{x}_y{y}.webp"
                try:
                    status, content, _ = _http_get(tile_url, timeout=15)
                    if status == 200 and len(content) > 500:
                        with open(tile_path, 'wb') as f:
                            f.write(content)
                        tiles_found += 1
                except:
                    pass
    print(f"  瓦片下载完成: {tiles_found} 个文件")

    return results

def fetch_interactivemap():
    """从interactivemap.app抓取国际站数据"""
    print("\n" + "=" * 60)
    print("🌍 从 interactivemap.app 抓取国际站数据 (6800+标记)...")
    print("=" * 60)

    base = "https://interactivemap.app/neverness-to-everness/maps/imapp"

    # 1. 高清底图 (已有，检查是否更新)
    print("\n📷 下载高清底图...")
    download(f"{base}/uploads/images/nte-game.jpg", OUTPUT_DIR / "nte-game-hd.jpg")

    # 2. 正确的API路径（从浏览器网络请求实际获取的）
    # 地图ID=1 是海特洛市主地图，ID=2 是Warren大陆等
    print("\n📋 获取地图标记数据API (已验证路径)...")
    real_apis = [
        ("imap_hethereau_map_areas.json", f"{base}/api/map_areas/1"),
        ("imap_hethereau_version.json", f"{base}/api/version/1"),
        ("imap_warren_map_areas.json", f"{base}/api/map_areas/2"),
        ("imap_warren_version.json", f"{base}/api/version/2"),
        ("imap_all_map_areas.json", f"{base}/api/map_areas"),
        ("imap_categories.json", f"{base}/api/categories"),
        ("imap_markers_all.json", f"{base}/api/markers"),
        ("imap_locations.json", f"{base}/api/locations"),
        ("imap_zones.json", f"{base}/api/zones"),
    ]

    for name, url in real_apis:
        out = OUTPUT_DIR / name
        try:
            data = fetch_json(url, timeout=30, extra_headers={
                'Referer': 'https://interactivemap.app/neverness-to-everness/maps/nte'
            })
            if data is not None:
                count = 0
                if isinstance(data, dict):
                    for k, v in data.items():
                        if isinstance(v, list): count += len(v)
                elif isinstance(data, list):
                    count = len(data)
                print(f"  ✓ {name}: OK, 约{count}条")
                with open(out, 'w', encoding='utf-8') as f:
                    json.dump(data, f, ensure_ascii=False, indent=2)
                continue
            status, content, _ = _http_get(url, timeout=30, extra_headers={
                'Referer': 'https://interactivemap.app/neverness-to-everness/maps/nte'
            })
            if status == 200 and len(content) > 50:
                try:
                    decoded = json.loads(content.decode('utf-8', errors='replace'))
                    with open(out, 'w', encoding='utf-8') as f:
                        json.dump(decoded, f, ensure_ascii=False, indent=2)
                    print(f"  ✓ {name}: OK (raw decode, {len(content)} bytes)")
                except:
                    with open(out, 'wb') as f:
                        f.write(content)
                    print(f"  ✓ {name}: 原始内容 ({len(content)} bytes)")
            else:
                print(f"  ~ {name}: HTTP {status}")
        except Exception as e:
            print(f"  ✗ {name}: {e}")

def merge_and_summarize():
    """合并数据并生成摘要"""
    print("\n" + "=" * 60)
    print("📊 合并数据并生成完整地图数据库...")
    print("=" * 60)

    all_markers = []
    marker_types = {}
    regions_found = {}

    # 1. 读取 nteguide 5个区域的标记
    print("\n📥 读取 nteguide 区域标记...")
    region_cn_map = {
        "new-herland": "新赫兰德",
        "bridge-crossings": "桥间地",
        "unheard-shores": "未闻浦",
        "miguel-district": "米格尔区",
        "illusion-town": "幻镇",
    }
    for region_key, region_cn in region_cn_map.items():
        path = OUTPUT_DIR / f"nteguide_markers_{region_key}.json"
        if path.exists():
            try:
                with open(path, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                if isinstance(data, list):
                    for m in data:
                        m['_region'] = region_cn
                        m['_region_key'] = region_key
                        m['_source'] = 'nteguide'
                        all_markers.append(m)
                        t = m.get('type', m.get('category', 'unknown'))
                        marker_types[t] = marker_types.get(t, 0) + 1
                    regions_found[region_cn] = len(data)
                    print(f"  ✓ {region_cn}: {len(data)} 个标记")
            except Exception as e:
                print(f"  ✗ {region_cn}: {e}")

    # 2. 读取 interactivemap 的数据
    print("\n📥 读取 interactivemap 标记...")
    for imap_file in OUTPUT_DIR.glob("imap_*_options.json"):
        try:
            with open(imap_file, 'r', encoding='utf-8') as f:
                data = json.load(f)
            found = 0
            if isinstance(data, dict):
                for key, value in data.items():
                    if isinstance(value, list) and len(value) > 0:
                        for item in value:
                            if isinstance(item, dict) and ('x' in item or 'lat' in item or 'coords' in item):
                                item['_source'] = 'interactivemap'
                                item['_category_group'] = key
                                all_markers.append(item)
                                found += 1
            print(f"  ✓ {imap_file.name}: 提取 {found} 个标记")
        except Exception as e:
            print(f"  ✗ {imap_file.name}: {e}")

    # 3. 读取 map-core 里的地点信息
    core_path = OUTPUT_DIR / "nteguide_map-core.json"
    core_places = []
    if core_path.exists():
        try:
            with open(core_path, 'r', encoding='utf-8') as f:
                core = json.load(f)
            print(f"\n📋 map-core 结构: {list(core.keys()) if isinstance(core, dict) else type(core)}")
            if isinstance(core, dict):
                for key, val in core.items():
                    if isinstance(val, list):
                        for item in val:
                            if isinstance(item, dict) and 'name' in item:
                                core_places.append(item)
            print(f"  ✓ 核心地点数: {len(core_places)}")
        except Exception as e:
            print(f"  ✗ map-core 解析错误: {e}")

    # 4. 保存完整合并的数据库
    merged_path = OUTPUT_DIR / "complete_map_database.json"
    summary = {
        "total_markers": len(all_markers),
        "regions": regions_found,
        "marker_types": dict(sorted(marker_types.items(), key=lambda x: -x[1])),
        "core_places_count": len(core_places),
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "sources": ["nteguide.com", "interactivemap.app"],
    }

    output_db = {
        "summary": summary,
        "markers": all_markers,
        "core_places": core_places,
    }

    with open(merged_path, 'w', encoding='utf-8') as f:
        json.dump(output_db, f, ensure_ascii=False, indent=2)

    print(f"\n✅ 完整地图数据库已保存: {merged_path}")
    print(f"\n📊 数据摘要:")
    print(f"  标记总数: {summary['total_markers']}")
    print(f"  区域分布: {json.dumps(regions_found, ensure_ascii=False, indent=4)}")
    print(f"  类型分布 (前15): ")
    for t, c in list(summary['marker_types'].items())[:15]:
        print(f"    {t}: {c}")

    return summary

def main():
    print("🎮 异环 (Neverness to Everness) 完整地图数据抓取器")
    print("=" * 60)

    try:
        # Step 1: 抓中文站
        fetch_nteguide()

        # Step 2: 抓国际站
        fetch_interactivemap()

        # Step 3: 合并
        merge_and_summarize()

        print("\n" + "=" * 60)
        print("🎉 全部完成！地图数据已保存到 models/ 目录")
        print("=" * 60)
        print("\n生成的关键文件:")
        for f in sorted(OUTPUT_DIR.glob("nteguide_*.json")):
            print(f"  - {f.name} ({f.stat().st_size//1024}KB)")
        for f in sorted(OUTPUT_DIR.glob("imap_*.json")):
            print(f"  - {f.name} ({f.stat().st_size//1024 if f.exists() else 0}KB)")
        print(f"  - complete_map_database.json (全部合并)")
        print(f"  - nte-game-hd.jpg (高清底图)")
        print(f"  - map_tiles_nteguide/ (地图瓦片目录)")

    except KeyboardInterrupt:
        print("\n⚠️ 用户中断")
    except Exception as e:
        print(f"\n❌ 出错: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    main()
