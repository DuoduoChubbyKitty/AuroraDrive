#!/usr/bin/env python3
"""
AuroraDrive auto-labeling pipeline (offline / batch).

Drives a local vision-language model served by llama.cpp (`llama-server`,
OpenAI-compatible API at http://127.0.0.1:8080/v1) to produce
`(steer, throttle)` training labels from driving video clips.

Method (see docs/auto_label_design.md):
  - split each clip into 3-5s segments
  - for each segment, sample N frames and query the model `samples` times
    (temperature sampling) -> N candidate (steer, throttle)
  - take the median of steer and throttle as the primary label
  - compute consensus (std of candidates):
        tight  -> source = "auto"      (accepted, no human review)
        loose  -> source = "verified"  (flagged for human review)
  - write labels.csv (training-ready) + review_queue.csv (flagged segments)

Model: ggml-org/SmolVLM2-2.2B-Instruct-GGUF  (Q4_K_M ~1.11GB) via llama.cpp.

Usage:
  # real run (requires llama-server up on :8080):
  python3 tools/auto_label.py data/raw_clips            # batch: all clips
  python3 tools/auto_label.py data/raw_clips/clip_xxx   # single clip folder
  python3 tools/auto_label.py drive.mp4                 # or a video file

  # quick test WITHOUT the model (deterministic mock):
  python3 tools/auto_label.py data/raw_clips --mock --out data/labels/labels.csv

Dependencies:
  - stdlib only for the API client (urllib).
  - clip-folder input (frames/*.jpg from record_video.py) needs NO extra deps.
  - video-file input needs `opencv-python` (cv2). If missing, install:
        pip install opencv-python
  - server: `bash tools/start_label_server.sh` (downloads + serves the model)
"""

import argparse
import base64
import glob
import json
import math
import os
import statistics
import sys
import urllib.request

# ----------------------------- config ---------------------------------------
API_BASE = os.environ.get("AURORA_LABEL_API", "http://127.0.0.1:8080/v1")
MODEL_NAME = "local-model"          # llama-server ignores this for a single model
NUM_SAMPLES = 5                      # multi-sample count for median/consensus
TEMPERATURE = 0.7                    # sampling temperature for variance
FRAMES_PER_SEGMENT = 4               # keyframes sent per clip segment
SEGMENT_SEC = 4.0                    # segment length in seconds
CONSENSUS_STD = 0.15                 # max allowed std(steer/throttle) to auto-accept
MIN_VALID = 3                        # need >= this many valid samples to trust

SYSTEM_PROMPT = (
    "You are an autonomous-driving action labeler for a UE5 car game. "
    "Given one or more consecutive game frames, output the driver's control "
    "intent as JSON only."
)
USER_PROMPT = (
    "These frames are consecutive from one driving clip. Decide a SINGLE control "
    "intent for the whole clip. Output strictly one JSON object, no prose, no "
    "markdown fences:\n"
    "{\"steer\": <float in [-1,1]>, \"throttle\": <float in [-1,1]>}\n"
    "steer: -1 = hard left, 0 = straight, +1 = hard right.\n"
    "throttle: -1 = hard brake, 0 = coast, +1 = accelerate.\n"
    "Be conservative: when uncertain, prefer straight (steer 0) and coast "
    "(throttle 0)."
)


# --------------------------- frame extraction -------------------------------
def _encode(frame):
    import cv2
    ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 80])
    if not ok:
        return None
    return base64.b64encode(buf).decode("ascii")


def iter_segments(video_path, segment_sec=SEGMENT_SEC,
                  frames_per_segment=FRAMES_PER_SEGMENT):
    """Yield (seg_index, [base64_jpeg, ...]) sampled within each time segment."""
    import cv2
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        print(f"[warn] cannot open video: {video_path}", file=sys.stderr)
        return
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    duration = (total / fps) if fps else 0.0
    if duration <= 0:
        # fallback: just read whatever frames exist
        frames = []
        while len(frames) < frames_per_segment:
            ok, frame = cap.read()
            if not ok:
                break
            b = _encode(frame)
            if b:
                frames.append(b)
        if frames:
            yield 0, frames
        cap.release()
        return

    n_seg = max(1, math.ceil(duration / segment_sec))
    for s in range(n_seg):
        t0 = s * segment_sec
        t1 = min((s + 1) * segment_sec, duration)
        times = [t0 + (t1 - t0) * (i + 0.5) / frames_per_segment
                 for i in range(frames_per_segment)]
        frames = []
        for t in times:
            cap.set(cv2.CAP_PROP_POS_MSEC, t * 1000.0)
            ok, frame = cap.read()
            if ok:
                b = _encode(frame)
                if b:
                    frames.append(b)
        if frames:
            yield s, frames
    cap.release()


# --------------------------- clip-folder mode -------------------------------
def _b64_file(path):
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode("ascii")


def clip_frame_paths(clip_dir):
    """Return sorted image paths inside a clip folder (frames/ subdir or directly)."""
    for d in (os.path.join(clip_dir, "frames"), clip_dir):
        if os.path.isdir(d):
            paths = sorted(
                glob.glob(os.path.join(d, "*.jpg")) +
                glob.glob(os.path.join(d, "*.jpeg")) +
                glob.glob(os.path.join(d, "*.png"))
            )
            if paths:
                return paths
    return []


def _load_clip_meta(clip_dir):
    mp = os.path.join(clip_dir, "clip.json")
    if os.path.exists(mp):
        try:
            with open(mp, encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}


def iter_clip_segments(clip_dir, segment_sec=SEGMENT_SEC,
                       frames_per_segment=FRAMES_PER_SEGMENT):
    """Yield (seg_index, [base64_jpeg, ...]) sampled from a clip folder of images.
    No cv2 needed — reads JPEG files written by tools/record_video.py."""
    paths = clip_frame_paths(clip_dir)
    if not paths:
        print(f"[warn] no frames in clip: {clip_dir}", file=sys.stderr)
        return
    meta = _load_clip_meta(clip_dir)
    fps = float(meta.get("fps", 10.0)) or 10.0
    n = len(paths)
    duration = n / fps
    if duration <= 0:
        duration = n * 0.1
    n_seg = max(1, math.ceil(duration / segment_sec))
    for s in range(n_seg):
        t0 = s * segment_sec
        t1 = min((s + 1) * segment_sec, duration)
        idxs = [min(n - 1, max(0, int((t0 + (t1 - t0) * (i + 0.5) / frames_per_segment) * fps)))
                for i in range(frames_per_segment)]
        frames = []
        for i in idxs:
            b = _b64_file(paths[i])
            if b:
                frames.append(b)
        if frames:
            yield s, frames


# ----------------------------- model calls ----------------------------------
def _parse_json(content):
    try:
        start = content.find("{")
        end = content.rfind("}")
        if start == -1 or end == -1:
            return None
        obj = json.loads(content[start:end + 1])
        steer = float(obj["steer"])
        throttle = float(obj["throttle"])
        steer = max(-1.0, min(1.0, steer))
        throttle = max(-1.0, min(1.0, throttle))
        return {"steer": steer, "throttle": throttle}
    except Exception:
        return None


def call_model(frames_b64, temperature=TEMPERATURE, api_base=API_BASE):
    images = [
        {"type": "image_url",
         "image_url": {"url": f"data:image/jpeg;base64,{b}"}}
        for b in frames_b64
    ]
    payload = {
        "model": MODEL_NAME,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": [
                {"type": "text", "text": USER_PROMPT},
                *images,
            ]},
        ],
        "temperature": temperature,
        "max_tokens": 96,
    }
    req = urllib.request.Request(
        f"{api_base}/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    content = data["choices"][0]["message"]["content"]
    return _parse_json(content)


def _mock_call(frames_b64, seg_index, temperature=TEMPERATURE):
    # deterministic pseudo-label, no server needed (for pipeline testing).
    # segment has a FIXED true label (seed from seg_index); each sample adds
    # different noise (seed varies with temperature -> varies per sample loop).
    import random
    base = random.Random(seg_index * 7)
    base_s = base.uniform(-0.6, 0.6)
    base_t = base.uniform(-0.2, 0.8)
    noise = random.Random(seg_index * 13 + int(temperature * 1000))
    if seg_index % 3 == 2:
        # divergent segment -> exercise the review queue (large per-sample noise)
        steer = base_s + noise.uniform(-0.9, 0.9)
        throttle = base_t + noise.uniform(-0.9, 0.9)
    else:
        # consistent segment -> should auto-accept (tiny per-sample noise)
        steer = base_s + noise.uniform(-0.04, 0.04)
        throttle = base_t + noise.uniform(-0.04, 0.04)
    return {
        "steer": round(max(-1.0, min(1.0, steer)), 2),
        "throttle": round(max(-1.0, min(1.0, throttle)), 2),
    }


def label_segment(frames_b64, seg_index, mock=False):
    candidates = []
    for i in range(NUM_SAMPLES):
        if mock:
            c = _mock_call(frames_b64, seg_index, TEMPERATURE + i * 0.01)
        else:
            try:
                c = call_model(frames_b64, temperature=TEMPERATURE)
            except Exception as e:
                print(f"  [sample {i}] model error: {e}", file=sys.stderr)
                c = None
        if c:
            candidates.append(c)
    if len(candidates) < MIN_VALID:
        return {
            "ok": False,
            "candidates": candidates,
            "median_steer": None,
            "median_throttle": None,
            "max_std": None,
            "source": "verified",
        }
    steers = [c["steer"] for c in candidates]
    throttles = [c["throttle"] for c in candidates]
    med_steer = statistics.median(steers)
    med_throttle = statistics.median(throttles)
    std_steer = statistics.pstdev(steers)
    std_throttle = statistics.pstdev(throttles)
    max_std = max(std_steer, std_throttle)
    source = "auto" if max_std <= CONSENSUS_STD else "verified"
    return {
        "ok": True,
        "candidates": candidates,
        "median_steer": med_steer,
        "median_throttle": med_throttle,
        "max_std": max_std,
        "source": source,
    }


# ------------------------------- main ---------------------------------------
def collect_inputs(input_path):
    """Resolve input into a list of items to label.
    Item = {'kind':'video', 'path':...} or {'kind':'clip', 'path':..., 'meta':...}
      - a file                -> single video
      - a dir with frames/*   -> single clip (no cv2 needed)
      - a dir of subdirs/videos -> batch (each subdir-with-frames=clip, each video=video)
    """
    if os.path.isfile(input_path):
        return [{"kind": "video", "path": input_path}]
    if not os.path.isdir(input_path):
        return []
    # the directory itself is a clip?
    if clip_frame_paths(input_path):
        return [{"kind": "clip", "path": input_path, "meta": _load_clip_meta(input_path)}]
    items = []
    for name in sorted(os.listdir(input_path)):
        p = os.path.join(input_path, name)
        if os.path.isdir(p) and clip_frame_paths(p):
            items.append({"kind": "clip", "path": p, "meta": _load_clip_meta(p)})
        elif os.path.isfile(p) and name.lower().endswith((".mp4", ".mov", ".mkv", ".webm", ".avi")):
            items.append({"kind": "video", "path": p})
    return items


def main():
    global NUM_SAMPLES, TEMPERATURE, FRAMES_PER_SEGMENT, SEGMENT_SEC
    ap = argparse.ArgumentParser(description="AuroraDrive auto-labeling pipeline")
    ap.add_argument("input",
                    help="a video file, a clip folder (frames/*.jpg + clip.json), "
                         "or a directory of clips/videos")
    ap.add_argument("--out", default="data/labels/labels.csv",
                    help="output labels.csv path")
    ap.add_argument("--review-out", default=None,
                    help="output review_queue.csv path (default: <out>.review.csv)")
    ap.add_argument("--samples", type=int, default=NUM_SAMPLES)
    ap.add_argument("--temp", type=float, default=TEMPERATURE)
    ap.add_argument("--frames", type=int, default=FRAMES_PER_SEGMENT)
    ap.add_argument("--segment-sec", type=float, default=SEGMENT_SEC)
    ap.add_argument("--mock", action="store_true",
                    help="use deterministic mock labels (no model needed)")
    args = ap.parse_args()

    NUM_SAMPLES = args.samples
    TEMPERATURE = args.temp
    FRAMES_PER_SEGMENT = args.frames
    SEGMENT_SEC = args.segment_sec

    if not args.mock:
        try:
            urllib.request.urlopen(f"{API_BASE}/models", timeout=5)
        except Exception as e:
            print(f"[error] cannot reach model server at {API_BASE}: {e}",
                  file=sys.stderr)
            print("        start it with: bash tools/start_label_server.sh",
                  file=sys.stderr)
            sys.exit(1)

    videos = collect_inputs(args.input)
    if not videos:
        print(f"[error] no video/clip found at: {args.input}", file=sys.stderr)
        sys.exit(1)

    review_out = args.review_out or (args.out + ".review.csv")
    label_rows = []
    review_rows = []
    seg_counter = 0

    for item in videos:
        tag = os.path.basename(item["path"])
        if item["kind"] == "video":
            seg_iter = iter_segments(item["path"], segment_sec=SEGMENT_SEC,
                                     frames_per_segment=FRAMES_PER_SEGMENT)
        else:
            seg_iter = iter_clip_segments(item["path"], segment_sec=SEGMENT_SEC,
                                          frames_per_segment=FRAMES_PER_SEGMENT)
        print(f"[info] labeling: {tag}")
        for seg_idx, frames in seg_iter:
            seg_id = f"seg_{seg_counter:04d}"
            res = label_segment(frames, seg_counter, mock=args.mock)
            seg_counter += 1
            if not res["ok"]:
                # too few valid samples -> always flag for review
                label_rows.append((seg_id, tag, "NA", "NA", "verified"))
                review_rows.append((seg_id, tag,
                                    json.dumps(res["candidates"], ensure_ascii=False),
                                    "NA", "NA", "NA"))
                continue
            label_rows.append((
                seg_id, tag,
                f"{res['median_steer']:.2f}",
                f"{res['median_throttle']:.2f}",
                res["source"],
            ))
            if res["source"] == "verified":
                review_rows.append((
                    seg_id, tag,
                    json.dumps(res["candidates"], ensure_ascii=False),
                    f"{res['median_steer']:.2f}",
                    f"{res['median_throttle']:.2f}",
                    f"{res['max_std']:.3f}",
                ))

    _write_csv(args.out, ["segment_id", "video", "steer", "throttle", "source"],
               label_rows)
    _write_csv(review_out,
               ["segment_id", "video", "candidates", "median_steer",
                "median_throttle", "max_std"],
               review_rows)

    n_auto = sum(1 for r in label_rows if r[4] == "auto")
    n_verified = sum(1 for r in label_rows if r[4] == "verified")
    print(f"[done] total segments: {len(label_rows)} | "
          f"auto: {n_auto} | verified(needs review): {n_verified}")
    print(f"       labels    -> {args.out}")
    print(f"       review    -> {review_out}")


def _write_csv(path, header, rows):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(",".join(header) + "\n")
        for r in rows:
            f.write(",".join(str(x) for x in r) + "\n")


if __name__ == "__main__":
    main()
