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


#: 安全动作头：这些头的"非边界翻转"视为不可接受的量化退化。
SAFETY_HEADS = ("vertical", "horizontal", "handbrake", "brake", "super_brake", "ultimate")
#: fp16 侧 |logit|（二分类）或 top1-top2（三分类）>= 此值时视为"高置信/非边界"：
#: 此时被 INT4 翻转说明量化把明确决策改错，属真退化（不是边界噪声）。
NON_BOUNDARY_MARGIN = 0.6


def _load_accepted_risk() -> dict:
    """读取用户签字记录的**结构化**豁免（绑定模型指纹+数据指纹+具体 head/shard/frame）。"""
    import re as _re
    p = Path(__file__).resolve().parents[2] / "models" / "V3_RESIDUAL_RISK_ACCEPT.md"
    if not p.is_file():
        return {}
    txt = p.read_text(encoding="utf-8", errors="ignore")
    m = _re.search(r"```json\s*(\{.*?\})\s*```", txt, _re.S)
    if not m:
        return {}
    try:
        return json.loads(m.group(1))
    except Exception:
        return {}


def _finite(x) -> bool:
    import math
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)


def verify_drift(drift, accepted: dict = None, measured_content_sha: str = "") -> tuple:
    """按指标 schema + 阈值**全字段严格重算** drift（评审 R4 P0#1/P1#2）。

    · 所有数值必须**有限**，误差/漂移必须**非负**，一致率必须 ∈[0,1]；
    · 转换一致率**严格 == 1.0**（不接受 >1 或 <1）；
    · 逐头报告结构：八路都必须有 per_output（含 confidence/risk）；
    · 翻转索引必须对齐 data.per_sample 的 shard/frame；
    · 非边界翻转：默认 FAIL，仅当 (model+data 指纹匹配) 且 (head,shard,frame,direction) 精确命中签署
      记录时降级 WARN；方向必须匹配签字的 false→true。
    返回 (ok, 说明)。
    """
    accepted = accepted or {}
    if not isinstance(drift, dict):
        return False, "drift 缺失或非 dict"
    problems, warns = [], []
    for key in ("per_output", "flip_margins", "thresholds", "n_samples", "data",
                "min_safe_decision_agreement", "min_safe_convert_agreement",
                "confidence_quant_err", "confidence_convert_err", "worst_convert_drift"):
        if key not in drift:
            problems.append(f"缺 {key}")
    if problems:
        return False, "schema 不全: " + ", ".join(problems)
    thr = drift["thresholds"]
    need_thr = ("min_safe_agreement", "max_convert_prob_err", "max_quant_conf_err",
                "gross_logit_drift", "min_calib_samples")
    if not isinstance(thr, dict) or [k for k in need_thr if not _finite(thr.get(k))]:
        return False, f"thresholds 非有限/缺失: {[k for k in need_thr if not (isinstance(thr,dict) and _finite(thr.get(k)))]}"
    min_safe = float(thr["min_safe_agreement"]); max_conf = float(thr["max_quant_conf_err"])
    max_conv_prob = float(thr["max_convert_prob_err"]); gross = float(thr["gross_logit_drift"])
    min_calib = float(thr["min_calib_samples"])
    if not (0 < min_safe <= 1 and max_conf > 0 and max_conv_prob >= 0 and gross > 0 and min_calib > 0):
        problems.append("阈值范围非法")
    n = drift.get("n_samples")
    if not (isinstance(n, int) and not isinstance(n, bool) and n > 0):
        problems.append(f"n_samples 非正整数: {n!r}"); n = None
    if n is not None and n < min_calib:
        problems.append(f"n_samples={n} < min_calib")
    data = drift.get("data") or {}
    per_sample = data.get("per_sample") if isinstance(data, dict) else None
    if not isinstance(per_sample, list) or (n is not None and len(per_sample) != n):
        problems.append(f"data.per_sample 缺失或长度≠n")
    if not isinstance(data, dict) or len(str(data.get("data_sha256", ""))) < 16:
        problems.append("缺 data.data_sha256")

    # 误差/漂移必须非负且有限
    for key in ("confidence_quant_err", "confidence_convert_err", "worst_convert_drift"):
        v = drift.get(key)
        if not _finite(v) or v < 0:
            problems.append(f"{key}={v!r} 非有限或为负")

    per = drift.get("per_output") or {}
    flips = drift.get("flip_margins") or {}
    # 八路结构必须齐全（含 confidence/risk）
    REPORT_HEADS = SAFETY_HEADS + ("confidence", "risk")
    for h in REPORT_HEADS:
        if not isinstance(per.get(h), dict):
            problems.append(f"缺 per_output.{h}")
    acc_model = accepted.get("model_content_sha", "")
    acc_data = accepted.get("data_sha256", "")
    acc_list = accepted.get("accepted", []) if isinstance(accepted.get("accepted"), list) else []
    acc_set = {(a.get("head"), a.get("shard"), a.get("frame"), a.get("direction"))
               for a in acc_list if isinstance(a, dict)}
    acc_active = bool(acc_model and measured_content_sha and acc_model == measured_content_sha
                      and acc_data and acc_data == data.get("data_sha256"))
    if acc_list and not acc_active:
        warns.append("签字记录存在但模型/数据指纹不匹配→本轮不生效")

    das = []
    for head in SAFETY_HEADS:
        po = per.get(head) or {}
        da = po.get("decision_agreement")
        if not _finite(da) or not (0 <= da <= 1):
            problems.append(f"{head}.decision_agreement 非法 {da!r}")
        else:
            das.append(float(da))
            if da < min_safe:
                problems.append(f"{head} 一致率 {da:.4f}<{min_safe}")
        nf = po.get("n_flip"); fids = po.get("flip_ids"); mags = flips.get(head)
        if not (isinstance(nf, int) and not isinstance(nf, bool) and nf >= 0):
            problems.append(f"{head}.n_flip 非法 {nf!r}"); nf = None
        if not isinstance(fids, list) or not isinstance(mags, list):
            problems.append(f"{head} flip_ids/flip_margins 非列表"); continue
        if nf is not None and not (len(fids) == len(mags) == nf):
            problems.append(f"{head} n_flip({nf})≠flip_ids({len(fids)})≠margins({len(mags)})")
        if _finite(da) and nf is not None and n:
            if abs((1.0 - da) - nf / n) > 0.5 / n:
                problems.append(f"{head} 一致率与 n_flip/n 不自洽")
        for j, m in enumerate(mags):
            if not _finite(m):
                problems.append(f"{head} 翻转裕度非有限"); continue
            fd = fids[j] if j < len(fids) else {}
            # 索引必须对齐 per_sample
            if isinstance(fd, dict) and isinstance(per_sample, list):
                idx = fd.get("idx")
                if not (isinstance(idx, int) and 0 <= idx < len(per_sample)):
                    problems.append(f"{head} 翻转 idx={idx} 越界 data.per_sample")
                else:
                    ps = per_sample[idx]
                    if ps.get("shard") != fd.get("shard") or ps.get("frame") != fd.get("frame"):
                        problems.append(f"{head} 翻转 shard/frame 与 per_sample[{idx}] 不符")
            # 方向必须由决策字段重建并核对（评审 R5 P1：防止伪造 direction 骗过豁免）
            fpd = fd.get("fp16_decision") if isinstance(fd, dict) else None
            itd = fd.get("int4_decision") if isinstance(fd, dict) else None
            dirn = fd.get("direction") if isinstance(fd, dict) else None
            dom = {"0", "1", "2"} if head in ("vertical", "horizontal") else {"true", "false"}
            if fpd not in dom or itd not in dom:
                problems.append(f"{head} 翻转决策字段缺失/越域 fp16={fpd!r} int4={itd!r}")
            elif fpd == itd:
                problems.append(f"{head} 翻转两端决策相同({fpd})→并非真实翻转")
            else:
                rebuilt = f"{fpd}→{itd}"
                if dirn != rebuilt:
                    problems.append(f"{head} direction={dirn!r} 与决策重建 {rebuilt!r} 不符")
            if abs(float(m)) >= NON_BOUNDARY_MARGIN:
                key = (head, fd.get("shard") if isinstance(fd, dict) else None,
                       fd.get("frame") if isinstance(fd, dict) else None,
                       dirn)
                if acc_active and key in acc_set and dirn == f"{fpd}→{itd}":
                    warns.append(f"{head} 非边界翻转({fd.get('shard')}#{fd.get('frame')},{dirn},裕度{abs(float(m)):.3f})已签字接受")
                else:
                    problems.append(f"{head} 非边界翻转(裕度{abs(float(m)):.3f})不可接受(方向/样本未签署)")
    if das:
        if not _finite(drift.get("min_safe_decision_agreement")) or abs(float(drift["min_safe_decision_agreement"]) - min(das)) > 1e-6:
            problems.append("min_safe_decision_agreement 与逐头最小不符")

    # 转换保真（硬，严格 ==1）
    mc = drift.get("min_safe_convert_agreement")
    if not _finite(mc) or mc != 1.0:
        problems.append(f"min_safe_convert_agreement={mc!r} !=1.0")
    for head in SAFETY_HEADS:
        ca = (per.get(head) or {}).get("convert_agreement")
        if not _finite(ca) or ca != 1.0:
            problems.append(f"{head}.convert_agreement={ca!r} !=1.0")
    wc = drift.get("worst_convert_drift")
    if not _finite(wc) or wc < 0 or wc > gross:
        problems.append(f"worst_convert_drift={wc!r} 越界")
    cconv = drift.get("confidence_convert_err")
    if not _finite(cconv) or cconv < 0 or cconv > max_conv_prob:
        problems.append(f"confidence_convert_err={cconv!r} 越界")
    cq = drift.get("confidence_quant_err")
    if not _finite(cq) or cq < 0 or cq > max_conf:
        problems.append(f"confidence_quant_err={cq!r} 越界")
    if drift.get("reasons"):
        problems.append(f"reasons 非空={list(drift['reasons'])[:2]}")

    ok = not problems
    if ok:
        note = "OK" + ("（" + "；".join(warns) + "）" if warns else "")
    else:
        note = "；".join(problems[:6]) + ("（另：" + "；".join(warns) + "）" if warns else "")
    return ok, note


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

    # ── 评估证据完整性（评审 P0-B/P0#1：不信任 status 字符串，按指标 schema 重算）──
    drift = calib.get("drift") if isinstance(calib.get("drift"), dict) else None
    eval_status = calib.get("eval_status", "unknown")
    deploy_status = calib.get("deploy_status", "unknown")
    gates.append(("存在 drift 评估证据", drift is not None, "有" if drift else "缺失 drift"))
    drift_ok, drift_note = verify_drift(drift, _load_accepted_risk(), measured_content or "")
    gates.append(("drift 指标 schema 完整且按阈值重算通过", drift_ok, drift_note))
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
