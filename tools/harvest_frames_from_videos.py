#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从 B站视频快照(videoshot)批量取帧 -> 提取辅助线标签

不下载视频本体, 只取 B站官方生成的快照雪碧图(10x10=100帧,每帧480x270,几百KB/视频)。
用来在没有游戏客户端、不录屏的前提下验证:
  1) 辅助线在真实视频里是否稳定出现
  2) 自动分割命中率
  3) 逐帧 line_now/f1/f2 标签是否连续可用

用法:
  python3 tools/harvest_frames_from_videos.py --aid 116650087024751 116828177171567 --out /tmp/harvest
"""
import argparse
import json
import os
import sys
import urllib.request

UA = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                  "(KHTML, like Gecko) Chrome/125.0 Safari/537.36",
    "Referer": "https://www.bilibili.com/",
}


def fetch_json(url):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def fetch_bytes(url):
    if url.startswith("//"):
        url = "https:" + url
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


def get_videoshot(aid):
    d = fetch_json(f"https://api.bilibili.com/x/player/videoshot?aid={aid}&index=1")
    if d.get("code") != 0:
        return None
    return d["data"]


def cut_tiles(img_bytes, out_dir, prefix, xlen, ylen, tw, th):
    """把雪碧图切成单帧。用 PIL。"""
    from PIL import Image
    import io
    im = Image.open(io.BytesIO(img_bytes))
    paths = []
    for iy in range(ylen):
        for ix in range(xlen):
            box = (ix * tw, iy * th, (ix + 1) * tw, (iy + 1) * th)
            tile = im.crop(box)
            if tile.size != (tw, th):
                continue
            p = os.path.join(out_dir, f"{prefix}_{iy:02d}{ix:02d}.jpg")
            tile.convert("RGB").save(p, quality=92)
            paths.append(p)
    return paths


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--aid", nargs="+", required=True, type=int)
    ap.add_argument("--out", default="/tmp/harvest")
    ap.add_argument("--keep", action="store_true", help="保留原始雪碧图")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    meta = []

    for aid in args.aid:
        try:
            info = fetch_json(f"https://api.bilibili.com/x/web-interface/view?aid={aid}")
            title = info["data"]["title"] if info.get("code") == 0 else ""
        except Exception:
            title = ""
        try:
            vs = get_videoshot(aid)
        except Exception as e:
            print(f"  aid={aid} 快照失败: {e}", file=sys.stderr)
            continue
        if not vs:
            print(f"  aid={aid} 无快照", file=sys.stderr)
            continue

        xlen, ylen = vs.get("img_x_len", 10), vs.get("img_y_len", 10)
        tw, th = vs.get("img_x_size", 480), vs.get("img_y_size", 270)
        sub = os.path.join(args.out, f"aid{aid}")
        os.makedirs(sub, exist_ok=True)

        n = 0
        for k, url in enumerate(vs.get("image", [])):
            try:
                b = fetch_bytes(url)
            except Exception as e:
                print(f"  雪碧图{k} 下载失败: {e}", file=sys.stderr)
                continue
            if args.keep:
                with open(os.path.join(sub, f"sprite{k}.jpg"), "wb") as f:
                    f.write(b)
            n += len(cut_tiles(b, sub, f"s{k}", xlen, ylen, tw, th))

        print(f"  aid={aid}  {str(title)[:44]}  切出 {n} 帧 -> {sub}")
        meta.append({"aid": aid, "title": title, "frames": n, "dir": sub})

    with open(os.path.join(args.out, "_index.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
    print(f"\n共 {len(meta)} 个视频, 合计 {sum(m['frames'] for m in meta)} 帧")


if __name__ == "__main__":
    main()
