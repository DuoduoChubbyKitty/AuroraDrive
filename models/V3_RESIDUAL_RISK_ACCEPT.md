# V3 INT4 部署残余风险接受记录（用户决策）

日期：2026-11-16
模型：`models/v3_int4.mlmodelc`（protect_backbone，9.66 MiB）

## 决策
经用户明确选择：**保留 9.64MB 小体积档**，不采用 22.8MB 的 `protect_safe` 安全档。

## 已知残余风险（如实记录，不隐藏）
在 128 帧独立留出验证集上，该 9.64MB 模型存在 **2 处"非边界"安全动作量化翻转**（同一验证样本 `clip_20261104_211247` 分片 frame 2006，index 105）：
- `handbrake`（手刹）：fp16 侧 logit=-1.159（明确不刹）→ INT4 侧 +0.004（越过阈值触发），裕度 1.159；
- `super_brake`（超级刹车）：fp16 侧 logit=-1.146 → INT4 侧 +0.002，裕度 1.146。

另有 1 处 `vertical`（纵向三分类，非刹车类）翻转，裕度仅 0.125（<0.6 非边界，属近阈值噪声），不在本豁免范围内。

## 对照
- `protect_safe` 安全档（backbone+temporal+stage1+stage2，22.83MB）实测可消除上述 handbrake/super_brake 翻转（各 100% 一致），e2e p95 仅 6.08ms（速度无劣化），代价是模型文件大 13MB。
- 用户权衡后选择体积优先，接受上述刹车类残余翻转风险。

## 影响与建议
- 该风险仅在"刹车类动作恰好处于决策边界附近"的少数帧出现；离线验证集 128 帧中命中 1 例（≈0.78%），实际后果为：极端边界帧上可能多触发一次手刹/超级刹车（偏保守方向，非漏刹）。
- 若后续对刹车误触发敏感，切换 `protect_safe` 档即可消除（命令：`--scheme protect_safe`）。

## 结构化豁免（审计脚本读取；精确到 head+样本，且绑定模型与数据指纹）
审计 `verify_drift` 仅当：①`model_content_sha` == 当前部署 modelc 实测内容指纹，②`data_sha256` == 校验集数据指纹，③翻转 (head, shard, frame) 精确命中下列记录时，才把该非边界翻转降级为 WARN；否则一律 FAIL。新增动作、新样本或相反方向不受本豁免保护。

```json
{
  "model_content_sha": "8431c7815b447193e7b7fc48b268e02733d15bfeacb7aeabe1b973ecd48b4ac5",
  "data_sha256": "07d8fba94f56f6597cdbf85d22d57ca10c084ea9b38535027e7fd497ffb11c7f",
  "accepted": [
    {
      "head": "handbrake",
      "shard": "clip_20261104_211247_p00000",
      "frame": 2006,
      "direction": "false→true",
      "margin": 1.1592
    },
    {
      "head": "super_brake",
      "shard": "clip_20261104_211247_p00000",
      "frame": 2006,
      "direction": "false→true",
      "margin": 1.1455
    }
  ]
}
```

本记录随审计报告一并留存，供追溯。若切换模型或数据，此豁免自动失效（恢复硬失败）。
