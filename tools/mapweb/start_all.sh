#!/bin/bash
# ============================================================================
#  start_all.sh — 一键启动三个 MaaNTE 地图站（原版完整还原）
# ============================================================================
#
#  三个站各自独立服务自己的目录，端口固定：
#    主图 map.maante.org   → http://127.0.0.1:15530/
#    999夜 999.maante.org  → http://127.0.0.1:15531/
#    粉爪  pph.maante.org  → http://127.0.0.1:15532/
#
#  用法:
#    ./start_all.sh          启动（已在跑的会跳过）
#    ./start_all.sh stop     停掉三个
#    ./start_all.sh status   只查状态
#
#  ⚠️ 本机 bash 是 3.2，**不支持关联数组**（declare -A），所以这里用
#     平铺变量 + 位置参数，别改成关联数组（Lead 已踩过这个坑）。
# ============================================================================

ROOT="$(cd "$(dirname "$0")" && pwd)"

# 站名 / 目录 / 端口 —— 三条一一对应，改的时候一起改
NAMES=("主图(MaaNTE-Map)" "999夜(MaaNTE-999)" "粉爪(MaaNTE-PPH)")
DIRS=("MaaNTE-Map" "MaaNTE-999" "MaaNTE-PPH")
PORTS=(15530 15531 15532)
COUNT=3

# 本地瓦片目录（主图 DEV 下由 vite 插件挂在 /mapsource-tiles/）
export MAANTE_MAPSOURCE_TILES_DIR="$ROOT/MapSource/tiles"

start_one() {
    local idx=$1
    local name="${NAMES[$idx]}"
    local dir="$ROOT/${DIRS[$idx]}"
    local port="${PORTS[$idx]}"

    if [ ! -d "$dir" ]; then
        echo "  ✗ $name —— 目录不存在: $dir"
        return 1
    fi
    if [ ! -d "$dir/node_modules" ]; then
        echo "  … $name —— 依赖未装，正在 npm install"
        (cd "$dir" && npm install --no-audit --no-fund >/dev/null 2>&1)
    fi

    # 已在跑就跳过（不重复起，避免端口冲突）
    if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$port/" 2>/dev/null; then
        echo "  = $name —— 已在运行 :$port"
        return 0
    fi

    (cd "$dir" && nohup npx vite --port "$port" --host 127.0.0.1 \
        > "/tmp/mapweb_${port}.log" 2>&1 &)
    return 0
}

wait_ready() {
    local idx=$1
    local name="${NAMES[$idx]}"
    local port="${PORTS[$idx]}"
    for _ in $(seq 1 30); do
        if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$port/" 2>/dev/null; then
            echo "  ✓ $name → http://127.0.0.1:$port/"
            return 0
        fi
        sleep 1
    done
    echo "  ✗ $name —— :$port 30 秒内没起来，看 /tmp/mapweb_${port}.log"
    return 1
}

case "${1:-start}" in
    stop)
        echo "停掉三个地图站…"
        for i in $(seq 0 $((COUNT - 1))); do
            pkill -f "vite --port ${PORTS[$i]}" 2>/dev/null && \
                echo "  ✓ 已停 ${NAMES[$i]}" || echo "  – ${NAMES[$i]} 本来就没跑"
        done
        ;;
    status)
        echo "三个地图站状态："
        for i in $(seq 0 $((COUNT - 1))); do
            code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
                   "http://127.0.0.1:${PORTS[$i]}/" 2>/dev/null)
            echo "  ${NAMES[$i]}  :${PORTS[$i]}  HTTP ${code:-无响应}"
        done
        ;;
    *)
        echo "═══════════════════════════════════════════"
        echo "  启动三个地图站（原版完整还原）"
        echo "═══════════════════════════════════════════"
        for i in $(seq 0 $((COUNT - 1))); do start_one "$i"; done
        echo ""
        echo "等待就绪…"
        FAIL=0
        for i in $(seq 0 $((COUNT - 1))); do wait_ready "$i" || FAIL=1; done
        echo ""
        if [ "$FAIL" -eq 0 ]; then
            echo "全部就绪。浏览器打开上面三个地址即可。"
        else
            echo "有站点没起来，见上。"
        fi
        exit "$FAIL"
        ;;
esac
