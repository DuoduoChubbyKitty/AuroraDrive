#!/bin/bash
# 25 次运行矩阵：不同 (seed, iters)。每次记录命令 + 真实输出 + 退出码 + 汇总行。
set -u
cd "$(dirname "$0")/../../.." || exit 1
OUT=verify/speed_extrapolator_audit/adv/results
mkdir -p "$OUT"
rm -f "$OUT"/run_*.log "$OUT/summary.txt"

BIN=verify/speed_extrapolator_audit/adv/build/adv_tests
n=0
# 25 组不同参数（seed, iters）
PAIRS=(
  "1 100"   "2 120"   "3 140"   "4 160"   "5 180"
  "6 200"   "7 220"   "8 240"   "9 260"   "10 280"
  "11 300"  "12 320"  "13 340"  "14 360"  "15 380"
  "16 400"  "17 420"  "18 440"  "19 460"  "20 480"
  "21 500"  "22 520"  "23 540"  "24 560"  "25 600"
)
for pair in "${PAIRS[@]}"; do
  set -- $pair
  seed=$1; iters=$2
  n=$((n+1))
  log="$OUT/run_$(printf '%02d' $n)_seed${seed}_it${iters}.log"
  cmd="./$BIN $seed $iters"
  echo "RUN #$n: $cmd" >"$log"
  "$BIN" "$seed" "$iters" >>"$log" 2>&1
  rc=$?
  echo "EXIT=$rc" >>"$log"
  summary=$(grep '^结果：' "$log")
  hard=$(grep 'HARD-FAIL（' "$log")
  fails=$(grep -c '✗' "$log")
  echo "#$n  $cmd  rc=$rc  $summary  $hard  failLines=$fails" | tee -a "$OUT/summary.txt"
done
echo "---- 共 $n 次运行 ----" | tee -a "$OUT/summary.txt"
