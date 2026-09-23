#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
macOS 游戏画面连续截图器

每 interval 秒截一张图，用于给 MaaNTE 模板匹配做验证数据集。

优先使用 Quartz (CoreGraphics) 直接截屏，速度快、间隔准；
不可用时回退到 screencapture 命令。

用法:
    python3 tools/mac_screen_record.py --out data/recording --interval 0.5
"""

import os
import sys
import time
import argparse
import subprocess

def make_quartz_grabber(window_id=None):
    """返回一个截屏函数；不可用则返回 None。"""
    try:
        import Quartz
        import CoreFoundation
    except ImportError:
        return None

    def grab(path):
        try:
            if window_id:
                arr = Quartz.CGWindowListCopyWindowInfo(
                    Quartz.kCGWindowListOptionIncludingWindow, window_id)
                if arr and len(arr) > 0:
                    img = Quartz.CGWindowListCreateImage(
                        Quartz.CGRectNull,
                        Quartz.kCGWindowListOptionIncludingWindow,
                        window_id,
                        Quartz.kCGWindowImageBoundsIgnoreFraming)
                else:
                    img = None
            else:
                img = Quartz.CGDisplayCreateImage(
                    Quartz.CGMainDisplayID())
            if img is None:
                return False
            url = CoreFoundation.CFURLCreateFromFileSystemRepresentation(
                None, path.encode('utf-8'), len(path.encode('utf-8')), False)
            dest = Quartz.CGImageDestinationCreateWithURL(
                url, 'public.jpeg', 1, None)
            if dest is None:
                return False
            Quartz.CGImageDestinationAddImage(dest, img, None)
            ok = Quartz.CGImageDestinationFinalize(dest)
            return bool(ok)
        except Exception:
            return False

    return grab


def screencapture_grabber(window_id=None, region=None):
    """用 screencapture 命令截图（回退方案）。"""
    def grab(path):
        cmd = ['screencapture', '-x', '-t', 'jpg']
        if window_id:
            cmd += ['-l', str(window_id), '-o']
        elif region:
            cmd += ['-R', region]
        cmd.append(path)
        try:
            r = subprocess.run(cmd, capture_output=True, timeout=10)
            return r.returncode == 0 and os.path.exists(path)
        except Exception:
            return False
    return grab


def main():
    ap = argparse.ArgumentParser(description='macOS 连续截图器')
    ap.add_argument('--out', default='data/recording', help='输出目录')
    ap.add_argument('--interval', type=float, default=0.5, help='间隔秒数')
    ap.add_argument('--duration', type=float, default=0, help='总时长秒，0=不限')
    ap.add_argument('--window-id', type=int, default=0, help='只截该窗口 id，0=全屏')
    ap.add_argument('--region', default='', help='区域 x,y,w,h（仅 screencapture 回退时用）')
    ap.add_argument('--quality', type=int, default=85, help='JPEG 质量（screencapture 回退用）')
    ap.add_argument('--max-frames', type=int, default=0, help='最多截多少张，0=不限')
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)

    wid = args.window_id or None
    grab = make_quartz_grabber(wid)
    backend = 'Quartz/CoreGraphics'
    if grab is None or not grab(os.path.join(args.out, '.probe.jpg')):
        grab = screencapture_grabber(wid, args.region or None)
        backend = 'screencapture (回退)'
    probe = os.path.join(args.out, '.probe.jpg')
    if os.path.exists(probe):
        os.remove(probe)

    print(f'[recorder] 后端: {backend}')
    print(f'[recorder] 输出: {os.path.abspath(args.out)}')
    print(f'[recorder] 间隔: {args.interval}s  时长: {"不限" if not args.duration else str(args.duration)+"s"}')
    sys.stdout.flush()

    t0 = time.time()
    n = 0
    fails = 0
    next_t = t0
    while True:
        if args.duration and (time.time() - t0) >= args.duration:
            break
        if args.max_frames and n >= args.max_frames:
            break
        path = os.path.join(args.out, f'frame_{n:05d}.jpg')
        ok = grab(path)
        if ok:
            n += 1
        else:
            fails += 1
        if n % 20 == 0 and n > 0:
            el = time.time() - t0
            print(f'[recorder] {n} 张 / {el:.1f}s  (实际 {n/el:.2f} fps)')
            sys.stdout.flush()
        next_t += args.interval
        sleep = next_t - time.time()
        if sleep > 0:
            time.sleep(sleep)
        else:
            next_t = time.time()   # 落后了就重置基准

    el = time.time() - t0
    print(f'[recorder] 结束: {n} 张, {fails} 失败, 耗时 {el:.1f}s, 平均 {n/max(el,0.001):.2f} fps')
    return 0


if __name__ == '__main__':
    sys.exit(main())
