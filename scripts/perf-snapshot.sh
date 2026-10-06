#!/bin/bash
# ============================================================================
#  scripts/perf-snapshot.sh —— 七维度性能/质量快照采集器
# ============================================================================
#
#  【为什么需要它】
#  本项目有 25 个自检入口，但**没有统一的快照格式**。后果是「优化前后」没法
#  机器比对 —— 只能靠人眼看日志，于是「悄悄降质换速度」在流程上是**不可能被
#  发现**的。本脚本把每次测量固化成 JSON，交给 regression-gate.sh 做判据。
#
#  【用法】
#    bash scripts/perf-snapshot.sh <二进制路径> <输出.json> [标签]
#
#  例：
#    bash scripts/perf-snapshot.sh .build/scratch/release/AuroraDrive \
#         tools/perf/baseline-postA.json "阶段A后"
#
#  【纪律】耗时类数字**必须带负载一起看**（本脚本会记录 loadavg 与核数）。
#          load 超过核数 1.5 倍时，JSON 里会打 "timing_unreliable": true。
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

BIN="${1:-}"
OUT="${2:-}"
LABEL="${3:-未标注}"
PY="/Users/dupi/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3"
[ -x "$PY" ] || PY="python3"

if [ -z "$BIN" ] || [ -z "$OUT" ]; then
    echo "用法: bash scripts/perf-snapshot.sh <二进制> <输出.json> [标签]"
    exit 2
fi
if [ ! -x "$BIN" ]; then
    echo "✗ 二进制不可执行：$BIN"
    exit 2
fi

RAW="$(dirname "$OUT")/raw/$(basename "$OUT" .json)"
mkdir -p "$RAW"
mkdir -p "$(dirname "$OUT")"

# ── 构建/验收锁 ───────────────────────────────────────────────────────────
# 采集本身就是「长任务 + 基准测量」：并发跑会让 loadavg 冲高，使**任何耗时类
# 数字都不可比**（实测：3 个 agent 同时 --mc-map-bench → load 5.15/8 核）。
if [ "${AURORA_SKIP_BUILD_LOCK:-0}" != "1" ]; then
    if ! bash "$ROOT/scripts/build-lock.sh" acquire "perf-snapshot: $LABEL"; then
        echo ""
        echo "  ✗ 拿不到构建锁 —— 拒绝在并发环境下采集（数字不可比）。"
        echo "    查看： bash scripts/build-lock.sh status"
        echo "    强制跳过（不推荐）： AURORA_SKIP_BUILD_LOCK=1 bash $0 ..."
        exit 3
    fi
    trap 'bash "$ROOT/scripts/build-lock.sh" release >/dev/null 2>&1' EXIT
fi

# macOS 没有 timeout 命令 —— 自己实现，避免某个自检挂住整个采集
run_timeout() {  # run_timeout <秒> <name> <args...>
    local secs="$1"; shift
    local name="$1"; shift
    AURORA_UI_LOCAL=1 "$BIN" "$@" > "$RAW/$name.log" 2>&1 &
    local p=$!
    local i=0
    while kill -0 "$p" 2>/dev/null; do
        sleep 1
        i=$((i+1))
        if [ "$i" -ge "$secs" ]; then
            kill "$p" 2>/dev/null; sleep 1; kill -9 "$p" 2>/dev/null
            echo "TIMEOUT(${secs}s)" >> "$RAW/$name.log"
            return 124
        fi
    done
    wait "$p" 2>/dev/null
    return $?
}

# ── 负载快照 ──────────────────────────────────────────────────────────────
LOAD1=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
NCPU=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)
echo "═══ 采集快照 [$LABEL] ═══"
echo "  负载 $LOAD1 / $NCPU 核"
echo "  二进制 $BIN"
echo ""

if [ "${AURORA_REPARSE:-0}" = "1" ]; then
    echo "  [reparse 模式] 跳过二进制执行 —— 直接用 $RAW 下已有日志重新解析"
else
    # 每个自检都落一份原始日志，便于人工复核
    run() {  # run <name> <args...>
        local name="$1"; shift
        printf "  %-22s " "$name"
        run_timeout 180 "$name" "$@"
        local ec=$?
        echo "exit=$ec"
        return 0
    }

    run map-selftest      --map-selftest
    run perf-selftest     --perf-selftest --seconds 8
    run mc-bench          --mc-map-bench --iters 40
    run mc-map            --mc-map
    run yolopx-selftest   --yolopx-selftest
    run speed-selftest    --speed-selftest
    run motion-selftest   --motion-selftest
    run fit-selftest      --fit-selftest
    run route-selftest    --route-selftest
    run taxonomy-selftest --taxonomy-selftest
    run limit-selftest    --limit-selftest
    run opticalflow-selftest --opticalflow-selftest

    # ── 线程数：在 mc-map-bench 运行期间采样峰值 ──────────────────────────────
    echo -n "  threads-probe          "
    : > "$RAW/threads.txt"
    AURORA_UI_LOCAL=1 "$BIN" --mc-map-bench --iters 60 > "$RAW/threads_run.log" 2>&1 &
    BPID=$!
    for _ in $(seq 1 40); do
        sleep 0.25
        T=$(ps -M "$BPID" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
        [ -n "$T" ] && [ "$T" -gt 0 ] && echo "$T" >> "$RAW/threads.txt"
        kill -0 "$BPID" 2>/dev/null || break
    done
    wait "$BPID" 2>/dev/null
    echo "峰值 $(sort -n "$RAW/threads.txt" 2>/dev/null | tail -1) 线程"

    # ── 工程化维度 ────────────────────────────────────────────────────────────
    echo -n "  build-unhandled        "
    swift build -c release --disable-sandbox --scratch-path .build/scratch > "$RAW/build.log" 2>&1
    echo "exit=$? unhandled=$(grep -c unhandled "$RAW/build.log" 2>/dev/null || echo 0)"

    echo -n "  check-package-sources  "
    bash scripts/check-package-sources.sh > "$RAW/check-sources.log" 2>&1
    echo "exit=$?"

fi

echo ""
echo "  解析 → $OUT"

# ── 解析（python3 + Pillow）──────────────────────────────────────────────
SNAP_LABEL="$LABEL" SNAP_OUT="$OUT" SNAP_RAW="$RAW" SNAP_LOAD="$LOAD1" \
SNAP_NCPU="$NCPU" SNAP_PY="$PY" "$PY" - <<'PY'
import json, os, re, hashlib, subprocess, sys

RAW = os.environ['SNAP_RAW']
OUT = os.environ['SNAP_OUT']
LABEL = os.environ['SNAP_LABEL']
LOAD1 = float(os.environ['SNAP_LOAD'])
NCPU = int(os.environ['SNAP_NCPU'])

def log(name):
    p = os.path.join(RAW, name + '.log')
    try:
        return open(p, encoding='utf-8', errors='replace').read()
    except Exception:
        return ''

def first(pat, text, group=1, cast=float):
    m = re.search(pat, text)
    if not m:
        return None
    try:
        return cast(m.group(group))
    except Exception:
        return None

snap = {
    'label': LABEL,
    'timestamp': subprocess.run(['date', '+%Y-%m-%dT%H:%M:%S%z'],
                                capture_output=True, text=True).stdout.strip(),
    'load': {'load1': LOAD1, 'ncpu': NCPU, 'oversub': round(LOAD1 / NCPU, 2),
             'timing_unreliable': LOAD1 > NCPU * 1.5},
    'dimensions': {},
}

# ── 维度 1：帧率/频率（mc-map-bench 稳态 p50/p95）────────────────────────
frames = {}
t = log('mc-bench')
view = None
for line in t.splitlines():
    m = re.search(r'── 视野 (\d+) m', line)
    if m:
        view = m.group(1)
        frames.setdefault(view, {})
        continue
    # ⚠️ 兼容两种格式：stage A 之后是「【稳态】平均 … ｜【冷启】首轮 …」，
    #    HEAD（pre-A）是「平均 … · p50 … · p95 …」无【稳态】/【冷启】标记。
    m = (re.search(r'([①②③])\s*(.+?)\s*【稳态】平均\s*([\d.]+)\s*ms\s*·\s*p50\s*([\d.]+)\s*·\s*p95\s*([\d.]+)\s*·\s*max\s*([\d.]+)\s*｜【冷启】首轮\s*([\d.]+)', line)
         or re.search(r'([①②③])\s*(.+?)\s*平均\s*([\d.]+)\s*ms\s*·\s*p50\s*([\d.]+)\s*·\s*p95\s*([\d.]+)', line))
    if m and len(m.groups()) < 7:
        # 旧格式：没有 max / 冷启，用 p95 占位，冷启置 None
        frames.setdefault(view or '0', {})[m.group(1)] = {
            'name': m.group(2), 'avg': float(m.group(3)), 'p50': float(m.group(4)),
            'p95': float(m.group(5)), 'max': None, 'cold': None, 'legacy_format': True,
        }
        continue
    if m and view:
        frames[view][m.group(1)] = {
            'name': m.group(2), 'avg': float(m.group(3)), 'p50': float(m.group(4)),
            'p95': float(m.group(5)), 'max': float(m.group(6)), 'cold': float(m.group(7)),
        }
snap['dimensions']['frames'] = frames
snap['dimensions']['frames_extra'] = {
    'marker_layer_old_ms': first(r'标记层增量：旧 ([\d.]+) ms', t),
    'marker_layer_new_ms': first(r'标记层增量：旧 [\d.]+ ms\s*→\s*新 ([\d.]+) ms', t),
    'near_marker_old_ms': first(r'近景标记层增量：旧 ([\d.]+) ms', t),
    'near_marker_new_ms': first(r'近景标记层增量：旧 [\d.]+ ms\s*→\s*新 ([\d.]+) ms', t),
}

# ── 维度 2：输出频率（tick 提交 Hz + 各模型出结果 Hz）─────────────────────
t = log('perf-selftest')
rates = {'tick_hz': first(r'tick 提交次数 \d+（([\d.]+) Hz 提交）', t)}
for m in re.finditer(r'^\s{7}(\w+)\s+([\d.]+) Hz\s+推理计数=(\d+)', t, re.M):
    rates[m.group(1) + '_hz'] = float(m.group(2))
    rates[m.group(1) + '_count'] = int(m.group(3))
snap['dimensions']['rates'] = rates

# ── 维度 2b：真实推理成本 infer.* ─────────────────────────────────────────
# 为什么单独列：`submit.*` 只是**提交**（入队）耗时，p50 常在 0.0x ms；
# 真正的推理成本在 `infer.*`（site-main 实测 submit.yolopx 0.019ms vs
# infer.yolopx 12.405ms = 650 倍）。只看 submit 会漏掉全部真实开销。
infer = {}
for m in re.finditer(
        r'^\s{4}(submit|infer)\.(\w+)\s+n=(\d+)\s+p50=([\d.]+)\s+p95=([\d.]+)\s+p99=([\d.]+)\s+max=([\d.]+)\s+mean=([\d.]+)',
        t, re.M):
    infer[f'{m.group(1)}.{m.group(2)}'] = {
        'n': int(m.group(3)), 'p50': float(m.group(4)), 'p95': float(m.group(5)),
        'p99': float(m.group(6)), 'max': float(m.group(7)), 'mean': float(m.group(8)),
    }
# 光流 / tick 循环也在同一张表里
for m in re.finditer(
        r'^\s{4}(opticalflow|tick\.loop)\s+n=(\d+)\s+p50=([\d.]+)\s+p95=([\d.]+)\s+p99=([\d.]+)\s+max=([\d.]+)\s+mean=([\d.]+)',
        t, re.M):
    infer[m.group(1)] = {
        'n': int(m.group(2)), 'p50': float(m.group(3)), 'p95': float(m.group(4)),
        'p99': float(m.group(5)), 'max': float(m.group(6)), 'mean': float(m.group(7)),
    }
snap['dimensions']['infer'] = infer

# ── 维度 4：模型质量（R2/R3 + 各精度自检退出码）──────────────────────────
quality = {
    'R2_det_count': first(r'R2 检测框数量:\s*(\d+) 个', t, cast=int),
    'R3_drivable_pct': first(r'R3 掩码精度:\s*可行驶 ([\d.]+)%', t),
    'R3_lane_pct': first(r'车道线 ([\d.]+)%', t),
}
for name in ['yolopx-selftest', 'speed-selftest', 'motion-selftest', 'fit-selftest',
             'route-selftest', 'taxonomy-selftest', 'limit-selftest', 'opticalflow-selftest']:
    txt = log(name)
    quality[name] = {
        'has_fail_marker': bool(re.search(r'❌|FAIL|失败', txt)),
        'pass_marker': bool(re.search(r'✅|PASS|通过', txt)),
        'lines': len(txt.splitlines()),
    }
snap['dimensions']['model_quality'] = quality

# ── 维度 6：内存（map-selftest 的 T4/T5）─────────────────────────────────
t = log('map-selftest')
mem = {
    'T4_first_frame_load_ms': first(r'T4 · 首帧加载 < 3000ms\s*([\d.]+) ms', t),
    'T4_first_render_ms': first(r'首帧渲染 < 16\.7ms[^\n]*实测 ([\d.]+) ms', t),
    'T4_cache_hit_ms': first(r'缓存命中平均 < 0\.1ms\s*平均 ([\d.]+) ms', t),
    'T4_rerender_ms': first(r'视野变化重渲染平均 < 8ms[^\n]*实测 ([\d.]+) ms', t),
    'T4_cull_ms': first(r'剔除开销 平均 ([\d.]+) ms/次', t),
    'T5_rss_growth_mb': first(r'T5 · RSS 增长 < 50MB\s*增长 \+([\d.]+) MB', t),
    'T5_start_rss_mb': first(r'起始 RSS ([\d.]+) MB', t),
    'T6_map_tile_ms': first(r'MapTileCache\.tile → 1200×1200，([\d.]+) ms', t),
    'load_factor': first(r'时间阈值系数 ×([\d.]+)', t),
    'has_fail_marker': bool(re.search(r'❌', t)),
}
snap['dimensions']['memory'] = mem

# ── 维度 3：画质（--mc-map 出图逐像素）───────────────────────────────────
img_path = '/tmp/aurora_mc_map_online.png'
img = {'path': img_path, 'exists': os.path.exists(img_path)}
if img['exists']:
    data = open(img_path, 'rb').read()
    img['bytes'] = len(data)
    img['md5'] = hashlib.md5(data).hexdigest()
    img['mtime'] = subprocess.run(['stat', '-f', '%Sm', img_path],
                                  capture_output=True, text=True).stdout.strip()
    try:
        sys.path.insert(0, os.environ.get('PYTHONPATH', ''))
        from PIL import Image
        im = Image.open(img_path).convert('RGB')
        img['size'] = list(im.size)
        small = im.resize((64, 64))
        px = list(small.getdata())
        img['pixel_sig_64'] = hashlib.md5(
            bytes([c for p in px for c in p])).hexdigest()
        # 非空校验：纯色/纯黑图会被这里抓住
        uniq = len(set(px))
        img['distinct_colors_64'] = uniq
        img['mean_rgb'] = [round(sum(p[i] for p in px) / len(px), 2) for i in range(3)]
    except Exception as e:
        img['pillow_error'] = str(e)
snap['dimensions']['image_quality'] = img

# ── 维度 5：线程数 ───────────────────────────────────────────────────────
try:
    th = [int(x) for x in open(os.path.join(RAW, 'threads.txt')).read().split() if x.strip()]
except Exception:
    th = []
snap['dimensions']['threads'] = {
    'peak': max(th) if th else None,
    'samples': len(th),
    'median': sorted(th)[len(th) // 2] if th else None,
}

# ── 维度 7：工程化 ───────────────────────────────────────────────────────
b = log('build')
snap['dimensions']['engineering'] = {
    'unhandled_lines': b.count('unhandled'),
    'warning_count': len(re.findall(r'warning:', b)),
    'error_count': len(re.findall(r'error:', b)),
    'build_ok': 'Build complete!' in b or 'error:' not in b,
}
cs = log('check-sources')
snap['dimensions']['engineering']['check_package_sources_ok'] = '全部一致' in cs

json.dump(snap, open(OUT, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(f'  ✓ 已写入 {OUT}')
PY

echo ""
echo "快照完成：$OUT"
