# SpeedExtrapolator 隔离回归测试

测的是生产源 `Sources/AuroraDrive/Agent/SpeedExtrapolator.swift`（逐字复制，零改写）。

## 构建
```bash
python3 verify/speed_extrapolator_audit/build_harness.py
```

## 运行
```bash
# 1) 26 条固定用例（覆盖边角，必须全过）
./verify/speed_extrapolator_audit/build/harness

# 2) 单 seed fuzz（<迭代数> <seed>）
./verify/speed_extrapolator_audit/build/harness fuzz 5000 42

# 3) 批量 sweep（<seedStart> <seedEnd> <每seed迭代数>）
./verify/speed_extrapolator_audit/build/harness sweep 1000 1020 3000
```

## 补充固定用例（独立二进制）
`Tests/main_fixed_extra.swift` 因 main.swift 已有顶层入口，需单独编译（避免重复 main 符号）：
```bash
# 先跑一次 build_harness.py 生成 build/SpeedExtrapolator.swift，再：
python3 verify/speed_extrapolator_audit/build_harness_extra.py
./verify/speed_extrapolator_audit/build/harness_extra              # 全部 79 条
./verify/speed_extrapolator_audit/build/harness_extra A,B,C        # 只跑指定组
```
覆盖组：A 时间倒退 / B 窗口边界 / C maxExtrap=0 / D minSamples=1 / E 上界 / F elapsed=0 /
G 超长 elapsed 与恰在边界 / H 1000·5000 样本 / I 交替抖动 / J window=0 / K 非法配置 /
L 乱序样本 / N 同刻重复 / O 查询不再裁剪 / P 回归 / Q clamp 单调性 / R 查询无副作用 /
S minSamples 归一 / T NaN·inf·1e308 等未定义输入。

## 不变量（fuzz 强制校验）
- I1 估计值恒为有限数且在 `[0, maxSpeedKmh]`
- I2 超过外推窗口后，更晚时刻的估计值相等（冻结，不再变化）且 == 最后有效值
- I3 无读数时 `estimatedSpeed` 返回 nil（不崩）
- I4 单样本时任何未来时刻估计值 == 该样本值（无斜率可造）
- I5 `reset()` 后回到无读数状态

## 注意
`build/` 是生成产物，不入库。
