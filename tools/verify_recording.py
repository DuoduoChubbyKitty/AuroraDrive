#!/usr/bin/env python3
# 验证录制产物是否符合训练端 mono_dataset 期望格式（纯 stdlib，无需 torch）
# 对应 mono_dataset 约定:
#   目录 data/raw_clips/clip_*  → _list_clips 只扫 clip_ 前缀
#   frames/%06d.jpg            → _frame_path v1_old: {frame_idx:06d}.jpg
#   controls.csv 表头 t_sec,frame,steer,throttle,brake → _load_controls_csv 读 steer/throttle/brake
#   view.txt (FPV/TPV)         → _clip_view 视角过滤
import csv
from pathlib import Path

ROOT = Path("/Users/dupi/Desktop/自动驾驶系统/data/raw_clips")
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
