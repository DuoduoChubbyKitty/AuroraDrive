#!/usr/bin/env python3
"""watch_collect.py — 游戏画面只读循环采集。

绝对不注入任何输入：只调用 cgrab.py 截屏 + cv2 比较 + 写盘。
只保存「与最近帧都明显不同」的画面，避免同一场景存几百张。

用法: watch_collect.py [间隔秒] [差异阈值]
输出: data/watch/w_<ts>.png  +  data/watch/watch.log
"""
import cv2
import numpy as np
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'data/watch')
os.makedirs(OUT, exist_ok=True)

INTERVAL = float(sys.argv[1]) if len(sys.argv) > 1 else 1.5
THRESH = float(sys.argv[2]) if len(sys.argv) > 2 else 7.0
MAXKEEP = 1200
GAME_PID = '53168'
TMP = '/tmp/_watch_grab.png'
LOG = os.path.join(OUT, 'watch.log')

recent = []          # 最近帧的 160x90 灰度缩略图
saved = 0
frames = 0
skipped_dup = 0
skipped_bg = 0
last_fg_check = 0.0
fg_ok = True

logf = open(LOG, 'a', buffering=1)


def say(msg):
    line = f'{time.strftime("%H:%M:%S")} {msg}'
    print(line, flush=True)
    logf.write(line + '\n')


def game_frontmost():
    try:
        r = subprocess.run(
            ['osascript', '-e',
             'tell application "System Events" to get unix id of first process whose frontmost is true'],
            capture_output=True, text=True, timeout=5)
        return r.stdout.strip() == GAME_PID
    except Exception:
        return False


def grab():
    try:
        r = subprocess.run(
            ['/usr/bin/python3', os.path.join(ROOT, 'tools/cgrab.py'),
             TMP, '0', '33', '1470', '923'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
        if r.returncode != 0:
            return None
        return cv2.imread(TMP)
    except Exception:
        return None


say(f'=== 采集开始  间隔={INTERVAL}s  阈值={THRESH} ===')

while True:
    loop_start = time.time()
    frames += 1

    # 每 3 帧检查一次游戏是否在前台，避免存下别的窗口
    if frames - last_fg_check >= 3:
        fg_ok = game_frontmost()
        last_fg_check = frames
    if not fg_ok:
        skipped_bg += 1
        if skipped_bg % 20 == 1:
            say(f'[待机] 游戏不在前台 (已跳过 {skipped_bg} 帧)')
        time.sleep(INTERVAL)
        continue

    img = grab()
    if img is None:
        time.sleep(1.0)
        continue

    H, W = img.shape[:2]
    full = cv2.resize(img, (1280, int(H * 1280 / W)), interpolation=cv2.INTER_AREA)
    small = cv2.cvtColor(
        cv2.resize(full, (160, 90), interpolation=cv2.INTER_AREA),
        cv2.COLOR_BGR2GRAY)

    best = 255.0
    for s in recent:
        d = float(np.mean(cv2.absdiff(small, s)))
        if d < best:
            best = d

    if best < THRESH:
        skipped_dup += 1
    else:
        saved += 1
        fn = os.path.join(OUT, f'w_{int(time.time())}_{time.strftime("%H%M%S")}.png')
        cv2.imwrite(fn, full)
        recent.append(small)
        if len(recent) > 40:
            recent.pop(0)
        say(f'保存 #{saved}  差异={best:.1f}  {os.path.basename(fn)}')
        if saved >= MAXKEEP:
            say(f'达到上限 {MAXKEEP}，停止')
            break

    if frames % 60 == 0:
        say(f'[进度] 帧={frames} 存={saved} 重复跳过={skipped_dup} 后台跳过={skipped_bg}')

    dt = time.time() - loop_start
    time.sleep(max(0.05, INTERVAL - dt))

say(f'=== 采集结束  帧={frames} 存={saved} ===')
