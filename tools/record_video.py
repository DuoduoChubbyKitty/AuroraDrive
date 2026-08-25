#!/usr/bin/env python3
"""
AuroraDrive 纯视频录制器 v2 — 复用 collect.py 的 CoreGraphics ctypes 截屏方案。

与 collect.py 的区别：
  - 不捕获键盘、不写 controls.csv、不做控制注入。只录"画面"。
  - 输出为 JPEG 序列片段文件夹（零视频编码依赖，100% 系统框架），直接喂给
    tools/auto_label.py（其支持读取片段文件夹，无需 ffmpeg/opencv 视频解码）。
  - 支持多屏：默认抓**苹果内建屏幕**(builtin)；可用 --display 选屏
    （0/1 数字索引，或 "main"=菜单栏所在主屏，"builtin"=内建屏）。
  - 提供 --list-displays：把每块屏当前画面截下来生成查看器，肉眼确认游戏在哪块。

用法:
  python3 tools/record_video.py --list-displays   # 看每块屏现在显示什么，选对屏再录
  python3 tools/record_video.py --now             # 3 秒倒计时后自动开始(默认内建屏)
  python3 tools/record_video.py --display 1 --now # 录第 1 号屏
  python3 tools/record_video.py --source mixed    # 标注本段是人机共驾(mixed)

停止方式（--now 模式）： touch /tmp/aurora_video_stop

首跑需在 系统设置 → 隐私与安全性 → 屏幕录制 中允许"终端"(或你用的 shell)，
且给完权限要**退出并重启终端**才生效。
若双击 .command 打不开/录到空帧，先在终端跑: xattr -cr ~/Desktop/AuroraRecorder.command
然后改用  bash ~/Desktop/AuroraRecorder.command  启动(别双击)。

输出目录: <项目>/data/raw_clips/clip_<时间戳>/
  frames/000001.jpg ...       截帧（JPEG）
  clip.json                   元数据(fps/分辨率/时长/来源/display)
"""

import os
import sys
import time
import json
import base64
import hashlib
import threading
import ctypes
import argparse
from datetime import datetime

# ════════════════════════════════════════════════════════════════════════
# CoreGraphics + CoreFoundation + ImageIO via ctypes（与 collect.py 同款）
# ════════════════════════════════════════════════════════════════════════

_CG = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
_CF = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
_IIO = ctypes.CDLL("/System/Library/Frameworks/ImageIO.framework/ImageIO")

_CF.CFStringCreateWithCString.restype = ctypes.c_void_p
_CF.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
_CF.CFRelease.restype = None
_CF.CFRelease.argtypes = [ctypes.c_void_p]
_CF.CFDataCreateMutable.restype = ctypes.c_void_p
_CF.CFDataCreateMutable.argtypes = [ctypes.c_void_p, ctypes.c_long]
_CF.CFDataGetBytePtr.restype = ctypes.c_void_p
_CF.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]
_CF.CFDataGetLength.restype = ctypes.c_long
_CF.CFDataGetLength.argtypes = [ctypes.c_void_p]

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
class CGSize(ctypes.Structure):
    _fields_ = [("width", ctypes.c_double), ("height", ctypes.c_double)]


class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


class CGRect(ctypes.Structure):
    _fields_ = [("origin", CGPoint), ("size", CGSize)]


_CG.CGDisplayBounds.restype = CGRect
_CG.CGDisplayBounds.argtypes = [ctypes.c_uint32]
_CG.CGGetOnlineDisplayList.restype = ctypes.c_int32
_CG.CGGetOnlineDisplayList.argtypes = [ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)]
try:
    _CG.CGDisplayIsBuiltin.restype = ctypes.c_int
    _CG.CGDisplayIsBuiltin.argtypes = [ctypes.c_uint32]
    _HAVE_BUILTIN = True
except AttributeError:
    _HAVE_BUILTIN = False

_kCFAllocatorDefault = None
_kCFStringEncodingUTF8 = 0x08000100
_kCGBitmapByteOrder32Big = 0x400
_kCGImageAlphaNoneSkipLast = 5
_kUTTypeJPEG = "public.jpeg"


def _cf_str(s: str) -> ctypes.c_void_p:
    return _CF.CFStringCreateWithCString(None, s.encode("utf-8"), _kCFStringEncodingUTF8)


def capture_to_jpeg(out_path: str, w: int, h: int, display_id=None) -> bool:
    """抓取指定屏幕 -> resize 到 w*h -> 写 JPEG。无权限/无屏时返回 False。"""
    did = display_id if display_id is not None else _CG.CGMainDisplayID()
    img = _CG.CGDisplayCreateImage(did)
    if not img:
        return False

    cs = _CG.CGColorSpaceCreateDeviceRGB()
    ctx = _CG.CGBitmapContextCreate(
        None, w, h, 8, w * 4, cs,
        _kCGBitmapByteOrder32Big | _kCGImageAlphaNoneSkipLast)
    _CG.CGColorSpaceRelease(cs)
    if not ctx:
        _CG.CGImageRelease(img)
        return False

    rect = (ctypes.c_double * 4)(0.0, 0.0, float(w), float(h))
    _CG.CGContextDrawImage(ctx, rect, img)
    _CG.CGImageRelease(img)

    resized = _CG.CGBitmapContextCreateImage(ctx)
    _CG.CGContextRelease(ctx)
    if not resized:
        return False

    data = _CF.CFDataCreateMutable(None, 0)
    jpg = _cf_str(_kUTTypeJPEG)
    dest = _IIO.CGImageDestinationCreateWithData(data, jpg, 1, None)
    _IIO.CGImageDestinationAddImage(dest, resized, None)
    ok = _IIO.CGImageDestinationFinalize(dest)

    if ok:
        ptr = _CF.CFDataGetBytePtr(data)
        length = _CF.CFDataGetLength(data)
        if ptr and length > 0:
            with open(out_path, "wb") as f:
                f.write(ctypes.string_at(ptr, length))

    _CF.CFRelease(dest) if dest else None
    _CF.CFRelease(jpg)
    _CF.CFRelease(data)
    _CG.CGImageRelease(resized)
    return ok and os.path.exists(out_path)


def list_displays():
    """返回在线屏幕列表: [{index,id,w,h,main,builtin}]"""
    maxd = 16
    ids = (ctypes.c_uint32 * maxd)()
    cnt = ctypes.c_uint32(0)
    _CG.CGGetOnlineDisplayList(maxd, ids, ctypes.byref(cnt))
    main_id = _CG.CGMainDisplayID()
    out = []
    for i in range(cnt.value):
        did = ids[i]
        builtin = False
        if _HAVE_BUILTIN:
            try:
                builtin = bool(_CG.CGDisplayIsBuiltin(did))
            except Exception:
                builtin = False
        b = _CG.CGDisplayBounds(did)
        out.append({
            "index": i,
            "id": did,
            "w": int(b.size.width),
            "h": int(b.size.height),
            "main": did == main_id,
            "builtin": builtin,
        })
    return out


def resolve_display(spec):
    """把 --display 参数解析成 CGDirectDisplayID。
    spec: None->内建屏(找不到则主屏); 'builtin'->内建; 'main'->主屏; int->索引。"""
    disp = list_displays()
    if not disp:
        return _CG.CGMainDisplayID()
    if spec is None or spec == "builtin":
        for d in disp:
            if d["builtin"]:
                return d["id"]
        if spec == "builtin":
            print("[warn] 未找到内建屏幕, 退回主屏")
        return _CG.CGMainDisplayID()
    if spec == "main":
        return _CG.CGMainDisplayID()
    try:
        idx = int(spec)
    except (ValueError, TypeError):
        print(f"[error] --display 无效: {spec} (用 0/1 或 builtin/main)")
        sys.exit(1)
    if 0 <= idx < len(disp):
        return disp[idx]["id"]
    print(f"[error] display 索引越界: {idx} (共 {len(disp)} 块屏)")
    sys.exit(1)


def build_display_picker(out_html):
    """截取每块屏当前画面, 生成自包含 HTML 查看器, 让用户肉眼确认游戏在哪块。"""
    disp = list_displays()
    cards = []
    for d in disp:
        tp = f"/tmp/aurora_disp_{d['index']}.jpg"
        ok = capture_to_jpeg(tp, 480, 270, d["id"])
        if ok:
            # 用 with 语句保证文件句柄释放，避免循环内 open().read() 泄漏 FD
            with open(tp, "rb") as f:
                b = base64.b64encode(f.read()).decode()
            sz = os.path.getsize(tp)
            if sz < 12000:
                note = "⚠️ 体积极小, 疑似空屏/无内容(权限未生效 或 此屏确为空白)"
            else:
                note = "✓ 有画面内容"
        else:
            b = ""
            sz = 0
            note = "✗ 捕获失败(多半是屏幕录制权限未给终端)"
        tag = "【主屏】" if d["main"] else ""
        if d["builtin"]:
            tag += "【内建屏】"
        cards.append(f"""
    <div class="card">
      <h3>屏幕 {d['index']} {tag}</h3>
      <p class="meta">{d['w']}x{d['h']} | 捕获 {sz} 字节<br>{note}</p>
      <img src="data:image/jpeg;base64,{b}"/>
      <p class="cmd">录这块屏: <code>python3 tools/record_video.py --display {d['index']} --now</code></p>
    </div>""")
    html = f"""<!doctype html><html lang="zh"><head><meta charset="utf-8">
<title>AuroraDrive 选屏查看器</title>
<style>
 body{{background:#11151c;color:#d8dee9;font-family:-apple-system,Segoe UI,Roboto,sans-serif;margin:0;padding:24px}}
 h1{{font-size:20px}} h3{{font-size:15px;margin:8px 0 4px;color:#88c0d0}}
 .meta{{color:#7b8494;font-size:12px;margin:0 0 6px}}
 .grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:14px;margin-top:12px}}
 .card{{border:1px solid #2a2f3a;border-radius:6px;padding:10px;background:#161b22}}
 img{{width:100%;border-radius:4px;background:#000;display:block}}
 .cmd{{color:#a3be8c;font-size:12px;margin-top:6px}}
 code{{background:#0b0e13;padding:2px 5px;border-radius:3px}}
</style></head><body>
<h1>AuroraDrive 选屏查看器</h1>
<p class="meta">每块屏当前画面如下。找到显示《异环》的那块, 记下它的"屏幕 N",
   录的时候加 <code>--display N</code>。默认(不加 --display)录<b>内建屏</b>。</p>
<div class="grid">{''.join(cards)}</div>
</body></html>"""
    os.makedirs(os.path.dirname(out_html), exist_ok=True)
    with open(out_html, "w", encoding="utf-8") as f:
        f.write(html)
    return out_html


# ── 停止信号 ──────────────────────────────────────────────────────────────
STOP_FILE = "/tmp/aurora_video_stop"


def set_stop_signal():
    with open(STOP_FILE, "w", encoding="utf-8") as f:
        f.write("stop")
    print(f"\n[信号] 已创建停止信号 {STOP_FILE}")


def clear_stop_signal():
    try:
        os.remove(STOP_FILE)
    except OSError:
        pass


def check_stop_signal() -> bool:
    return os.path.exists(STOP_FILE)


class VideoRecorder:
    def __init__(self, out_dir, w, h, fps, source, display_id):
        self.out_dir = out_dir
        self.frames_dir = os.path.join(out_dir, "frames")
        self.w = w
        self.h = h
        self.fps = fps
        self.source = source
        self.display_id = display_id
        self.interval = 1.0 / fps
        self.running = False
        self.count = 0
        self.timestamps = []
        self._lock = threading.Lock()

    def _loop(self):
        os.makedirs(self.frames_dir, exist_ok=True)
        t0 = time.time()
        while self.running:
            ts = time.time()
            path = os.path.join(self.frames_dir, f"{self.count + 1:06d}.jpg")
            if capture_to_jpeg(path, self.w, self.h, self.display_id):
                with self._lock:
                    self.timestamps.append(round(time.time() - t0, 4))
                    self.count += 1
            else:
                time.sleep(0.2)
                continue

            if self.count % 30 == 0 and check_stop_signal():
                print(f"\n[录制] 检测到停止信号，正在收尾...")
                self.running = False
                break

            dt = time.time() - ts
            if dt < self.interval:
                time.sleep(self.interval - dt)

    def start(self):
        self.running = True
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self):
        self.running = False
        self._thread.join(timeout=5)

    def save(self):
        duration = self.timestamps[-1] if self.timestamps else 0.0
        meta = {
            "name": os.path.basename(self.out_dir),
            "drive_source": self.source,
            "fps": self.fps,
            "width": self.w,
            "height": self.h,
            "total_frames": self.count,
            "duration_seconds": round(duration, 1),
            "created_at": datetime.now().isoformat(),
        }
        with open(os.path.join(self.out_dir, "clip.json"), "w", encoding="utf-8") as f:
            json.dump(meta, f, indent=2, ensure_ascii=False)
        return meta

    def stats(self) -> dict:
        sz = 0
        if os.path.isdir(self.frames_dir):
            sz = sum(os.path.getsize(os.path.join(self.frames_dir, f))
                     for f in os.listdir(self.frames_dir))
        dur = self.timestamps[-1] if self.timestamps else 0.0
        return {
            "frames": self.count,
            "duration_s": dur,
            "duration_min": dur / 60,
            "size_mb": sz / 1024 / 1024,
        }


def _md5(p):
    # 用 with 语句保证文件句柄释放，避免 open().read() 泄漏 FD
    with open(p, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description="AuroraDrive 纯视频录制器")
    parser.add_argument("--source", choices=["autopilot", "human", "mixed"],
                        default="autopilot",
                        help="本段驾驶来源：autopilot=异环自带自动驾驶, "
                             "human=纯人工, mixed=人机共驾(你中途接管)")
    parser.add_argument("--width", type=int, default=640, help="截帧宽(默认640)")
    parser.add_argument("--height", type=int, default=360, help="截帧高(默认360)")
    parser.add_argument("--fps", type=int, default=10, help="帧率(默认10)")
    parser.add_argument("--name", default="", help="片段名后缀(可选)")
    parser.add_argument("--display", default=None,
                        help="选屏: 0/1 数字索引, 或 builtin(内建屏,默认), main(主屏)")
    parser.add_argument("--list-displays", action="store_true",
                        help="截取每块屏当前画面生成查看器, 用于确认游戏在哪块屏")
    parser.add_argument("--now", action="store_true",
                        help="立即开始(3秒倒计时)，靠 /tmp/aurora_video_stop 停止")
    args = parser.parse_args()

    proj = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    if args.list_displays:
        out = os.path.join(proj, "data", "labels", "display_picker.html")
        p = build_display_picker(out)
        print(f"[ok] 选屏查看器已生成: {p}")
        print("     打开它, 找到显示《异环》的屏幕 N, 然后录的时候加 --display N")
        # 顺手在终端尝试打开
        try:
            os.system(f'open "{p}" >/dev/null 2>&1 &')
        except Exception:
            pass
        return

    display_id = resolve_display(args.display)
    disp_info = [d for d in list_displays() if d["id"] == display_id]
    disp_label = f"屏幕{disp_info[0]['index']}" if disp_info else "?"

    # 截屏权限 + 空帧自检
    test_p = os.path.join(proj, "data", "raw_clips", "_test.jpg")
    os.makedirs(os.path.dirname(test_p), exist_ok=True)
    if not capture_to_jpeg(test_p, args.width, args.height, display_id):
        print("截屏失败 ✗ — 系统设置 → 隐私与安全性 → 屏幕录制，允许终端后重启终端再试")
        sys.exit(1)
    test_size = os.path.getsize(test_p)
    blank = test_size < 12000
    if not blank and args.width <= 1280:
        t2 = os.path.join(proj, "data", "raw_clips", "_test2.jpg")
        time.sleep(0.5)
        if capture_to_jpeg(t2, args.width, args.height, display_id):
            if _md5(test_p) == _md5(t2) and os.path.getsize(t2) < 12000:
                blank = True
            os.remove(t2)
    os.remove(test_p)
    if blank:
        print("截屏返回的是空帧 ✗ (图存在但近乎纯色/空白, 体积极小)")
        print("  → 多半: ① 屏幕录制权限没真正生效(给终端并重启终端);")
        print("  → 或 ② 当前选的屏没有游戏(用 --list-displays 看游戏在哪块, 再加 --display N)。")
        print("  → 若双击 .command 启动, 先 xattr -cr ~/Desktop/AuroraRecorder.command 并改用 bash 启动。")
        sys.exit(1)
    print(f"截屏测试 OK ✓ (抓到真实画面, 来自 {disp_label})")

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    clip_name = f"clip_{ts}" + (f"_{args.name}" if args.name else "")
    out_dir = os.path.join(proj, "data", "raw_clips", clip_name)
    os.makedirs(out_dir, exist_ok=True)

    print(f"\n输出: {out_dir}")
    print(f"来源: {args.source} | 屏: {disp_label} | 分辨率: {args.width}x{args.height} | 帧率: {args.fps}fps")
    print(f"（建议全屏运行《异环》在所选屏幕上，录制器截取整个该屏）")

    clear_stop_signal()
    rec = VideoRecorder(out_dir, args.width, args.height, args.fps, args.source, display_id)

    if args.now:
        print(f"\n3 秒后开始录制——切到游戏！")
        for i in [3, 2, 1]:
            print(f"  {i}...")
            time.sleep(1)
        rec.start()
        print(f"\n录制中！停止方式: touch {STOP_FILE}  或  Ctrl+C")
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
    meta = rec.save()
    st = rec.stats()

    print(f"\n── 完成 ──")
    print(f"  帧数: {st['frames']}  时长: {st['duration_s']:.0f}s ({st['duration_min']:.1f}min)")
    print(f"  大小: {st['size_mb']:.1f}MB")
    print(f"  下一步查看: python3 tools/make_clip_viewer.py  (生成 data/labels/clip_viewer.html)")
    print(f"  下一步标注: python3 tools/auto_label.py {out_dir} --out data/labels/labels.csv")
    print(f"  {out_dir}")


if __name__ == "__main__":
    main()
