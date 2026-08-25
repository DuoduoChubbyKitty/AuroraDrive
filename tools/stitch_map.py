#!/usr/bin/env python3
"""
游戏大地图截图拼接脚本 v2
- 使用OpenCV Stitcher（ORB+RANSAC+多频段融合）
- 选内容最丰富的全景图作为锚点
- 分组合并同缩放级别的全局概览图
- 裁剪UI边缘，mask掉右下角小地图预览
"""
import cv2
import numpy as np
import glob
import os
import json

# ── 配置 ──
SCREENSHOT_DIR = "/Users/dupi/Desktop"
OUTPUT_DIR = "/Users/dupi/Desktop/自动驾驶系统/models"
OUTPUT_MAP = os.path.join(OUTPUT_DIR, "game_map.png")
OUTPUT_META = os.path.join(OUTPUT_DIR, "game_map_meta.json")

# UI裁剪（加大裁剪，彻底去除所有UI元素）
CROP = {
    "left":   140,   # 左侧控制面板+指南针+齿轮+缩放条+区域标签
    "right":  70,    # 右侧X按钮
    "top":    80,    # 顶部标题栏+资源条
    "bottom": 200,   # 底部按钮栏+右下角小地图预览
}
# 额外mask：右下角小地图预览框（约260x200在右下角）
MINIMAP_MASK = {"x_offset": 220, "y_offset": 160, "w": 340, "h": 240}

# 全局概览筛选（放宽阈值，纳入内容更丰富的全景图如01.21.10.png）
GLOBAL_NONBLACK_MAX = 0.26
# 理想锚点non_black范围（内容最丰富但不放大）
ANCHOR_IDEAL_RANGE = (0.13, 0.19)


def load_and_preprocess(path):
    """加载图片，裁剪UI，mask掉小地图预览，返回BGR图"""
    img = cv2.imread(path, cv2.IMREAD_COLOR)
    if img is None:
        return None, None
    h, w = img.shape[:2]
    # 裁剪UI边缘
    cropped = img[CROP["top"]:h-CROP["bottom"], CROP["left"]:w-CROP["right"]]
    ch, cw = cropped.shape[:2]

    # 创建mask（白色=有效区域，黑色=UI区域，拼接时忽略黑色区域）
    mask = np.full((ch, cw), 255, dtype=np.uint8)
    # mask右下角小地图预览
    mm_x = cw - MINIMAP_MASK["x_offset"]
    mm_y = ch - MINIMAP_MASK["y_offset"]
    mm_w = MINIMAP_MASK["w"]
    mm_h = MINIMAP_MASK["h"]
    mask[max(0,mm_y):min(ch,mm_y+mm_h), max(0,mm_x):min(cw,mm_x+mm_w)] = 0
    # mask左侧可能残留的UI（缩放按钮区域）
    mask[:, :10] = 0
    # mask底部可能残留的UI
    mask[-10:, :] = 0

    return cropped, mask


def nonblack_ratio(img):
    """计算非黑像素比例（判断缩放级别）"""
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) if len(img.shape) == 3 else img
    return (gray > 30).mean()


def select_anchor(images_with_info):
    """选最佳锚点图：non_black最接近理想范围的那张（内容最丰富的全景）"""
    best_idx = 0
    best_dist = float('inf')
    for i, (fname, img, mask, nb) in enumerate(images_with_info):
        mid = (ANCHOR_IDEAL_RANGE[0] + ANCHOR_IDEAL_RANGE[1]) / 2
        dist = abs(nb - mid)
        if dist < best_dist:
            best_dist = dist
            best_idx = i
    return best_idx


def try_stitch(images, masks):
    """尝试用OpenCV Stitcher拼接一组图
    返回拼接后的BGR图或None
    """
    # 创建Stitcher（SCANS模式适合2D平面/文档扫描，比PANORAMA更适合地图拼接）
    stitcher = cv2.Stitcher.create(cv2.Stitcher_SCANS)
    # 配置参数
    stitcher.setPanoConfidenceThresh(0.3)  # 降低置信度阈值，允许更多匹配

    # Stitcher需要list of images
    # 注意：mask在OpenCV Python Stitcher中不能直接传
    # 我们把mask区域涂黑来模拟mask效果
    imgs_for_stitch = []
    for img, mask in zip(images, masks):
        masked = img.copy()
        masked[mask == 0] = 0
        imgs_for_stitch.append(masked)

    status, result = stitcher.stitch(imgs_for_stitch)
    if status == cv2.Stitcher_OK:
        return result
    else:
        error_names = {
            cv2.Stitcher_ERR_NEED_MORE_IMGS: "需要更多图片",
            cv2.Stitcher_ERR_HOMOGRAPHY_EST_FAIL: "单应性估计失败",
            cv2.Stitcher_ERR_CAMERA_PARAMS_ADJUST_FAIL: "相机参数调整失败",
        }
        err = error_names.get(status, f"错误码{status}")
        print(f"  Stitcher失败: {err}")
        return None


def manual_stitch(images, masks, anchor_idx=0):
    """手动拼接：以anchor为基础，逐张用ORB+RANSAC匹配并贴到画布上
    比Stitcher更可控，适合有大量黑色区域的地图
    """
    if not images:
        return None

    anchor = images[anchor_idx]
    anchor_mask = masks[anchor_idx]
    ah, aw = anchor.shape[:2]

    # 画布初始化为锚点图（预留扩展空间）
    pad = 800
    canvas = np.zeros((ah + 2*pad, aw + 2*pad, 3), dtype=np.uint8)
    canvas_mask = np.zeros((ah + 2*pad, aw + 2*pad), dtype=np.uint8)
    canvas[pad:pad+ah, pad:pad+aw] = anchor
    canvas_mask[pad:pad+ah, pad:pad+aw] = anchor_mask

    # 每张图在画布上的偏移
    offsets = {anchor_idx: (pad, pad)}

    # ORB检测器
    orb = cv2.ORB_create(nfeatures=5000, scaleFactor=1.2, nlevels=8)

    # 预先计算锚点和所有图的特征
    def compute_features(img, mask):
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        kp, des = orb.detectAndCompute(gray, mask)
        return kp, des

    # 已放置图的特征（在画布坐标系下）
    canvas_kp, canvas_des = compute_features(canvas, canvas_mask)

    # 待处理的图
    remaining = [i for i in range(len(images)) if i != anchor_idx]
    placed = {anchor_idx}

    max_rounds = len(images)
    for round_num in range(max_rounds):
        if not remaining:
            break

        placed_this_round = False
        best_match = None
        best_score = 0
        best_data = None

        for idx in remaining:
            img = images[idx]
            mask = masks[idx]
            kp, des = compute_features(img, mask)
            if des is None or len(kp) < 15:
                continue

            # 与当前画布匹配
            if canvas_des is None or len(canvas_kp) < 15:
                continue

            bf = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=False)
            try:
                matches = bf.knnMatch(des, canvas_des, k=2)
            except cv2.error:
                continue

            # Lowe's ratio test
            good = []
            for m, n in matches:
                if m.distance < 0.75 * n.distance:
                    good.append(m)

            if len(good) < 15:
                continue

            # 提取点对
            src_pts = np.float32([kp[m.queryIdx].pt for m in good]).reshape(-1, 1, 2)
            dst_pts = np.float32([canvas_kp[m.trainIdx].pt for m in good]).reshape(-1, 1, 2)

            # RANSAC单应性（仅用于筛选内点，不直接用H做warp）
            _, inlier_mask = cv2.findHomography(src_pts, dst_pts, cv2.RANSAC, 5.0)
            if inlier_mask is None:
                continue

            inliers = int(inlier_mask.ravel().sum())
            if inliers < 12:
                continue

            # 强制纯平移：从内点计算平移向量中位数，剥离旋转/透视/缩放
            # 这是避免Stitcher式地图倾斜的关键——游戏大地图本质是2D平移扫图
            inlier_flags = inlier_mask.ravel().astype(bool)
            src_inliers = src_pts.reshape(-1, 2)[inlier_flags]
            dst_inliers = dst_pts.reshape(-1, 2)[inlier_flags]
            translations = dst_inliers - src_inliers  # 每个内点的(dx,dy)
            dx, dy = np.median(translations, axis=0)  # 中位数抗噪声

            # 一致性校验：内点平移标准差过大说明存在旋转/缩放，匹配不可靠
            trans_std = translations.std(axis=0)
            if trans_std.max() > 30.0:  # 像素阈值
                continue

            # 构造纯平移矩阵（无旋转、无透视、无缩放）
            H = np.array([[1, 0, dx], [0, 1, dy], [0, 0, 1]], dtype=np.float64)

            score = inliers / len(good)

            if inliers > best_score:
                best_score = inliers
                best_match = idx
                best_data = (H, inliers, score, kp, des)

        if best_match is None:
            print(f"  第{round_num+1}轮：无法匹配剩余 {len(remaining)} 张图")
            for idx in remaining:
                print(f"    未匹配: {os.path.basename(files_info[idx][0])}")
            break

        idx = best_match
        H, inliers, score, kp, des = best_data
        img = images[idx]
        mask = masks[idx]
        ih, iw = img.shape[:2]

        print(f"  放置 {os.path.basename(files_info[idx][0])} 内点={inliers} 比例={score:.2f}")

        # 用单应性变换把图片warp到画布坐标系
        # 计算图片四个角在画布上的位置
        corners = np.float32([[0, 0], [iw, 0], [iw, ih], [0, ih]]).reshape(-1, 1, 2)
        warped_corners = cv2.perspectiveTransform(corners, H)

        # 计算warp后画布需要多大
        [min_x, min_y] = np.int32(warped_corners.min(axis=0).ravel() - 5)
        [max_x, max_y] = np.int32(warped_corners.max(axis=0).ravel() + 5)

        # 如果新图超出当前画布，扩展画布
        need_extend = False
        if min_x < 0 or min_y < 0 or max_x > canvas.shape[1] or max_y > canvas.shape[0]:
            need_extend = True
            new_w = max(canvas.shape[1], max_x + pad) - min(0, min_x) + pad
            new_h = max(canvas.shape[0], max_y + pad) - min(0, min_y) + pad
            offset_x = max(0, -min_x) + pad
            offset_y = max(0, -min_y) + pad
            new_canvas = np.zeros((new_h, new_w, 3), dtype=np.uint8)
            new_mask = np.zeros((new_h, new_w), dtype=np.uint8)
            # 把旧画布内容移过去
            old_h, old_w = canvas.shape[:2]
            new_canvas[offset_y:offset_y+old_h, offset_x:offset_x+old_w] = canvas
            new_mask[offset_y:offset_y+old_h, offset_x:offset_x+old_w] = canvas_mask
            # 更新已放置图的偏移
            for k in offsets:
                ox, oy = offsets[k]
                offsets[k] = (ox + offset_x - pad, oy + offset_y - pad)
            # 更新单应性矩阵（平移变换）
            H_trans = np.array([[1, 0, offset_x - pad], [0, 1, offset_y - pad], [0, 0, 1]], dtype=np.float64)
            H = H_trans @ H
            canvas = new_canvas
            canvas_mask = new_mask

        # Warp图片到画布
        warped = cv2.warpPerspective(img, H, (canvas.shape[1], canvas.shape[0]))
        warped_mask_arr = cv2.warpPerspective(mask, H, (canvas.shape[1], canvas.shape[0]))

        # 融合：新图区域中，canvas_mask为0的地方直接放新图；有重叠的地方取亮值（道路更亮）
        overlap = (canvas_mask > 0) & (warped_mask_arr > 0)
        new_area = (canvas_mask == 0) & (warped_mask_arr > 0)

        canvas[new_area] = warped[new_area]
        # 重叠区域取较亮的值（道路是亮色，取max保留道路线）
        canvas[overlap] = np.maximum(canvas[overlap], warped[overlap])
        canvas_mask[warped_mask_arr > 0] = 255

        offsets[idx] = (0, 0)  # 已warp到画布坐标系
        placed.add(idx)
        remaining.remove(idx)
        placed_this_round = True

        # 重新计算画布特征
        canvas_kp, canvas_des = compute_features(canvas, canvas_mask)

    # 裁剪画布到有效区域
    ys, xs = np.where(canvas_mask > 0)
    if len(ys) > 0:
        margin = 10
        y0, y1 = max(0, ys.min()-margin), min(canvas.shape[0], ys.max()+margin)
        x0, x1 = max(0, xs.min()-margin), min(canvas.shape[1], xs.max()+margin)
        canvas = canvas[y0:y1, x0:x1]

    return canvas


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # 加载所有截图
    files = sorted(glob.glob(os.path.join(SCREENSHOT_DIR, "截屏2026-08-05*.png")))
    print(f"发现 {len(files)} 张截图")

    # 加载并筛选全局概览图
    global files_info
    files_info = []
    for f in files:
        img, mask = load_and_preprocess(f)
        if img is None:
            continue
        nb = nonblack_ratio(img)
        if nb < GLOBAL_NONBLACK_MAX:
            files_info.append((f, img, mask, nb))

    print(f"全局概览图: {len(files_info)} 张")

    # 打印每张全局图的non_black比例
    for i, (f, img, mask, nb) in enumerate(files_info):
        print(f"  [{i}] {os.path.basename(f)}  non_black={nb:.3f}")

    if len(files_info) < 1:
        print("没有找到全局概览图！")
        return

    # 选锚点
    anchor_idx = select_anchor(files_info)
    anchor_file = os.path.basename(files_info[anchor_idx][0])
    print(f"\n锚点图: [{anchor_idx}] {anchor_file} (non_black={files_info[anchor_idx][3]:.3f})")

    # 把锚点放第一个
    if anchor_idx != 0:
        files_info[0], files_info[anchor_idx] = files_info[anchor_idx], files_info[0]

    images = [fi[1] for fi in files_info]
    masks = [fi[2] for fi in files_info]

    # 直接使用纯平移拼接（跳过OpenCV Stitcher——它会估计旋转变换导致地图倾斜）
    # 游戏大地图本质是2D平移扫图，强制纯平移可保证拼接后地图不歪
    print("\n=== 纯平移ORB+RANSAC拼接（强制无旋转）===")
    result = manual_stitch(images, masks, anchor_idx=0)

    if result is None:
        print("\n纯平移拼接失败！退化为单张锚点图")
        result = images[0]

    # 裁剪黑边
    gray = cv2.cvtColor(result, cv2.COLOR_BGR2GRAY)
    coords = cv2.findNonZero((gray > 5).astype(np.uint8))
    if coords is not None:
        x, y, w, h = cv2.boundingRect(coords)
        margin = 5
        x = max(0, x - margin)
        y = max(0, y - margin)
        w = min(result.shape[1] - x, w + 2*margin)
        h = min(result.shape[0] - y, h + 2*margin)
        result = result[y:y+h, x:x+w]

    # 保存
    cv2.imwrite(OUTPUT_MAP, result)
    print(f"\n拼接完成！保存到: {OUTPUT_MAP}")
    print(f"输出尺寸: {result.shape[1]}x{result.shape[0]}")

    # 保存元信息
    meta = {
        "source": "异环游戏大地图截图拼接",
        "region": "米格尔区（含新赫兰德区/绘空町/桥间地/未闻浦/绿墙坡/异象管理局）",
        "total_screenshots": len(files),
        "global_shots_used": len(files_info),
        "anchor": anchor_file,
        "crop_pixels": CROP,
        "output_size": [result.shape[1], result.shape[0]],
        "road_color": "深灰色亮线(#444466~#8888AA)",
        "area_boundary": "白色轮廓线",
        "water": "纯黑色区域",
        "landmark_icons": "多色图标（红/蓝/黄/粉/紫）",
        "minimap_alignment": "朝北固定（与小地图朝向一致）",
        "note": "UI已裁剪，右下角小地图预览已mask。重叠区域取亮值保留道路。",
    }
    with open(OUTPUT_META, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
    print(f"元信息: {OUTPUT_META}")


if __name__ == "__main__":
    main()
