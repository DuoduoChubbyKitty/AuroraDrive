#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
车道线掩码几何契约 —— 训练侧 ↔ 运行时（Swift）**逐位对拍回归测试**

================================================================================
0. 这个测试防的是什么（背景）
================================================================================
2026-10-08 发现一个隐蔽的几何口径 bug：

  `lane_mask` 的 shape 两侧都是 160×160，**但几何口径完全不同**：
    · 运行时 Swift `MaskGrid`：**letterbox 640 坐标系**下采样 → 画面内容只占
      网格行 **35..125**，上下各 35 行是 letterbox 灰边（114 填充）
    · 修复前训练侧：录制帧直接 resize 到 160×160 → 内容填满全图、无灰边、
      **纵横比被破坏**

  后果：同一物理像素的网格行坐标**最多相差 35 格 = 网格高度的 21.9%**，
  且上下反向拉伸。模型训练时看到的车道线位置，上车后系统性错位。

  最危险之处：`LaneMaskEncoder` 用 `MaxPool2d(2,2)` + `AdaptiveAvgPool2d((1,1))`，
  **任何输入尺寸都能吃下去不报错**，所以 shape 对齐会给人「已经对齐了」的
  **假安全感** —— 这类 bug 不会崩、不会告警，只会让模型上车即失效。

  本测试通过**真编译并运行 Swift 代码**（不是读代码推断），把同一份输入分别
  喂给 Swift 的 `extractMask()` 与 Python 的 `logits_to_grid()`，**逐位比对**。

================================================================================
1. 依赖
================================================================================
    · `src/lane_geometry.py`   —— 训练侧唯一真值实现（被 dataset_v2 使用）
    · `swiftc`                 —— macOS 自带（Xcode CLT）。缺失时本测试**降级为
                                  纯 Python 自检**并明确标注「未做 Swift 对拍」，
                                  绝不假装通过。
    · Swift 源片段在本文件内**逐行复刻**自：
        - `Sources/AuroraDrive/Inference/YolopxEngine.swift` `LetterboxMetrics.calculate()`
        - `Sources/AuroraDrive/Inference/YolopxEngine.swift` `extractMask()`

================================================================================
2. 用法
================================================================================
    cd <repo root>
    ./.venv-yolo26/bin/python3 tools/verify_lane_geometry_contract.py

    退出码：0 = 全部通过；1 = 有失败项（可直接接入 CI / regression-gate.sh）
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

import numpy as np

_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT / "src") not in sys.path:
    sys.path.insert(0, str(_ROOT / "src"))

try:
    import lane_geometry as LG
except ImportError as exc:  # pragma: no cover
    print(f"✗ 无法导入 src/lane_geometry.py: {exc}")
    sys.exit(1)


# ==================================================================================
# Swift 源片段（复刻自 YolopxEngine.swift）
# ==================================================================================
_SWIFT_LETTERBOX = textwrap.dedent('''
    import Foundation

    struct LetterboxMetrics {
        var ratio: Double
        var padX: Int
        var padY: Int
        var padBottom: Int
        var newW: Int
        var newH: Int
        var srcW: Int
        var srcH: Int

        // 复刻 YolopxEngine.swift:150-166 LetterboxMetrics.calculate()
        static func calculate(srcW: Int, srcH: Int, size: Int) -> LetterboxMetrics {
            guard srcW > 0, srcH > 0 else {
                return LetterboxMetrics(ratio: 0, padX: 0, padY: 0, padBottom: 0,
                                        newW: 0, newH: 0, srcW: 0, srcH: 0)
            }
            let r = min(Double(size) / Double(srcH), Double(size) / Double(srcW))
            let newW = Int((Double(srcW) * r).rounded())
            let newH = Int((Double(srcH) * r).rounded())
            let dw = Double(size - newW) / 2
            let dh = Double(size - newH) / 2
            let padX = Int((dw - 0.1).rounded())
            let padY = Int((dh - 0.1).rounded())
            let padBottom = Int((dh + 0.1).rounded())
            return LetterboxMetrics(ratio: r, padX: padX, padY: padY,
                                    padBottom: padBottom, newW: newW, newH: newH,
                                    srcW: srcW, srcH: srcH)
        }
    }

    let sizes = [(640,360),(1280,720),(1920,1080),(800,600),(640,640),
                 (1024,768),(2560,1440),(3840,2160),(500,500),(640,480),
                 (1600,900),(720,480),(1440,900),(2048,1152),(640,400)]
    for (w,h) in sizes {
        let m = LetterboxMetrics.calculate(srcW: w, srcH: h, size: 640)
        print("\\(w) \\(h) \\(m.ratio) \\(m.newW) \\(m.newH) \\(m.padX) \\(m.padY) \\(m.padBottom)")
    }
''')

_SWIFT_EXTRACT = textwrap.dedent('''
    import Foundation

    func readNpyFloat(_ path: String, _ n: Int) -> [Float] {
        guard let data = FileManager.default.contents(atPath: path) else {
            fatalError("read fail \\(path)")
        }
        let hlen = Int(data[8]) | (Int(data[9]) << 8)
        let off = 10 + hlen
        var out = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: off).assumingMemoryBound(to: Float.self)
            for i in 0..<n { out[i] = base[i] }
        }
        return out
    }

    // ★ 逐行复刻 YolopxEngine.swift extractMask() 的核心循环：
    //   (ch1 > ch0) → 每个 stride×stride 块多数表决 → grid×grid
    func extractMask(_ ch0: [Float], _ ch1: [Float], grid: Int, srcSize: Int) -> [UInt8] {
        let stride = srcSize / grid
        var cells = [UInt8](repeating: 0, count: grid * grid)
        for gy in 0..<grid {
            for gx in 0..<grid {
                var positive = 0
                for dy in 0..<stride {
                    for dx in 0..<stride {
                        let py = gy * stride + dy
                        let px = gx * stride + dx
                        let i0 = py * srcSize + px
                        let a = ch0[i0], b = ch1[i0]
                        if b > a { positive += 1 }
                    }
                }
                if positive * 2 >= stride * stride { cells[gy * grid + gx] = 1 }
            }
        }
        return cells
    }

    let n = 640 * 640
    let ch0 = readNpyFloat(CommandLine.arguments[1], n)
    let ch1 = readNpyFloat(CommandLine.arguments[2], n)
    let cells = extractMask(ch0, ch1, grid: 160, srcSize: 640)
    var s = ""
    for v in cells { s += "\\(v)" }
    print(s)
''')


class Result:
    def __init__(self) -> None:
        self.passed = 0
        self.failed: list = []
        self.skipped: list = []

    def ok(self, name: str, detail: str = "") -> None:
        self.passed += 1
        print(f"  ✓ {name}" + (f"  {detail}" if detail else ""))

    def fail(self, name: str, detail: str = "") -> None:
        self.failed.append(name)
        print(f"  ✗ {name}" + (f"  {detail}" if detail else ""))

    def skip(self, name: str, reason: str) -> None:
        self.skipped.append((name, reason))
        print(f"  ⊘ SKIP {name}  ({reason})")


def _swiftc_available() -> bool:
    try:
        r = subprocess.run(["swiftc", "--version"], capture_output=True, text=True)
        return r.returncode == 0
    except FileNotFoundError:
        return False


def test_swift_round(res: Result) -> None:
    print("\n[1] Swift round 语义（half away from zero）")
    cases = [(0.5, 1), (-0.5, -1), (1.5, 2), (2.5, 3), (-2.5, -3),
             (139.9, 140), (140.1, 140), (0.4999, 0), (0.0, 0),
             (3.5, 4), (-3.5, -4), (0.1, 0), (-0.1, 0)]
    bad = []
    for x, exp in cases:
        got = LG._swift_round(x)
        if got != exp:
            bad.append((x, got, exp))
    if bad:
        res.fail("_swift_round 与 Swift 语义一致", f"不一致: {bad[:4]}")
    else:
        res.ok("_swift_round 与 Swift 语义一致", f"{len(cases)} 组")
    # 明确记录 Python 内置 round 的差异（这是必须自实现的原因）
    if round(2.5) == LG._swift_round(2.5):
        res.fail("Python round 与 Swift 确实不同（自实现必要性）",
                 "round(2.5) 竟然等于 Swift 结果，自实现的理由需复核")
    else:
        res.ok("Python 内置 round 与 Swift 不同（自实现必要性）",
               f"round(2.5)={round(2.5)} vs Swift={LG._swift_round(2.5)}")


def test_letterbox_vs_swift(res: Result, tmp: Path) -> None:
    print("\n[2] letterbox 参数 vs Swift LetterboxMetrics.calculate")
    if not _swiftc_available():
        res.skip("letterbox 参数逐位对拍", "swiftc 不可用")
        return
    src = tmp / "lb.swift"
    src.write_text(_SWIFT_LETTERBOX)
    binp = tmp / "lb"
    r = subprocess.run(["swiftc", "-O", str(src), "-o", str(binp)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        res.fail("Swift letterbox 编译", r.stderr.strip()[:200])
        return
    out = subprocess.run([str(binp)], capture_output=True, text=True)
    if out.returncode != 0:
        res.fail("Swift letterbox 运行", out.stderr.strip()[:200])
        return

    bad = []
    n = 0
    for line in out.stdout.strip().splitlines():
        p = line.split()
        if len(p) < 8:
            continue
        n += 1
        w, h = int(p[0]), int(p[1])
        s_ratio, s_nw, s_nh = float(p[2]), int(p[3]), int(p[4])
        s_px, s_py, s_pb = int(p[5]), int(p[6]), int(p[7])
        m = LG.letterbox_metrics(w, h, 640)
        if not (abs(m["ratio"] - s_ratio) < 1e-12 and m["newW"] == s_nw
                and m["newH"] == s_nh and m["padX"] == s_px
                and m["padY"] == s_py and m["padBottom"] == s_pb):
            bad.append((w, h, (s_nw, s_nh, s_px, s_py, s_pb),
                        (m["newW"], m["newH"], m["padX"], m["padY"], m["padBottom"])))
    if bad:
        res.fail("letterbox 参数逐位对拍", f"{len(bad)}/{n} 组不一致: {bad[:2]}")
    else:
        res.ok("letterbox 参数逐位对拍", f"{n} 组源尺寸全部一致")


def test_extract_mask_vs_swift(res: Result, tmp: Path) -> None:
    print("\n[3] extractMask 逐位对拍（Swift 真跑 vs Python 复刻）")
    if not _swiftc_available():
        res.skip("extractMask 逐位对拍", "swiftc 不可用")
        return

    # 构造确定性 logits：两条斜车道线 + 2% 单像素噪声（检验多数表决的降噪）
    rng = np.random.default_rng(20261008)
    ch0 = rng.normal(0, 1, (640, 640)).astype(np.float32)
    ch1 = rng.normal(0, 1, (640, 640)).astype(np.float32)
    for y in range(140, 500):
        for x in range(200 + (y - 140) // 3, 210 + (y - 140) // 3):
            ch1[y, x] += 8.0
        for x in range(430 - (y - 140) // 4, 440 - (y - 140) // 4):
            ch1[y, x] += 8.0
    noise = rng.random((640, 640)) < 0.02
    ch1[noise] += 6.0

    p0 = tmp / "ch0.npy"
    p1 = tmp / "ch1.npy"
    np.save(p0, ch0)
    np.save(p1, ch1)

    src = tmp / "em.swift"
    src.write_text(_SWIFT_EXTRACT)
    binp = tmp / "em"
    r = subprocess.run(["swiftc", "-O", str(src), "-o", str(binp)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        res.fail("Swift extractMask 编译", r.stderr.strip()[:200])
        return
    out = subprocess.run([str(binp), str(p0), str(p1)],
                         capture_output=True, text=True)
    if out.returncode != 0:
        res.fail("Swift extractMask 运行", out.stderr.strip()[:200])
        return

    swift_cells = np.array([int(c) for c in out.stdout.strip()],
                           dtype=np.uint8).reshape(160, 160)
    py_cells = LG.logits_to_grid(np.stack([ch0, ch1]), grid=160)
    diff = int((swift_cells != py_cells).sum())
    if diff == 0:
        res.ok("extractMask 逐位对拍",
               f"25600 像素 0 差异，正像素 {int(swift_cells.sum())}")
    else:
        res.fail("extractMask 逐位对拍", f"{diff}/25600 像素不一致")


def test_geometry_constants(res: Result) -> None:
    print("\n[4] 几何常量（640×360 源图）")
    m = LG.letterbox_metrics(640, 360, 640)
    if (m["padY"], m["newH"], m["ratio"]) == (140, 360, 1.0):
        res.ok("640×360 letterbox 参数", f"padY={m['padY']} newH={m['newH']} ratio={m['ratio']}")
    else:
        res.fail("640×360 letterbox 参数", f"实得 {m['padY']},{m['newH']},{m['ratio']}")

    vx0, vy0, vx1, vy1 = LG.valid_region_in_grid(m, 160)
    if (vy0, vy1) == LG.VALID_ROWS_640x360:
        res.ok("valid 行范围 = 35..125", f"实际 [{vy0},{vy1})，占 {(vy1-vy0)/160:.1%}")
    else:
        res.fail("valid 行范围 = 35..125",
                 f"实得 [{vy0},{vy1})，期望 {LG.VALID_ROWS_640x360}")


def test_fail_fast(res: Result) -> None:
    print("\n[5] fail-fast 契约（拒绝静默 resize —— 本 bug 的根治点）")
    # 必须拒绝的输入
    reject = [
        ("相机空间 180×320", np.zeros((180, 320), np.float32)),
        ("非整除 128×128", np.zeros((128, 128), np.float32)),
        ("非方形 100×160", np.zeros((100, 160), np.float32)),
    ]
    for name, arr in reject:
        try:
            LG.mask_to_grid(arr)
            res.fail(f"拒绝 {name}", "竟然接受了（静默降级 = 本 bug 复发风险）")
        except ValueError:
            res.ok(f"拒绝 {name}")

    # 必须接受的输入
    accept = [
        ("已降采样 160×160", np.zeros((160, 160), np.float32), (160, 160)),
        ("letterbox 全分辨率 640×640", np.zeros((640, 640), np.float32), (160, 160)),
        ("[1,160,160]", np.zeros((1, 160, 160), np.float32), (160, 160)),
    ]
    for name, arr, exp in accept:
        try:
            g = LG.mask_to_grid(arr)
            if g.shape == exp:
                res.ok(f"接受 {name}", f"→ {g.shape}")
            else:
                res.fail(f"接受 {name}", f"shape {g.shape} != {exp}")
        except ValueError as e:
            res.fail(f"接受 {name}", str(e)[:80])

    # 取值校验
    try:
        LG.assert_lane_contract(np.full((160, 160), 0.5, np.float32))
        res.fail("拒绝非 0/1 取值", "竟然接受了")
    except ValueError:
        res.ok("拒绝非 0/1 取值")


def test_content_rows(res: Result) -> None:
    print("\n[6] 几何口径诊断（内容行范围）—— 用于识别错误口径")
    # letterbox 口径：内容应落在 35..125
    lb = np.zeros((160, 160), np.float32)
    lb[35:125, 70:90] = 1.0
    rows = LG.grid_content_rows(lb)
    if rows is not None and rows[0] >= 35 and rows[1] <= 125:
        res.ok("letterbox 口径内容落在 35..125", f"实测 {rows}")
    else:
        res.fail("letterbox 口径内容落在 35..125", f"实测 {rows}")

    # 错误口径：内容填满 0..160（拉伸填满的特征）
    st = np.zeros((160, 160), np.float32)
    st[0:160, 70:90] = 1.0
    rows2 = LG.grid_content_rows(st)
    if rows2 is not None and (rows2[0] < 35 or rows2[1] > 125):
        res.ok("错误拉伸口径可被诊断出来", f"实测 {rows2} 超出 valid 区间")
    else:
        res.fail("错误拉伸口径可被诊断出来", f"实测 {rows2}")

    if LG.grid_content_rows(np.zeros((160, 160), np.float32)) is None:
        res.ok("全 0 掩码返回 None")
    else:
        res.fail("全 0 掩码返回 None")


def test_dataset_wiring(res: Result) -> None:
    print("\n[7] dataset_v2 / train_v2 接线（口径已统一）")
    try:
        import torch  # noqa: F401
        from dataset_v2 import MultiTaskClipsDataset
    except ImportError as e:
        res.skip("dataset_v2 接线", f"导入失败: {e}")
        return

    clips = _ROOT / "data" / "raw_clips"
    if not clips.exists():
        res.skip("dataset_v2 接线", "data/raw_clips 不存在")
        return
    try:
        ds = MultiTaskClipsDataset(str(clips), allow_empty=True)
        s = ds[0]
        lm = s["lane_mask"]
        if tuple(lm.shape) == (1, LG.LANE_GRID, LG.LANE_GRID):
            res.ok("数据集输出 lane_mask 为 [1,160,160]", f"实测 {tuple(lm.shape)}")
        else:
            res.fail("数据集输出 lane_mask 为 [1,160,160]", f"实测 {tuple(lm.shape)}")
        if getattr(ds, "lane_grid", None) == LG.LANE_GRID:
            res.ok("数据集 lane_grid 默认 160")
        else:
            res.fail("数据集 lane_grid 默认 160", f"实测 {getattr(ds, 'lane_grid', None)}")
    except Exception as e:
        res.fail("dataset_v2 接线", f"{type(e).__name__}: {str(e)[:100]}")

    # 适配层：错误口径必须被拒绝，不得静默 resize
    try:
        import train_v2 as T
        import torch
        B = 1
        batch = {
            "image": torch.zeros(B, 3, 180, 320),
            "lane_mask": torch.zeros(B, 1, 180, 320),   # ★ 错误口径
            "det_boxes": torch.zeros(B, 20, 4),
            "det_scores": torch.zeros(B, 20),
            "det_classes": torch.zeros(B, 20, dtype=torch.long),
            "det_mask": torch.zeros(B, 20),
            "vehicle_state": torch.zeros(B, 10),
        }
        import contextlib
        import io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            out = T.build_m2_inputs(batch, torch.device("cpu"), True, True, 160)
        if out["lane_mask"] is None:
            res.ok("适配层拒绝 180×320 错误口径（不 resize）")
        else:
            res.fail("适配层拒绝 180×320 错误口径",
                     f"竟然透传 {tuple(out['lane_mask'].shape)} —— 静默 resize 复发！")

        try:
            with contextlib.redirect_stdout(io.StringIO()):
                T.build_m2_inputs(batch, torch.device("cpu"), True, True, 160,
                                  strict_lane_geometry=True)
            res.fail("strict_lane_geometry=True 抛错", "竟然没抛")
        except ValueError:
            res.ok("strict_lane_geometry=True 抛错")

        # 正确口径必须原样透传
        batch["lane_mask"] = torch.zeros(B, 1, 160, 160)
        batch["lane_mask"][0, 0, 80:90, 70:90] = 1.0
        with contextlib.redirect_stdout(io.StringIO()):
            out2 = T.build_m2_inputs(batch, torch.device("cpu"), True, True, 160)
        if out2["lane_mask"] is not None and int(out2["lane_mask"].sum()) == 200:
            res.ok("适配层原样透传 160×160 正确口径", "非零像素 200 未被改动")
        else:
            got = None if out2["lane_mask"] is None else int(out2["lane_mask"].sum())
            res.fail("适配层原样透传 160×160 正确口径", f"非零像素 {got} != 200")
    except ImportError as e:
        res.skip("train_v2 适配层接线", f"导入失败: {e}")
    except Exception as e:
        res.fail("train_v2 适配层接线", f"{type(e).__name__}: {str(e)[:100]}")


def main() -> int:
    print("=" * 78)
    print("车道线掩码几何契约 · 训练侧 ↔ Swift 运行时 逐位对拍")
    print("=" * 78)
    print(f"  lane_geometry: {LG.__file__}")
    print(f"  swiftc       : {'可用' if _swiftc_available() else '不可用（将降级）'}")
    print(f"  LANE_GRID={LG.LANE_GRID} LANE_SRC_SIZE={LG.LANE_SRC_SIZE} "
          f"LANE_STRIDE={LG.LANE_STRIDE}")

    res = Result()
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        test_swift_round(res)
        test_letterbox_vs_swift(res, tmp)
        test_extract_mask_vs_swift(res, tmp)
    test_geometry_constants(res)
    test_fail_fast(res)
    test_content_rows(res)
    test_dataset_wiring(res)

    print()
    print("=" * 78)
    print(f"结果：通过 {res.passed} / 失败 {len(res.failed)} / 跳过 {len(res.skipped)}")
    if res.failed:
        print("失败项：")
        for f in res.failed:
            print(f"  · {f}")
    if res.skipped:
        print("跳过项：")
        for n, why in res.skipped:
            print(f"  · {n} — {why}")
    print("=" * 78)
    if res.failed:
        print("✗ 几何契约未满足")
        return 1
    if res.skipped:
        print("⚠ 通过，但有跳过项（未做 Swift 对拍时结论不完整）")
        return 0
    print("✓ 几何契约全部满足（含 Swift 逐位对拍）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
