#!/bin/bash
# 阶段3 导出链路：Paddle 推理模型 → ONNX → CoreML
# 用法: bash export_pipeline.sh <训练输出目录>
set -e
FT=/Users/dupi/Desktop/自动驾驶系统/tools/ppocrv6_finetune
R=/Users/dupi/Desktop/自动驾驶系统/.venv-paddle/lib/python3.11/site-packages/paddlex/repo_manager/repos/PaddleOCR
OUT=${1:-$FT/output/v6tiny_ft}
CFG=${2:-$FT/train_full.yml}

echo "=== 1/3 Paddle .pdparams → 推理模型 ==="
cd "$R"
source /Users/dupi/Desktop/自动驾驶系统/.venv-paddle/bin/activate
python tools/export_model.py -c "$CFG" \
  -o Global.pretrained_model="$OUT/best_accuracy/best_accuracy" \
     Global.save_inference_dir="$OUT/inference" 2>&1 | tail -5
ls -la "$OUT/inference/" 2>/dev/null

echo
echo "=== 2/3 Paddle 推理模型 → ONNX ==="
paddle2onnx --model_dir "$OUT/inference" \
  --model_filename inference.pdmodel \
  --params_filename inference.pdiparams \
  --save_file "$FT/models/ppocrv6_tiny_ft.onnx" \
  --opset_version 17 --enable_onnx_checker True 2>&1 | tail -5

echo
echo "=== 3/3 ONNX → CoreML（在 .venv-yolo26 中执行）==="
deactivate 2>/dev/null || true
source /Users/dupi/Desktop/自动驾驶系统/.venv-yolo26/bin/activate
python "$FT/onnx2coreml.py"
