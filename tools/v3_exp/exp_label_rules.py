#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""标签构造规则的可执行验证：keylog.csv 无损还原 vs controls.csv 7 列的有损反推。

本脚本回答三个问题（全部有可复现输出，不是口头结论）：
  Q1 aurora_recorder.c 的 is_*/ 推导逻辑到底把哪些键并成同一列？
  Q2 从 keylog.csv（原始键码边沿）能否精确还原用户要的 6 个键？
  Q3 从 controls.csv 7 列反推，哪些标签**原理上无法还原**（信息已丢失）？

⚠️ 数据诚实性声明：
    本仓库 data/raw_clips/ 为空、全仓不存在任何 controls.csv / keylog.csv
    （已 find 验证），因此**真实标签分布无法统计**。
    本脚本用**合成键位序列**验证规则正确性与信息损失结构；
    合成数据上的比例数字只说明「规则本身的性质」，不代表真实分布（真实分布：未测）。

跑法：
    /usr/local/bin/python3.11 tools/v3_exp/exp_label_rules.py
"""

from __future__ import annotations

from typing import Dict, List, Tuple

# ----------------------------------------------------------------------------
# 1. 录制端键位定义（逐行对照 tools/aurora_recorder.c:52-57）
# ----------------------------------------------------------------------------
#: 键码 → 语义键。数值来自 aurora_recorder.c 注释与 is_* 实现。
KEY_W = {0x0D, 0x7E}      # W / UpArrow
KEY_A = {0x00, 0x7B}      # A / LeftArrow
KEY_S = {0x01, 0x7D}      # S / DownArrow
KEY_D = {0x02, 0x7C}      # D / RightArrow
KEY_SPACE = {0x31}        # Space
KEY_SHIFT = {0x38}        # 仅左 Shift

SEMANTIC_KEYS = ("W", "A", "S", "D", "SHIFT", "SPACE")


def pressed_from_keys(pressed_keycodes: set[int]) -> Dict[str, bool]:
    """从「当前按住的键码集合」还原 6 个语义键。"""
    return {
        "W": bool(pressed_keycodes & KEY_W),
        "A": bool(pressed_keycodes & KEY_A),
        "S": bool(pressed_keycodes & KEY_S),
        "D": bool(pressed_keycodes & KEY_D),
        "SHIFT": bool(pressed_keycodes & KEY_SHIFT),
        "SPACE": bool(pressed_keycodes & KEY_SPACE),
    }


def replay_keylog(events: List[Tuple[float, int, int]],
                  frame_times: List[float]) -> List[Dict[str, bool]]:
    """把 keylog.csv 的 (t_sec, keycode, down) 边沿回放成每帧的 6 键状态。

    ⚠️ 已知失效条件（必须写进数据集构建脚本的告警）：
      ① 录制开始前就按住的键 → 没有 down 事件 → 该键状态未知（默认视为未按）
      ② 丢失 up 事件（tap 被系统临时禁用）→ 键状态会「粘住」
      ③ 因此构建标签时应校验：controls.csv 的 7 列与 keylog 回放结果交叉核对，
         不一致的 clip 要标出来，不要静默通过。
    """
    events = sorted(events, key=lambda e: e[0])
    pressed: set[int] = set()
    out: List[Dict[str, bool]] = []
    ei = 0
    for tf in frame_times:
        while ei < len(events) and events[ei][0] <= tf:
            _, kc, down = events[ei]
            if down:
                pressed.add(kc)
            else:
                pressed.discard(kc)
            ei += 1
        out.append(pressed_from_keys(pressed))
    return out


# ----------------------------------------------------------------------------
# 2. 录制端 7 列推导（逐行对照 tools/aurora_recorder.c:171-176）
# ----------------------------------------------------------------------------
def derive_seven_columns(k: Dict[str, bool]) -> Tuple[float, ...]:
    """按键状态 → controls.csv 7 列 (steer, throttle, brake, handbrake, strong_brake)。"""
    left, right = k["A"], k["D"]
    thr = k["W"]
    brk = k["S"] or k["SPACE"]          # is_brk 含 S/↓/Space → 三者被合并
    shift, space = k["SHIFT"], k["SPACE"]
    steer = -1.0 if (left and not right) else (1.0 if (right and not left) else 0.0)
    throttle = 1.0 if thr else 0.0
    brake = 1.0 if brk else 0.0
    handbrake = 1.0 if (shift and not space) else 0.0
    strong_brake = 1.0 if (shift and space) else 0.0
    return steer, throttle, brake, handbrake, strong_brake


#: 反推结果的三档分类（比笼统的「不确定」更能指导数据集构建决策）
EXACT = "精确"        # 7 列即可唯一确定该键状态
DEGENERATE = "退化歧义"  # 仅当 A+D 同按（或无键）时 steer=0 无法区分，实际驾驶极罕见
LOST = "信息缺失"      # S 与 Space 在 7 列里同形，原理上无法区分


def invert_seven_columns(row: Tuple[float, ...]) -> Dict[str, str]:
    """从 7 列反推语义键状态，返回每个键的三档分类。

    分类依据（所有规则都可对照 aurora_recorder.c:171-176 复核）：
      · steer ∈ {-1,0,+1} 是 left/right 互斥后的结果：
          steer=-1 ⟹ 按了 A 且没按 D
          steer=+1 ⟹ 按了 D 且没按 A
          steer= 0 ⟹ 要么都没按，要么 A+D 同按（被折叠成中立）→ 退化歧义
      · throttle 与 thr 一一对应 → W 精确
      · shift = handbrake ∨ strong_brake（两列互补，必有一个为 1）→ SHIFT 精确
      · brake = S ∨ Space（is_brk 合并三者）：
          strong_brake=1 ⟹ Space 必然按下（精确）
          brake=1 且 strong_brake=0 ⟹ 可能是 S，也可能是 Space → 信息缺失
    """
    steer, throttle, brake, handbrake, strong_brake = row
    res: Dict[str, str] = {}
    res["A"] = EXACT if steer != 0 else DEGENERATE
    res["D"] = EXACT if steer != 0 else DEGENERATE
    res["W"] = EXACT
    res["SHIFT"] = EXACT          # handbrake/strong_brake 两列已把 Shift 状态编码全
    if strong_brake > 0.5:
        res["SPACE"] = EXACT      # Shift+Space 场景：Space 确定按下
    elif brake > 0.5:
        res["SPACE"] = LOST       # 单独 brake=1：S 与 Space 无法区分
    else:
        res["SPACE"] = EXACT      # brake=0 ⟹ S 与 Space 都没按
    if brake > 0.5 and strong_brake < 0.5:
        res["S"] = LOST           # 同上，无法区分
    elif brake > 0.5:
        res["S"] = LOST           # Space 已定；brake 里是否还夹着 S 无法判断
    else:
        res["S"] = EXACT
    return res


def reconstruct_seven(row: Tuple[float, ...]) -> Dict[str, bool]:
    """按 7 列能唯一确定的部分重建键状态。

    只对 invert_seven_columns 标为 EXACT 的键有意义（其余键的返回值不可信，
    所以 Q3 只用 EXACT 档做断言，避免拿猜测量当真）。
    """
    steer, throttle, brake, handbrake, strong_brake = row
    return {
        "W": throttle > 0.5,
        "A": steer < 0,
        "D": steer > 0,
        # brake<0.5 时 S 与 Space 都必为 0，此时 S 是精确的
        "S": False if brake < 0.5 else True,
        "SHIFT": handbrake > 0.5 or strong_brake > 0.5,
        # strong_brake=1 ⟹ Space 必按下（brake 亦必为 1，见录制器逻辑）
        "SPACE": True if strong_brake > 0.5 else False,
    }


# ----------------------------------------------------------------------------
# 3. 合成键位序列（覆盖所有关键组合），验证还原链路
# ----------------------------------------------------------------------------
def build_synthetic_clip() -> Tuple[List[Dict[str, bool]], List[float]]:
    """构造一段合成操作序列，覆盖：W+A 同按、Shift 手刹、Shift+Space 急刹、
    单独 Space、单独 S、无方向键、A+D 同按（recorder 判中立）。

    10 fps（aurora_recorder.c:37 默认值），每段 5 帧 = 0.5 秒。
    """
    segments = [
        # (段名, 按住的键, 帧数)
        ("直道 W",                     {"W"}, 5),
        ("入弯 W+A（★W 与 A 同按）",   {"W", "A"}, 5),
        ("弯心 A",                     {"A"}, 5),
        ("出弯 W+D（★W 与 D 同按）",   {"W", "D"}, 5),
        ("只按 Space（刹车）",          {"SPACE"}, 5),
        ("只按 S（后退）",              {"S"}, 5),
        ("Shift 手刹（无 Space）",      {"SHIFT"}, 5),
        ("Shift+Space 紧急刹车",        {"SHIFT", "SPACE"}, 5),
        ("W+Shift+Space（组合）",       {"W", "SHIFT", "SPACE"}, 5),
        ("A+D 同按（recorder 判中立）", {"A", "D"}, 5),
        ("松手（无方向键）",            set(), 5),
        ("W+Shift（手刹+油门）",        {"W", "SHIFT"}, 5),
    ]
    frames: List[Dict[str, bool]] = []
    for _, keys, n in segments:
        for _ in range(n):
            frames.append({k: (k in keys) for k in SEMANTIC_KEYS})
    fps = 10.0
    times = [i / fps for i in range(len(frames))]
    return frames, times


def emit_keylog(frames: List[Dict[str, bool]], times: List[float]) -> List[Tuple[int, int]]:
    """把帧级键状态转成边沿事件（模拟真实 keylog 内容）。返回 (keycode, down) 序列
    以及事件发生时刻（略早于帧时刻，模拟「先按键后截帧」）。"""
    code_of = {"W": 0x0D, "A": 0x00, "S": 0x01, "D": 0x02, "SHIFT": 0x38, "SPACE": 0x31}
    events: List[Tuple[float, int, int]] = []
    prev: Dict[str, bool] = {k: False for k in SEMANTIC_KEYS}
    for k_state, t in zip(frames, times):
        for name, code in code_of.items():
            now = k_state[name]
            if now != prev[name]:
                events.append((t - 0.001, code, 1 if now else 0))
                prev[name] = now
    return events


def main() -> int:
    print("=" * 80)
    print("Q1 键位合并事实（aurora_recorder.c:52-57 / :168-176）")
    print("=" * 80)
    print("  is_left  : A(0x00) / Left(0x7B)")
    print("  is_right : D(0x02) / Right(0x7C)")
    print("  is_thr   : W(0x0D) / Up(0x7E)")
    print("  is_brk   : S(0x01) / Down(0x7D) / Space(0x31)   ← ★S 与 Space 被合并")
    print("  is_shift : 仅左 Shift(0x38)")
    print("  ⇒ brake 列 = S|↓|Space；因此「只按 Space」与「只按 S」在 7 列里完全同形。")

    frames, times = build_synthetic_clip()
    print(f"\n合成 clip：{len(frames)} 帧 @10fps，覆盖 12 种操作段（含 W+A 同按）")

    # ---- Q2：keylog 无损还原 ----
    events = emit_keylog(frames, times)
    restored = replay_keylog(events, times)
    ok = 0
    for t_gt, t_res in zip(frames, restored):
        if all(t_gt[k] == t_res[k] for k in SEMANTIC_KEYS):
            ok += 1
    print("\n" + "=" * 80)
    print("Q2 从 keylog.csv 还原 6 键")
    print("=" * 80)
    print(f"  事件数 {len(events)}，帧数 {len(frames)}")
    print(f"  逐帧 6 键完全一致：{ok}/{len(frames)} 帧 "
          f"({100.0 * ok / len(frames):.1f}%)")
    assert ok == len(frames), "keylog 还原链路有 bug"
    print("  ✓ 结论：keylog 路径可**无损**还原用户要的 6 个键（W/A/S/D/Shift/Space）")

    # ---- Q3：7 列反推的信息损失（逐帧核对真值，不是只数标签）----
    print("\n" + "=" * 80)
    print("Q3 从 controls.csv 7 列反推的损耗（逐帧核对真值）")
    print("=" * 80)
    tally = {k: {EXACT: 0, DEGENERATE: 0, LOST: 0} for k in SEMANTIC_KEYS}
    checked = 0
    for t_gt in frames:
        row = derive_seven_columns(t_gt)
        inv = invert_seven_columns(row)
        recon = reconstruct_seven(row)
        for k in SEMANTIC_KEYS:
            tag = inv[k]
            tally[k][tag] += 1
            if tag == EXACT:
                checked += 1
                # ★这是真正的校验：凡标「精确」的，反推值必须与真值一致
                assert recon[k] == t_gt[k], (
                    f"标为「精确」却还原错了：键={k} 真值={t_gt[k]} "
                    f"还原={recon[k]} 7列={row}")

    print(f"  {'键':<7}{'精确':>8}{'退化歧义':>10}{'信息缺失':>10}")
    print("  " + "-" * 38)
    for k in SEMANTIC_KEYS:
        print(f"  {k:<7}{tally[k][EXACT]:>8}{tally[k][DEGENERATE]:>10}"
              f"{tally[k][LOST]:>10}")
    print(f"\n  已校验「精确」档断言数：{checked} 个（全部通过，规则无错）")

    n = len(frames)
    print(f"\n  合成序列共 {n} 帧。★关键结论：")
    print(f"    · S 有 {tally['S'][LOST]} 帧、SPACE 有 {tally['SPACE'][LOST]} 帧属于"
          f"「信息缺失」——二者在 7 列里都是 brake=1，")
    print(f"      原理上无法区分（不是阈值调不好，是信息压根没落盘）")
    print(f"    · A/D 的「退化歧义」{tally['A'][DEGENERATE]} 帧来自 steer=0："
          f"既可能是没按方向键，也可能是 A+D 同按被折叠成中立")
    print(f"    · 因此「direction 的 S 类」与「space 头」的真值无法只靠 7 列构造")

    # ---- 逐行演示：让不可还原点一眼可见 ----
    print("\n" + "=" * 80)
    print("逐段对照（7 列长什么样 / 反推结果）")
    print("=" * 80)
    print(f"  {'真实按键':<26}{'steer':>6}{'thr':>5}{'brk':>5}{'hbrk':>6}{'sbrk':>6}"
          f"   S 档位 / SPACE 档位")
    print("  " + "-" * 84)
    seen = set()
    for t_gt in frames:
        keys = "+".join([k for k in SEMANTIC_KEYS if t_gt[k]]) or "(无)"
        if keys in seen:
            continue
        seen.add(keys)
        row = derive_seven_columns(t_gt)
        inv = invert_seven_columns(row)
        # 直接展示三档标签：精确=✓ / 退化歧义=~ / 信息缺失=✗
        mark = {EXACT: "✓精确", DEGENERATE: "~歧义", LOST: "✗缺失"}
        print(f"  {keys:<26}{row[0]:>6.1f}{row[1]:>5.1f}{row[2]:>5.1f}"
              f"{row[3]:>6.1f}{row[4]:>6.1f}"
              f"   {mark[inv['S']]:<8} / {mark[inv['SPACE']]}")

    # ---- 同形冲突：这两行 7 列完全相同，但真实按键不同 ----
    print("\n" + "=" * 80)
    print("★ 同形冲突证明（决定性证据）")
    print("=" * 80)
    only_space = {"W": False, "A": False, "S": False, "D": False,
                  "SHIFT": False, "SPACE": True}
    only_s = {"W": False, "A": False, "S": True, "D": False,
              "SHIFT": False, "SPACE": False}
    r1, r2 = derive_seven_columns(only_space), derive_seven_columns(only_s)
    print(f"  「只按 Space」→ 7 列 = {r1}")
    print(f"  「只按 S」    → 7 列 = {r2}")
    print(f"  两行完全相同？ {r1 == r2}")
    assert r1 == r2, "预期同形"
    print("  ⇒ 7 列数据里这两件事**不可区分**。用户要求 S=后退 与 Space=刹车 是"
          "两个不同输出，\n     所以**必须用 keylog.csv 构建标签**；只有 7 列的旧数据"
          "只能用于 direction 的 {W,A,D} 三类。")

    print("\n" + "=" * 80)
    print("结论汇总")
    print("=" * 80)
    print("  1) keylog.csv 是唯一能构造用户要的全部 6 键标签的数据源（已实测无损）")
    print("  2) controls.csv 7 列只能还原 W/A/D/shift + strong_brake(急刹)，")
    print("     S 与 Space 不可区分 → direction 的 S 类与 space 头缺真值")
    print("  3) 真实数据分布（W 占比、S/Space 占比、W+A 同按率）：**未测**（仓库无数据）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
