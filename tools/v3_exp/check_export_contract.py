#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
# SPDX-License-Identifier: GPL-3.0-or-later
"""export_coreml 存档键契约的纯静态检查（不 import torch，本机可跑）。

为什么需要：
  `src/model_v3.py::export_coreml` 历史上只认 `ckpt["model_state_dict"]`，认不到
  就把整个 ckpt 当 state_dict 加载，再被 strict=False 静默吞掉全部失配——
  导出过零权重随机模型且不报任何错（生产脚本 tools/v3_exp/export_v3_checkpoint_int4.py
  文件头 ① 逐条记录过这次事故）。已修复为 `_extract_state_dict` + 默认 strict=True，
  本脚本把「修复不许回退」固化成三条可机器校验的断言：

    1) `src/model_v3.py` 的模块级常量 `_STATE_DICT_KEYS` 必须含 "model"
       （train_v3.py 的存档键就是它，丢了它修复就失效）；
    2) `export_coreml` 函数体内必须存在 strict=True 的 load_state_dict
       （默认路径必须是 strict，partial 只许走 allow_partial 显式分支）；
    3) `src/train_v3.py` 的 torch.save 字面量必须含 "model" 键
       （云端 15 轮 checkpoint 都按这个键存，改键即毁历史存档）。

用法：
  python3 tools/v3_exp/check_export_contract.py
退出码：0 三条全过；1 任一断言失败（打印是哪一条断了）。
"""
from __future__ import annotations

import ast
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODEL_V3 = ROOT / "src" / "model_v3.py"
TRAIN_V3 = ROOT / "src" / "train_v3.py"

# 未测 / 已知取舍：本脚本只做 AST 结构断言，不验证权重数值正确性——
# 那需要加载 .pt（违反本机禁令），由云端导出日志的「权重加载摘要」行承担。


def _fail(msg: str) -> None:
    print(f"FAIL {msg}")


def check_state_dict_keys(tree: ast.Module) -> bool:
    """断言 1：_STATE_DICT_KEYS 元组常量里含 "model"。"""
    for node in ast.walk(tree):
        # 既要认裸赋值（Assign）也要认带类型注解的（AnnAssign，
        # 现行代码是 `_STATE_DICT_KEYS: Tuple[str, ...] = (...)`）
        targets: list[ast.expr] = []
        value: ast.expr | None = None
        if isinstance(node, ast.Assign):
            targets, value = list(node.targets), node.value
        elif isinstance(node, ast.AnnAssign):
            targets, value = ([node.target] if node.target else []), node.value
        if value is None:
            continue
        for target in targets:
            if isinstance(target, ast.Name) and target.id == "_STATE_DICT_KEYS":
                elts = getattr(value, "elts", None)
                if elts is None:
                    _fail("_STATE_DICT_KEYS 不是元组字面量（赋值右侧无 elts）")
                    return False
                keys = [e.value for e in elts
                        if isinstance(e, ast.Constant) and isinstance(e.value, str)]
                if "model" in keys:
                    return True
                _fail(f"_STATE_DICT_KEYS={keys} 不含 \"model\"（train_v3.py 的存档键），"
                      f"export_coreml 会认不出训练存档")
                return False
    _fail("src/model_v3.py 里找不到模块级 _STATE_DICT_KEYS 赋值")
    return False


def check_export_strict(tree: ast.Module) -> bool:
    """断言 2：export_coreml 函数体里存在 strict=True 的 load_state_dict 调用。"""
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == "export_coreml":
            for sub in ast.walk(node):
                if isinstance(sub, ast.Call):
                    func = sub.func
                    name = getattr(func, "attr", None) or getattr(func, "id", "")
                    if name != "load_state_dict":
                        continue
                    for kw in sub.keywords:
                        if kw.arg == "strict" and isinstance(kw.value, ast.Constant) \
                                and kw.value.value is True:
                            return True
            _fail("export_coreml 里找不到 strict=True 的 load_state_dict —— "
                  "默认路径必须 strict，否则回到「零权重静默导出」")
            return False
    _fail("src/model_v3.py 里找不到 export_coreml 函数定义")
    return False


def check_train_save_key(tree: ast.Module) -> bool:
    """断言 3：train_v3.py 的 torch.save 字面量含 "model" 键。"""
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        # 只认 torch.save(...)；train_v3.py 全仓唯一存档路径
        if not (isinstance(func, ast.Attribute) and func.attr == "save"
                and isinstance(func.value, ast.Name) and func.value.id == "torch"):
            continue
        if not node.args:
            continue
        first = node.args[0]
        if isinstance(first, ast.Dict):
            for key in first.keys:
                if isinstance(key, ast.Constant) and key.value == "model":
                    return True
            _fail("train_v3.py 的 torch.save 字面量不含 \"model\" 键 —— "
                  "云端历史 checkpoint 全按此键存，改键即毁存档；"
                  "若确要改键，必须同步改 _STATE_DICT_KEYS 顺序并迁移存档")
            return False
    _fail("src/train_v3.py 里找不到 torch.save 的 dict 字面量调用")
    return False


def main() -> int:
    results: list[tuple[str, bool]] = []
    for path, checker, desc in (
        (MODEL_V3, check_state_dict_keys, "断言1 _STATE_DICT_KEYS 含 \"model\""),
        (MODEL_V3, check_export_strict, "断言2 export_coreml 存在 strict=True"),
        (TRAIN_V3, check_train_save_key, "断言3 train_v3 torch.save 含 \"model\" 键"),
    ):
        try:
            tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        except (OSError, SyntaxError) as e:  # 文件读不了/解析不了：明确报哪条断言断了
            _fail(f"{desc}：读/解析 {path} 失败：{e!r}")
            results.append((desc, False))
            continue
        ok = checker(tree)
        results.append((desc, ok))
        if ok:
            print(f"PASS {desc}")

    failed = [desc for desc, ok in results if not ok]
    if failed:
        print(f"\n共 {len(failed)}/{len(results)} 条断言失败：")
        for desc in failed:
            print(f"  ✗ {desc}")
        return 1
    print(f"\n全部 {len(results)} 条断言通过。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
