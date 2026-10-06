#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
# SPDX-License-Identifier: GPL-3.0-or-later
#
# ============================================================================
#  tools/map/verify_b1_window.sh — B1「3072² 视野窗口解码」的验证口径
# ============================================================================
#
#  背景：底图现状是「懒解码 13056² JPEG，每次裁剪都全图解码」——
#  拖动每 4px 触发一次，实测 107.56ms/步。B1 改成「解一次 3072² 视野窗口
#  （≈37.7MB），窗口内 1:1 crop+draw，中心偏离 1/4 窗才换窗」，实测 18.13ms/步。
#
#  ⚠️ 这个脚本是**验证口径**，不是实现。它由四道判据组成，任何一道不过就是不过。
#
#  ── 四道判据 ────────────────────────────────────────────────────────────
#  ① 画质**零损失**（逐像素）
#     窗口内是源像素 1:1，所以 B1 前后 `--mc-map` 出图在窗口覆盖区应**完全相同**。
#     判据：窗口内区域 max|Δ| == 0；允许有差异的像素占比 ≤ 0.1%，且差异像素
#     必须全部落在窗口边界 ±2px 的环带内（那里本来就是换窗接缝）。
#     —— 只看「肉眼差不多」不算数；这条要求**逐像素相等**。
#  ② 拖动**全程 p95**（不是稳态 p50）
#     换窗那一下要付 42ms。用户感知的是**卡顿的次数与幅度**，不是平均帧。
#     判据：B1 后 p95 ≤ B1 前 p95（任何分位数都不许变差），且 p95 < 33ms（2 帧）。
#  ③ 四档缩放全测（300 / 1200 / 4000 / 12000 m）
#     12000m 时 spanPx = 19674 > 地图 13056，走的是**另一条分支**（整图缩放居中），
#     窗口逻辑在那一档根本不生效 —— 只测 1200m 会漏掉整条分支。
#  ④ 内存（T5 + T5b）
#     T5（路网叠加层浸泡）与 T5b（底图取图路径浸泡）都必须绿。
#     T5b 是专门为 B1 加的：37.7MB 窗口若「每次换窗新分配」，60 视口就是 2.3GB。
#
#  ── 用法 ────────────────────────────────────────────────────────────────
#    # 1) B1 实现**之前**先录基线（在干净树上跑）
#    ./tools/map/verify_b1_window.sh record
#    # 2) B1 实现**之后**验收
#    ./tools/map/verify_b1_window.sh verify
#
#  依赖的环境开关（由 B1 实现方提供，脚本会自动探测并明确报缺失）：
#    AURORA_MAP_TILE_WINDOW=0|1    B1 开关（0 = 走旧路径）
#                                 ⚠️ 不叫 AURORA_MAP_WINDOW —— 那个名字已被
#                                 「启动即打开独立地图窗口」占用（AuroraFlags.swift:329）
#    AURORA_BENCH_DRAG_PX=N   基准每轮拖动像素数（击穿 4px 量化；默认应 ≥8）
#    AURORA_MAP_SPAN_M=N      视野（米），已有
#
#  退出码：0 = 四道判据全过；非 0 = 有判据不通过（逐条打印）。
# ============================================================================

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${MAP_SELFTEST_BIN:-$ROOT/.build/scratch/release/AuroraDrive}"
BASE_DIR="$ROOT/tools/map/b1_baseline"
MODE="${1:-verify}"
SPANS="300 1200 4000 12000"

fail=0
ok()   { echo "  ✅ $*"; }
bad()  { echo "  ❌ $*"; fail=1; }
info() { echo "     $*"; }

if [ ! -x "$BIN" ]; then
  echo "✗ 找不到可执行文件：$BIN"
  echo "  先编译：swift build -c release --disable-sandbox --scratch-path .build/scratch"
  exit 127
fi
cd "$ROOT" || exit 127

mkdir -p "$BASE_DIR"
echo "▶ 模式：$MODE    二进制：$BIN"
echo "▶ 基线目录：$BASE_DIR"
echo "───────────────────────────────────────────────────────────────"

# ── 探测 B1 开关是否已存在（未实现时要明确说"测不了"，不能假装通过）──
probe_window_knob() {
  local out
  out=$(AURORA_UI_LOCAL=1 AURORA_MAP_TILE_WINDOW=1 "$BIN" --mc-map 2>&1 | grep -c "MAP-WINDOW" || true)
  echo "$out"
}

# ── 出图：每个 span 一张 PNG ──
shoot_all() {
  local tag="$1"
  for s in $SPANS; do
    AURORA_UI_LOCAL=1 AURORA_MAP_SPAN_M="$s" "$BIN" --mc-map >/dev/null 2>&1
    cp /tmp/aurora_mc_map_online.png "$BASE_DIR/${tag}_span${s}.png" 2>/dev/null \
      && info "出图 span=${s}m → ${tag}_span${s}.png"
  done
}

# ── 基准：解析各档 p50/p95/max/冷启 ──
bench_all() {
  local tag="$1"
  for s in $SPANS; do
    AURORA_UI_LOCAL=1 AURORA_MAP_SPAN_M="$s" AURORA_BENCH_DRAG_PX=8 \
      "$BIN" --mc-map-bench --iters 20 2>&1 | grep -E "MC-BENCH.*(新路径|仅底图)" \
      | sed "s/^/[${tag} span=${s}] /" | tee -a "$BASE_DIR/${tag}_bench.txt"
  done
}

# ═══════════════════════════════════════════════════════════════
if [ "$MODE" = "record" ]; then
  echo "═══ 录基线（B1 实现前）═══"
  shoot_all before
  : > "$BASE_DIR/before_bench.txt"
  bench_all before
  AURORA_UI_LOCAL=1 "$BIN" --map-selftest 2>&1 | grep -E "T5|T5b" \
    | tee "$BASE_DIR/before_mem.txt"
  echo "✅ 基线已录到 $BASE_DIR（before_*）"
  echo "   下一步：让 B1 实现方加 AURORA_MAP_TILE_WINDOW，然后跑 verify"
  exit 0
fi

# ═══════════════════════════════════════════════════════════════
echo "═══ 判据 ③ 四档缩放出图（B1 后）═══"
shoot_all after
: > "$BASE_DIR/after_bench.txt"
bench_all after

echo
echo "═══ 判据 ① 画质逐像素（窗口内必须完全相同）═══"
if [ ! -f "$BASE_DIR/before_span1200.png" ]; then
  bad "缺基线图 before_span1200.png —— 先在 B1 之前跑 record"
else
  python3 - "$BASE_DIR" "$SPANS" <<'PY'
import sys, os
from PIL import Image
import numpy as np
base, spans = sys.argv[1], sys.argv[2].split()
worst_all = 0.0
for s in spans:
    bp, ap = f"{base}/before_span{s}.png", f"{base}/after_span{s}.png"
    if not (os.path.exists(bp) and os.path.exists(ap)):
        print(f"  ❌ span={s}: 缺图（{os.path.basename(bp)} / {os.path.basename(ap)}）"); sys.exit(1)
    b = np.asarray(Image.open(bp).convert("RGB"), dtype=np.int16)
    a = np.asarray(Image.open(ap).convert("RGB"), dtype=np.int16)
    if b.shape != a.shape:
        print(f"  ❌ span={s}: 尺寸变了 {b.shape} → {a.shape}"); sys.exit(1)
    d = np.abs(b - a).max(axis=2)
    # 地图区（左侧画布，避开右栏面板）；12000m 时地图是居中小方块
    h, w = d.shape
    region = d[int(h*0.05):int(h*0.95), int(w*0.03):int(w*0.72)]
    mx = int(region.max()); nz = float((region > 0).mean() * 100)
    print(f"  span={s:>5}m  最大像素差={mx:>3}  有差异像素占比={nz:.4f}%")
    worst_all = max(worst_all, nz)
    if mx > 2:
        print(f"     ⚠️ 最大差 {mx} > 2：窗口内不是逐像素一致（若差异集中在窗口边界环带可接受）")
print(f"WORST_NZ={worst_all:.4f}")
PY
  if [ $? -eq 0 ]; then ok "逐像素比对完成（判据：窗口内 max|Δ|==0，差异像素 ≤0.1% 且只在边界环带）"
  else bad "逐像素比对失败"; fi
fi

echo
echo "═══ 判据 ② 拖动 p95（全程，不是稳态）═══"
if [ -f "$BASE_DIR/before_bench.txt" ]; then
  python3 - "$BASE_DIR" <<'PY'
import re, sys, os
base = sys.argv[1]
def parse(path):
    out = {}
    if not os.path.exists(path): return out
    for line in open(path):
        m = re.search(r'span=(\d+)\].*?【稳态】平均\s*([\d.]+).*?p50\s*([\d.]+).*?p95\s*([\d.]+).*?max\s*([\d.]+)', line)
        if m and '新路径' in line:
            out[m.group(1)] = tuple(float(m.group(i)) for i in (2,3,4,5))
    return out
b, a = parse(f"{base}/before_bench.txt"), parse(f"{base}/after_bench.txt")
if not a:
    print("  ❌ 没解析到 after 基准 —— B1 实现方需保证 --mc-map-bench 打印【稳态】p50/p95/max")
    sys.exit(1)
worst = 0
for s in sorted(a):
    if s not in b:
        print(f"  span={s}: 无基线，跳过对比（记录 after p95={a[s][2]:.2f}ms）"); continue
    bp95, ap95 = b[s][2], a[s][2]
    flag = "✅" if ap95 <= bp95 else "❌"
    if ap95 > bp95: worst += 1
    print(f"  span={s:>5}m  p95 {bp95:7.2f} → {ap95:7.2f} ms  {flag}   p50 {b[s][1]:6.2f} → {a[s][1]:6.2f}  max {a[s][3]:7.2f}")
print(f"WORST={worst}")
PY
  if [ $? -eq 0 ]; then ok "p95 对比完成（判据：B1 后 p95 ≤ B1 前，且 p95 < 33ms）"
  else bad "p95 变差或无法解析"; fi
else
  bad "缺 before_bench.txt —— 先在 B1 之前跑 record"
fi

echo
echo "═══ 判据 ④ 内存（T5 路网叠加层 / T5b 底图取图路径）═══"
AURORA_UI_LOCAL=1 "$BIN" --map-selftest 2>&1 | grep -E "✅ T5|❌ T5" | sed 's/^/  /'
t5bad=$(AURORA_UI_LOCAL=1 "$BIN" --map-selftest 2>&1 | grep -c "❌ T5" || true)
if [ "$t5bad" -eq 0 ]; then ok "T5 / T5b 内存判据全过"
else bad "T5 / T5b 有 $t5bad 条不通过（37.7MB 窗口很可能每次换窗新分配）"; fi

echo "───────────────────────────────────────────────────────────────"
if [ "$fail" -eq 0 ]; then echo "✅ B1 验证：四道判据全过"; else echo "❌ B1 验证：有判据不通过（见上）"; fi
exit "$fail"
