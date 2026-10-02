#!/usr/bin/env python3
"""自车框面积占比实测（2026-10-02）

背景
----
模型会把「自车」也标成 car（用户结论：天王老子来都改不了）。
用户已否决「按位置裁剪」——因为镜头会到处跑，自车框可以出现在任意位置。
剩下的可行路线是【面积占比阈值】：自车离镜头极近，框的面积远大于真车。

本脚本的目的：用实测数据给出这个阈值到底该定多少。

计算单元（2026-10-02 用户要求）
-------------------------------
用户要求「用 ANE 跑」。CoreML 的 compute_units 四档：
  all       = CPU + GPU + ANE（默认，让 CoreML 自己挑）
  cpu_ne    = CPU + ANE（**排除 GPU**，最接近「纯 ANE」）
  cpu_gpu   = CPU + GPU（排除 ANE，用于对照）
  cpu_only  = 仅 CPU（基线）

注意：CoreML 不保证真的落在 ANE 上——不支持的算子会回落 CPU。
因此本脚本同时输出**每帧延迟**：ANE 命中时约 8~12ms；纯 CPU 会明显更慢。

用法
----
  measure_ego_area.py <图片目录> [--n 200] [--compute cpu_ne] [--dump out.tsv]
"""
import os, sys, glob, time, argparse, random
import numpy as np
import cv2
import coremltools as ct

COMPUTE = {
    "all":      ct.ComputeUnit.ALL,
    "cpu_ne":   ct.ComputeUnit.CPU_AND_NE,
    "cpu_gpu":  ct.ComputeUnit.CPU_AND_GPU,
    "cpu_only": ct.ComputeUnit.CPU_ONLY,
}


def letterbox(im, size=640, color=114):
    h, w = im.shape[:2]
    r = min(size / h, size / w)
    nw, nh = int(round(w * r)), int(round(h * r))
    resized = cv2.resize(im, (nw, nh), interpolation=cv2.INTER_LINEAR)
    canvas = np.full((size, size, 3), color, dtype=np.uint8)
    dw, dh = (size - nw) // 2, (size - nh) // 2
    canvas[dh:dh + nh, dw:dw + nw] = resized
    return canvas, r, dw, dh


def nms(boxes, scores, iou_thr=0.45):
    if len(boxes) == 0:
        return []
    x1, y1, x2, y2 = boxes[:, 0], boxes[:, 1], boxes[:, 2], boxes[:, 3]
    areas = (x2 - x1) * (y2 - y1)
    order = scores.argsort()[::-1]
    keep = []
    while order.size > 0:
        i = order[0]
        keep.append(i)
        xx1 = np.maximum(x1[i], x1[order[1:]])
        yy1 = np.maximum(y1[i], y1[order[1:]])
        xx2 = np.minimum(x2[i], x2[order[1:]])
        yy2 = np.minimum(y2[i], y2[order[1:]])
        w = np.maximum(0.0, xx2 - xx1)
        h = np.maximum(0.0, yy2 - yy1)
        inter = w * h
        iou = inter / (areas[i] + areas[order[1:]] - inter + 1e-9)
        inds = np.where(iou <= iou_thr)[0]
        order = order[inds + 1]
    return keep


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("imgdir")
    ap.add_argument("--n", type=int, default=200, help="抽样帧数（>=总数则全跑）")
    ap.add_argument("--offset", type=int, default=-1,
                    help="从第几帧开始**连续**取（用于把同一批帧拆给 CPU/GPU/ANE 多个进程，"
                         "各跑一段互不重叠）。不传则随机抽样。")
    ap.add_argument("--model", default="models/ayolom/ayolom_n_fp16.mlpackage")
    ap.add_argument("--conf", type=float, default=0.25)
    ap.add_argument("--iou", type=float, default=0.45)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--compute", default="cpu_ne", choices=list(COMPUTE.keys()),
                    help="计算单元，默认 cpu_ne（CPU+ANE，排除 GPU）")
    ap.add_argument("--dump", default="", help="把每帧明细写到这个 tsv")
    ap.add_argument("--warmup", type=int, default=5)
    a = ap.parse_args()

    files = sorted(glob.glob(os.path.join(a.imgdir, "*.jpg")))
    if not files:
        print(f"✗ {a.imgdir} 里没有 jpg"); sys.exit(1)
    if a.offset >= 0:
        # 连续分段：给 CPU / GPU / ANE 各喂一段，互不重叠
        pick = files[a.offset:a.offset + a.n]
        seg = f"[{a.offset} : {a.offset + len(pick)})"
    else:
        random.seed(a.seed)
        pick = files if len(files) <= a.n else random.sample(files, a.n)
        pick.sort()
        seg = "随机抽样"
    if not pick:
        print(f"✗ 该区间没有帧"); sys.exit(1)

    print("=" * 70)
    print(f"目录      {a.imgdir}")
    print(f"总帧      {len(files)}   本次跑 {len(pick)}   区间 {seg}")
    print(f"模型      {a.model}")
    print(f"计算单元  {a.compute}  (= {COMPUTE[a.compute]})")

    t_load0 = time.perf_counter()
    m = ct.models.MLModel(a.model, compute_units=COMPUTE[a.compute])
    t_load = (time.perf_counter() - t_load0) * 1000
    inp = m.get_spec().description.input[0].name
    print(f"加载耗时  {t_load:.0f} ms")
    print("=" * 70, flush=True)

    recs = []
    per_frame_top = []
    frame_box_counts = []
    lat = []
    unreadable = 0
    t_start = time.perf_counter()

    for i, fp in enumerate(pick):
        im = cv2.imread(fp)
        if im is None:
            unreadable += 1
            continue
        H, W = im.shape[:2]
        canvas, r, dw, dh = letterbox(im)
        x = np.transpose(canvas[:, :, ::-1].astype(np.float32) / 255.0, (2, 0, 1))[None]

        t0 = time.perf_counter()
        out = m.predict({inp: x})
        dt = (time.perf_counter() - t0) * 1000
        if i >= a.warmup:
            lat.append(dt)

        keys = list(out.keys())
        det = out[keys[0]][0]
        cx, cy, bw, bh = det[0], det[1], det[2], det[3]
        conf = det[4]
        sel = conf > a.conf
        if not sel.any():
            frame_box_counts.append(0)
            continue
        boxes = np.stack([cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2], 1)[sel]
        scores = conf[sel]
        keep = nms(boxes, scores, a.iou)
        boxes, scores = boxes[keep], scores[keep]
        frame_box_counts.append(len(boxes))

        areas_this = []
        for (x1, y1, x2, y2), s in zip(boxes, scores):
            ax1, ay1 = (x1 - dw) / r, (y1 - dh) / r
            ax2, ay2 = (x2 - dw) / r, (y2 - dh) / r
            w_, h_ = ax2 - ax1, ay2 - ay1
            area = max(0.0, w_) * max(0.0, h_) / (W * H)
            ncx = ((ax1 + ax2) / 2) / W
            ncy = ((ay1 + ay2) / 2) / H
            rec = dict(file=os.path.basename(fp), area=area, ncx=ncx, ncy=ncy,
                       w=w_, h=h_, conf=s, W=W, H=H)
            recs.append(rec)
            areas_this.append((area, rec))
        if areas_this:
            per_frame_top.append(max(areas_this, key=lambda t: t[0])[1])

        if (i + 1) % 500 == 0 or (i + 1) == len(pick):
            el = time.perf_counter() - t_start
            rate = (i + 1) / el
            eta = (len(pick) - i - 1) / rate if rate > 0 else 0
            print(f"  {i+1:6d}/{len(pick)}   {rate:6.1f} 帧/s   "
                  f"已用 {el:6.1f}s   ETA {eta:6.1f}s", flush=True)

    t_total = time.perf_counter() - t_start
    if unreadable:
        print(f"⚠️ {unreadable} 张读不出来")

    all_area = np.array([r["area"] for r in recs])
    top_area = np.array([r["area"] for r in per_frame_top])
    bxc = np.array(frame_box_counts)
    lat = np.array(lat) if lat else np.array([0.0])

    def pct(arr, qs=(50, 90, 95, 99, 100)):
        if len(arr) == 0:
            return "  (空)"
        return "  ".join(f"p{q}={np.percentile(arr,q):.4f}" for q in qs)

    # ---------- 性能 ----------
    print("\n" + "=" * 70)
    print(f"【推理性能 · 计算单元 = {a.compute}】")
    print(f"  总耗时      {t_total:.1f} s   （{len(frame_box_counts)} 帧，含读图/NMS）")
    print(f"  吞吐        {len(frame_box_counts)/t_total:.1f} 帧/s")
    print(f"  纯推理延迟  中位 {np.median(lat):.2f} ms   "
          f"p90 {np.percentile(lat,90):.2f}   p99 {np.percentile(lat,99):.2f}   "
          f"min {lat.min():.2f}   max {lat.max():.2f}")
    print(f"  → 纯推理可达 {1000/np.median(lat):.1f} Hz")

    # ---------- 总览 ----------
    print("\n【总览】")
    print(f"  有效帧        {len(frame_box_counts)}")
    print(f"  每帧框数      均值 {bxc.mean():.2f}  中位 {np.median(bxc):.0f}  最大 {bxc.max()}")
    print(f"  框总数        {len(all_area)}")

    print("\n【全部框 · 面积占画面比例】")
    print(f"  {pct(all_area)}")
    print(f"  均值 {all_area.mean():.4f}   中位 {np.median(all_area):.4f}")

    print("\n【每帧最大框 · 面积占画面比例】（最可能是自车）")
    print(f"  {pct(top_area)}")
    print(f"  均值 {top_area.mean():.4f}   中位 {np.median(top_area):.4f}")

    print("\n【面积占比分档 · 框数量分布】")
    bins = [0, 0.001, 0.005, 0.01, 0.02, 0.05, 0.10, 0.20, 1.01]
    labels = ["<0.1%", "0.1-0.5%", "0.5-1%", "1-2%", "2-5%", "5-10%", "10-20%", ">20%"]
    hist, _ = np.histogram(all_area, bins=bins)
    for lb, c in zip(labels, hist):
        bar = "█" * int(c / max(1, hist.max()) * 40)
        print(f"  {lb:>9}  {c:6d}  {bar}")

    print("\n【每帧最大框 · 分档】")
    hist2, _ = np.histogram(top_area, bins=bins)
    for lb, c in zip(labels, hist2):
        bar = "█" * int(c / max(1, hist2.max()) * 40)
        print(f"  {lb:>9}  {c:6d}  {bar}")

    ego_like = [r for r in recs if abs(r["ncx"] - 0.5) < 0.15 and r["ncy"] > 0.55]
    other = [r for r in recs if not (abs(r["ncx"] - 0.5) < 0.15 and r["ncy"] > 0.55)]
    ea = np.array([r["area"] for r in ego_like])
    oa = np.array([r["area"] for r in other])
    print("\n【粗分：位于画面中下部 / 其它】")
    print(f"  中下部框 {len(ea):5d} 个   面积中位 {np.median(ea) if len(ea) else 0:.4f}   "
          f"p90 {np.percentile(ea,90) if len(ea) else 0:.4f}")
    print(f"  其它框   {len(oa):5d} 个   面积中位 {np.median(oa) if len(oa) else 0:.4f}   "
          f"p90 {np.percentile(oa,90) if len(oa) else 0:.4f}")

    if a.dump:
        with open(a.dump, "w") as f:
            f.write("file\tarea\tncx\tncy\tw\th\tconf\tW\tH\n")
            for r in recs:
                f.write(f"{r['file']}\t{r['area']:.6f}\t{r['ncx']:.4f}\t{r['ncy']:.4f}\t"
                        f"{r['w']:.1f}\t{r['h']:.1f}\t{r['conf']:.4f}\t{r['W']}\t{r['H']}\n")
        print(f"\n明细已写 {a.dump}")

    print("=" * 70)


if __name__ == "__main__":
    main()
