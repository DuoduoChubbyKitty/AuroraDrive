#!/usr/bin/env bash
# ============================================================================
#  harvest_frames_ffmpeg.sh —— 从视频抽帧（2026-10-02）
#
#  用户要求：
#    · 去掉开头结尾（经常是介绍/片尾），只留中间
#    · 均匀抽帧，总量 1000 张
#    · 落到外置硬盘
#
#  为什么不用 tools/harvest_frames_from_videos.py：
#    那个脚本走 B 站"雪碧图"接口，只有 100 帧/视频且固定 480x270，画质太差。
#    本脚本用 ffmpeg 直接解码原始视频，帧率和尺寸都可控。
#
#  用法：
#    harvest_frames_ffmpeg.sh <输出目录> <每视频帧数> <视频1> [视频2 ...]
#
#  去头尾策略：默认掐掉前 8% 和后 8%（经验值，避开片头片尾）。
#    可用 HEAD_CUT / TAIL_CUT 环境变量覆盖（0.0~0.5）。
# ============================================================================
set -euo pipefail

OUT="$1"; shift
PER="$1"; shift
[ $# -gt 0 ] || { echo "用法: $0 <输出目录> <每视频帧数> <视频...>"; exit 1; }

HEAD_CUT="${HEAD_CUT:-0.08}"
TAIL_CUT="${TAIL_CUT:-0.08}"

mkdir -p "$OUT"
total=0

for f in "$@"; do
  [ -f "$f" ] || { echo "  ✗ 找不到 $f"; continue; }
  tag="$(basename "${f%.*}")"
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f")
  # 有效区间 = 总时长 × (1 - 头 - 尾)
  ss=$(python3 -c "print(f'{$dur*$HEAD_CUT:.3f}')")
  keep=$(python3 -c "print(f'{$dur*(1-$HEAD_CUT-$TAIL_CUT):.3f}')")
  # 抽帧间隔（秒）= 有效时长 / 每视频帧数
  iv=$(python3 -c "print(f'{$keep/$PER:.4f}')")

  d="$OUT/$tag"
  mkdir -p "$d"
  ffmpeg -v error -ss "$ss" -t "$keep" -i "$f" \
    -vf "fps=1/$iv" -q:v 2 "$d/${tag}_%04d.jpg" -y

  n=$(ls -1 "$d"/*.jpg 2>/dev/null | wc -l | tr -d ' ')
  total=$((total+n))
  printf "  %-16s 总%6.1fs  留%6.1fs  间隔%6.3fs  → %3d 张\n" "$tag" "$dur" "$keep" "$iv" "$n"
done

echo "  ────────────────────────────────────────────"
echo "  合计 $total 张 → $OUT"
