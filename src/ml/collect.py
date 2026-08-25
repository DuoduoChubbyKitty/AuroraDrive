#!/usr/bin/env python3
# [OFFLINE-TOOL] 离线训练数据采集工具，不进入 Route B 运行时部署包。
"""
AuroraDrive 驾驶数据采集 v3 — 纯 ctypes CoreGraphics 版，零 pip 依赖，零子进程

用法:
  python3 src/ml/collect.py --list          # 列出所有可见窗口
  python3 src/ml/collect.py                 # 交互式: 选窗口 → 选视角 → 录制
  python3 src/ml/collect.py --perspective third  # 跳过视角选择

录制: 回车开始 / 回车停止。10fps, 224×224 PNG。
"""

import os, csv, json, time, threading, sys, ctypes, argparse
from datetime import datetime

# ════════════════════════════════════════════════════════════════════════
# CoreGraphics + CoreFoundation + ImageIO via ctypes
# ════════════════════════════════════════════════════════════════════════

_CG = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
_CF = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
_IIO = ctypes.CDLL("/System/Library/Frameworks/ImageIO.framework/ImageIO")

# ── CF 签名 ────────────────────────────────────────────────────────────

_CF.CFStringCreateWithCString.restype = ctypes.c_void_p
_CF.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
_CF.CFRelease.restype = None
_CF.CFRelease.argtypes = [ctypes.c_void_p]
_CF.CFDictionaryGetValueIfPresent.restype = ctypes.c_bool
_CF.CFDictionaryGetValueIfPresent.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
_CF.CFStringGetCString.restype = ctypes.c_bool
_CF.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
_CF.CFNumberGetValue.restype = ctypes.c_bool
_CF.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p]
_CF.CFArrayGetCount.restype = ctypes.c_long
_CF.CFArrayGetCount.argtypes = [ctypes.c_void_p]
_CF.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
_CF.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
_CF.CFDataCreateMutable.restype = ctypes.c_void_p
_CF.CFDataCreateMutable.argtypes = [ctypes.c_void_p, ctypes.c_long]
_CF.CFDictionaryCreate.restype = ctypes.c_void_p
_CF.CFDictionaryCreate.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long,
                                    ctypes.c_void_p, ctypes.c_void_p]
_CF.CFDataGetBytePtr.restype = ctypes.c_void_p
_CF.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]
_CF.CFDataGetLength.restype = ctypes.c_long
_CF.CFDataGetLength.argtypes = [ctypes.c_void_p]

# ── CG 签名 ────────────────────────────────────────────────────────────

_CG.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
_CG.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
_CG.CGEventSourceKeyState.restype = ctypes.c_bool
_CG.CGEventSourceKeyState.argtypes = [ctypes.c_int32, ctypes.c_uint16]
_CG.CGMainDisplayID.restype = ctypes.c_uint32
_CG.CGDisplayCreateImage.restype = ctypes.c_void_p
_CG.CGDisplayCreateImage.argtypes = [ctypes.c_uint32]
_CG.CGImageGetWidth.restype = ctypes.c_size_t
_CG.CGImageGetWidth.argtypes = [ctypes.c_void_p]
_CG.CGImageGetHeight.restype = ctypes.c_size_t
_CG.CGImageGetHeight.argtypes = [ctypes.c_void_p]
_CG.CGImageRelease.restype = None
_CG.CGImageRelease.argtypes = [ctypes.c_void_p]
_CG.CGColorSpaceCreateDeviceRGB.restype = ctypes.c_void_p
_CG.CGBitmapContextCreate.restype = ctypes.c_void_p
_CG.CGBitmapContextCreate.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t,
    ctypes.c_size_t, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_uint32]
_CG.CGBitmapContextCreateImage.restype = ctypes.c_void_p
_CG.CGBitmapContextCreateImage.argtypes = [ctypes.c_void_p]
_CG.CGContextDrawImage.restype = None
_CG.CGContextDrawImage.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
_CG.CGContextRelease.restype = None
_CG.CGContextRelease.argtypes = [ctypes.c_void_p]
_CG.CGColorSpaceRelease.restype = None
_CG.CGColorSpaceRelease.argtypes = [ctypes.c_void_p]
_CG.CGBitmapContextGetData.restype = ctypes.c_void_p
_CG.CGBitmapContextGetData.argtypes = [ctypes.c_void_p]

# ── IIO 签名 ───────────────────────────────────────────────────────────

_IIO.CGImageDestinationCreateWithData.restype = ctypes.c_void_p
_IIO.CGImageDestinationCreateWithData.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p]
_IIO.CGImageDestinationAddImage.restype = None
_IIO.CGImageDestinationAddImage.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
_IIO.CGImageDestinationFinalize.restype = ctypes.c_bool
_IIO.CGImageDestinationFinalize.argtypes = [ctypes.c_void_p]

# ── 常量 ────────────────────────────────────────────────────────────────

_kCFAllocatorDefault = None
_kCFStringEncodingUTF8 = 0x08000100
_kCGBitmapByteOrder32Big = 0x400
_kCGImageAlphaNoneSkipLast = 5
_kUTTypePNG = "public.png"
_kHIDState = 1
kCGWindowListOptionOnScreenOnly = 1

TARGET_W = 224
TARGET_H = 224
CAPTURE_INTERVAL = 0.1

VK_MAP = {"W": 0x0D, "A": 0x00, "S": 0x01, "D": 0x02, "SPACE": 0x31}


# ════════════════════════════════════════════════════════════════════════
# 辅助函数
# ════════════════════════════════════════════════════════════════════════

def _cf_str(s: str) -> ctypes.c_void_p:
    return _CF.CFStringCreateWithCString(None, s.encode("utf-8"), _kCFStringEncodingUTF8)

def _dict_get_str(d, key: str) -> str:
    kv = _cf_str(key)
    v = ctypes.c_void_p()
    if _CF.CFDictionaryGetValueIfPresent(d, kv, ctypes.byref(v)):
        buf = ctypes.create_string_buffer(512)
        if _CF.CFStringGetCString(v, buf, 512, _kCFStringEncodingUTF8):
            _CF.CFRelease(kv); return buf.value.decode("utf-8", errors="replace")
    _CF.CFRelease(kv); return ""

def _dict_get_int(d, key: str) -> int:
    kv = _cf_str(key)
    v = ctypes.c_void_p()
    out = ctypes.c_int32()
    if _CF.CFDictionaryGetValueIfPresent(d, kv, ctypes.byref(v)):
        _CF.CFNumberGetValue(v, 3, ctypes.byref(out))
    _CF.CFRelease(kv); return out.value


# ════════════════════════════════════════════════════════════════════════
# 窗口扫描
# ════════════════════════════════════════════════════════════════════════

def list_windows():
    arr = _CG.CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, 0)
    n = _CF.CFArrayGetCount(arr)
    results = []
    for i in range(n):
        d = _CF.CFArrayGetValueAtIndex(arr, i)
        title = _dict_get_str(d, "kCGWindowName")
        owner = _dict_get_str(d, "kCGWindowOwnerName")
        wid = _dict_get_int(d, "kCGWindowNumber")
        if title or owner:
            results.append({"id": wid, "title": title, "owner": owner})
    _CF.CFRelease(arr)
    return results


# ════════════════════════════════════════════════════════════════════════
# 键盘状态 — 优先读 key_watcher.py 的日志文件，不可用时回退轮询
# ════════════════════════════════════════════════════════════════════════

KEYLOG_PATH = "/tmp/aurora_keys.csv"
_keylog_offset = 0  # 上次读到的行数

def _read_keylog() -> tuple | None:
    """读 key_watcher.py 输出的 CSV 最新一行 → (steer, throttle, brake) 或 None"""
    global _keylog_offset
    try:
        if not os.path.exists(KEYLOG_PATH):
            return None
        # 新鲜度检查：key_watcher 每 ~100ms 写一次，mtime 超过 0.5s 视为该进程已停止，
        # 此时不要再读陈旧最后一行，直接回退到直接轮询（用户自己的终端里能读到键）。
        if time.time() - os.path.getmtime(KEYLOG_PATH) > 0.5:
            return None
        lines = []
        with open(KEYLOG_PATH, "r", encoding="utf-8") as f:
            f.seek(_keylog_offset)
            lines = [l.strip() for l in f.readlines()]
            _keylog_offset = f.tell()
        if not lines:
            return None
        # 取最后一行
        last = lines[-1].split(",")
        if len(last) < 7:
            return None
        # timestamp,W,A,S,D,SPACE,SHIFT
        w = int(last[1]); a = int(last[2]); s = int(last[3])
        d = int(last[4]); sp = int(last[5])
        steer = -1.0 if (a and not d) else (1.0 if (d and not a) else 0.0)
        throttle = 1.0 if w else 0.0
        brake = 1.0 if (s or sp) else 0.0
        return (steer, throttle, brake)
    except Exception:
        return None


def _key_down_direct(kc: int) -> bool:
    """直接轮询（沙箱内不可用，仅回退）"""
    return _CG.CGEventSourceKeyState(_kHIDState, kc)


def poll_keyboard():
    """优先读 keylog 文件，不可用则直接轮询（大概率不可用）"""
    r = _read_keylog()
    if r is not None:
        return r

    a = _key_down_direct(0x00); d = _key_down_direct(0x02)
    w = _key_down_direct(0x0D); s = _key_down_direct(0x01)
    sp = _key_down_direct(0x31)
    steer = -1.0 if (a and not d) else (1.0 if (d and not a) else 0.0)
    throttle = 1.0 if w else 0.0
    brake = 1.0 if (s or sp) else 0.0
    return steer, throttle, brake


# 注意：不要在启动时删除 keylog。key_watcher.py 是独立进程持续写入该文件，
# 若这里删除会导致两个进程间的文件通道断裂、键盘数据丢失。
# 偏移默认为 0，首次读取会从文件头扫到末尾再取最后一行（即当前按键状态）。


# ════════════════════════════════════════════════════════════════════════
# 截屏：CGDisplayCreateImage → CGBitmapContext resize → PNG
# ════════════════════════════════════════════════════════════════════════

def capture_to_png(out_path: str) -> bool:
    """完整的 CGDisplayCreateImage → resize → PNG 保存"""
    # 1. 截图
    did = _CG.CGMainDisplayID()
    img = _CG.CGDisplayCreateImage(did)
    if not img:
        return False

    # 2. 创建目标 bitmap context (224×224 ARGB)
    cs = _CG.CGColorSpaceCreateDeviceRGB()
    bytes_per_row = TARGET_W * 4
    ctx = _CG.CGBitmapContextCreate(
        None, TARGET_W, TARGET_H, 8, bytes_per_row,
        cs, _kCGBitmapByteOrder32Big | _kCGImageAlphaNoneSkipLast
    )
    _CG.CGColorSpaceRelease(cs)

    if not ctx:
        _CG.CGImageRelease(img)
        return False

    # 3. 绘制缩放
    rect_arr = (ctypes.c_double * 4)(0.0, 0.0, float(TARGET_W), float(TARGET_H))
    _CG.CGContextDrawImage(ctx, rect_arr, img)
    _CG.CGImageRelease(img)

    # 4. 获取像素数据
    pixel_ptr = _CG.CGBitmapContextGetData(ctx)
    if not pixel_ptr:
        _CG.CGContextRelease(ctx)
        return False

    # 5. 用 ImageIO 写 PNG
    data = _CF.CFDataCreateMutable(None, 0)
    png_type = _cf_str(_kUTTypePNG)

    # CGImage from context
    resized = _CG.CGBitmapContextCreateImage(ctx)
    _CG.CGContextRelease(ctx)

    if not resized:
        _CF.CFRelease(png_type); _CF.CFRelease(data); return False

    dest = _IIO.CGImageDestinationCreateWithData(data, png_type, 1, None)
    _IIO.CGImageDestinationAddImage(dest, resized, None)
    ok = _IIO.CGImageDestinationFinalize(dest)

    # 6. 写出 PNG bytes
    if ok:
        ptr = _CF.CFDataGetBytePtr(data)
        length = _CF.CFDataGetLength(data)
        if ptr and length > 0:
            buf = ctypes.string_at(ptr, length)
            with open(out_path, "wb") as f:
                f.write(buf)

    _CF.CFRelease(dest) if dest else None
    _CF.CFRelease(png_type)
    _CF.CFRelease(data)
    _CG.CGImageRelease(resized)
    return ok and os.path.exists(out_path)


# ════════════════════════════════════════════════════════════════════════
# 录制器
# ════════════════════════════════════════════════════════════════════════

STOP_FILE = "/tmp/aurora_stop"

def set_stop_signal():
    """外部可在任意时刻 touch /tmp/aurora_stop 来停止录制"""
    with open(STOP_FILE, "w", encoding="utf-8") as f:
        f.write("stop")
    print(f"\n[信号] 已创建停止信号 {STOP_FILE}")

def clear_stop_signal():
    try: os.remove(STOP_FILE)
    except OSError: pass

def check_stop_signal() -> bool:
    return os.path.exists(STOP_FILE)


class Recorder:
    def __init__(self, perspective: str, output_dir: str):
        self.perspective = perspective
        self.output_dir = output_dir
        self.frame_count = 0
        self.controls = []
        self.running = False
        self._lock = threading.Lock()

    def _loop(self):
        frames_dir = os.path.join(self.output_dir, "frames")
        os.makedirs(frames_dir, exist_ok=True)
        t0 = time.time()

        while self.running:
            t_start = time.time()

            path = os.path.join(frames_dir, f"{self.frame_count:05d}.png")
            if not capture_to_png(path):
                time.sleep(0.05)
                continue

            s, th, b = poll_keyboard()
            elapsed = time.time() - t0

            with self._lock:
                self.controls.append({"timestamp": round(elapsed, 4),
                    "frame": self.frame_count, "steer": s, "throttle": th, "brake": b})
                self.frame_count += 1

            # 每 30 帧检查一次停止信号（减少文件 IO）
            if self.frame_count % 30 == 0 and check_stop_signal():
                print(f"\n[录制] 检测到停止信号，正在保存...")
                self.running = False
                break

            dt = time.time() - t_start
            if dt < CAPTURE_INTERVAL:
                time.sleep(CAPTURE_INTERVAL - dt)

    def start(self):
        self.running = True
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self):
        self.running = False
        self._thread.join(timeout=5)

    def save(self):
        csv_path = os.path.join(self.output_dir, "controls.csv")
        with open(csv_path, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=["timestamp", "frame", "steer", "throttle", "brake"])
            w.writeheader()
            with self._lock:
                w.writerows(self.controls)

        meta = {"perspective": self.perspective, "target_w": TARGET_W, "target_h": TARGET_H,
                "capture_interval_ms": int(CAPTURE_INTERVAL * 1000), "total_frames": self.frame_count,
                "duration_seconds": round(self.controls[-1]["timestamp"], 1) if self.controls else 0,
                "created_at": datetime.now().isoformat()}
        with open(os.path.join(self.output_dir, "meta.json"), "w", encoding="utf-8") as f:
            json.dump(meta, f, indent=2, ensure_ascii=False)

    def stats(self) -> dict:
        if not self.controls: return {}
        n = len(self.controls); dur = self.controls[-1]["timestamp"]
        s = sum(1 for c in self.controls if c["steer"] != 0) / n * 100
        t = sum(1 for c in self.controls if c["throttle"] > 0) / n * 100
        b = sum(1 for c in self.controls if c["brake"] > 0) / n * 100
        fd = os.path.join(self.output_dir, "frames")
        fs = sum(os.path.getsize(os.path.join(fd, f)) for f in os.listdir(fd)) if os.path.isdir(fd) else 0
        return {"frames": self.frame_count, "duration_s": dur, "duration_min": dur/60,
                "steer_pct": s, "throttle_pct": t, "brake_pct": b, "size_mb": fs/1024/1024}


# ════════════════════════════════════════════════════════════════════════
# 主入口
# ════════════════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(description="AuroraDrive 数据采集")
    parser.add_argument("--list", action="store_true", help="仅列出窗口")
    parser.add_argument("--perspective", choices=["third", "first"], help="视角")
    parser.add_argument("--now", action="store_true", help="立即开始录制（跳过交互），靠 /tmp/aurora_stop 停止")
    args = parser.parse_args()

    if args.list:
        wins = list_windows()
        print(f"\n{len(wins)} 个窗口:\n")
        for i, w in enumerate(wins):
            title = w["title"] or "(无标题)"
            owner = w["owner"] or "(无)"
            print(f"  [{i}] ID={w['id']:<6} | {title[:45]:45s} | {owner}")
        return

    # 选视角
    perspective = args.perspective
    if not perspective:
        perspective = input("视角 [third/first]: ").strip().lower()
        while perspective not in ("third", "first"):
            perspective = input("输入 third 或 first: ").strip().lower()

    # 输出目录
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    proj = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    out_dir = os.path.join(proj, "recordings", f"{perspective}_{ts}")
    os.makedirs(out_dir, exist_ok=True)

    # 测试截图
    test_p = os.path.join(out_dir, "_test.png")
    if capture_to_png(test_p):
        os.remove(test_p)
        print("截屏测试 OK ✓")
    else:
        print("截屏失败 ✗ — 无障碍权限？系统设置 → 隐私 → 屏幕录制")
        sys.exit(1)

    # 录制
    print(f"\n输出: {out_dir}")
    print(f"视角: {perspective}, 分辨率: {TARGET_W}×{TARGET_H}, 帧率: 10fps")

    clear_stop_signal()
    rec = Recorder(perspective, out_dir)

    if args.now:
        # 无人模式：3 秒倒计时后直接开始
        print(f"\n3 秒后开始录制——切到游戏！")
        for i in [3, 2, 1]:
            print(f"  {i}...")
            time.sleep(1)
        rec.start()
        print(f"\n录制中！停止方式:")
        print(f"  1) 切回来按 Ctrl+C")
        print(f"  2) 或让我执行: touch {STOP_FILE}")
        print(f"  3) 或你手动: touch {STOP_FILE}")
        try:
            while rec.running:
                time.sleep(0.5)
        except KeyboardInterrupt:
            print("\nCtrl+C — 正在停止...")
    else:
        input("\n>>> 按回车开始录制 <<<")
        rec.start()
        print("\n录制中... 按回车停止")
        input()

    rec.stop()
    rec.save()

    st = rec.stats()
    print(f"\n── 完成 ──")
    print(f"  帧数: {st['frames']}  时长: {st['duration_s']:.0f}s ({st['duration_min']:.1f}min)")
    print(f"  大小: {st['size_mb']:.1f}MB")
    print(f"  转向: {st['steer_pct']:.0f}%  油门: {st['throttle_pct']:.0f}%  刹车: {st['brake_pct']:.0f}%")
    print(f"  {out_dir}")


if __name__ == "__main__":
    main()
