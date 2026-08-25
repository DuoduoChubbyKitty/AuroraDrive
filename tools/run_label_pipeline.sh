#!/usr/bin/env bash
# 一键标注：把 data/raw_clips 下所有录制片段交给本地 llama.cpp 模型打标签。
# 前置：先运行 tools/start_label_server.sh 把模型服务起来（:8080）。
set -e
cd "$(dirname "$0")/.."

if ! curl -s -o /dev/null "http://127.0.0.1:8080/v1/models" 2>/dev/null; then
  echo "ERROR: 模型服务未在 :8080 起来。" >&2
  echo "       先在另一个终端跑: bash tools/start_label_server.sh" >&2
  exit 1
fi

python3 tools/auto_label.py data/raw_clips --out data/labels/labels.csv
echo
echo "完成。需要人工复核的分歧段在: data/labels/labels.csv.review.csv"
