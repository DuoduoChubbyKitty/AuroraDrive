#!/bin/bash
# ============================================================================
#  scripts/train-v3.sh —— V3 拷贝学习一键训练（在你自己的终端直接跑）
# ============================================================================
#
#  【为什么要有这个脚本】
#  直接敲 `python3 src/train_v3.py ...` 有几个坑，每个都让人白跑一次：
#    1. 必须用 /usr/local/bin/python3.11 —— 系统 python3 是 3.14，没装 torch
#    2. 训练峰值占 2-3GB 内存，机器只有 16GB；不监控可能被系统 OOM 杀掉，
#       死在最后几分钟最气人 —— 本脚本开训前预检内存，训练中每 5 分钟报一次水位
#    3. train_v3.py 不支持断点续训，中断 = 从头再来。所以脚本默认只跑够用的 epoch，
#       且把完整日志落盘，中断后能看跑到哪
#    4. 训练是长任务，按项目惯例要持构建锁，否则并发编译/基准会让耗时数字不可比
#    5. data/lean_clips 是指向 /Volumes/系统 的软链接，find 不加 -L 会数出 0 个片段
#
#  【实测速度（本机 MPS，2026-11-07 实测，不是估算）】
#      batch=8  → 7.2 样本/秒   每个 epoch ≈ 1.93 小时（全量 49,973 训练样本）
#      batch=16 → 6.5 样本/秒（更大 batch 反而更慢，不再往上加）
#      数据加载不是瓶颈：num_workers 0→2 实测毫无变化（0.18s/batch，占比 <5%）
#    → 所以默认 8 epoch ≈ 15.4 小时。想更快用 --epochs 3（≈5.8 小时），
#      想更充分用 --epochs 20（≈38 小时）。别用 30（≈58 小时，两天多）。
#
#  【用法】
#      bash scripts/train-v3.sh                  # 默认：全量数据 8 epoch（约 15.4 小时）
#      bash scripts/train-v3.sh --epochs 3       # 更快（约 5.8 小时）
#      bash scripts/train-v3.sh --smoke          # 冒烟：300 样本 2 epoch（约 2 分钟，验证链路）
#      bash scripts/train-v3.sh --batch 4        # 内存紧张时降 batch
#      bash scripts/train-v3.sh --clips <dir>    # 指定数据目录
#      bash scripts/train-v3.sh --ckpt <dir>     # 指定产出目录（默认 checkpoints/v3）
#      bash scripts/train-v3.sh --limit 800      # 只用前 N 个样本（限时跑通，不产可用模型）
#      bash scripts/train-v3.sh --no-lock        # 不持构建锁（仅当你确定没人并发）
#
#  【产出】
#      checkpoints/v3/best_model.pt          ← 最佳模型（按 macro recall 选）
#      checkpoints/v3/train_v3_summary.json  ← 全量指标与每 epoch 历史
#      logs/train-v3-<时间戳>.log            ← 完整日志（中断后靠它看进度）
#
#  【为什么按 macro recall 选模型而不是准确率】
#      W 键（油门）在有效样本里占 85.5%，全猜 W 就有 85% 准确率但对刹车零召回。
#      macro recall 是各类召回的算术平均，油门的高分掩盖不了刹车的失败。
#
#  【中断了怎么办】
#      Ctrl-C 即可，构建锁会自动释放。日志里能看到跑到第几个 epoch。
#      但 train_v3.py 不支持续训，重跑会从头开始 —— 所以先用 --epochs 3 试水。
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PY=/usr/local/bin/python3.11
CLIPS="data/lean_clips"
EPOCHS=8          # 实测 1.93 小时/epoch，8 epoch ≈ 15.4 小时
BATCH=8           # 实测最快的 batch
CKPT="checkpoints/v3"
LIMIT=""
USE_LOCK=1

# 实测吞吐，用于开训前给出 ETA（不要让用户启动后才发现要跑一天）
MEASURED_SAMPLES_PER_SEC=7.2

# ── 参数解析 ────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --smoke)
            LIMIT=300; EPOCHS=2; BATCH=2
            echo "[冒烟模式] 只用 300 样本、2 epoch、batch=2（只验证链路，不产可用模型）"
            shift ;;
        --epochs) EPOCHS="$2"; shift 2 ;;
        --batch)  BATCH="$2";  shift 2 ;;
        --clips)  CLIPS="$2";  shift 2 ;;
        --ckpt)   CKPT="$2";   shift 2 ;;
        --limit)  LIMIT="$2";  shift 2 ;;
        --no-lock) USE_LOCK=0; shift ;;
        -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
        *) echo "未知参数: $1（用 --help 看用法）" >&2; exit 2 ;;
    esac
done

# ── 前置检查：任何一项失败都不该开训（开训后才发现 = 白等）──────────────────
echo "═══════════════════════════════════════════════"
echo "  V3 拷贝学习训练"
echo "═══════════════════════════════════════════════"

if [ ! -x "$PY" ]; then
    echo "✗ 找不到 ${PY}" >&2
    echo "  训练必须用 python3.11（系统 python3 是 3.14，没装 torch）" >&2
    exit 1
fi

if ! "$PY" -c 'import torch' 2>/dev/null; then
    echo "✗ ${PY} 里没有 torch" >&2
    exit 1
fi
TORCH_VER=$("$PY" -c 'import torch; print(torch.__version__)')
MPS_OK=$("$PY" -c 'import torch; print("yes" if torch.backends.mps.is_available() else "no")')
echo "  python: $PY ($("$PY" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])'))"
echo "  torch:  ${TORCH_VER}   MPS: ${MPS_OK}"

if [ ! -d "$CLIPS" ]; then
    echo "✗ 数据目录不存在: ${CLIPS}" >&2
    exit 1
fi
# find 默认不跟随软链接，不加 -L 会数出 0 个片段并误判「没有数据」
CLIP_N=$(find -L "$CLIPS" -maxdepth 1 -type d -name 'clip_*' 2>/dev/null | wc -l | tr -d ' ')
if [ "${CLIP_N}" -lt 1 ]; then
    echo "✗ ${CLIPS} 下没有 clip_* 片段" >&2
    exit 1
fi
echo "  数据:   ${CLIPS}（${CLIP_N} 个片段）"

# 真实训练样本数（用于 ETA）。dataset 构建会读全部 CSV，约 1-2 秒；失败就退回估值
# 注意：V3KeyDataset / make_train_val_split 会往 stdout 打印中文日志（[V3KeyDataset] …），
# 直接 print 会让 bash 拿到多行非数字文本、数值判定失败（实测退回 50000 估算）。
# 所以把这些日志重定向到 stderr，只让最后的数字留在 stdout。
TRAIN_N=$("$PY" - "$CLIPS" <<'PYEOF' 2>/dev/null
import contextlib, sys
sys.path.insert(0, "src"); sys.path.insert(0, ".")
from dataset_v3 import V3KeyDataset, make_train_val_split
with contextlib.redirect_stdout(sys.stderr):
    ds = V3KeyDataset(sys.argv[1])
    tr, _va = make_train_val_split(ds)
print(len(tr))
PYEOF
)
if ! [ "${TRAIN_N:-0}" -gt 0 ] 2>/dev/null; then
    TRAIN_N=50000
    echo "  （样本数探测失败，ETA 按 50000 估算）"
fi
echo "  训练样本: ${TRAIN_N}"

if [ -n "$LIMIT" ]; then
    EFF_N=$(awk -v n="${TRAIN_N}" -v l="${LIMIT}" 'BEGIN{printf "%d", l*0.9}')
else
    EFF_N="${TRAIN_N}"
fi

# ── ETA：开训前就让用户知道要占用多久，而不是启动后才发现 ────────────────────
ETA_H=$(awk -v n="${EFF_N}" -v e="${EPOCHS}" -v r="${MEASURED_SAMPLES_PER_SEC}" \
    'BEGIN{printf "%.1f", n*e/r/3600}')
echo ""
echo "  计划:   ${EPOCHS} epoch × ${EFF_N} 样本  ≈ ${ETA_H} 小时（按实测 ${MEASURED_SAMPLES_PER_SEC} 样本/秒）"
if awk -v h="${ETA_H}" 'BEGIN{exit !(h > 12)}'; then
    echo "          ⚠ 这个时长远超半天。想缩短就 Ctrl-C 后加 --epochs 3（约 5.8 小时）" >&2
fi

# 内存预检：训练峰值约 2-3GB
FREE_MB=$(vm_stat | awk '/Pages free/{f=$3} /Pages inactive/{i=$3}
    END{gsub(/\./,"",f); gsub(/\./,"",i); printf "%d", (f+i)*4096/1024/1024}')
SWAP_USED=$(sysctl -n vm.swapusage | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p')
echo "  内存:   可用约 ${FREE_MB} MB，swap 已用 ${SWAP_USED} MB"
if [ "${FREE_MB:-0}" -lt 1500 ]; then
    echo ""
    echo "⚠ 可用内存不足 1.5GB，训练很可能被系统杀掉。" >&2
    echo "  建议先关掉游戏/浏览器，或改用 --batch 4。继续吗？(y/N)" >&2
    read -r ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || exit 1
fi

mkdir -p logs "$CKPT"
LOG="logs/train-v3-$(date +%Y%m%d_%H%M%S).log"
echo "  日志:    ${LOG}"
echo ""

# ── 构建锁（长任务按项目惯例串行化；--no-lock 可跳过）────────────────────────
if [ "$USE_LOCK" = "1" ]; then
    if ! bash scripts/build-lock.sh acquire "train-v3" 2>/dev/null; then
        echo "✗ 构建锁被占用（有人在编译/跑基准）。" >&2
        echo "  等它结束，或加 --no-lock（仅当你确定没人并发）" >&2
        exit 3
    fi
    trap 'bash scripts/build-lock.sh release 2>/dev/null || true' EXIT INT TERM
    echo "  🔒 已获取构建锁"
fi

# ── 组命令 ──────────────────────────────────────────────────────────────────
RUN_ARGS=(--clips "$CLIPS" --epochs "$EPOCHS" --batch-size "$BATCH" --device auto
          --ckpt-dir "$CKPT")
[ -n "$LIMIT" ] && RUN_ARGS+=(--limit "$LIMIT")

echo "  命令: $PY src/train_v3.py ${RUN_ARGS[*]}"
echo "───────────────────────────────────────────────"
echo ""

# ── 跑训练 + 心跳 ────────────────────────────────────────────────────────────
# 为什么要心跳：train_v3.py 只在每个 epoch 结束时打印一行，而一个 epoch 要 1.9 小时。
# 终端近两小时没有任何输出，用户无法区分「在算」和「已经死了」。
# 心跳每 5 分钟写一行当前耗时与内存，既证明进程活着，也提前暴露内存上涨。
START_TS=$(date +%s)

"$PY" src/train_v3.py "${RUN_ARGS[@]}" > >(tee -a "$LOG") 2>&1 &
PY_PID=$!

(
    while kill -0 "$PY_PID" 2>/dev/null; do
        sleep 300
        kill -0 "$PY_PID" 2>/dev/null || break
        NOW_TS=$(date +%s)
        ELAPSED_M=$(( (NOW_TS - START_TS) / 60 ))
        MEM_MB=$(vm_stat | awk '/Pages free/{f=$3} /Pages inactive/{i=$3}
            END{gsub(/\./,"",f); gsub(/\./,"",i); printf "%d", (f+i)*4096/1024/1024}')
        LINE="  ⏱ 已运行 ${ELAPSED_M} 分钟（约 $((ELAPSED_M/60)) 小时 $((ELAPSED_M%60)) 分 已完成）· 可用内存 ${MEM_MB} MB"
        echo "$LINE" | tee -a "$LOG"
    done
) &
HB_PID=$!

wait "$PY_PID"
RC=$?
kill "$HB_PID" 2>/dev/null || true
wait "$HB_PID" 2>/dev/null || true

TOTAL_S=$(( $(date +%s) - START_TS ))
echo ""
echo "═══════════════════════════════════════════════"
echo "  总耗时: $((TOTAL_S/3600)) 小时 $((TOTAL_S%3600/60)) 分钟"

if [ "$RC" -eq 0 ]; then
    echo "  ✓ 训练结束（退出码 0）"
    if [ -f "$CKPT/train_v3_summary.json" ]; then
        echo ""
        echo "  最佳结果:"
        SUMMARY_PATH="$CKPT/train_v3_summary.json" "$PY" - <<'PYEOF'
import json, os, pathlib
d = json.loads(pathlib.Path(os.environ["SUMMARY_PATH"]).read_text())
print(f"    best_epoch     = {d.get('best_epoch')}")
sel = d.get("best_select")
print(f"    macro_recall   = {sel:.4f}" if isinstance(sel, (int, float)) else "    macro_recall   = n/a")
print(f"    checkpoint     = {d.get('ckpt')}")

# 指标平铺在 history 条目顶层，不在 val_metrics 里。
# 看分动作召回而不是准确率：油门占比高，准确率会掩盖刹车的失败。
hist = d.get("history") or []
last = hist[-1] if hist else {}
labels = [
    ("recall_v_W",    "油门 W"),
    ("recall_v_S",    "刹车 S"),
    ("recall_v_NONE", "纵向空"),
    ("recall_h_A",    "左转 A"),
    ("recall_h_D",    "右转 D"),
    ("recall_h_NONE", "横向空"),
]
shown = [(k, n, last[k]) for k, n in labels if k in last]
if shown:
    print("    最后 epoch 分项召回:")
    for _k, name, v in shown:
        # -1 是「该类在验证集中无样本」的哨兵值，不是 0 分
        text = "   n/a（该类无验证样本）" if v < -0.5 else f"{v:+.3f}"
        print(f"      {name:8s} {text}")
PYEOF
    fi
else
    echo "  ✗ 训练失败（退出码 ${RC}），完整日志：${LOG}" >&2
    echo "    常见原因：内存不足被系统杀掉（查 Console.app 或 log show）、MPS 后端报错" >&2
fi
echo ""
echo "  完整日志: ${LOG}"
echo "═══════════════════════════════════════════════"
exit "$RC"
