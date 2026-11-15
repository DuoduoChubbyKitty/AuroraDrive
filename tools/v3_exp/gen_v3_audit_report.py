#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 V3 INT4 部署**审计**报告 —— 严格门禁版（评审 P0-B / P1-D 全面整改）。

与旧版的本质区别（旧版会给不存在的模型/崩溃的测试打印"全部通过"）：
  1. 保留并校验每个子进程的**退出码**；不足/崩溃/无断言一律判 failed，绝不假通过。
  2. 重新测量部署模型的体积/LUT/**契约**（从 model.mil 的 func main 签名真实解析，不硬编码）。
  3. 交叉校验「实测模型内容指纹」与「部署时记录的内容指纹」，不一致即 failed。
  4. 一次运行生成**两份**报告（Markdown + SMOKE txt），数据同源，消除口径不一致。
  5. 记录源码快照（git HEAD + 关键文件哈希 + dirty 状态）、Swift 二进制哈希、模型完整 sha。
  6. 任一门禁失败 → 报告照常生成但明确标 failed/unverified，且**退出码非 0**（可作发布门禁）。

用法：
  /usr/local/bin/python3.11 tools/v3_exp/gen_v3_audit_report.py
输出：
  models/V3_INT4_AUDIT_REPORT.md
  models/V3_INT4_SMOKE_TEST_REPORT.txt
退出码：0 审计通过；1 审计未通过（build/eval/selftest/contract/指纹任一门禁失败或数据缺失）。
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CALIB = REPO / "models" / "calibration_report.json"
MODELC = REPO / "models" / "v3_int4.mlmodelc"
SELFTEST_BIN = REPO / ".build" / "scratch" / "release" / "AuroraDrive"
CONTRACT = REPO / "tools" / "v3_contract_test.py"
OUT_MD = REPO / "models" / "V3_INT4_AUDIT_REPORT.md"
OUT_TXT = REPO / "models" / "V3_INT4_SMOKE_TEST_REPORT.txt"
EXPORT_SCRIPT = REPO / "tools" / "v3_exp" / "export_v3_checkpoint_int4.py"
SELFTEST_SWIFT = REPO / "Sources" / "AuroraDrive" / "Inference" / "V3EngineSelfTest.swift"

sys.path.insert(0, str(Path(__file__).resolve().parent))
from export_v3_checkpoint_int4 import (  # noqa: E402
    modelc_content_sha, modelc_full_sha, sha256_of, REQUIRED_MODELC_FILES)

EXPECTED_INPUTS = ["image_hi", "image_lo", "lane", "dets", "det_mask", "vehicle_state"]
EXPECTED_OUTPUTS = ["vertical", "horizontal", "handbrake", "brake",
                    "super_brake", "ultimate", "confidence", "risk"]


def dir_mb(p: Path) -> float:
    if not p.is_dir():
        return 0.0
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file()) / (1024 * 1024)


def run(cmd: list, timeout=300):
    """返回 (输出文本, 退出码)。超时视为失败（rc=-1）。"""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           cwd=str(REPO), env={**__import__("os").environ, "PYTHONPATH": str(REPO)})
        return r.stdout + r.stderr, r.returncode
    except subprocess.TimeoutExpired as exc:
        return f"[TIMEOUT] {exc}", -1
    except Exception as exc:  # 文件不存在/不可执行等
        return f"[RUN-ERROR] {type(exc).__name__}: {exc}", -1


def git(*args) -> str:
    try:
        return subprocess.check_output(["git", "-C", str(REPO), *args], text=True,
                                       stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""


def source_snapshot() -> dict:
    status = git("status", "--porcelain")
    return {
        "git_head": git("rev-parse", "HEAD") or "unknown",
        "git_dirty": bool(status),
        "git_status_sha256": sha256_of_text(status) if status else sha256_of_text(""),
        "export_script_sha256": sha256_of(EXPORT_SCRIPT) if EXPORT_SCRIPT.exists() else "missing",
        "selftest_swift_sha256": sha256_of(SELFTEST_SWIFT) if SELFTEST_SWIFT.exists() else "missing",
        "selftest_bin_sha256": sha256_of(SELFTEST_BIN) if SELFTEST_BIN.exists() else "missing",
    }


def sha256_of_text(s: str) -> str:
    import hashlib
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


EXPECTED_INPUT_SIGNATURES = {
    "image_hi": "fp16, [1, 3, 3, 224, 384]",
    "image_lo": "fp16, [1, 21, 3, 112, 192]",
    "lane": "fp16, [1, 1, 160, 160]",
    "dets": "fp16, [1, 20, 12]",
    "det_mask": "fp16, [1, 20]",
    "vehicle_state": "fp16, [1, 8]",
}


def parse_model_contract(modelc: Path) -> dict:
    """从 model.mil 的 `func main(...)` 签名**严格**解析并核对 6 输入/8 输出的名称、形状、dtype。

    评审 P0-B（第 2 次）：旧实现过滤掉未知输入、只比名称，导致「输入全改 int32[99] 再加第七个输入」
    仍判 inputs_ok=True。这里：
      · 捕获**每一个**输入参数（不过滤），逐一核对 (名称, dtype=fp16, shape)；
      · 输入数量必须正好 6、名称集合必须精确等于期望；
      · 输出必须正好 8 路且有序。
    任一不符即 ok=False（并在报告中列出差异）。
    """
    mil = modelc / "model.mil"
    if not mil.is_file():
        raise RuntimeError("model.mil 不存在，无法解析契约")
    txt = mil.read_text(encoding="utf-8", errors="ignore")
    m = re.search(r"func main<[^>]*>\((.*?)\)\s*\{", txt, re.S)
    if not m:
        raise RuntimeError("model.mil 中未找到 func main 签名")
    params = m.group(1)
    # 捕获完整 "tensor<dtype, [shape]>" + 变量名（不过滤）
    raw_inputs = [(x.group(1), x.group(2)) for x in
                  re.finditer(r"tensor<([^>]*)>\s+([A-Za-z_][A-Za-z0-9_]*)", params)]
    # 反过来：raw_inputs 是 [(sig, name)]
    sig_by_name = {name: sig.strip() for (sig, name) in raw_inputs}
    r = re.search(r"\}\s*->\s*\((.*?)\)\s*;", txt, re.S)
    if not r:
        raise RuntimeError("model.mil 中未找到 main 的返回签名")
    outputs = [x.strip() for x in r.group(1).split(",") if x.strip()]

    input_names = sorted(sig_by_name.keys())
    input_diffs = []
    # 数量与名称集合精确匹配
    if len(sig_by_name) != len(EXPECTED_INPUT_SIGNATURES):
        input_diffs.append(f"输入数量 {len(sig_by_name)} != {len(EXPECTED_INPUT_SIGNATURES)}")
    if set(sig_by_name.keys()) != set(EXPECTED_INPUT_SIGNATURES.keys()):
        extra = set(sig_by_name) - set(EXPECTED_INPUT_SIGNATURES)
        miss = set(EXPECTED_INPUT_SIGNATURES) - set(sig_by_name)
        input_diffs.append(f"额外输入={sorted(extra)} 缺失输入={sorted(miss)}")
    # 逐个核对 (dtype=fp16, shape)
    for nm, exp in EXPECTED_INPUT_SIGNATURES.items():
        got = sig_by_name.get(nm)
        if got is None:
            continue
        if got != exp:
            input_diffs.append(f"{nm} 签名 '{got}' != 期望 '{exp}'")
    inputs_ok = not input_diffs
    outputs_ok = outputs == EXPECTED_OUTPUTS
    return {
        "lut_ops": txt.count("constexpr_lut_to_dense"),
        "inputs": input_names,
        "outputs": outputs,
        "input_diffs": input_diffs,
        "inputs_ok": inputs_ok,
        "outputs_ok": outputs_ok,
    }


def parse_selftest(txt: str):
    m = re.search(r"V3 引擎自检：(\d+)/(\d+) 通过", txt)
    if not m:
        return {"pass": None, "total": None, "fail_lines": [], "parsed": False}
    fails = [ln.strip() for ln in txt.splitlines() if "✗" in ln and "枚举失败" not in ln]
    return {"pass": int(m.group(1)), "total": int(m.group(2)), "fail_lines": fails, "parsed": True}


def main() -> int:
    gates: list = []  # (名称, 通过?, 说明)
    calib = {}
    if CALIB.exists():
        try:
            calib = json.loads(CALIB.read_text(encoding="utf-8"))
        except Exception as exc:
            gates.append(("calibration_report.json 可解析", False, f"{type(exc).__name__}: {exc}"))
    else:
        gates.append(("calibration_report.json 存在", False, f"缺少 {CALIB}"))

    # ── 模型结构 & 契约 ──
    contract = None
    modelc_present = MODELC.is_dir()
    gates.append(("部署模型目录存在", modelc_present, str(MODELC)))
    if modelc_present:
        missing = [n for n in REQUIRED_MODELC_FILES if not (MODELC / n).is_file()]
        gates.append(("部署模型必需文件齐全", not missing, f"缺 {missing}" if missing else "OK"))
        try:
            contract = parse_model_contract(MODELC)
            gates.append(("契约：输入 6 路名称/形状/dtype 全符", contract["inputs_ok"],
                          "OK" if contract["inputs_ok"] else f"差异={contract['input_diffs']}"))
            gates.append(("契约：输出 8 路有序一致", contract["outputs_ok"], str(contract["outputs"])))
            gates.append(("LUT 算子数 > 0", (contract["lut_ops"] or 0) > 0, str(contract["lut_ops"])))
        except Exception as exc:
            gates.append(("契约可解析", False, f"{type(exc).__name__}: {exc}"))

    # ── 指纹交叉校验（内容指纹 + 完整目录哈希都必须匹配）──
    measured_content = None
    measured_full = None
    if modelc_present:
        try:
            measured_content = modelc_content_sha(MODELC)
            measured_full = modelc_full_sha(MODELC)
        except Exception as exc:
            gates.append(("模型指纹可计算", False, f"{type(exc).__name__}: {exc}"))
    recorded = calib.get("deployed_modelc_content_sha256")
    if measured_content is not None and recorded:
        gates.append(("实测内容指纹 == 部署记录", measured_content == recorded,
                      f"实测 {measured_content[:16]}… vs 记录 {str(recorded)[:16]}…"))
    elif measured_content is not None:
        gates.append(("部署记录含有内容指纹", False, "calibration 未记录 deployed_modelc_content_sha256"))
    # 完整目录哈希（评审 P0-B：WRONG 完整哈希仍 PASSED 的漏洞）
    recorded_full = calib.get("deployed_modelc_full_sha256")
    if measured_full is not None:
        if recorded_full:
            gates.append(("实测完整目录哈希 == 部署记录", measured_full == recorded_full,
                          f"实测 {measured_full[:16]}… vs 记录 {str(recorded_full)[:16]}…"))
        else:
            gates.append(("部署记录含有完整目录哈希", False, "calibration 未记录 deployed_modelc_full_sha256"))

    # ── 评估证据完整性（评审 P0-B：缺 drift / drift.status=failed 仍 PASSED 的漏洞）──
    drift = calib.get("drift") if isinstance(calib.get("drift"), dict) else None
    eval_status = calib.get("eval_status", "unknown")
    deploy_status = calib.get("deploy_status", "unknown")
    gates.append(("存在 drift 评估证据", drift is not None, "有" if drift else "缺失 drift"))
    drift_status_ok = bool(drift) and drift.get("status") == "passed"
    gates.append(("drift.status == passed", drift_status_ok,
                  f"drift.status={drift.get('status') if drift else 'N/A'}"
                  + (f" reasons={drift.get('reasons')}" if drift and drift.get('reasons') else "")))
    gates.append(("顶层 eval_status == passed", eval_status == "passed", f"eval_status={eval_status}"))
    # 部署门禁：必须明确 deployed（不再允许 unknown 跳过）
    gates.append(("deploy_status == deployed", deploy_status == "deployed", f"deploy_status={deploy_status}"))

    # ── 自检 & 契约实测 ──
    st_txt, st_rc = run([str(SELFTEST_BIN), "--v3-selftest"]) if SELFTEST_BIN.exists() else ("[缺二进制]", -1)
    st = parse_selftest(st_txt)
    selftest_ok = (st["parsed"] and st_rc == 0 and st["pass"] == st["total"]
                   and (st["total"] or 0) > 0 and not st["fail_lines"])
    gates.append(("v3-selftest 全通过且退出 0", selftest_ok,
                  f"{st['pass']}/{st['total']} rc={st_rc} 失败项={len(st['fail_lines'])}"))

    ct_txt, ct_rc = run([sys.executable, str(CONTRACT)]) if CONTRACT.exists() else ("[缺脚本]", -1)
    ct_pass = len(re.findall(r"✅", ct_txt))
    ct_fail = len(re.findall(r"❌|✗", ct_txt))
    contract_ok = ct_rc == 0 and ct_fail == 0 and ct_pass > 0
    gates.append(("contract_test 通过/退出0/有断言", contract_ok,
                  f"pass={ct_pass} fail={ct_fail} rc={ct_rc}"))

    overall_ok = all(g[1] for g in gates)
    overall = "PASSED" if overall_ok else "FAILED/UNVERIFIED"

    snap = source_snapshot()
    drift = calib.get("drift", {}) if isinstance(calib.get("drift"), dict) else {}
    size_mb = round(dir_mb(MODELC), 3)

    # ── 写 Markdown ──
    md = []
    A = md.append
    A("# V3 INT4 部署审计报告")
    A("")
    A(f"> 由 `tools/v3_exp/gen_v3_audit_report.py` 于 {time.strftime('%Y-%m-%d %H:%M:%S')} 自动生成。")
    A(f"> **总判定：{overall}**（任一门禁失败即 FAILED，且脚本退出码非 0）")
    A("")
    A("## 一、门禁结果")
    A("")
    A("| 门禁 | 结果 | 说明 |")
    A("|---|---|---|")
    for name, ok, note in gates:
        A(f"| {name} | {'✅' if ok else '❌'} | {note} |")
    A("")
    A("## 二、交付绑定（来源可追溯）")
    A("")
    A("| 项 | 值 |")
    A("|---|---|")
    A(f"| git HEAD | `{snap['git_head']}` |")
    A(f"| git 工作树 dirty | {snap['git_dirty']}（status sha256 `{snap['git_status_sha256'][:12]}…`）|")
    A(f"| 导出脚本 sha256 | `{snap['export_script_sha256'][:16]}…` |")
    A(f"| 自检 Swift 源码 sha256 | `{snap['selftest_swift_sha256'][:16]}…` |")
    A(f"| 自检二进制 sha256 | `{snap['selftest_bin_sha256'][:16]}…` |")
    A(f"| checkpoint | `{Path(calib.get('ckpt','?')).name}` (sha256 `{str(calib.get('ckpt_sha256','?'))[:16]}…`) |")
    A(f"| 量化方案 | `{calib.get('scheme','?')}`（保护算子 {calib.get('scheme_protected_ops','?')}）|")
    A(f"| 部署模型体积(实测) | {size_mb} MiB |")
    A(f"| 部署模型内容指纹(实测) | `{(measured_content or 'N/A')[:16]}…` |")
    A(f"| 部署模型完整目录 sha(实测) | `{(measured_full or 'N/A')[:16]}…` |")
    A(f"| 部署记录内容指纹 | `{str(recorded or 'N/A')[:16]}…` |")
    if contract:
        A(f"| LUT 算子(实测 model.mil) | {contract['lut_ops']} |")
        A(f"| 输入(实测) | {contract['inputs']} |")
        A(f"| 输出(实测) | {contract['outputs']} |")
    A(f"| 评估数据 | `{drift.get('data',{}).get('source','?')}` data_sha256 `{str(drift.get('data',{}).get('data_sha256','?'))[:12]}…` |")
    A(f"| 评估分片 | {drift.get('data',{}).get('val_clips','?')} |")
    A("")
    A("## 三、验收数据")
    A("")
    A(f"- eval_status={eval_status}  deploy_status={deploy_status}")
    if isinstance(drift, dict) and drift:
        A(f"- 样本数：{drift.get('n_samples','?')}（下限 {drift.get('thresholds',{}).get('min_calib_samples','?')}）")
        A(f"- 安全动作项最低决策一致率：{drift.get('min_safe_decision_agreement',0)*100:.2f}%"
          f"（Wilson 下界见下表）")
        A(f"- 转换保真：动作最低一致 {drift.get('min_safe_convert_agreement',0)*100:.1f}%，"
          f"confidence 转换误差 {drift.get('confidence_convert_err',0):.4f}")
        A(f"- 量化影响：confidence 概率误差 {drift.get('confidence_quant_err',0):.4f}，"
          f"risk 概率误差 {drift.get('risk_quant_err',0):.4f}（仅告警）")
        for r in drift.get("reasons", []) or []:
            A(f"  - ❌ {r}")
        for w in drift.get("warnings", []) or []:
            A(f"  - ⚠ {w}")
        A("")
        A("| 输出 | 决策一致率 | 95% CI（下界） | 翻转数 | 翻转裕度 |")
        A("|---|---|---|---|---|")
        for name, po in (drift.get("per_output", {}) or {}).items():
            ci = po.get("agreement_ci95", ["?", "?"])
            mg = drift.get("flip_margins", {}).get(name, [])
            A(f"| {name} | {po.get('decision_agreement',0)*100:.1f}% | 下界 {ci[0]} | "
              f"{po.get('n_flip','?')} | {[round(x,3) for x in mg[:4]]} |")
    A("")
    A("## 四、自检与契约（实测运行）")
    A("")
    A(f"- `--v3-selftest`：**{st['pass']}/{st['total']} 通过**，退出码 {st_rc}"
      + (f"，失败项：{st['fail_lines']}" if st["fail_lines"] else "，无失败项"))
    A(f"- `tools/v3_contract_test.py`：通过 {ct_pass} / 失败 {ct_fail}，退出码 {ct_rc}")
    A("")
    A("## 五、复现命令")
    A("")
    A("```bash")
    A("/usr/local/bin/python3.11 tools/v3_exp/export_v3_checkpoint_int4.py \\")
    A(f"  --stage all --scheme {calib.get('scheme','protect_backbone')} --val-clips --n-calib 128 \\")
    A("  --modelc models/v3_int4.mlmodelc")
    A("/usr/local/bin/python3.11 tools/v3_exp/gen_v3_audit_report.py")
    A("```")
    OUT_MD.write_text("\n".join(md) + "\n", encoding="utf-8")

    # ── 写 SMOKE txt（同源数据，同一 size_mb，消除口径不一致）──
    tx = []
    T = tx.append
    T("=" * 72)
    T(f"V3 INT4 部署冒烟/验收汇总 —— 总判定 {overall}")
    T("=" * 72)
    T(f"模型: models/v3_int4.mlmodelc（scheme={calib.get('scheme')}，保护算子 {calib.get('scheme_protected_ops')}）")
    T(f"体积(实测目录): {size_mb} MiB   LUT: {contract['lut_ops'] if contract else 'N/A'}")
    T(f"内容指纹(实测): {(measured_content or 'N/A')[:16]}…   记录: {str(recorded or 'N/A')[:16]}…")
    T(f"checkpoint: {Path(calib.get('ckpt','?')).name}  sha {str(calib.get('ckpt_sha256','?'))[:12]}…")
    T(f"git HEAD: {snap['git_head']}  dirty={snap['git_dirty']}")
    T("-" * 72)
    T(f"eval_status={eval_status}  deploy_status={deploy_status}")
    if isinstance(drift, dict) and drift:
        T(f"样本数={drift.get('n_samples')} 来源={drift.get('data',{}).get('source')} 分片={drift.get('data',{}).get('val_clips')}")
        T(f"安全动作最低一致率={drift.get('min_safe_decision_agreement',0)*100:.2f}%  "
          f"转换动作最低一致={drift.get('min_safe_convert_agreement',0)*100:.1f}%")
        T(f"confidence 量化误差={drift.get('confidence_quant_err',0):.4f}  risk 误差={drift.get('risk_quant_err',0):.4f}(告警)")
    T(f"--v3-selftest: {st['pass']}/{st['total']}（退出 {st_rc}）")
    T(f"v3_contract_test.py: 通过 {ct_pass} / 失败 {ct_fail}（退出 {ct_rc}）")
    T("-" * 72)
    T("门禁明细:")
    for name, ok, note in gates:
        T(f"  [{'OK' if ok else 'FAIL'}] {name} — {note}")
    T("=" * 72)
    OUT_TXT.write_text("\n".join(tx) + "\n", encoding="utf-8")

    print(f"[done] 审计报告 → {OUT_MD}")
    print(f"[done] 冒烟报告 → {OUT_TXT}")
    print(f"       总判定={overall}  selftest={st['pass']}/{st['total']}(rc{st_rc})  "
          f"contract={ct_pass}/{ct_pass+ct_fail}(rc{ct_rc})  指纹匹配={measured_content == recorded}")
    failed = [g[0] for g in gates if not g[1]]
    if failed:
        print(f"       ❌ 未通过门禁: {failed}")
    return 0 if overall_ok else 1


if __name__ == "__main__":
    sys.exit(main())
