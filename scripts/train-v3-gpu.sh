#!/bin/bash
# ============================================================================
#  scripts/train-v3-gpu.sh —— 租用 GPU 机器上的 V3 训练（30 epoch + warmup/余弦退火）
#
#  代码里 src/train_v3.py 已内置 CosineWithWarmup（线性 warmup → 余弦退火），
#  本脚本只是把参数固定成"练满 30 轮"的稳妥组合，并落盘完整日志。
#
#  用法:
#    bash scripts/train-v3-gpu.sh
#    CLIPS=/data/raw_clips CKPT=/data/ckpt_v3_30e BATCH=16 bash scripts/train-v3-gpu.sh
#    bash scripts/train-v3-gpu.sh --limit 2000        # 限时试跑
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PY="${PY:-python3}"
CLIPS="${CLIPS:-/data/raw_clips}"
CKPT="${CKPT:-/data/ckpt_v3_30e}"
EPOCHS="${EPOCHS:-30}"
BATCH="${BATCH:-16}"
DEVICE="${DEVICE:-cuda}"
WARMUP_RATIO="${WARMUP_RATIO:-0.1}"

mkdir -p logs "$CKPT"
LOG="logs/train-v3-gpu-$(date +%Y%m%d-%H%M%S).log"

echo "═══════════════════════════════════════════════"
echo "  V3 训练（GPU / ${EPOCHS} epoch / warmup=${WARMUP_RATIO} + cosine）"
echo "  数据:   $CLIPS"
echo "  产出:   $CKPT"
echo "  日志:   $LOG"
echo "═══════════════════════════════════════════════"

if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader || true
fi
if [ ! -d "$CLIPS" ]; then
    echo "✗ 数据目录不存在: $CLIPS（用 CLIPS=... 指定）" >&2
    exit 1
fi

echo "  命令: $PY src/train_v3.py --clips $CLIPS --epochs $EPOCHS --batch-size $BATCH --device $DEVICE --warmup-ratio $WARMUP_RATIO --ckpt-dir $CKPT $*"

"$PY" src/train_v3.py \
    --clips "$CLIPS" \
    --epochs "$EPOCHS" \
    --batch-size "$BATCH" \
    --device "$DEVICE" \
    --warmup-ratio "$WARMUP_RATIO" \
    --ckpt-dir "$CKPT" \
    "$@" 2>&1 | tee -a "$LOG"

exit "${PIPESTATUS[0]}"
