#!/bin/bash
# ============================================================================
#  scripts/paired-ab.sh —— 同负载「配对 A/B」比较器
# ============================================================================
#
#  【为什么不能用「改前跑一次、改后跑一次」】
#  顺序跑的两次在负载波动下**完全不可比**。实测同一条 `--mc-map-bench`：
#  负载 3.0 时 p50 = 20.9 ms，负载 6.9 时 p50 = 240 ms —— 12 倍差距，
#  足以把任何真实收益/劣化淹没。
#
#  【正确做法：配对 A/B】
#  把 A、B 两个实现**逐轮交替**调用，取**配对差值**：
#    · 负载漂移对相邻两轮影响相同 → 差值抵消掉漂移
#    · **偶数轮 A 先跑、奇数轮 B 先跑** → 抵消「谁先跑谁吃亏」
#    · 报**中位数差值**而不是均值 → 抗离群
#
#  【用法】
#    bash scripts/paired-ab.sh <二进制A> <二进制B> <轮数> [--load N] [--metric mc-bench|perf|tick]
#
#  【三个通道各测什么】
#    mc-bench  地图画布光栅化（含平移夹具）—— 测"地图渲染"
#    perf      各子系统单独成本（合成图、自检循环）—— 测"模型/光流本身"
#    tick      **真实 tick() 的整圈占用**（--tick-bench 主动驱动）—— 测"主线程每帧延迟"
#              ⚠️ tick 是唯一能回答"主线程平均延迟"的通道；前两者都不是。
#
#  例（6 线程背景负载下配对 10 轮）：
#    bash scripts/paired-ab.sh \
#         /tmp/aurora-preA/.build/scratch/release/AuroraDrive \
#         .build/scratch/release/AuroraDrive 10 --load 6
#
#  【输出】每指标一行：方向 / A 中位 / B 中位 / 配对差值中位 / 变化 / 结论
#  【退出码】0 = B 不劣于 A；1 = B 显著劣化；2 = 用法错误
#
#  ┌──────────────────────────────────────────────────────────────────────┐
#  │ ⚠️ 加新指标时**必须在本文件下面的 METRIC_DIRECTION 表里登记方向**     │
#  │    默认 'lower'（越低越好，适用于延迟/耗时/内存/线程数）              │
#  │    频率类（tick_hz / *提交 Hz / 出结果 Hz）必须登记 'higher'          │
#  │    判反的后果：把「改善」当「劣化」——用户红线恰恰是"不能降频率"。    │
#  │    自测： bash scripts/paired-ab.sh --selftest                       │
#  └──────────────────────────────────────────────────────────────────────┘
#
#  【本仓 bash 是 3.2 的硬规矩】所有变量引用一律写 `${VAR}`，**不管后面跟什么**。
#    macOS bash 3.2 不做 UTF-8 感知，`$VAR` 紧跟全角标点（，）（。：）时会把
#    标点字节并进变量名 → `set -u` 下直接 `unbound variable` 崩溃。
#    最小复现：bash -c 'set -u; X=1; echo "${X}）"'  → bash: X?: unbound variable
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

if [ "${1:-}" = "--selftest" ]; then
    # 方向表负向对照：证明「改善」不会被判成「劣化」
    echo "═══ paired-ab.sh 自测（方向表）═══"
    RC=0
    run_case() {  # run_case <名称> <A值> <B值> <指标key> <期望退出码>
        local name="$1" va="$2" vb="$3" key="$4" want="$5"
        local T; T=$(mktemp -d)
        for i in 1 2 3 4 5; do
            printf '%s=%s\n' "$key" "$va" > "$T/r${i}_A.txt"
            printf '%s=%s\n' "$key" "$vb" > "$T/r${i}_B.txt"
        done
        PAIRED_RAW="$T" AURORA_SKIP_BUILD_LOCK=1 bash "$0" /bin/echo /bin/echo 5 >/dev/null 2>&1
        local got=$?
        rm -rf "$T"
        if [ "$got" = "$want" ]; then echo "  ✅ ${name}（退出码 ${got}）"
        else echo "  ❌ ${name}：期望退出码 ${want}，实得 $got"; RC=1; fi
    }
    run_case "tick_hz 升高（改善）→ 不得报劣化"   24.0 25.3 tick_hz            0
    run_case "tick_hz 降低（降频红线）→ 必须报劣化" 25.0 20.0 tick_hz            1
    run_case "延迟升高 → 必须报劣化"              10.0 15.0 infer.yolopx.p50   1
    run_case "延迟降低（改善）→ 不得报劣化"        15.0 10.0 infer.yolopx.p50   0
    # ── 未登记方向的**新**频率类指标：靠名字启发兜底 ──────────────────
    # 这几条是真正的护栏：它们证明了"后人加指标忘了登记方向"时，
    # 升频率仍然不会被误报成劣化（用户红线：不能降频率）。
    run_case "未登记的 *hz 升频（改善）→ 不得报劣化"  30.0 33.0 submit.hz        0
    run_case "未登记的 *hz 降频（红线）→ 必须报劣化"  33.0 30.0 submit.hz        1
    run_case "未登记的 *rate 升速（改善）→ 不得报劣化" 1.0 1.2 infer.rate        0
    # 反向对照：歧义名不许被启发误判成"越高越好"。
    # 若 infer.count 被误当 higher，则"下降"会被判劣化 → 退出码 1 ≠ 期望 0。
    run_case "歧义词 infer.count 下降（默认 lower=改善）→ 不得报劣化" 100 80 infer.count 0
    # ── 实际意义阈值（2026-10-05 假红灯修复）的负向对照 ────────────────
    # ③ 噪声级劣化：方向完全一致（5/5 全升）但幅度只有 0.5%。
    #    修前实测就是这么飘红的（零假设对照同二进制 A vs A：
    #    ①仅底图 +0.060ms/+0.5% → 旧逻辑报「❌ 显著劣化」）。
    #    ⚠️ 这条**必须**期望退出码 0：否则门禁又会开始喊狼来了。
    run_case "噪声级劣化 0.5%（方向一致但幅度在阈值内）→ 不得报劣化" 13.20 13.27 infer.yolopx.p50 0
    # ④ 真劣化必须**仍然**报红 —— 证明阈值没变成新的掩盖手段。
    #    真实值参照：本次配对实测 底图 +56.3%、Canvas+聚类 +142.1%。
    run_case "真劣化 +4%（过阈值）→ 必须报劣化"  10.0 10.4 infer.yolopx.p50 1

    # ── 量具可比性闸自测（2026-10-05）───────────────────────────────────
    # 为什么单独测这一段：闸门自己**静默失效**过两次，而且两次都打印了 ✅。
    #   坑1 `grep -q` + pipefail（SIGPIPE 141）→ `&& probe=1` 永不执行
    #   坑2 `grep -c '--tick-bench'` 被当成 grep 长选项 → 报错被 `|| true` 吞掉
    #        → 两端都算 0 → 判定"一致"放行 → 拿不支持 --tick-bench 的老二进制
    #        跑配对，它会以 GUI 模式挂死（实测踩到，跑了 10 分钟没退）
    # 所以这里用**真的假二进制**去撞闸门，断言它必须拒绝。
    echo ""
    echo "  ── 量具可比性闸（防静默失效）──"
    GAUGE_TMP=$(mktemp -d)
    printf '#!/bin/bash\necho hello\n' > "$GAUGE_TMP/old"
    printf '#!/bin/bash\necho AURORA_BENCH_DRAG_PX --tick-bench\n' > "$GAUGE_TMP/new"
    chmod +x "$GAUGE_TMP/old" "$GAUGE_TMP/new"
    gauge_case() {  # gauge_case <名称> <A> <B> <metric> <期望退出码>
        local name="$1" a="$2" b="$3" m="$4" want="$5"
        AURORA_SKIP_BUILD_LOCK=1 bash "$0" "$a" "$b" 2 --load 0 --metric "$m" >/dev/null 2>&1
        local got=$?
        if [ "$got" = "$want" ]; then echo "  ✅ ${name}（退出码 ${got}）"
        else echo "  ❌ ${name}：期望 ${want}，实得 ${got}"; RC=1; fi
    }
    # ① 一端缺 --tick-bench → 必须拒绝（退出 4）。放行就会跑挂死。
    gauge_case "tick 通道：一端缺 --tick-bench → 拒绝" "$GAUGE_TMP/old" "$GAUGE_TMP/new" tick 4
    # ② 一端缺平移夹具指纹 → 必须拒绝（这就是 +60% 假劣化的成因）
    gauge_case "mc-bench 通道：一端缺平移指纹 → 拒绝" "$GAUGE_TMP/old" "$GAUGE_TMP/new" mc-bench 4
    # ③ 两端都不认识 → 视为"同一把旧尺子"，闸门**不得误拒**。
    #    期望 2 而不是 0：假二进制只 echo 不产出指标，闸门放行后会因
    #    「没采到任何指标」退出 2。**只要不是 4 就证明闸门放行了** ——
    #    这条断言的目的是"不误拒"，不是"跑出结果"。
    gauge_case "mc-bench 通道：两端同为旧尺子 → 放行（非 4）" "$GAUGE_TMP/old" "$GAUGE_TMP/old" mc-bench 2
    rm -rf "$GAUGE_TMP"
    echo ""
    [ "$RC" = "0" ] && echo "  ✅ 方向表自测全部通过" || echo "  ❌ 方向表自测失败"
    exit "$RC"
fi

BIN_A="${1:-}"; BIN_B="${2:-}"; ROUNDS="${3:-10}"; shift 3 2>/dev/null || true
LOADN=0
METRIC="mc-bench"
while [ $# -gt 0 ]; do
    case "$1" in
        --load) LOADN="${2:-0}"; shift 2 ;;
        --metric) METRIC="${2:-mc-bench}"; shift 2 ;;
        *) shift ;;
    esac
done
[ -x "$BIN_A" ] && [ -x "$BIN_B" ] || { echo "用法: $0 <二进制A> <二进制B> <轮数> [--load N]"; exit 2; }

# ── 量具可比性闸（2026-10-05 新增，防"换了把尺子"被当成"变慢了"）─────────
#  【为什么必须有】
#  实测事故：HEAD(preA) vs 当前 的配对 A/B 报
#      「①仅底图 +60.0%」「③Canvas+聚类 +170.6%」→ 判「❌ 显著劣化」。
#  真相**不是变慢，是换了把尺子**：
#    · preA 二进制**不认识** `AURORA_BENCH_DRAG_PX` → 用旧夹具（`.offset(0.5px)`，
#      击不穿 4px 量化 → 测的是**缓存命中后的光栅化**，虚低）
#    · 当前二进制认识它 → 新夹具默认 drag=8px → 测**真冷路径**平移
#  同二进制内实测尺子差异：drag=0 → 10.0ms，drag=8 → 14.6ms（单调）。
#  所以那份 +60% 里有相当一部分是**夹具语义变更**，属于不可比。
#
#  【判据】探针常量 `AURORA_BENCH_DRAG_PX` 是「新夹具」的编译期指纹。
#  两端不一致 → 拒绝配对（退出 4），而不是给一个会误导人的数字。
#  ⚠️ 这是**结构性**检查：以后任何人改夹具语义，都必须同时改这个探针，
#    否则闸门会失效。探针字符串本身也要在负向对照里被验证。
if [ "$METRIC" = "mc-bench" ] || [ "$METRIC" = "tick" ]; then
    # ⚠️ 探针实现踩过两个坑，都必须避开：
    #   坑1 `set -o pipefail` + `grep -q`：grep 命中即退出 → strings 收到 SIGPIPE(141)
    #       → pipefail 判管道失败 → `&& probe=1` 永不执行 → 闸门**静默失效**却打印 ✅。
    #   坑2 模式以 `-` 开头时**必须用 `-e`**：`grep -c '--tick-bench'` 会被当成
    #       grep 的长选项 → `unrecognized option`（退出码 2）→ 被 `|| true` 吞掉
    #       → 两端都算 0 → 判定"一致"放行 → 然后拿一个**不支持该夹具的老二进制**
    #       跑配对，它会以 GUI 模式挂死（实测踩到）。
    #   现在的写法：`-e` 传模式 + `strings` 无输出时**硬失败**，绝不假装 0。
    probe_count() {   # probe_count <二进制> <模式> → 1/0；无法判定时直接退出
        local out n
        if [ ! -r "$1" ]; then
            echo "  ✗ 量具闸无法判定：读不到二进制 ${1}" >&2
            exit 4
        fi
        out=$(strings "$1" 2>/dev/null | grep -c -e "$2" || true)
        n="${out:-0}"
        case "$n" in
            ''|*[!0-9]*) echo "  ✗ 量具闸无法判定：探针计数异常（${n:-空}）" >&2; exit 4 ;;
        esac
        [ "$n" -gt 0 ] && echo 1 || echo 0
    }
    # 每个通道各有自己的"尺子指纹"：
    #   · mc-bench → `AURORA_BENCH_DRAG_PX`（平移夹具语义）
    #   · tick     → `--tick-bench`（生产主循环夹具是否存在；老二进制没有它，
    #                跑出来是空指标，若不当场拒绝就会得到"没采到指标"的误导性失败）
    if [ "$METRIC" = "tick" ]; then
        PROBE='--tick-bench'; PROBE_NAME='--tick-bench（生产主循环夹具）'
    else
        PROBE='AURORA_BENCH_DRAG_PX'; PROBE_NAME='AURORA_BENCH_DRAG_PX（平移夹具语义）'
    fi
    probe_a=$(probe_count "$BIN_A" "$PROBE")
    probe_b=$(probe_count "$BIN_B" "$PROBE")
    if [ "$probe_a" != "$probe_b" ]; then
        echo "═══ 配对 A/B 已拒绝：量具不可比 ═══"
        echo "  A = $BIN_A   → ${PROBE_NAME} = ${probe_a}"
        echo "  B = $BIN_B   → ${PROBE_NAME} = ${probe_b}"
        echo ""
        echo "  两端测的**不是同一个东西**，直接比会得出假劣化/假改善。"
        if [ "$METRIC" = "tick" ]; then
            echo "  具体：有一端不认识 --tick-bench，跑不出任何 tick.total 样本。"
            echo "  修法：两端都重建到含 --tick-bench 的提交后再配对。"
        else
            echo "  实测前例：HEAD vs 当前 报 +60%，实为「旧夹具 0.5px 击不穿 4px 量化"
            echo "  （测缓存命中）→ 新夹具 8px（测真冷路径）」的尺子差异。"
            echo "  修法：用同一把尺子 —— 重建 A 侧到含同一夹具的提交，"
            echo "        或两端都设 AURORA_BENCH_DRAG_PX 到同一值后重跑。"
        fi
        echo "  参考：perf-snapshot.sh 也有同样的可比性前提。"
        exit 4
    fi
    [ "$probe_a" = "1" ] && echo "  [量具] 两端指纹一致（${PROBE_NAME} 存在）✓" \
                          || echo "  [量具] 两端指纹一致（均为旧形态：无 ${PROBE_NAME}）✓"
    echo ""
fi

RAW="$ROOT/tools/perf/raw/paired-$(date +%H%M%S)"
mkdir -p "$RAW"
echo "═══ 配对 A/B ═══"
echo "  A = $BIN_A"
echo "  B = $BIN_B"
echo "  轮数 = $ROUNDS   背景负载 = ${LOADN} 线程"
echo ""

# ── 取锁：配对 A/B 本身是长任务，且不能被别的基准干扰 ────────────────────
if [ "${AURORA_SKIP_BUILD_LOCK:-0}" != "1" ]; then
    bash "$ROOT/scripts/build-lock.sh" acquire "paired-ab" >/dev/null || {
        echo "  ✗ 拿不到构建锁，拒绝在并发环境下配对（差值会被第三方干扰）"; exit 3; }
    trap 'bash "$ROOT/scripts/build-lock.sh" release >/dev/null 2>&1' EXIT
fi

# ── 背景负载 ──────────────────────────────────────────────────────────────
LOADPID=""
if [ "$LOADN" -gt 0 ]; then
    bash "$ROOT/tools/perf/load.sh" build >/dev/null 2>&1
    "$ROOT/tools/perf/.burn" "$LOADN" $((ROUNDS * 30 + 60)) >/dev/null 2>&1 &
    LOADPID=$!
    trap 'kill $LOADPID 2>/dev/null; bash "$ROOT/scripts/build-lock.sh" release >/dev/null 2>&1' EXIT
    sleep 3
    echo "  [load] ${LOADN} 线程 UTILITY 负载已起（pid=${LOADPID}）"
    echo "  [load] 当前 loadavg = $(sysctl -n vm.loadavg | awk '{print $2}')"
    echo ""
fi

one_run() {  # one_run <bin> <tag>  → 打印指标 "key=value"
    local bin="$1" tag="$2"
    if [ "$METRIC" = "tick" ]; then
        # 生产主循环整圈（--tick-bench）：**主动驱动真实 tick()**，离屏可重复。
        # 与 perf 通道的区别：perf 测各子系统单独成本（合成图、自检循环），
        # tick 测的是**真实 tick() 的整圈占用** —— 这才是"主线程平均延迟"。
        AURORA_UI_LOCAL=1 "$bin" --tick-bench --seconds 6 > "$RAW/$tag.log" 2>&1
    elif [ "$METRIC" = "perf" ]; then
        AURORA_UI_LOCAL=1 "$bin" --perf-selftest --seconds 6 > "$RAW/$tag.log" 2>&1
    else
        AURORA_UI_LOCAL=1 "$bin" --mc-map-bench --iters 12 > "$RAW/$tag.log" 2>&1
    fi
    # ⚠️ BSD sed 不支持非贪婪 `+?`（GNU 扩展）→ 用 python 提取，可移植
    SNAP_METRIC="$METRIC" python3 - "$RAW/$tag.log" <<'PYX'
import os, re, sys
metric = os.environ.get('SNAP_METRIC', 'mc-bench')
t = open(sys.argv[1], encoding='utf-8', errors='replace').read()
if metric == 'tick':
    # `--tick-bench` 直接输出 `key=value`（机器可读段），照搬即可。
    # 只取**默认档 .ayolom** 的那一段：那是生产默认档。
    for m in re.finditer(r'^(tick\.[a-z0-9.]+|tick_hz)=([0-9.]+)\s*$', t, re.M):
        print(f'{m.group(1)}={m.group(2)}')
elif metric == 'perf':
    for m in re.finditer(r'^\s{4}(infer\.[a-z0-9]+|opticalflow|tick\.loop)\s+n=\d+\s+p50=([0-9.]+)', t, re.M):
        print(f'{m.group(1)}.p50={m.group(2)}')
    m = re.search(r'tick 提交次数 \d+（([0-9.]+) Hz', t)
    if m: print(f'tick_hz={m.group(1)}')
else:
    for m in re.finditer(r'([①③])\s*(.+?)\s*(?:【稳态】)?平均\s*([0-9.]+) ms', t):
        name = re.sub(r'\s+', '', m.group(2))[:10]
        print(f'{m.group(1)}{name}.p50={m.group(3)}')
PYX
}

if [ -n "${PAIRED_RAW:-}" ]; then
    RAW="$PAIRED_RAW"
    echo "  [直接比对已有 raw 目录] $RAW"
else
echo "  逐轮交替采集（偶数轮 A 先、奇数轮 B 先）…"
for i in $(seq 1 "$ROUNDS"); do
    if [ $((i % 2)) -eq 0 ]; then
        one_run "$BIN_A" "r${i}_A" > "$RAW/r${i}_A.txt"
        one_run "$BIN_B" "r${i}_B" > "$RAW/r${i}_B.txt"
    else
        one_run "$BIN_B" "r${i}_B" > "$RAW/r${i}_B.txt"
        one_run "$BIN_A" "r${i}_A" > "$RAW/r${i}_A.txt"
    fi
    printf "\r    轮 %2d/%d   loadavg=%s   " "$i" "$ROUNDS" "$(sysctl -n vm.loadavg | awk '{print $2}')"
done
echo ""
echo ""

[ -n "$LOADPID" ] && kill "$LOADPID" 2>/dev/null
fi

python3 - "$RAW" "$ROUNDS" <<'PY'
import sys, os, statistics, re
raw, rounds = sys.argv[1], int(sys.argv[2])

def load(tag):
    p = os.path.join(raw, tag + '.txt')
    d = {}
    if not os.path.exists(p): return d
    for line in open(p, encoding='utf-8', errors='replace'):
        if '=' in line:
            k, v = line.strip().split('=', 1)
            try: d[k] = float(v)
            except ValueError: pass
    return d

# ── 指标方向表（后来人加指标时**必须在此登记方向**）──────────────────
#   默认 'lower'（越低越好，适用于所有延迟/耗时/内存/线程数）
#   'higher' = 越高越好（频率类）
METRIC_DIRECTION = {
    'tick_hz': 'higher',          # 提交频率：越高越好
    # 下面这些显式写出来是为了**可读性**，值与默认一致
    'opticalflow.p50': 'lower',
    'tick.loop.p50': 'lower',
}

# ── 名字启发：频率/速率/吞吐类指标**越高越好** ────────────────────────
#   为什么需要它：指标键是内联 emit 的，没人能保证后人加键时记得登记方向。
#   漏登记的后果是把「改善」判成「劣化」——而用户红线恰恰是"不能降频率"，
#   一个会乱报劣化的门禁比没有门禁更糟：它会让人去"修"根本没坏的东西。
#   仅在**未显式登记**时兜底；显式登记永远优先。
#   刻意不含 count/hit/alloc 之类歧义词——它们越低不一定好、越高也不一定好，
#   歧义就老实走默认 'lower'，宁可漏判也绝不误判方向。
HIGHER_IS_BETTER_RE = re.compile(
    r'(?:^|[._])(?:hz|fps|rate|throughput|tps|qps)(?:$|[._])'
)

def direction_of(metric):
    """显式登记 > 名字启发 > 默认 lower。"""
    if metric in METRIC_DIRECTION:
        return METRIC_DIRECTION[metric]
    if HIGHER_IS_BETTER_RE.search(metric):
        return 'higher'
    return 'lower'

def is_worse(md, consistent, direction):
    """配对差中位 md 在该方向上是否显著劣化。

    方向语义必须分开，不能一律"越大越坏"：
      延迟类 direction='lower'：md>0 是变慢  → 劣化
      频率类 direction='higher'：md<0 是变少 → 劣化（正是用户红线的"降频率"）
    判反 = 把用户最在意的"掉频率"当成"没掉"。
    """
    if not consistent:
        return False
    return md < 0 if direction == 'higher' else md > 0

A = [load(f'r{i}_A') for i in range(1, rounds + 1)]
B = [load(f'r{i}_B') for i in range(1, rounds + 1)]
keys = sorted({k for d in A + B for k in d})
if not keys:
    print("  ✗ 没采到任何指标（检查二进制是否可跑）"); sys.exit(2)

print(f"  {'指标':<28} {'方向':<9} {'A 中位':>9} {'B 中位':>9} {'配对差中位':>11} {'变化':>8}  结论")
print('  ' + '-' * 78)
diffs_all = []
for k in keys:
    pairs = [(a[k], b[k]) for a, b in zip(A, B) if k in a and k in b]
    if len(pairs) < 3: continue
    ds = [b - a for a, b in pairs]
    ma = statistics.median(a for a, _ in pairs)
    mb = statistics.median(b for _, b in pairs)
    md = statistics.median(ds)
    pct = (md / ma * 100) if ma else 0.0
    # 简单符号检验：配对差里同号占比 ≥ 80% 才认为"方向一致"
    pos = sum(1 for x in ds if x > 0); neg = sum(1 for x in ds if x < 0)
    consistent = max(pos, neg) / len(ds) >= 0.8
    # ── ⚠️ 符号一致性 ≠ 显著劣化（2026-10-05 修掉的假红灯）──────────────
    #  零假设对照（同一个二进制 A vs A，6 线程负载）实测：
    #      ①仅底图 +0.060ms / +0.5%   →  旧逻辑判「❌ 显著劣化」
    #      ③Canvas+聚类 +0.030ms / +0.2% →  同样一路飘红
    #  根因：符号检验只看**方向**是否一致，完全不看**幅度**。
    #    0.5% 的抖动只要方向稳定，就会稳定地飘红。
    #  代价：一个总喊"狼来了"的门禁没人会看 —— 真劣化（+56%）混在
    #    噪声假红灯里，反而不再有信号价值。本队第 ① 条文化就是治这个。
    #  修法：显著劣化需**同时**满足「方向一致」且「幅度过实际意义阈值」。
    #    阈值取 max(相对 3%, 绝对 0.05ms)：
    #      · 相对 3% —— 低于 3% 的渲染波动在真实负载下根本不可归因
    #      · 绝对下限 0.05ms —— 防止极小基线（如 0.02ms）被相对阈值放大成假红
    #    两个都取 max 是**刻意保守**：宁可漏判小幅劣化（会由高负载绝对值复核
    #    兜住），也绝不制造假红灯。
    #  被漏判的小幅劣化不会消失：regression-gate.sh 的**高负载绝对值**那一栏
    #    仍会对照 thresholds，配对栏只负责"归因"。
    meaningful = abs(pct) >= 3.0 and abs(md) >= 0.05
    direction = direction_of(k)
    worse = is_worse(md, consistent and meaningful, direction)
    arrow = '越高越好' if direction == 'higher' else '越低越好'
    if worse:
        verdict = '❌ 劣化'
    elif not consistent:
        verdict = '⚠️ 不显著（方向不一致）'
    elif not meaningful:
        # 方向稳定但幅度在噪声内 —— 明确标出来，别让它伪装成"无劣化"
        verdict = f'➖ 噪声内（{abs(md):.3f}ms/{abs(pct):.1f}% < 阈值 0.05ms/3%）'
    else:
        verdict = '✅ 无劣化'
    print(f"  {k:<28} {arrow:<9} {ma:>9.3f} {mb:>9.3f} {md:>+11.3f} {pct:>+7.1f}%  {verdict}")
    diffs_all.append((k, md, worse))
print('  ' + '-' * 78)
bad = [k for k, _, w in diffs_all if w]
print()
if bad:
    print(f"  ❌ {len(bad)} 项显著劣化（配对差同号 ≥80%）：{', '.join(bad)}")
    sys.exit(1)
print(f"  ✅ 配对 A/B 未发现显著劣化（{len(diffs_all)} 项指标，{rounds} 轮交替）")
sys.exit(0)
PY
