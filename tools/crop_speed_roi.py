#!/usr/bin/env python3
"""
crop_speed_roi.py — 从全屏录制帧自动裁剪速度表区域

用法:
  python3 tools/crop_speed_roi.py <帧目录> [--output <输出目录>]

效果:
  读取目录下所有 .jpg/.png 全屏帧,裁出:
  1. 速度表整体区域 (3位数)  → output/speed_000003.jpg
  2. 单个数字槽位 (3个)      → output/slot0_000003.jpg, slot1_..., slot2_...

坐标来源: CaptureEngine.speedROINorm + SpeedOCRReader.slotCentersNorm
"""

import os
import sys
import argparse
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("需要 Pillow: pip3 install Pillow")
    sys.exit(1)

# ── 坐标常量(与 Swift 代码同步) ──

# 速度表整体 ROI (全屏归一化)
SPEED_ROI_X = 0.455
SPEED_ROI_Y = 0.885
SPEED_ROI_W = 0.080
SPEED_ROI_H = 0.050

# 三个数字槽位 (全屏归一化 x 中心)
SLOT_CENTERS_X = [0.479, 0.496, 0.512]
SLOT_WIDTH = 0.014
SLOT_Y_MIN = 0.897
SLOT_Y_MAX = 0.932

# 扩展裁剪边距(像素,给模型多一点上下文)
PADDING = 4


def crop_speed_roi(img_path, output_dir):
    """从全屏帧裁出速度表区域 + 3个数字槽位"""
    img = Image.open(img_path)
    w, h = img.size
    
    stem = Path(img_path).stem
    
    # 1. 裁速度表整体区域(带边距)
    roi_x = int(SPEED_ROI_X * w) - PADDING
    roi_y = int(SPEED_ROI_Y * h) - PADDING
    roi_w = int(SPEED_ROI_W * w) + PADDING * 2
    roi_h = int(SPEED_ROI_H * h) + PADDING * 2
    roi_x = max(0, roi_x)
    roi_y = max(0, roi_y)
    
    speed_crop = img.crop((roi_x, roi_y, roi_x + roi_w, roi_y + roi_h))
    speed_path = output_dir / f"speed_{stem}.jpg"
    speed_crop.save(speed_path, quality=95)
    
    # 2. 裁3个数字槽位
    slot_paths = []
    for i, cx in enumerate(SLOT_CENTERS_X):
        sx = int(cx * w) - int(SLOT_WIDTH * w / 2) - PADDING
        sy = int(SLOT_Y_MIN * h) - PADDING
        sw = int(SLOT_WIDTH * w) + PADDING * 2
        sh = int((SLOT_Y_MAX - SLOT_Y_MIN) * h) + PADDING * 2
        sx = max(0, sx)
        sy = max(0, sy)
        
        slot_crop = img.crop((sx, sy, sx + sw, sy + sh))
        # 放大到 25×45 (与字模同尺寸,方便训练)
        slot_crop = slot_crop.resize((25, 45), Image.LANCZOS)
        slot_path = output_dir / f"slot{i}_{stem}.jpg"
        slot_crop.save(slot_path, quality=95)
        slot_paths.append(slot_path)
    
    return speed_path, slot_paths


def main():
    parser = argparse.ArgumentParser(description="从全屏帧裁剪速度表区域")
    parser.add_argument("input_dir", help="全屏帧目录")
    parser.add_argument("--output", "-o", default="data/speed_crops", help="输出目录")
    args = parser.parse_args()
    
    input_dir = Path(args.input_dir)
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # 找所有帧
    frames = sorted(
        list(input_dir.glob("*.jpg")) + list(input_dir.glob("*.png")),
        key=lambda p: p.name
    )
    
    if not frames:
        print(f"在 {input_dir} 没找到帧文件 (.jpg/.png)")
        sys.exit(1)
    
    print(f"找到 {len(frames)} 帧,开始裁剪...")
    
    for i, frame in enumerate(frames):
        speed_path, slot_paths = crop_speed_roi(frame, output_dir)
        if (i + 1) % 100 == 0:
            print(f"  {i+1}/{len(frames)}")
    
    print(f"\n完成! 输出到 {output_dir}/")
    print(f"  速度表整体: speed_*.jpg ({len(frames)} 张)")
    print(f"  数字槽位0(百位): slot0_*.jpg")
    print(f"  数字槽位1(十位): slot1_*.jpg")
    print(f"  数字槽位2(个位): slot2_*.jpg")
    print(f"\n下一步: 用现有字模系统标注,或手动标注后训练")


if __name__ == "__main__":
    main()
