#!/usr/bin/env python3
"""判定「哪个框是自车」—— 时序刚性检验（2026-10-02）

为什么写这个脚本
----------------
之前的 measure_ego_area.py 里，我把「每帧面积最大的框」当成自车，
然后拿它当真值去评估屏蔽规则。**这是循环论证**，用户当场指出来了。

自车到底怎么判断？唯一不靠猜的物理依据：
    第三人称视角下，摄像机刚性挂在自车上，
    ⇒ 自车在画面里的**归一化位置**和**归一化尺寸**帧间几乎不变；
    ⇒ 真车（前车/侧车/对向车）会随相对运动不断改变位置和大小。

所以本脚本：
  1. 取**连续帧**（不是抽样！抽样就丢了时序信息）
  2. 每帧跑推理 → NMS
  3. 用 IoU 在相邻帧之间做贪心匹配 → 得到「轨迹」
  4. 统计每条轨迹的：
       覆盖率   = 出现帧数 / 总帧数
       位置抖动 = 归一化中心坐标的标准差
       尺寸抖动 = 归一化宽高的标准差
  5. 覆盖率接近 100% 且抖动接近 0 的那条轨迹 = 自车

输出会直接给出自车轨迹的平均归一化尺寸，从而算出**真实的自车面积占比**，
以及「面积最大的框」到底是不是自车（如果不是，说明我之前的假设是错的）。

用法
----
  measure_ego_identity.py <帧目录> [--start 0] [--n 600] [--compute cpu_ne]
"""
import os, sys, glob, time, argparse
import numpy as np
import cv2
import coremltools as ct

COMPUTE = {
    "all": ct.ComputeUnit.ALL,
    "cpu_ne": ct.ComputeUnit.CPU_AND_NE,
    "cpu_gpu": ct.ComputeUnit.CPU_AND_GPU,
    "cpu_only": ct.ComputeUnit.CPU_ONLY,
}


def letterbox(im, size=640, color=114):
    h, w = im.shape[:2]
    r = min(size / h, size / w)
    nw, nh = int(round(w * r)), int(round(h * r))
    canvas = np.full((size, size, 3), color, dtype=np.uint8)
    dw, dh = (size - nw) // 2, (size - nh) // 2
    canvas[dh:dh + nh, dw:dw + nw] = cv2.resize(im, (nw, nh), interpolation=cv2.INTER_LINEAR)
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
        order = order[np.where(iou <= iou_thr)[0] + 1]
    return keep


def iou_xyxy(a, b):
    xx1 = max(a[0], b[0]); yy1 = max(a[1], b[1])
    xx2 = min(a[2], b[2]); yy2 = min(a[3], b[3])
    iw = max(0.0, xx2 - xx1); ih = max(0.0, yy2 - yy1)
    inter = iw * ih
    ua = (a[2]-a[0])*(a[3]-a[1]) + (b[2]-b[0])*(b[3]-b[1]) - inter
    return inter / ua if ua > 0 else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("imgdir")
    ap.add_argument("--start", type=int, default=0, help="起始帧序号（从 0 开始）")
    ap.add_argument("--n", type=int, default=600, help="连续多少帧")
    ap.add_argument("--model", default="models/ayolom/ayolom_n_fp16.mlpackage")
    ap.add_argument("--conf", type=float, default=0.25)
    ap.add_argument("--iou", type=float, default=0.45)
    ap.add_argument("--match-iou", type=float, default=0.30, help="帧间匹配的 IoU 门槛")
    ap.add_argument("--compute", default="cpu_ne", choices=list(COMPUTE.keys()))
    ap.add_argument("--vis", default="", help="输出可视化拼图路径")
    a = ap.parse_args()

    files = sorted(glob.glob(os.path.join(a.imgdir, "*.jpg")))[a.start:a.start + a.n]
    if len(files) < 10:
        print(f"✗ 帧太少（{len(files)}）"); sys.exit(1)

    print("=" * 78)
    print(f"目录 {os.path.dirname(files[0])}")
    print(f"连续帧 [{a.start}, {a.start+len(files)})  共 {len(files)} 帧")
    print(f"匹配 IoU 门槛 {a.match_iou}   计算单元 {a.compute}")
    print("=" * 78, flush=True)

    m = ct.models.MLModel(a.model, compute_units=COMPUTE[a.compute])
    inp = m.get_spec().description.input[0].name

    # ---------- 逐帧检测 ----------
    per_frame = []     # 每帧: list of dict(xyxy_norm, area, conf)
    lat = []
    for i, fp in enumerate(files):
        im = cv2.imread(fp)
        H, W = im.shape[:2]
        c, r, dw, dh = letterbox(im)
        x = np.transpose(c[:, :, ::-1].astype(np.float32) / 255.0, (2, 0, 1))[None]
        t0 = time.perf_counter()
        out = m.predict({inp: x})
        lat.append((time.perf_counter() - t0) * 1000)
        ks = list(out.keys())
        det = out[ks[0]][0]
        cx, cy, bw, bh, cf = det[0], det[1], det[2], det[3], det[4]
        sel = cf > a.conf
        dets = []
        if sel.any():
            bx = np.stack([cx - bw/2, cy - bh/2, cx + bw/2, cy + bh/2], 1)[sel]
            sc = cf[sel]
            k = nms(bx, sc, a.iou)
            for (x1, y1, x2, y2), s in zip(bx[k], sc[k]):
                # 反 letterbox → 原图 → 归一化
                ax1, ay1 = (x1 - dw) / r / W, (y1 - dh) / r / H
                ax2, ay2 = (x2 - dw) / r / W, (y2 - dh) / r / H
                dets.append(dict(box=(ax1, ay1, ax2, ay2),
                                 area=max(0.0, ax2-ax1) * max(0.0, ay2-ay1),
                                 nx=(ax1+ax2)/2, ny=(ay1+ay2)/2,
                                 nw=ax2-ax1, nh=ay2-ay1, conf=float(s)))
        per_frame.append(dets)
        if (i+1) % 200 == 0:
            print(f"  检测 {i+1}/{len(files)}", flush=True)

    lat = np.array(lat)
    print(f"\n推理延迟 中位 {np.median(lat):.2f} ms   p99 {np.percentile(lat,99):.2f} ms")

    # ---------- 时序跟踪 ----------
    #
    # 为什么不是「纯 IoU 贪心」：第一版那样写，600 帧被切成 441 段轨迹，
    # 最高覆盖只有 30.8% —— 因为镜头一摇、或某帧漏检，IoU 立刻掉到门槛以下，
    # 同一条自车轨迹就被切断了。那样永远测不出「谁覆盖率接近 100%」。
    #
    # 所以这里放宽三处：
    #   ① 匹配不只看 IoU，也看**归一化中心距离 + 尺寸相似度**（对摇摆更鲁棒）
    #   ② 允许轨迹「丢失」最多 max_gap 帧后继续接上（镜头甩动/瞬时漏检）
    #   ③ 事后把「均值位置尺寸接近、且帧区间不重叠」的轨迹合并（NMS 抖动导致的分裂）
    max_gap = 8
    dist_thr = 0.05      # 归一化中心距离
    size_ratio = 0.75    # 宽高各自的最小相似比

    tracks = []          # 每条: dict(frames=[...], dets=[...], last_box, last_norm, last_fi)
    for fi, dets in enumerate(per_frame):
        used_det = set()
        used_trk = set()
        cand = []
        for ti, t in enumerate(tracks):
            if fi - t["last_fi"] > max_gap:
                continue                      # 太久没见，不再匹配（但轨迹保留）
            lb = t["last_box"]; ln = t["last_norm"]
            for di, d in enumerate(dets):
                iou = iou_xyxy(lb, d["box"])
                dx = d["nx"] - ln[0]; dy = d["ny"] - ln[1]
                dist = (dx * dx + dy * dy) ** 0.5
                rw = min(d["nw"], ln[2]) / max(d["nw"], ln[2], 1e-9)
                rh = min(d["nh"], ln[3]) / max(d["nh"], ln[3], 1e-9)
                if iou >= a.match_iou or (dist <= dist_thr and rw >= size_ratio and rh >= size_ratio):
                    cand.append((iou - dist, ti, di))
        cand.sort(reverse=True)
        for score, ti, di in cand:
            if ti in used_trk or di in used_det:
                continue
            used_trk.add(ti); used_det.add(di)
            d = dets[di]
            tracks[ti]["frames"].append(fi)
            tracks[ti]["dets"].append(d)
            tracks[ti]["last_box"] = d["box"]
            tracks[ti]["last_norm"] = (d["nx"], d["ny"], d["nw"], d["nh"])
            tracks[ti]["last_fi"] = fi
        for di, d in enumerate(dets):
            if di in used_det:
                continue
            tracks.append(dict(frames=[fi], dets=[d], last_box=d["box"],
                               last_norm=(d["nx"], d["ny"], d["nw"], d["nh"]), last_fi=fi))

    print(f"\n合并前轨迹数 {len(tracks)}")

    # ---------- 轨迹合并（同一目标被切断/分裂）----------
    def tmean(t):
        return (float(np.mean([d["nx"] for d in t["dets"]])),
                float(np.mean([d["ny"] for d in t["dets"]])),
                float(np.mean([d["nw"] for d in t["dets"]])),
                float(np.mean([d["nh"] for d in t["dets"]])))

    changed = True
    while changed:
        changed = False
        for i in range(len(tracks)):
            if tracks[i] is None:
                continue
            for j in range(i + 1, len(tracks)):
                if tracks[j] is None:
                    continue
                # 帧区间不允许重叠 —— 同一时刻不可能出现在两个位置
                if set(tracks[i]["frames"]) & set(tracks[j]["frames"]):
                    continue
                a1, b1 = tmean(tracks[i]), tmean(tracks[j])
                dist = ((a1[0] - b1[0]) ** 2 + (a1[1] - b1[1]) ** 2) ** 0.5
                rw = min(a1[2], b1[2]) / max(a1[2], b1[2], 1e-9)
                rh = min(a1[3], b1[3]) / max(a1[3], b1[3], 1e-9)
                if dist < 0.03 and rw > 0.85 and rh > 0.85:
                    fr = tracks[i]["frames"] + tracks[j]["frames"]
                    dt = tracks[i]["dets"] + tracks[j]["dets"]
                    order = np.argsort(fr)
                    tracks[i]["frames"] = [fr[k] for k in order]
                    tracks[i]["dets"] = [dt[k] for k in order]
                    tracks[j] = None
                    changed = True
        tracks = [t for t in tracks if t is not None]

    print(f"合并后轨迹数 {len(tracks)}")

    # ---------- 统计 ----------
    N = len(files)
    print("\n" + "=" * 78)
    print(f"【轨迹统计】共 {len(tracks)} 条")
    stats = []
    for ti, t in enumerate(tracks):
        cov = len(t["frames"]) / N
        if len(t["frames"]) < 5:
            continue
        nx = np.array([d["nx"] for d in t["dets"]])
        ny = np.array([d["ny"] for d in t["dets"]])
        nw = np.array([d["nw"] for d in t["dets"]])
        nh = np.array([d["nh"] for d in t["dets"]])
        ar = np.array([d["area"] for d in t["dets"]])
        stats.append(dict(ti=ti, cov=cov, n=len(t["frames"]),
                          frames=t["frames"], dets=t["dets"],
                          nx_m=nx.mean(), ny_m=ny.mean(), nw_m=nw.mean(), nh_m=nh.mean(),
                          nx_s=nx.std(), ny_s=ny.std(), nw_s=nw.std(), nh_s=nh.std(),
                          area_m=ar.mean(), area_s=ar.std(),
                          jsig=(nx.std()/max(nx.mean(),1e-6) + ny.std()/max(ny.mean(),1e-6)
                                + nw.std()/max(nw.mean(),1e-6) + nh.std()/max(nh.mean(),1e-6))))
    stats.sort(key=lambda s: (-s["cov"], s["jsig"]))

    print(f"\n{'轨迹':>5}{'覆盖':>8}{'帧数':>6}{'中心x':>8}{'中心y':>8}"
          f"{'归一宽':>8}{'归一高':>8}{'面积':>9}{'位置抖动':>10}{'尺寸抖动':>10}{'刚性分':>9}")
    for s in stats[:12]:
        print(f"{s['ti']:>5}{s['cov']*100:7.1f}%{s['n']:>6}"
              f"{s['nx_m']:8.3f}{s['ny_m']:8.3f}{s['nw_m']:8.3f}{s['nh_m']:8.3f}"
              f"{s['area_m']*100:8.2f}%"
              f"{(s['nx_s']+s['ny_s'])/2:10.4f}{(s['nw_s']+s['nh_s'])/2:10.4f}"
              f"{s['jsig']:9.3f}")

    # ---------- 结论 ----------
    #
    # ⚠️ 判据说明（2026-10-02 用户指出「镜头会摇摆」后修正）
    #
    # 原本我以为自车跟摄像机刚性连接、帧间位置应该纹丝不动。
    # 用户当场指出：第三人称是弹簧臂，镜头会甩、会飘、会滞后，
    # 所以「抖动≈0」这个判据在会摇摆的镜头上**不成立**。
    #
    # 改用**不受摇摆影响**的信号：**覆盖率**。
    #   真车会开进画面、也会开出画面 ⇒ 覆盖率低
    #   自车永远在画面里                    ⇒ 覆盖率≈100%
    # 这条判据与镜头怎么摇无关。
    #
    # 抖动只作为**次要佐证**：自车的抖动应当明显小于其它轨迹（相对比较，
    # 而不是要求绝对为 0）——因为镜头一摇，背景和真车都跟着大幅位移，
    # 自车相对画面的位移是最小的那个。
    ego = stats[0]
    print("\n" + "=" * 78)
    print("【结论】判据 = 覆盖率（不受镜头摇摆影响）")
    print(f"  轨迹 #{ego['ti']}")
    print(f"  ★ 覆盖率    {ego['cov']*100:.1f}%  （出现 {ego['n']}/{N} 帧）")
    print(f"     ↑ 自车应当接近 100%；真车会进进出出，覆盖率明显低")
    print(f"  归一化中心   ({ego['nx_m']:.4f}, {ego['ny_m']:.4f})")
    print(f"  归一化尺寸   {ego['nw_m']:.4f} × {ego['nh_m']:.4f}")
    print(f"  ★ 面积占比   均值 {ego['area_m']*100:.2f}%   "
          f"标准差 {ego['area_s']*100:.3f}%")
    ego_ar = np.array([d["area"] for d in ego["dets"]])
    print(f"     面积分布   min {ego_ar.min()*100:.2f}%   p5 {np.percentile(ego_ar,5)*100:.2f}%   "
          f"中位 {np.median(ego_ar)*100:.2f}%   "
          f"p95 {np.percentile(ego_ar,95)*100:.2f}%   max {ego_ar.max()*100:.2f}%")
    # 实际像素尺寸（最直观，防止我把归一化算错）
    if per_frame:
        H0, W0 = next((cv2.imread(f).shape[:2] for f in files if cv2.imread(f) is not None), (0, 0))
        if H0:
            print(f"  实际像素    原图 {W0}×{H0}，自车框约 "
                  f"{ego['nw_m']*W0:.0f}×{ego['nh_m']*H0:.0f} px  "
                  f"= {ego['nw_m']*W0*ego['nh_m']*H0:.0f} px²  "
                  f"（占 {ego['area_m']*100:.2f}%）")
    # 摇摆容忍度：自车抖动 vs 其它轨迹抖动的倍数
    if len(stats) > 1:
        oth = np.median([(s['nx_s']+s['ny_s'])/2 for s in stats[1:8]])
        egoj = (ego['nx_s'] + ego['ny_s']) / 2
        print(f"\n  位置抖动对比（镜头摇摆会让所有物体都动，看相对值）")
        print(f"    自车    {egoj:.5f}")
        print(f"    其它中位 {oth:.5f}")
        if egoj > 0:
            print(f"    → 自车抖动只有其它轨迹的 1/{oth/egoj:.1f}"
                  f"（{egoj/oth*100:.1f}%）")
        else:
            print(f"    → 自车抖动为 0（完全静止）")

    # 对照组：其它轨迹
    print("\n  对照（其它轨迹）：")
    for s in stats[1:6]:
        print(f"    #{s['ti']:<4} 覆盖 {s['cov']*100:5.1f}%  面积 {s['area_m']*100:6.2f}%  "
              f"位置抖动 {(s['nx_s']+s['ny_s'])/2:.4f}  尺寸抖动 {(s['nw_s']+s['nh_s'])/2:.4f}")

    print("\n  → 自车的抖动应该比真车小一个数量级以上。看上面两组数字对比。")

    # ---------- 验证「面积最大框 = 自车」这个假设 ----------
    print("\n" + "=" * 78)
    print("【检验我之前的假设：「每帧面积最大的框 = 自车」】")
    hit = 0
    for fi, dets in enumerate(per_frame):
        if not dets:
            continue
        big = max(dets, key=lambda d: d["area"])
        # 最大的框是否落在这条自车轨迹上？
        if fi in ego["frames"]:
            ego_det = ego["dets"][ego["frames"].index(fi)]
            if iou_xyxy(big["box"], ego_det["box"]) > 0.5:
                hit += 1
    tot = sum(1 for d in per_frame if d)
    print(f"  面积最大框 与 自车轨迹重叠(IoU>0.5) 的帧: {hit}/{tot} = {hit/tot*100:.1f}%")
    if hit / tot > 0.95:
        print("  ✅ 假设基本成立 —— 面积最大的框确实就是自车")
    else:
        print("  ❌ 假设不成立 —— 有相当比例的帧，面积最大的框不是自车！")

    # 面积最大框的面积 vs 自车轨迹面积
    big_areas = np.array([max(d["area"] for d in dets) for dets in per_frame if dets])
    ego_areas = np.array([d["area"] for d in ego["dets"]])
    print(f"\n  面积最大框的面积  中位 {np.median(big_areas)*100:.2f}%")
    print(f"  自车轨迹的面积    中位 {np.median(ego_areas)*100:.2f}%")

    # 用自车轨迹的真实面积重算阈值
    print("\n" + "=" * 78)
    print("【用「真·自车面积」重新给阈值建议】")
    ea = ego_areas
    print(f"  自车面积  中位 {np.median(ea)*100:.2f}%   "
          f"p5 {np.percentile(ea,5)*100:.2f}%   p95 {np.percentile(ea,95)*100:.2f}%   "
          f"min {ea.min()*100:.2f}%   max {ea.max()*100:.2f}%")
    # 非自车框的面积分布
    other = []
    for fi, dets in enumerate(per_frame):
        if fi in ego["frames"]:
            ego_det = ego["dets"][ego["frames"].index(fi)]
            for d in dets:
                if iou_xyxy(d["box"], ego_det["box"]) <= 0.5:
                    other.append(d["area"])
        else:
            other += [d["area"] for d in dets]
    oa = np.array(other) if other else np.array([0.0])
    print(f"  非自车框  数量 {len(oa)}   中位 {np.median(oa)*100:.2f}%   "
          f"p95 {np.percentile(oa,95)*100:.2f}%   p99 {np.percentile(oa,99)*100:.2f}%   "
          f"max {oa.max()*100:.2f}%")
    print(f"\n  {'阈值':>8}{'屏蔽自车成功率':>16}{'误伤真车/帧':>14}")
    for thr in [0.01, 0.015, 0.02, 0.025, 0.03, 0.035, 0.04, 0.05, 0.06, 0.08]:
        ok = (ea > thr).mean()
        hurt = (oa > thr).sum() / N
        print(f"  {thr*100:7.1f}%{ok*100:15.1f}%{hurt:14.3f}")

    # ---------- 可视化：连续帧画轨迹 ----------
    if a.vis:
        print(f"\n正在画可视化 → {a.vis}")
        picks = list(range(0, min(N, 240), 10))[:24]
        tiles = []
        for fi in picks:
            fp = files[fi]
            im = cv2.imread(fp); H, W = im.shape[:2]
            for ti, s in enumerate(stats[:3]):
                col = [(0, 0, 255), (0, 255, 0), (255, 128, 0)][ti]
                if fi in s["frames"]:
                    d = s["dets"][s["frames"].index(fi)]
                    x1, y1, x2, y2 = d["box"]
                    cv2.rectangle(im, (int(x1*W), int(y1*H)), (int(x2*W), int(y2*H)), col, 2)
                    if ti == 0:
                        cv2.putText(im, f"#{s['ti']} {d['area']*100:.1f}%",
                                    (int(x1*W), max(14, int(y1*H)-6)),
                                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, col, 1)
            tiles.append(im)
        th = 190; tw = int(tiles[0].shape[1]*th/tiles[0].shape[0])
        sheet = np.zeros((th*4, tw*6, 3), dtype=np.uint8)
        for i, t in enumerate(tiles):
            sheet[(i//6)*th:(i//6+1)*th, (i%6)*tw:(i%6+1)*tw] = cv2.resize(t, (tw, th))
        cv2.imwrite(a.vis, sheet, [cv2.IMWRITE_JPEG_QUALITY, 88])
        print(f"  已存（红=覆盖率最高的轨迹，即自车；绿/橙=次高＝对照）")

    print("=" * 78)


if __name__ == "__main__":
    main()
