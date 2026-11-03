#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3 关键契约回归测试（自包含，无需预置数据）。

【为什么需要这个脚本】
V3 的很多契约只在代码注释里，一旦有人"顺手优化"就会静默破坏，而且
**模型不报错、只在实车上出错**。本脚本把已实测确认的契约固化成断言。

覆盖的 6 组契约（每组都对应一个真实踩过的坑）：
  1. 17 列 CSV（App 录制器格式）→ dataset_v3 标签转换逐项正确
  2. 缺帧不再让训练中途崩（曾实测 FileNotFoundError 打断训练循环）
  3. 防侧翻惩罚数值与 03 文档 §3.7.4 表格逐项吻合
  4. 防侧翻梯度只流向 vertical（不许压 super_brake）——最关键的安全设计
  5. 速度缺失的两种 fail-safe（个别帧→满罚；整批→关闭并告警，不许静默）
  6. 输出一致性项 L_coh 的量级（矛盾输出被罚得比自洽输出重约 40×）

【不覆盖什么（诚实边界）】
  · Swift 侧（RecordEngine / KeyboardMonitor / EngineProc 转发）——
    本脚本是纯 Python。那边的保障是 `swift build` + 部署契约见
    `docs/v3-design/04-model-code.md` §4.6。
  · 真机录制与真实数据分布 —— 当前无真实数据，全部用合成 fixture。

跑法：
    /usr/local/bin/python3.11 tools/v3_contract_test.py
退出码：0=全部通过；1=有断言失败（失败项逐条打印）
"""

from __future__ import annotations

import csv
import math
import shutil
import sys
import tempfile
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[1]
if str(_REPO_ROOT / "src") not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT / "src"))

import torch                            # noqa: E402

from PIL import Image                   # noqa: E402

from dataset_v3 import V3KeyDataset     # noqa: E402
from model_v3 import V3Loss             # noqa: E402

#: 17 列表头。**必须与 `Sources/AuroraDrive/Capture/RecordEngine.swift` 写出的
#: 表头逐字一致**（前 9 列 V2 连续量 + 后 8 列 V3 原生按键）。改那边就要改这里。
HDR_17 = ["t_sec", "frame", "steer", "throttle", "brake", "speed_kmh",
          "heading", "curvature", "speed_limit", "w", "a", "s", "d",
          "shift", "space", "super_brake", "ultimate_brake"]

#: 10 列表头（`tools/aurora_recorder.c` 的格式，无速度列）
HDR_10 = ["t_sec", "frame", "w", "a", "s", "d",
          "shift", "space", "super_brake", "ultimate_brake"]

_failures: list[str] = []
_checks = 0


def check(cond: bool, label: str, detail: str = "") -> None:
    """记录一条断言结果。不抛异常，让所有问题一次报全。"""
    global _checks
    _checks += 1
    if cond:
        print(f"  ✅ {label}")
    else:
        print(f"  ❌ {label}" + (f"  [{detail}]" if detail else ""))
        _failures.append(label)


def _isolated(tmp: Path, tag: str) -> Path:
    """每组测试用独立的子目录。

    ⚠️ 必须隔离：`V3KeyDataset(clips_dir)` 扫描**该目录下所有** `clip_*`。
    第一版所有组共用一个 tmp 根目录，导致组 7 读到的 ds[0] 其实是组 1 的数据
    （实测 speed=60 却读到 40.0、10 列数据里混进 valid=1.0）——
    **是测试自身串味，不是业务代码的问题**。此函数就是为修掉这个假失败。
    """
    sub = tmp / tag
    sub.mkdir()
    return sub


def _write_clip(root: Path, name: str, header: list[str], rows: list[list],
                n_frames: int, skip_frames: set[int] | None = None,
                view: str = "FPV", size: tuple[int, int] = (640, 360)) -> Path:
    """造一个 clip 目录：controls.csv + frames/*.jpg（+ view.txt）。"""
    clip = root / name
    (clip / "frames").mkdir(parents=True)
    (clip / "view.txt").write_text(view, encoding="utf-8")
    with open(clip / "controls.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)
    skip = skip_frames or set()
    for i in range(n_frames):
        if i in skip:
            continue                 # 模拟 JPEG 编码失败：CSV 有行、图缺失
        # 颜色随帧号变化，保证测试数据不是全同图
        Image.new("RGB", size, ((i * 7) % 256, (i * 3) % 256, (i * 5) % 256)).save(
            clip / "frames" / f"{i:06d}.jpg", quality=60)
    return clip


def _row17(i: int, keys: dict, speed: float | str = "") -> list:
    """按 17 列布局造一行。keys: w/a/s/d/shift/space。"""
    w, a, s, d = (keys.get(k, 0) for k in ("w", "a", "s", "d"))
    sh, sp = keys.get("shift", 0), keys.get("space", 0)
    sup = 1 if (sh and sp) else 0
    ult = 1 if (sh and sp and s) else 0
    return [f"{i / 15:.4f}", i, "0.0000", f"{float(w):.4f}", f"{float(sp):.4f}",
            speed, "", "", "", w, a, s, d, sh, sp, sup, ult]


# ---------------------------------------------------------------------------
# 组 1：17 列 CSV → 标签转换
# ---------------------------------------------------------------------------
def test_17col_labels(tmp: Path) -> None:
    print("\n[组 1] 17 列 CSV（App 录制器格式）→ dataset_v3 标签逐项正确")
    cases = [
        # (keys, 期望 vertical, 期望 horizontal, 期望 hb, 期望 br, 期望 sup, 期望 ult)
        ({"w": 1}, 0, 1, 0, 0, 0, 0),                       # 单纯油门
        ({"w": 1, "d": 1}, 0, 2, 0, 0, 0, 0),               # 油门+右
        ({"space": 1}, 1, 1, 0, 1, 0, 0),                   # 正常刹车
        ({"a": 1}, 1, 0, 0, 0, 0, 0),                       # 左转
        ({"shift": 1, "space": 1}, 1, 1, 1, 1, 1, 0),       # 超级刹车
        ({"shift": 1, "space": 1, "s": 1}, 2, 1, 1, 1, 1, 1),  # 极致刹车
        ({"s": 1}, 2, 1, 0, 0, 0, 0),                       # 纯后退
    ]
    rows = [_row17(i, k, speed=40.0) for i, (k, *_) in enumerate(cases)]
    root = _isolated(tmp, "labels")
    clip = _write_clip(root, "clip_labels", HDR_17, rows, len(rows))
    ds = V3KeyDataset(str(root), skip_all_zero=False)

    check(len(ds) == len(cases), f"样本数 = {len(ds)}（期望 {len(cases)}）",
          f"期望 {len(cases)}")
    for i, (keys, ev, eh, ehb, ebr, esup, eult) in enumerate(cases):
        s = ds[i]
        got = (int(s["vertical"]), int(s["horizontal"]),
               int(float(s["handbrake"])), int(float(s["brake"])),
               int(float(s["super_brake"])), int(float(s["ultimate"])))
        exp = (ev, eh, ehb, ebr, esup, eult)
        check(got == exp, f"keys={keys} → {got}", f"期望 {exp}")


# ---------------------------------------------------------------------------
# 组 2：缺帧不让训练崩
# ---------------------------------------------------------------------------
def test_missing_frame(tmp: Path) -> None:
    print("\n[组 2] 缺帧：建索引时按整窗可用判定，逐样本读取不抛异常")
    n = 40
    rows = [_row17(i, {"w": 1}, speed=40.0) for i in range(n)]
    root = _isolated(tmp, "missing")
    clip = _write_clip(root, "clip_missing", HDR_17, rows, n, skip_frames={10})
    ds = V3KeyDataset(str(root), skip_all_zero=False)

    kept = [fi for _, fi in ds.index]
    check(10 not in kept, "缺失帧 10 未被收录")
    # 窗口深度 = NUM_HI_FRAMES(3) + history(21) - 1 = 23 → 帧 10..33 的窗口含缺失帧
    expect_kept = list(range(10)) + list(range(34, n))
    check(kept == expect_kept, f"保留帧号 = {kept[:5]}..{kept[-3:]}",
          f"期望 {expect_kept}")

    errors = []
    for k in range(len(ds)):
        try:
            ds[k]
        except Exception as exc:            # noqa: BLE001 — 测试要统计任何异常
            errors.append(f"{k}:{type(exc).__name__}")
    check(not errors, f"逐样本读取 {len(ds)} 个，异常 0 个", str(errors[:3]))


# ---------------------------------------------------------------------------
# 组 3/4/5/6：损失项
# ---------------------------------------------------------------------------
def _vert_logits(p_S: float, b: int = 1) -> torch.Tensor:
    """造出让 softmax 的 S 位概率精确等于 p_S 的 logits。

    softmax([0,0,c]) 的 S 位 = e^c/(2+e^c)，要求它 = p → c = ln(2p/(1-p))。
    ⚠️ 不是 ln(p/(1-p))（那是二分类 sigmoid 的公式，会得到偏小的概率）。
    """
    c = math.log(2.0 * p_S / (1.0 - p_S))
    return torch.tensor([[0.0, 0.0, c]]).repeat(b, 1)


def _sb_logit(p: float, b: int = 1) -> torch.Tensor:
    return torch.full((b, 1), math.log(p / (1.0 - p)))


def test_rollover_numbers() -> None:
    print("\n[组 3] 防侧翻数值对齐 03 文档 §3.7.4（7 个场景逐项）")
    crit = V3Loss(enable_ccm=False, enable_intent=False)
    # 文档实测表：(说明, 速度, P(super), P(S), 期望惩罚)
    cases = [
        ("低速 10km/h 超级刹车不带S", 10.0, 0.982, 0.05, 0.00000),
        ("临界 20km/h", 20.0, 0.982, 0.05, 0.00000),
        ("中速 25km/h 半罚", 25.0, 0.982, 0.05, 0.46646),
        ("高速 40km/h 重罚", 40.0, 0.982, 0.05, 0.93291),
        ("高速 40km/h 带S（几乎不罚）", 40.0, 0.982, 0.95, 0.04910),
        ("高速 40km/h 不按超级刹车", 40.0, 0.018, 0.05, 0.01709),
    ]
    for label, v, psup, pS, expect in cases:
        pred = {"vertical": _vert_logits(pS), "super_brake": _sb_logit(psup)}
        target = {"speed_kmh": torch.tensor([v]),
                  "speed_valid": torch.tensor([1.0])}
        _, roll = crit._safety_losses(pred, target)
        got = float(roll)
        check(abs(got - expect) < 5e-4, f"{label} → {got:.5f}",
              f"文档 {expect:.5f}")


def test_rollover_gradient() -> None:
    print("\n[组 4] 防侧翻梯度只流向 vertical（不许压 super_brake）")
    crit = V3Loss(enable_ccm=False, enable_intent=False)
    vert = _vert_logits(0.05).clone().requires_grad_(True)
    sb = _sb_logit(0.982).clone().requires_grad_(True)
    _, roll = crit._safety_losses(
        {"vertical": vert, "super_brake": sb},
        {"speed_kmh": torch.tensor([50.0]), "speed_valid": torch.tensor([1.0])})
    roll.backward()

    check(sb.grad is None, "super_brake 梯度已切断（grad is None）",
          f"实际 {sb.grad}")
    g_s = float(vert.grad[0, 2])
    # 负梯度 = 梯度下降会抬高 P(S) = 训练模型"想踩 S"，正是安全要的方向
    check(g_s < 0, f"vertical[S] 梯度 = {g_s:+.6f}（负值正确）")


def test_rollover_failsafe() -> None:
    print("\n[组 5] 速度缺失的两种 fail-safe")
    crit = V3Loss(enable_ccm=False, enable_intent=False)
    pred = {"vertical": _vert_logits(0.05), "super_brake": _sb_logit(0.982)}

    # ① 个别帧缺速度 → 该帧按满罚（不能当 0 速度，否则安全项静默失效）
    _, roll = crit._safety_losses(
        pred, {"speed_kmh": torch.tensor([40.0, 0.0]),
               "speed_valid": torch.tensor([1.0, 0.0])})
    check(abs(float(roll) - 0.93290) < 1e-3,
          f"个别帧缺速度 → {float(roll):.5f}（应为满罚 0.93290）")

    # ② 整批都无速度 → 关闭并告警一次（不许静默，也不许全罚）
    crit2 = V3Loss(enable_ccm=False, enable_intent=False)
    _, roll2 = crit2._safety_losses(
        pred, {"speed_kmh": torch.tensor([0.0]), "speed_valid": torch.tensor([0.0])})
    check(roll2 is None, "整批无速度 → L_rollover 关闭（返回 None）", str(roll2))
    check(crit2._rollover_disabled_warned is True, "已置告警标志（只告警一次）")

    # ③ 告警标志必须是**实例级**：第二个实例不能被第一个静默掉
    crit3 = V3Loss(enable_ccm=False, enable_intent=False)
    check(crit3._rollover_disabled_warned is False,
          "新实例的告警标志独立（实例级而非类级）")


def test_coherence() -> None:
    print("\n[组 6] L_coh 量级：矛盾输出应被罚得比自洽输出重约 40×")
    crit = V3Loss(enable_ccm=False, enable_intent=False)
    # 矛盾：没按 Shift/空格，却按了 Shift+空格
    bad = {"handbrake": _sb_logit(0.047), "brake": _sb_logit(0.047),
           "super_brake": _sb_logit(0.953), "ultimate": _sb_logit(0.047),
           "vertical": _vert_logits(0.047)}
    # 自洽：四键头一致
    good = {"handbrake": _sb_logit(0.95), "brake": _sb_logit(0.95),
            "super_brake": _sb_logit(0.95), "ultimate": _sb_logit(0.95),
            "vertical": _vert_logits(0.90)}
    coh_bad, _ = crit._safety_losses(bad, {})
    coh_good, _ = crit._safety_losses(good, {})
    kb, kg = float(coh_bad), float(coh_good)
    check(abs(kb - 0.90620) < 1e-3, f"矛盾输出 L_coh = {kb:.5f}（文档 0.90526）")
    check(abs(kg - 0.02123) < 1e-3, f"自洽输出 L_coh = {kg:.5f}（文档 0.02051）")
    check(kb / kg > 30, f"矛盾/自洽 = {kb / kg:.1f}×（文档约 44×）")


# ---------------------------------------------------------------------------
# 组 7：速度字段
# ---------------------------------------------------------------------------
def test_speed_field(tmp: Path) -> None:
    print("\n[组 7] speed_kmh / speed_valid 解析（供防侧翻项）")
    rows = [_row17(0, {"w": 1}, speed="60.0000"),
            _row17(1, {"w": 1}, speed=""),      # 读不到 → 无效
            _row17(2, {"w": 1}, speed="0.0000"),  # 真值 0（停车）→ 有效
            _row17(3, {"w": 1}, speed="-1.0000")]  # OCR 哨兵 → 无效
    root = _isolated(tmp, "speed")
    _write_clip(root, "clip_speed", HDR_17, rows, len(rows))
    ds = V3KeyDataset(str(root), skip_all_zero=False)
    got = [(float(ds[i]["speed_kmh"]), float(ds[i]["speed_valid"]))
           for i in range(len(ds))]
    check(got[0] == (60.0, 1.0), f"speed=60 → {got[0]}（有效）")
    check(got[1] == (0.0, 0.0), f"speed=空 → {got[1]}（无效）")
    check(got[2] == (0.0, 1.0), f"speed=0 → {got[2]}（有效，停车是真实状态）")
    check(got[3] == (0.0, 0.0), f"speed=-1 → {got[3]}（无效，OCR 哨兵）")

    # 无速度列的数据集必须全判无效（否则会拿 0 当速度，静默关掉安全项）
    rows10 = [[f"{i / 15:.4f}", i, 1, 0, 0, 0, 0, 0, 0, 0] for i in range(4)]
    root10 = _isolated(tmp, "nospeed")
    _write_clip(root10, "clip_nospeed", HDR_10, rows10, 4)
    ds10 = V3KeyDataset(str(root10), skip_all_zero=True)
    valid = [float(ds10[i]["speed_valid"]) for i in range(len(ds10))]
    check(all(v == 0.0 for v in valid), f"10 列数据 speed_valid 全 0 → {valid}")


# ---------------------------------------------------------------------------
def main() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="v3_contract_"))
    try:
        print(f"临时 fixture 目录：{tmp}")
        test_17col_labels(tmp)
        test_missing_frame(tmp)
        test_rollover_numbers()
        test_rollover_gradient()
        test_rollover_failsafe()
        test_coherence()
        test_speed_field(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("\n" + "=" * 66)
    if _failures:
        print(f"失败 {len(_failures)}/{_checks} 项：")
        for f in _failures:
            print(f"  · {f}")
        return 1
    print(f"全部通过：{_checks} 项断言，0 失败")
    return 0


if __name__ == "__main__":
    sys.exit(main())
