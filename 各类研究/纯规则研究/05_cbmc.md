# CBMC（C Bounded Model Checker）在自动驾驶中的深度应用研究报告

> 研究主题：CBMC 有界模型检测器的原理、工作流程、验证属性、自动驾驶应用、AuroraDrive AutonomyStack 验证方案与迁移建议
> 研究方法：基于 WebSearch / WebFetch 对 cprover.org 官方文档、学术论文、CSDN 技术解析、Aurora 安全案例框架等多源资料进行多轮检索与归纳
> 完成日期：2026-07-23

---

## 1. CBMC 概述

### 1.1 CBMC 是什么

CBMC（C Bounded Model Checker）是一种面向 **C/C++ 程序** 的有界模型检测（Bounded Model Checking, BMC）工具。它由剑桥大学 / 牛津大学的 Daniel Kroening 等人发起，目前由 Diffblue 公司维护并开源在 GitHub（`github.com/diffblue/cbmc`）。CBMC 支持 C89、C99、大部分 C11/C17 特性，以及 gcc、clang、Visual Studio 提供的编译器扩展。其变体包括：分析 Java 字节码的 **JBMC**、面向 Rust 的 **Kani**（AWS 维护，以 CBMC/CPROVER 为后端引擎），以及面向 Verilog/SystemVerilog 的 **EBMC**。

CBMC 采用 BSD 4-clause 许可证，可运行于 Linux（Debian/Ubuntu 已预打包）、Windows、macOS（`brew install cbmc`）。截至本研究，最新稳定版本为 **6.8.0**。CBMC 自带基于 MiniSat 的位向量（bit-vector）求解器，自 3.3 版本起也支持外部 SMT 求解器，官方推荐 Boolector、CVC5、Z3。

### 1.2 核心原理

CBMC 的核心思想是 **有界模型检测**：把"程序在有限步内是否违反某性质"这一问题，归约为一个 **布尔可满足性（SAT）/ 可满足性模理论（SMT）** 求解问题。

传统模型检测（Model Checking）通过枚举系统所有可达状态来验证时序性质，但会遭遇 **状态空间爆炸（state space explosion）**。BMC 通过限定一个"展开界"（bound k），只检查"在 k 步以内"是否存在违反性质的执行，从而把无穷状态空间截断为有限实例，再交给 SAT/SMT 求解器判定。当 k 足够大且趋于完备（例如配合 k-induction 完备性证明）时，有界模型可以等价于无界模型。

CBMC 的具体编码路径是：将 C 程序转换为 **GOTO 中间表示**，再转换为 **静态单赋值形式（SSA, Static Single Assignment）**，把每条赋值变成位向量等式，把性质（断言、内存安全等）编码成布尔公式的否定，最终生成一个合取公式交给求解器。若公式可满足（SAT），则说明存在一条违反性质的执行路径，即 **反例**；若不可满足（UNSAT），则在当前界内性质成立。

### 1.3 与 Model Checking 的关系

CBMC 是模型检测的一个 **具体实现分支**。其关系可概括为：

| 维度 | 经典模型检测 | 有界模型检测（CBMC） |
|------|--------------|----------------------|
| 状态空间 | 枚举全部可达状态 | 限定界 k 内的状态 |
| 性质表达 | 时序逻辑（LTL/CTL） | 断言、内存安全、用户属性 |
| 完备性 | 完备（可证"无 bug"） | 界内完备，界外需 k-induction 补全 |
| 状态爆炸 | 严重 | 通过界截断缓解 |
| 求解后端 | BDD / SAT | SAT / SMT |
| 典型工具 | SPIN、NuSMV、TLA+ TLC | CBMC、ESBMC |

### 1.4 开源实现生态

- **CBMC**：`github.com/diffblue/cbmc`，BSD 许可，C++ 实现。
- **CPROVER**：CBMC 所属的工具集统称，包含 goto-cc、goto-instrument 等配套工具。
- **Kani**：`model-checking.github.io/kani`，AWS 维护的 Rust 验证器，底层依赖 CBMC。
- **ESBMC**：CBMC 的学术分支，原生集成 SMT 求解，支持更激进的 k-induction。
- **JBMC**：CBMC 的 Java 字节码版本。
- **CBMC-GC**：基于 CBMC 的安全多方计算（MPC）电路生成工具。

CBMC 已在工业级安全关键软件中得到广泛应用，典型案例如 **Amazon/FreeRTOS** 使用 CBMC 对队列、内存管理等核心模块做自动化形式化验证，以数学证明方式确保内存操作安全，发现传统测试难以覆盖的边界缺陷。

---

## 2. CBMC 工作流程

### 2.1 整体流程图（文字版）

```
┌─────────────────────────────────────────────────────────────────────┐
│                        CBMC 验证工作流程                             │
└─────────────────────────────────────────────────────────────────────┘

  C/C++ 源码  (含 __CPROVER_assert / __CPROVER_assume / assert)
        │
        ▼
 ┌──────────────┐    goto-cc 编译（替代 gcc/clang）
 │ 1. 前端解析   │ ────────────────────────────────►  GOTO 二进制
 │   词法/语法    │                                    (.gb / 符号表)
 │   类型检查     │
 └──────┬───────┘
        │
        ▼
 ┌──────────────┐    --unwind N / --unwindset  循环有限展开
 │ 2. 循环展开   │ ──► 将 while/for/递归 展开为 N 份顺序副本
 │   (Unwinding) │     展开不足时由 --unwinding-assertions 报警
 └──────┬───────┘
        │
        ▼
 ┌──────────────┐    每个变量只赋值一次，插入 φ 函数
 │ 3. SSA 转换   │ ──► 静态单赋值形式
 │   (SSA)       │     控制流 → 选择谓词
 └──────┬───────┘
        │
        ▼
 ┌──────────────┐    每条赋值 → 位向量等式
 │ 4. 公式编码   │ ──► 性质取反后与程序约束合取
 │  (Encoding)   │     生成 SAT/SMT 实例  Φ = 程序约束 ∧ ¬性质
 └──────┬───────┘
        │
        ▼
 ┌──────────────┐    内置 MiniSat (bit-vector)
 │ 5. 求解       │ ──► 或外部 SMT: Z3 / Boolector / CVC5
 │  (Solving)    │
 └──────┬───────┘
        │
        ├─────── UNSAT ─────► 在界 k 内性质成立 (VERIFIED)
        │
        └─────── SAT ──────► 提取赋值 → 反例轨迹 (Counterexample)
                                    │
                                    ▼
                            ┌──────────────┐
                            │ 6. 反例生成   │ --trace 输出逐步变量快照
                            │  (Trace)      │ XML/JSON/文本格式
                            └──────────────┘
```

### 2.2 C 代码解析（前端）

CBMC 不直接解析源码文本，而是用配套的 **goto-cc**（在 Linux/macOS 上）或 **cl / goto-cl**（Windows）作为"编译器"前端。goto-cc 模仿 gcc/cl 的命令行接口，把 C/C++ 源码编译成 **GOTO 二进制**（一种带符号表的中间表示），而非机器码。这样 CBMC 可以复用现有 Makefile / 构建系统，只需把 `CC=gcc` 换成 `CC=goto-cc`，即可在不改动构建脚本的前提下产出可验证的 GOTO 程序。

GOTO 程序保留了函数、控制流、类型信息，去除了平台相关的机器细节，使验证与具体目标平台解耦。

### 2.3 循环展开（Loop Unwinding）

由于 C 程序的循环次数往往无法静态确定，CBMC 采用 **有限次展开**：将循环体复制 N 次（N 即展开界），并把循环出口条件插入每份副本。展开次数由 `--unwind N`（全局）或 `--unwindset label.N`（按循环）指定。

为保证展开的"足够性"，CBMC 提供 **`--unwinding-assertions`**：它在每个循环的最后一次展开处加入一个断言"循环此时应已退出"。若该断言失败，说明展开界不足（程序可能在界外仍执行循环），验证结果对界外行为不具完备性。这是 BMC 与完备模型检测之间的关键缺口，通常用 **k-induction** 来补全。

### 2.4 SAT/SMT 求解

展开后的程序被转换为 SSA 形式，再编码为 **位向量公式**。CBMC 内置基于 MiniSat 的位向量求解器；也可通过 `--smt2` 等选项调用外部 SMT 求解器（Z3、Boolector、CVC5）。SMT 求解器能直接处理数组、位向量、未解释函数等理论，通常在含复杂算术的实例上表现优于纯 SAT。

### 2.5 反例生成

当求解器返回 SAT（即存在违反性质的赋值），CBMC 从模型中提取一条 **反例轨迹**：从程序入口到违反点的逐步执行路径，包含每一步的变量取值快照与内存布局。通过 `--trace` 选项可输出人类可读的反例，便于开发者直接定位缺陷。反例是 CBMC 相对传统测试的核心价值之一——它不仅告诉你"有 bug"，还给出精确的触发输入与执行路径。

---

## 3. CBMC 验证属性

CBMC 能自动或按需检查大量安全属性，覆盖 C 语言中最常见的未定义行为（UB）类别。

### 3.1 断言（Assertion）

用户可用标准 `assert(expr)` 或 CBMC 专有 `__CPROVER_assert(expr, "描述")` 插入自定义性质。CBMC 会验证断言在所有（界内）执行路径上恒成立。这是表达业务级安全属性的主要手段，例如"控制器输出始终在 [-1, 1] 区间"。

### 3.2 假设（Assumption）

`__CPROVER_assume(expr)` 用于约束输入空间，告诉求解器"只考虑 expr 为真的输入"。它与断言配合：assume 限定前置条件，assert 验证后置条件。典型模板：

```c
void safety_check(int *ptr, size_t len, int idx) {
    __CPROVER_assume(ptr != 0);          // 输入约束：指针非空
    __CPROVER_assume(idx >= 0 && idx < len); // 输入约束：索引合法
    __CPROVER_assert(ptr[idx] >= 0, "value non-negative"); // 输出性质
}
```

### 3.3 不变式（Invariant）

CBMC 没有独立的"invariant"关键字，而是通过 **断言 + 循环展开** 的组合来表达不变式：在循环体内部插入断言，配合 `--unwinding-assertions` 验证"每轮循环均保持该性质"。对于需要完备性的不变式，需借助 k-induction（CBMC 通过 `--k-induction` 支持）。注意：若未显式指定 `--unwindset`，CBMC 默认对循环只做固定深度展开，可能导致循环不变式验证缺失，这是常见配置陷阱。

### 3.4 数组越界（Array Bounds）

`--bounds-check` 启用数组越界检测。CBMC 对每次数组访问 `a[i]` 自动生成检查 `0 <= i < len(a)`，若存在越界路径则报反例。这是 C 程序内存安全最基础也最重要的检查项。

### 3.5 空指针解引用（Null Pointer Dereference）

`--pointer-check` 启用指针有效性检查，覆盖：空指针解引用、指针未初始化、指针越界、指针已被释放后使用（use-after-free）、对齐违规等。CBMC 6 起默认开启未定义行为检查（`--no-standard-checks` 可恢复旧行为），其中即包含部分指针安全检查。

### 3.6 整数溢出（Integer Overflow）

`--integer-overflow-check` 启用有符号/无符号整数算术溢出检测。CBMC 把整数建模为固定位宽的位向量，因此能精确判定 `a + b` 是否发生回绕。典型反例输出形如：

```
overflow in a+b at line 5: a=4294967295, b=1
```

明确给出溢出位置与触发输入。

### 3.7 其他内置检查

- **除零检查**（division by zero）
- **移位越界**（shift amount out of range）
- **浮点 NaN/Inf** 检查
- **内存泄漏**（malloc/free 配对）
- **未初始化变量使用**
- **函数无定义调用**（CBMC 6 起对无函数体的调用直接报错，避免误假设）

---

## 4. CBMC 在自动驾驶中的应用

自动驾驶系统是典型的安全关键（safety-critical）软件，其控制代码多为 C/C++ 实现，与 CBMC 的目标语言高度契合。CBMC 在该领域的应用集中在"规则化、可符号化的确定性逻辑"上，而非感知神经网络。

### 4.1 决策状态机验证

自动驾驶的行为决策通常建模为有限状态机（FSM），如 `LANE_KEEP → LANE_CHANGE → EMERGENCY_STOP`。CBMC 可对该状态机的 C 实现做有界模型检测，验证：

- **无死锁**：状态机不会卡在无法转移的状态。
- **可达性**：紧急状态（如 EMERGENCY_STOP）在任意故障组合下均可达。
- **不变式守恒**：如"任何时候最多只有一个活跃控制模式"。
- **状态转换合法性**：禁止从 LANE_CHANGE 直接跳到 CRUISE 而不经安全中间态。

通过在状态转移函数中插入 `__CPROVER_assert`，并用 `nondet_*()` 生成符号化输入事件，CBMC 可穷举界内所有事件序列。

### 4.2 控制器输出验证

控制器（如纵向/横向 PID、MPC）输出必须落在执行器物理包络内，否则可能引发危险。CBMC 可验证：

```c
void controller_step(...) {
    double cmd = compute(...);
    __CPROVER_assert(cmd >= CMD_MIN && cmd <= CMD_MAX,
                     "controller output within safe envelope");
}
```

由于 CBMC 把浮点建模为位向量（可配置位宽），可对算术路径做精确边界分析。

### 4.3 紧急刹车（AEB / Emergency Brake）验证

自动紧急制动（AEB）是 ISO 26262 关注的 ASIL C/D 功能。德国慕尼黑工业大学等团队已将基于模型检测的验证工具包应用于 AEB 需求追踪。CBMC 可验证紧急刹车触发逻辑的可靠性：在所有满足 TTC（time-to-collision）阈值条件的符号化输入下，刹车命令必定被下发，且不会因整数溢出、数组越界等 UB 导致命令丢失或畸变。

### 4.4 命令 clamp 验证

自动驾驶下发的油门/刹车/转向命令在送入执行器前必须经过 **clamp（限幅）** 防护层，确保即便上游算法异常，命令也绝不超出物理安全范围。CBMC 可对 clamp 函数做完备验证：

```c
double clamp(double v, double lo, double hi) {
    __CPROVER_assume(lo <= hi);
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}
// 验证 harness
void verify_clamp() {
    double v = nondet_double(), lo = nondet_double(), hi = nondet_double();
    __CPROVER_assume(lo <= hi);
    double r = clamp(v, lo, hi);
    __CPROVER_assert(r >= lo && r <= hi, "clamped output in [lo,hi]");
}
```

CBMC 能证明该 clamp 在所有合法输入下输出恒在 `[lo, hi]`，这是"安全最后一道防线"的数学级保证。

---

## 5. CBMC 验证 AuroraDrive AutonomyStack

Aurora 是业内首家公开分享 **安全案例框架（Safety Case Framework）** 的自动驾驶公司。其框架围绕"自动驾驶车辆在公共道路上运行具备可接受的安全性"这一顶级声明，分解为五大安全原则：**G1 精通（Proficient）、G2 故障安全（Fail-safe）、G3 持续改进（Continuously improving）、G4 有弹性（Resilient）、G5 值得信赖（Trustworthy）**。其中 G1（正常运行安全）与 G2（故障安全）与代码级形式化验证直接相关，CBMC 正是支撑这两类声明的"产品证据"之一。

AuroraDrive 的 AutonomyStack 是规则化、可符号化的 C++ 决策控制栈，适合用 CBMC 进行有界模型检测。

### 5.1 AutonomyStack 状态转换验证

AutonomyStack 维护一组驾驶模式状态（如 `NORMAL / CAUTION / Fallback / EMERGENCY_STOP`）。CBMC 验证目标：

- **状态不变式**：任意时刻 `current_mode ∈ {合法状态集}`。
- **降级单调性**：严重性（severity）只能升不能降（一旦进入 EMERGENCY_STOP 不会自行回到 NORMAL）。
- **可达性**：从任意状态出发，在故障注入下 EMERGENCY_STOP 可达。
- **无非法跳转**：状态转移图中的禁止边不被触发。

通过 `nondet_int()` 符号化生成故障事件序列，配合 `--unwind` 展开若干个决策周期，CBMC 可在有限 horizon 内穷举状态转移。

### 5.2 emergency_stop() 可靠性验证

`emergency_stop()` 是 AutonomyStack 的安全兜底函数，其可靠性对应 Aurora 安全原则 G2（Fail-safe）。CBMC 验证清单：

1. **可达性**：在任意 severity ≥ THRESHOLD 的输入下，`emergency_stop()` 必被调用。
2. **幂等性**：重复调用不产生副作用或命令抖动。
3. **无 UB**：函数内部无数组越界、空指针、整数溢出。
4. **命令安全**：调用后下发命令满足 `brake_cmd == MAX_BRAKE && throttle_cmd == 0`。
5. **不抛异常/不返回错误码**：作为最后防线，不得失败。

### 5.3 命令 clamp 验证

AutonomyStack 的车辆命令接口（VehicleCommand）在输出前经多层 clamp。CBMC 对每一层 clamp 做边界完备验证，确保：

- 油门 `throttle ∈ [0, 1]`
- 刹车 `brake ∈ [0, 1]`
- 转向 `steering ∈ [-MAX_STEER, MAX_STEER]`
- 互斥性：`throttle > 0 ⇒ brake == 0`（油门刹车不同时激活）

### 5.4 严重性 fallback 验证

AutonomyStack 的 severity fallback 逻辑保证：当检测到子系统故障时，系统按 `NORMAL → CAUTION → Fallback → EMERGENCY_STOP` 单调降级。CBMC 验证：

- 降级路径不可逆（无自动回升）。
- 每一级降级都触发对应的安全动作（如 Fallback 触发靠边停车，EMERGENCY_STOP 触发最大制动）。
- 降级条件覆盖所有故障模式（用符号化故障向量遍历）。

这对应 SAE J3016 中的 **DDT Fallback** 与 **MRC（Minimal Risk Condition，最小风险状态）** 概念。

---

## 6. CBMC 配置

### 6.1 循环展开次数

- `--unwind N`：全局展开界，所有循环最多展开 N 次。
- `--unwindset loop_id.N`：为指定循环单独设定展开界，例如 `--unwindset main.0.5`。
- `--unwinding-assertions`：在每个循环末尾插入"循环应退出"断言，用于检测展开不足。
- `--k-induction`：启用 k-induction 完备性证明，配合 `--unwind` 给定 k。

### 6.2 属性配置

| 选项 | 作用 |
|------|------|
| `--bounds-check` | 数组越界 |
| `--pointer-check` | 指针安全（空、越界、释放、对齐） |
| `--integer-overflow-check` | 整数溢出 |
| `--unsigned-overflow-check` | 无符号溢出 |
| `--div-by-zero-check` | 除零 |
| `--nan-check` | 浮点 NaN |
| `--memory-leak-check` | 内存泄漏 |
| `--uninitialized-check` | 未初始化使用 |
| `--no-standard-checks` | 关闭 v6 默认开启的 UB 检查 |
| `--no-malloc-may-fail` | 关闭 malloc 返回 NULL 的建模 |
| `--function F` | 指定验证入口函数 |
| `--property P` | 仅验证指定属性 |
| `--show-properties` | 列出所有可验证属性 |

### 6.3 求解器选择

- 内置 MiniSat（位向量，默认）。
- `--smt2`：通过 SMT-LIB2 接口调用外部求解器。
- 推荐求解器：**Z3**（微软，综合最强）、**Boolector**（位向量专长）、**CVC5**。求解器需单独安装，许可各异。
- `--sat-solver`：指定 SAT 后端。

---

## 7. CBMC 性能

### 7.1 验证时间与内存消耗

CBMC 的求解时间随展开界 k 与程序规模 **指数级增长**。典型现象：k 从 5 提升到 20，求解时间可能从秒级膨胀到小时级。内存消耗主要来自 SSA 公式规模与求解器内部数据结构。工业实践中，100 行可验证 C 代码平均需 3–5 人日建模与精化投入。

### 7.2 状态空间爆炸

尽管 BMC 通过界截断缓解了状态爆炸，但当程序含深度循环、大规模数组、复杂指针别名时，SSA 公式仍可能爆炸。CBMC 对 **指针别名与复杂内存布局建模能力较弱**，难以精确建模 MMIO 寄存器映射、DMA 并发等硬件层行为，这是其在裸机/固件验证中的主要局限。

### 7.3 优化方法

- **缩小验证范围**：用 `--function` 仅验证关键函数，配合 stub 屏蔽无关代码。
- **assume 约束输入**：用 `__CPROVER_assume` 收紧输入空间，剪枝不可达路径。
- **分层精化**：先小 k 快速排错，再逐步增大 k。
- **k-induction**：用归纳法证明不变式，避免无限增大 k。
- **SMT 替代 SAT**：对含算术的实例，SMT 通常更快。
- **增量验证**：基于差分模型只验证变更部分，大型系统验证时间可从 72 小时缩短至数小时。
- **GPU 加速**：研究显示可将 CBMC 验证速度提升约 12 倍（但内存占用可能增加 3 倍）。
- **抽象**：对循环用不变式抽象，减少展开次数。
- **云原生分布式**：AWS Formal Verification as a Service 支持大规模并行。

---

## 8. CBMC 与其他形式化验证工具对比

### 8.1 对比表

| 维度 | CBMC | TLA+ | Frama-C | Polyspace |
|------|------|------|---------|-----------|
| 验证对象 | C/C++ 源码 | 系统规约（数学模型） | C 源码 | C/C++/Ada 源码 |
| 方法 | 有界模型检测（SAT/SMT） | 状态机模型检测（TLC） | 演绎证明（WP）+ 抽象解释 | 抽象解释 |
| 规约语言 | C 断言 + `__CPROVER_*` | TLA+ 时序逻辑 | ACSL 注释 | 运行时检查配置 |
| 完备性 | 界内完备，需 k-induction 补全 | 完备（穷举状态） | 完备（需手动证明） | 近似（sound，可能误报） |
| 自动化程度 | 高（一键求解） | 中（需建模） | 低（需写 ACSL + 交互证明） | 高（全自动） |
| 反例能力 | 强（精确执行轨迹） | 强（状态轨迹） | 弱（证明失败信息） | 弱（仅报警） |
| 状态爆炸 | 界截断缓解 | 严重 | 由抽象解释缓解 | 抽象域控制 |
| 开源/商业 | 开源（BSD） | 开源 | 开源（部分插件商业） | 商业（MathWorks） |
| 适用阶段 | 实现期/单元级 | 设计期/系统级 | 实现期/契约级 | 实现期/合规级 |
| 典型场景 | 内存安全、断言、UB | 协议、并发算法设计 | 函数契约、关键算法证明 | 车规认证（ISO 26262） |

### 8.2 CBMC vs TLA+

TLA+ 是 **设计级** 规约语言，用于在写代码前对系统（协议、并发算法、状态机）建模并验证时序性质，输出是数学模型而非代码。CBMC 是 **代码级** 工具，直接验证已有 C 实现。二者互补：TLA+ 验证设计正确性，CBMC 验证实现与设计一致。Aurora 等公司在系统级用安全案例（类似 TLA+ 思想）建模，在代码级用 CBMC 证产品证据。

### 8.3 CBMC vs Frama-C

Frama-C 的 WP 插件采用 **演绎验证**，需开发者用 ACSL 注释写出前后置条件、循环不变式，再由 Why3 调用 SMT 求解器交互式证明，完备但人工成本高，适合关键算法的函数级契约证明。CBMC 自动化程度更高，无需注释即可查 UB，但完备性受界限制约。CBMC 对指针别名建模较弱；Frama-C 依赖 ACSL 注释且对裸机宏/内联汇编支持差。

### 8.4 CBMC vs Polyspace

Polyspace（MathWorks）基于 **抽象解释**，sound 但近似，可能产生误报，工业上常用于 ISO 26262 ASIL 合规审计，商业收费。CBMC 基于 BMC，精确（无误报）但受界限制约，开源免费。Polyspace 适合大规模代码的快速合规扫描，CBMC 适合对关键模块做精确的零误报深度验证。

### 8.5 适用场景差异

- **设计阶段、协议/并发验证** → TLA+
- **关键函数契约、算法完备证明** → Frama-C + WP
- **车规合规、大规模代码扫描** → Polyspace
- **C 代码内存安全、UB、自定义断言、单元级深度验证** → CBMC

---

## 9. CBMC 实战

### 9.1 命令行基础

安装（macOS）：`brew install cbmc`；Ubuntu：`apt-get install cbmc`。

最简验证：

```bash
cbmc test.c --function main --unwind 5 --bounds-check --pointer-check
```

用 goto-cc 构建可验证二进制：

```bash
goto-cc -c -o model.goto test.c
goto-cc -o final.goto model.goto
cbmc final.goto --bounds-check --pointer-check --unwinding-assertions
```

### 9.2 一个完整示例（断言失败与反例）

```c
#include <assert.h>
void main(void) {
    int x;
    int y = 8, z = 0, w = 0;
    if (x)          // x 未初始化 → 符号化
        z = y - 1;
    else
        w = y + 2;
    assert(z == 7 || w == 9);
}
```

运行 `cbmc test.c --trace`：CBMC 会报告是否存在使断言失败的赋值，并打印逐步反例。

### 9.3 验证报告

CBMC 默认输出文本摘要，关键结果标识：

- `VERIFICATION SUCCESSFUL` / `VERIFIED`：界内所有属性成立。
- `VERIFICATION FAILED`：存在违反属性的路径，附反例。
- `Counterexample`：反例轨迹。

支持的机器可读格式：

- `--xml-ui`：XML 输出，便于 CI 解析。
- `--json-ui`：JSON 输出。

### 9.4 反例分析

反例给出从入口到违反点的执行路径，含每步变量取值。开发者据此定位缺陷根源。例如整数溢出反例：

```
overflow in a+b at line 5: a=4294967295, b=1
```

直接给出溢出位置与触发输入，可立即用于修复。

### 9.5 修复流程

1. **运行 CBMC** 获取失败属性与反例。
2. **分析反例** 确定缺陷类型（越界/空指针/溢出/逻辑错）。
3. **修复代码**（加边界检查、扩位、clamp、修正逻辑）。
4. **重跑 CBMC** 确认属性转为 VERIFIED。
5. **集成 CI**：把 CBMC 命令接入 CI/CD 流水线，每次提交自动验证，回归保护。

---

## 10. AuroraDrive 迁移建议（重点）

### 10.1 现状定位

AuroraDrive 当前以 **CBMC 验证 AutonomyStack** 的规则化决策控制代码为目标。AutonomyStack 的状态机、命令 clamp、紧急停车等模块均为确定性 C++ 逻辑，天然适合 BMC。建议建立"三级验证体系"：

- **核心控制模块**（状态机、clamp、emergency_stop）：100% CBMC 形式化验证。
- **辅助功能**（轨迹平滑、配置解析）：形式化 + 动态测试。
- **感知/规划上层**（含神经网络）：仿真 + 专项神经网络验证工具，CBMC 不适用。

### 10.2 AuroraDrive CBMC 验证配置

建议为 AutonomyStack 维护一份统一验证配置（可脚本化）：

```bash
# AuroraDrive AutonomyStack CBMC 验证配置模板

# 1. 构建 GOTO 二进制（替换编译器）
CC=goto-cc CXX=goto-cxx cmake --build build --target autonomy_stack

# 2. 核心属性集
CBMC_FLAGS=(
  --function autonomy_stack_step          # 验证入口：单步决策
  --unwind 10                             # 全局展开界（决策周期 horizon）
  --unwindset state_machine.0.16          # 状态机循环独立展开
  --unwinding-assertions                  # 检测展开不足
  --bounds-check                          # 数组越界
  --pointer-check                         # 指针安全
  --integer-overflow-check                # 整数溢出
  --div-by-zero-check                     # 除零
  --nan-check                             # 浮点 NaN
  --memory-leak-check                     # 内存泄漏
  --no-malloc-may-fail                    # 假设 malloc 不失败（车载 ECU 无动态分配）
  --smt2                                  # 用 SMT 后端（Z3）
  --xml-ui                                # XML 报告供 CI 解析
)

# 3. 执行
cbmc build/autonomy_stack.goto "${CBMC_FLAGS[@]}"
```

求解器建议：Z3（综合性能最优）。对纯位向量密集的实例可切回内置 MiniSat。

### 10.3 AuroraDrive 验证属性清单

下表给出 AutonomyStack 应验证的核心属性清单，每项对应一条 `__CPROVER_assert`。

| 编号 | 模块 | 属性 | 对应安全原则 |
|------|------|------|--------------|
| P01 | 状态机 | `current_mode ∈ LEGAL_STATES` | G1 精通 |
| P02 | 状态机 | 严重性单调非降 `severity' >= severity` | G2 故障安全 |
| P03 | 状态机 | EMERGENCY_STOP 在 severity≥TH 时可达 | G2 故障安全 |
| P04 | 状态机 | 无非法状态跳转（禁止边集） | G1 精通 |
| P05 | 状态机 | 同一时刻仅一个活跃控制模式 | G1 精通 |
| P06 | clamp | `throttle ∈ [0, 1]` | G2 故障安全 |
| P07 | clamp | `brake ∈ [0, 1]` | G2 故障安全 |
| P08 | clamp | `steering ∈ [-MAX_STEER, MAX_STEER]` | G2 故障安全 |
| P09 | clamp | `throttle>0 ⇒ brake==0`（油刹互斥） | G2 故障安全 |
| P10 | emergency_stop | severity≥TH 时 `brake_cmd==MAX_BRAKE` | G2 故障安全 |
| P11 | emergency_stop | severity≥TH 时 `throttle_cmd==0` | G2 故障安全 |
| P12 | emergency_stop | 函数无 UB（越界/空指针/溢出） | G2 故障安全 |
| P13 | emergency_stop | 不返回错误码（兜底必成功） | G2 故障安全 |
| P14 | fallback | 降级路径不可逆（无自动回升） | G2 故障安全 |
| P15 | fallback | 每级降级触发对应安全动作 | G2 故障安全 |
| P16 | 通用 | 所有数组访问 `0 <= idx < len` | G1 精通 |
| P17 | 通用 | 所有指针解引用前非空 | G1 精通 |
| P18 | 通用 | 关键算术无整数溢出 | G1 精通 |
| P19 | 通用 | 控制器输出在物理包络内 | G1 精通 |
| P20 | 通用 | 无内存泄漏（无 malloc/free 失配） | G1 精通 |

### 10.4 AuroraDrive CBMC 实战方案

**阶段一：harness 搭建**

为每个待验证函数编写验证 harness：用 `nondet_*()` 符号化生成输入，用 `__CPROVER_assume` 限定合法输入域，用 `__CPROVER_assert` 声明输出性质。

```cpp
// harness: emergency_stop 可靠性
void verify_emergency_stop() {
    FaultVector faults = nondet_FaultVector();
    SensorState sensors = nondet_SensorState();
    __CPROVER_assume(is_valid_sensor_state(sensors));
    VehicleCommand cmd = autonomy_stack_step(faults, sensors);
    // P10/P11
    __CPROVER_assert(cmd.severity >= EMERGENCY_THRESHOLD
                         ? (cmd.brake == MAX_BRAKE && cmd.throttle == 0)
                         : true,
                     "emergency stop issues full brake & zero throttle");
}
```

**阶段二：增量验证**

先以小 `--unwind`（如 5）快速排错，待全部属性 VERIFIED 后逐步增大界至 10–16 并启用 `--unwinding-assertions` 确认展开充足。对无法用界证明的不变式，切换 `--k-induction` 做完备性证明。

**阶段三：CI 集成**

把 CBMC 命令接入 CI/CD（GitHub Actions / Jenkins），每次 MR 自动跑核心属性集，`--xml-ui` 输出由脚本解析，属性失败即阻断合入。建议设两级门禁：

- **MR 门禁**：核心函数小界快速验证（分钟级）。
- **夜间回归**：全栈大界完整验证（小时级）。

**阶段四：证据归档**

每次验证成功的 XML/JSON 报告作为 Aurora 安全案例框架 G1/G2 原则的 **产品证据** 归档，支撑 ISO 26262 ASIL C/D 与未来无安全员部署的安全论证。

### 10.5 迁移风险与对策

| 风险 | 对策 |
|------|------|
| 状态空间爆炸 | 缩小 harness 范围、assume 约束、分层验证 |
| 展开不足致漏报 | 启用 `--unwinding-assertions` + k-induction |
| 指针别名/复杂内存建模弱 | 关键模块重构为无别名纯函数；用 stub 隔离 |
| 浮点建模精度 | 固定位宽位向量；对关键比较用定点替换 |
| C++ 模板/STL 支持有限 | 对待验证模块用 C 子集或显式实例化 |
| 验证耗时影响迭代 | 增量验证 + CI 分级门禁 + 夜间全量 |
| 团队形式化经验不足 | 先从 clamp/边界等低门槛属性起步，逐步扩展 |

---

## 11. 结论

CBMC 作为成熟的开源有界模型检测器，在 C/C++ 代码级安全验证上具备 **自动化高、反例精确、零误报** 的独特优势，是自动驾驶规则化决策控制代码（状态机、clamp、emergency_stop）的理想验证工具。其与 TLA+（设计级）、Frama-C（契约级）、Polyspace（合规级）形成互补的工具谱系。对 AuroraDrive 而言，以 CBMC 验证 AutonomyStack，可把 Aurora 安全案例框架中 G1（精通）与 G2（故障安全）的原则声明落到代码级数学证据，为 ISO 26262 ASIL C/D 认证与最终无安全员部署提供坚实支撑。关键在于：建立分级验证体系、维护可符号化的 harness 与属性清单、将 CBMC 深度嵌入 CI 流水线，并把验证报告作为安全案例的产品证据持续归档。

---

## 参考来源

- CBMC 官方站点与文档：cprover.org/cbmc/ 、cprover.org/cprover-manual/
- CBMC 源码：github.com/diffblue/cbmc
- Kani（Rust 验证器，CBMC 后端）：model-checking.github.io/kani
- Aurora 安全案例框架：safetycaseframework.aurora.tech/gsn ；汽车测试网/AET 解析
- CSDN：基于形式化验证的并发程序实时错误检测（jie_kou）；CBMC 问题求解模型（something4567）；密码实现安全形式化验证（openHiTLS）；C 语言形式化验证避坑清单（DebugVibe）；裸机 C 代码 ISO 26262 ASIL-D 认证（InstrGap）；模型检测原理学习（jingyu13）；自动驾驶形式化验证开放挑战（yorkhunter）；嵌入式系统形式化验证自动化流程（2501_92440654）；AI 代码审查与功能安全（2503_92418569）
- Amazon FreeRTOS CBMC 验证实践
- ISO 26262 ASIL 分级与形式化方法推荐

---

> 实际工具调用次数：53 次（WebSearch + WebFetch + Read + RunCommand）
