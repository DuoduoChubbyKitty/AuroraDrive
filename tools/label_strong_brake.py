#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
label_strong_brake.py — 用 SmolVLM2 视觉模型从"刹车帧"中标注"紧急刹车/强力刹车"
- 只读 frames/(图片) 与 controls.csv(仅回填 strong_brake 列, 先备份)
- 流式输出 + 每帧打印模型判读原文(带图片路径)
- 用法:
    python3 tools/label_strong_brake.py                 # 全量标注 1437 个刹车帧
    python3 tools/label_strong_brake.py --limit 1      # 只标 1 帧(测试)
    python3 tools/label_strong_brake.py --clip <路径>   # 指定其他 clip
"""
import argparse, base64, json, os, sys, time, shutil, urllib.request

SRV = "http://127.0.0.1:8080/v1/chat/completions"
PROMPT = (
    "这是一张游戏《异环》的第三人称驾驶视角截图，画面中你可以看到玩家自己控制的汽车"
    "（通常是镜头跟随的主体，位于画面中下方或中央）。请忽略玩家自己的车，只判断："
    "玩家车正前方的道路上，是否有其他车辆、行人或障碍物正在高速接近玩家车、"
    "看起来即将发生追尾或正面碰撞（即必须立即急刹/强力刹车才能避免事故）。"
    "如果有，先输出一行'需要紧急制动'；如果只是玩家自己的车停在路边/空地上，"
    "或前方空旷、没有即将撞上的其他对象，输出'不需要紧急制动'。"
    "然后另起一行用一句话说明理由。"
)


def b64(path):
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode("ascii")


def stream_chat(img_b64):
    """流式请求视觉服务, 实时打印 delta, 返回完整文本"""
    payload = {
        "model": "smolvlm",
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": PROMPT},
            {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{img_b64}"}},
        ]}],
        "stream": True,
        "max_tokens": 160,
        "temperature": 0.0,
    }
    req = urllib.request.Request(
        SRV, data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"})
    buf = []
    with urllib.request.urlopen(req, timeout=180) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                obj = json.loads(data)
                d = obj["choices"][0]["delta"].get("content", "")
            except Exception:
                continue
            if d:
                buf.append(d)
                sys.stdout.write(d)
                sys.stdout.flush()
    return "".join(buf)


def decide(text):
    t = text.replace(" ", "")
    pos = (("需要紧急制动" in t) or ("紧急制动" in t) or ("紧急刹车" in t)
           or ("需要紧急" in t) or ("立即制动" in t))
    return 1 if pos else 0


def find_img(frames_dir, frame):
    p = os.path.join(frames_dir, f"{frame:06d}.jpg")
    if os.path.exists(p):
        return p
    p2 = os.path.join(frames_dir, f"{frame + 1:06d}.jpg")  # 兜底偏移
    if os.path.exists(p2):
        return p2
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clip",
                    default="/Users/dupi/Desktop/自动驾驶系统/data/raw_clips/clip_20260729_000501")
    ap.add_argument("--limit", type=int, default=0, help="限制处理刹车帧数(0=全部)")
    ap.add_argument("--out", default=None, help="label_log 路径")
    args = ap.parse_args()

    clip = os.path.abspath(args.clip)
    frames_dir = os.path.join(clip, "frames")
    ctrl = os.path.join(clip, "controls.csv")
    log_path = args.out or os.path.join(clip, "label_log.txt")

    if not os.path.exists(ctrl):
        print(f"[错误] 找不到 controls.csv: {ctrl}", flush=True)
        sys.exit(1)

    with open(ctrl, encoding="utf-8") as f:
        lines = f.read().splitlines()
    header = lines[0].split(",")
    idx = {h.strip(): i for i, h in enumerate(header)}
    fi, bi, si = idx["frame"], idx["brake"], idx["strong_brake"]

    brake_rows = []  # (line_index, frame)
    for li, row in enumerate(lines):
        if li == 0:
            continue
        cols = row.split(",")
        if len(cols) <= bi:
            continue
        if cols[bi].strip() in ("1", "1.0"):
            try:
                brake_rows.append((li, int(float(cols[fi]))))
            except Exception:
                pass

    if args.limit > 0:
        brake_rows = brake_rows[:args.limit]
    total = len(brake_rows)
    print(f"[信息] 待标注刹车帧: {total}  日志: {log_path}", flush=True)

    emergency = set()
    skipped = 0
    with open(log_path, "w", encoding="utf-8") as log:
        for n, (li, frame) in enumerate(brake_rows, 1):
            pct = n * 100 // total if total else 0
            print(f"\n{'=' * 60}\n帧 {n}/{total} ({pct}%)  frame={frame}", flush=True)
            img = find_img(frames_dir, frame)
            if not img:
                print(f"  [跳过] 找不到图片 frame={frame}", flush=True)
                log.write(f"{frame},NONE,skip,\n")
                skipped += 1
                continue
            print(f"  图片: {img}", flush=True)
            print("  模型判读: ", end="", flush=True)
            text = stream_chat(b64(img))
            dec = decide(text)
            print(f"\n  -> strong_brake = {dec}", flush=True)
            log.write(f"{frame},{os.path.basename(img)},{dec},{text.replace(chr(10), ' ')}\n")
            if dec:
                emergency.add(frame)
            time.sleep(0.05)

    # 回填 controls.csv 的 strong_brake 列 (先备份)
    bak = ctrl + ".bak"
    if not os.path.exists(bak):
        shutil.copy2(ctrl, bak)
    new_lines = []
    for li, row in enumerate(lines):
        cols = row.split(",")
        if li != 0 and len(cols) > si:
            try:
                fr = int(float(cols[fi]))
            except Exception:
                fr = -1
            if fr in emergency:
                cols[si] = "1.0"
        new_lines.append(",".join(cols))
    with open(ctrl, "w", encoding="utf-8") as f:
        f.write("\n".join(new_lines) + "\n")

    print(f"\n{'#' * 60}\n完成: 刹车帧 {total}, 标为紧急 {len(emergency)}, 跳过 {skipped}\n"
          f"已回填 {ctrl} (strong_brake 列), 备份 {bak}\n日志 {log_path}", flush=True)


if __name__ == "__main__":
    main()
