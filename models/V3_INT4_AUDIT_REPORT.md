# V3 INT4 部署审计报告

> 由 `tools/v3_exp/gen_v3_audit_report.py` 于 2026-11-15 23:00:35 自动生成。
> **总判定：PASSED**（任一门禁失败即 FAILED，且脚本退出码非 0）

## 一、门禁结果

| 门禁 | 结果 | 说明 |
|---|---|---|
| 部署模型目录存在 | ✅ | /Users/dupi/Desktop/自动驾驶系统/models/v3_int4.mlmodelc |
| 部署模型必需文件齐全 | ✅ | OK |
| 契约：输入 6 路齐全 | ✅ | ['det_mask', 'dets', 'image_hi', 'image_lo', 'lane', 'vehicle_state'] |
| 契约：输出 8 路有序一致 | ✅ | ['vertical', 'horizontal', 'handbrake', 'brake', 'super_brake', 'ultimate', 'confidence', 'risk'] |
| LUT 算子数 > 0 | ✅ | 84 |
| 实测内容指纹 == 部署记录 | ✅ | 实测 5720e47407b57fbe… vs 记录 5720e47407b57fbe… |
| 评估通过 (eval_status=passed) | ✅ | eval_status=passed |
| 部署完成 (deploy_status=deployed) | ✅ | deploy_status=deployed |
| v3-selftest 全通过且退出 0 | ✅ | 69/69 rc=0 失败项=0 |
| contract_test 通过/退出0/有断言 | ✅ | pass=31 fail=0 rc=0 |

## 二、交付绑定（来源可追溯）

| 项 | 值 |
|---|---|
| git HEAD | `4ca61dba14eeca7ea4e3d3a1933043a40ca1617c` |
| git 工作树 dirty | True（status sha256 `77dc1190dd65…`）|
| 导出脚本 sha256 | `cb6710b49e6ca3ef…` |
| 自检 Swift 源码 sha256 | `ba3074aebaff3606…` |
| 自检二进制 sha256 | `3a57ce3f631c10a5…` |
| checkpoint | `aurora_v3_best_ep13_20261115.pt` (sha256 `898cc9b98cdcf9e8…`) |
| 量化方案 | `protect_backbone`（保护算子 20）|
| 部署模型体积(实测) | 9.661 MiB |
| 部署模型内容指纹(实测) | `5720e47407b57fbe…` |
| 部署模型完整目录 sha(实测) | `0230c469926cd303…` |
| 部署记录内容指纹 | `5720e47407b57fbe…` |
| LUT 算子(实测 model.mil) | 84 |
| 输入(实测) | ['det_mask', 'dets', 'image_hi', 'image_lo', 'lane', 'vehicle_state'] |
| 输出(实测) | ['vertical', 'horizontal', 'handbrake', 'brake', 'super_brake', 'ultimate', 'confidence', 'risk'] |
| 评估数据 | `val_clips` data_sha256 `156e6d7c79a5…` |
| 评估分片 | ['clip_20261104_131750[0-4102]', 'clip_20261104_211247[0-3999]'] |

## 三、验收数据

- eval_status=passed  deploy_status=deployed
- 样本数：128（下限 30）
- 安全动作项最低决策一致率：99.22%（Wilson 下界见下表）
- 转换保真：动作最低一致 100.0%，confidence 转换误差 0.0002
- 量化影响：confidence 概率误差 0.0097，risk 概率误差 0.0661（仅告警）

| 输出 | 决策一致率 | 95% CI（下界） | 翻转数 | 翻转裕度 |
|---|---|---|---|---|
| vertical | 99.2% | 下界 0.9571 | 1 | [0.031] |
| horizontal | 100.0% | 下界 0.9709 | 0 | [] |
| handbrake | 100.0% | 下界 0.9709 | 0 | [] |
| brake | 100.0% | 下界 0.9709 | 0 | [] |
| super_brake | 100.0% | 下界 0.9709 | 0 | [] |
| ultimate | 100.0% | 下界 0.9709 | 0 | [] |
| confidence | 100.0% | 下界 0.9709 | 0 | [] |
| risk | 96.9% | 下界 0.9224 | 4 | [0.151, 0.089, 0.073, 0.119] |

## 四、自检与契约（实测运行）

- `--v3-selftest`：**69/69 通过**，退出码 0，无失败项
- `tools/v3_contract_test.py`：通过 31 / 失败 0，退出码 0

## 五、复现命令

```bash
/usr/local/bin/python3.11 tools/v3_exp/export_v3_checkpoint_int4.py \
  --stage all --scheme protect_backbone --val-clips --n-calib 128 \
  --modelc models/v3_int4.mlmodelc
/usr/local/bin/python3.11 tools/v3_exp/gen_v3_audit_report.py
```
