#!/usr/bin/env python3
# 验证录制产物是否符合训练端 mono_dataset 期望格式（纯 stdlib，无需 torch）
# 对应 mono_dataset 约定:
#   目录 data/raw_clips/clip_*  → _list_clips 只扫 clip_ 前缀
#   frames/%06d.jpg            → _frame_path v1_old: {frame_idx:06d}.jpg
#   controls.csv 表头 t_sec,frame,steer,throttle,brake → _load_controls_csv 读 steer/throttle/brake
#   view.txt (FPV/TPV)         → _clip_view 视角过滤
import csv
import sys
from pathlib import Path

# 默认校验正式录制目录；可传目录参数校验任意位置（临时夹具、备份盘、导出盘）。
# 用法: python3 tools/verify_recording.py [CLIPS_DIR]
ROOT = Path("/Users/dupi/Desktop/自动驾驶系统/data/raw_clips")
if len(sys.argv) > 1:
    ROOT = Path(sys.argv[1])
EXPECTED_HEADER = ["t_sec", "frame", "steer", "throttle", "brake"]

def verify():
    if not ROOT.exists():
        print(f"[!] {ROOT} 不存在 —— 还没有任何录制")
        return
    clips = sorted(p for p in ROOT.iterdir() if p.is_dir() and p.name.startswith("clip_"))
    print(f"扫描 {ROOT}\n找到 {len(clips)} 个 clip_ 目录\n")
    for c in clips:
        info, issues = [], []
        info.append("clip_ 前缀 OK")
        frames = sorted(c.glob("frames/*.jpg"))
        if frames:
            info.append(f"frames/*.jpg = {len(frames)} 张 (首张 {frames[0].name})")
        else:
            issues.append("缺少 frames/*.jpg")
        csvp = c / "controls.csv"
        if csvp.exists():
            with open(csvp) as f:
                h = next(csv.reader(f))
            # 支持三种格式（按时间倒序演进）：
            #   v3（2026-11-03 现行）：t_sec,frame,w,a,s,d,shift,space,super_brake,ultimate_brake
            #   v2（2026-11-03 中间版）：t_sec,frame,steer,throttle,brake,reverse,handbrake,super_brake,ultimate_brake
            #   v1（2026-11-03 前）  ：t_sec,frame,steer,throttle,brake,handbrake,strong_brake
            # v3 把列名改成原始按键名——V3 模型输出就是按键，不需要物理量翻译层。
            if "w" in h and "shift" in h:
                info.append("controls.csv 表头 OK (v3 纯按键 10 列格式)")
                rows = list(csv.DictReader(open(csvp)))
                if rows:
                    # 交叉校验：组合键必须严格等于原子键的逻辑与，否则录制器有 bug
                    bad_super = sum(
                        1 for r in rows
                        if (r.get("super_brake") == "1") !=
                           (r.get("shift") == "1" and r.get("space") == "1")
                    )
                    bad_ult = sum(
                        1 for r in rows
                        if (r.get("ultimate_brake") == "1") !=
                           (r.get("shift") == "1" and r.get("space") == "1" and r.get("s") == "1")
                    )
                    if bad_super or bad_ult:
                        issues.append(
                            f"组合键与原子键不一致: super 错 {bad_super} 行、ultimate 错 {bad_ult} 行"
                        )
                    else:
                        info.append("组合键校验通过（super/ultimate == 原子键逻辑与）")
                    stat = []
                    for key, label in (("w", "W"), ("a", "A"), ("s", "S"), ("d", "D"),
                                       ("shift", "Shift"), ("space", "Space"),
                                       ("super_brake", "超级刹车"), ("ultimate_brake", "极致刹车")):
                        n = sum(1 for r in rows if r.get(key) == "1")
                        stat.append(f"{label}={n}")
                    info.append(f"控制行={len(rows)}  " + " ".join(stat))

                    # ── 以下三项是 V3KeyDataset 加载时的硬性校验，这里提前查 ──
                    # 必须与 data 侧规则一致，否则本脚本报 OK、训练端却拒绝加载
                    # （审查 P1 的教训：口径不一致会让人误以为数据没问题）。

                    # (1) frame 列必须与行号严格一致
                    bad_frame = [
                        (i, r.get("frame")) for i, r in enumerate(rows)
                        if str(r.get("frame", "")).strip() != str(i)
                    ]
                    if bad_frame:
                        i0, f0 = bad_frame[0]
                        issues.append(
                            f"frame 列与行号不一致（共 {len(bad_frame)} 行，首个: 第{i0}行 frame={f0}）"
                            " → 图像与标签会错配，训练端会拒绝加载")
                    else:
                        info.append("frame 列与行号严格一致")

                    # (2) 实际帧率必须接近 15fps（用 t_sec 实数差，不看 clip.json 声明）
                    try:
                        ts = [float(r["t_sec"]) for r in rows]
                        dts = sorted(b - a for a, b in zip(ts, ts[1:]) if b > a)
                        if dts:
                            med = dts[len(dts) // 2]
                            fps = 1.0 / med if med > 0 else 0.0
                            if abs(fps - 15.0) / 15.0 > 0.15:
                                issues.append(
                                    f"实际帧率约 {fps:.1f}fps，与 V3 假设的 15fps 不符"
                                    "（V3 的 24 帧窗口按 15Hz=1.6s 设计），训练端会拒绝加载")
                            else:
                                info.append(f"实际帧率 {fps:.1f}fps（V3 要求 15fps）")
                        else:
                            issues.append("t_sec 无有效递增，无法判定帧率")
                    except (KeyError, ValueError) as exc:
                        issues.append(f"t_sec 解析失败: {exc}")

                    # (3) 整场必须有按键（否则标签全 0，训练价值为零）
                    labeled = sum(
                        1 for r in rows
                        if any(r.get(k) == "1" for k in
                               ("w", "a", "s", "d", "shift", "space"))
                    )
                    if labeled == 0:
                        issues.append("整场没有任何一帧检测到按键 → 标签列全 0，不能训练")
                    else:
                        info.append(f"有按键帧={labeled}/{len(rows)} "
                                    f"({labeled / len(rows) * 100:.1f}%)")
                        # Shift 是手刹/超级刹车/极致刹车的必要条件，零则三个安全头无正样本
                        if not any(r.get("shift") == "1" for r in rows):
                            issues.append(
                                "整场 shift 从未为 1 → handbrake/super_brake/ultimate "
                                "三个安全头不会有任何正样本（若确实没用手刹可忽略）")
            elif h[:5] == EXPECTED_HEADER:
                if "reverse" in h:
                    info.append("controls.csv 表头 OK (v2 9 列格式，S/空格已分开)")
                else:
                    info.append("controls.csv 表头 OK (v1 旧 7 列格式：S 与空格混在 brake 列)")
                rows = list(csv.DictReader(open(csvp)))
                if rows:
                    r0 = rows[0]
                    info.append(f"控制行={len(rows)} 首行 steer={r0['steer']} throttle={r0['throttle']} brake={r0['brake']}")
            else:
                issues.append(f"controls.csv 表头不符: {h}")
        else:
            issues.append("缺少 controls.csv")
        vt = c / "view.txt"
        if vt.exists():
            info.append(f"view.txt = {vt.read_text().strip()}")
        else:
            issues.append("缺少 view.txt")
        tag = "OK " if not issues else "WARN"
        print(f"[{tag}] {c.name}")
        for i in info:
            print(f"      \u2713 {i}")
        for i in issues:
            print(f"      \u2717 {i}")
    print("\n验证结束。OK = 训练端 mono_dataset 能直接扫描并读取该 clip。")


if __name__ == "__main__":
    verify()
