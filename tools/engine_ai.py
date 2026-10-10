#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
# SPDX-License-Identifier: GPL-3.0-or-later
"""engine_ai.py — AI / 脚本操作后台引擎的 CLI 客户端。

================================================================================
为什么要有这个文件
================================================================================
`AuroraDriveUI --engine` 是后台引擎进程，它监听一个 unix socket 接收命令。
此前只有 UI 能操作它（点按钮），AI/脚本没有**结构化**的操作入口 ——
本文件补上这个入口：发命令、拿回执、按条件等待、机器可读输出。

协议真相源：`Sources/AuroraDrive/Core/EngineMain.swift`
  · socket 路径：`~/Library/Application Support/AuroraDrive/engine.sock`（:721）
  · 协议：**一行一个 JSON**（服务端按 0x0A 切行，见 :542-548）
  · 服务端 → 客户端：心跳 `{"type":"heartbeat",...}`（:1119）、`{"type":"pong"}`
  · 客户端 → 服务端：见 `handleCommand`（:952-1109）

================================================================================
⚠️ 单客户端限制（必读）
================================================================================
引擎**只服务一个连接**：新连接会**踢掉旧连接**（`acceptClient` :509-533）。
所以：
  · 本 CLI 运行时，**UI 会被踢下线**；
  · UI 有 3 秒重连窗口（`startReconnectWindow` :1127），会自动连回来；
  · 因此本 CLI 的命令应当**短促、用完即断**（默认超时 5s），不要长驻。
  · 如果你在跑自动化，建议先停掉 UI，避免两边互相踢。

================================================================================
用法示例
================================================================================
    # 查询引擎状态（格式化 JSON）
    python3 tools/engine_ai.py state

    # 开始 / 停止驾驶
    python3 tools/engine_ai.py start
    python3 tools/engine_ai.py stop

    # 切换捕获源
    python3 tools/engine_ai.py capture fullscreen
    python3 tools/engine_ai.py capture window 12345

    # 录制开关（默认第一人称）
    python3 tools/engine_ai.py record on
    python3 tools/engine_ai.py record off
    python3 tools/engine_ai.py record on --perspective third

    # 等待条件满足（轮询 state），超时退出码 1
    python3 tools/engine_ai.py wait driving == true
    python3 tools/engine_ai.py wait frames '>' 100 --timeout 30

    # 发原始 JSON（调试用）
    python3 tools/engine_ai.py raw '{"type":"ping"}'

    # 机器可读输出（脚本消费）
    python3 tools/engine_ai.py --json state

    # 覆盖 socket 路径
    python3 tools/engine_ai.py --socket /tmp/other.sock state

退出码
    0  成功
    1  超时，或引擎回执 ok=false
    2  用法错误（含"本 CLI 不提供的功能"）

================================================================================
ack 回执与老引擎降级
================================================================================
新引擎（队友 A 加的）会对带 `id` 的命令回 `{"type":"ack","id":...,"cmd":...,
"ok":...,"detail":...,"data":{...}}`。本 CLI：
  1. **优先用 ack**：命令带 `id`，等匹配 id 的 ack；拿到 `ok=false` → 退出码 1。
  2. **老引擎优雅降级**：若在超时内**只收到心跳/pong、没有 ack**，说明引擎还没有
     ack 能力 → 打印警告、返回"未确认"（退出码 0，因为命令确实发出去了），
     **不死等**。用 `--json` 时会在输出里标 `"acknowledged": false`。

本文件只用标准库（json/socket/os/sys/time/argparse/uuid），不装任何依赖。
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time
import uuid

DEFAULT_SOCKET = os.path.expanduser(
    "~/Library/Application Support/AuroraDrive/engine.sock")
DEFAULT_TIMEOUT = 5.0

# 退出码（与任务约定一致）
EXIT_OK = 0
EXIT_TIMEOUT = 1
EXIT_USAGE = 2


class EngineError(Exception):
    """带退出码的 CLI 错误。"""

    def __init__(self, message: str, code: int = EXIT_USAGE):
        super().__init__(message)
        self.code = code


# ---------------------------------------------------------------------------
# socket 传输
# ---------------------------------------------------------------------------

class EngineClient:
    """一条到引擎的短连接。

    用法：
        with EngineClient(path, timeout) as c:
            reply = c.command({"type": "state"}, wait_ack=True)

    设计：每次命令**新建连接**（引擎单客户端，长驻会占着 UI 的坑）。
    """

    def __init__(self, path: str = DEFAULT_SOCKET, timeout: float = DEFAULT_TIMEOUT,
                 verbose: bool = False, ack_grace: float = 1.2):
        self.path = path
        self.timeout = timeout
        self.verbose = verbose
        #: 收到首个心跳后，额外等 ack 的宽限期（秒）。
        #: 取 1.2s > 心跳周期 1s，足以覆盖"心跳先到、ack 后到"的竞态。
        self.ack_grace = ack_grace
        self.sock: socket.socket | None = None
        self._buf = b""
        # 收到的非 ack 消息（心跳/pong），供降级判断与诊断
        self.seen_heartbeats: list[dict] = []
        self.last_heartbeat: dict | None = None
        # 每次 command 内重置的收集器
        self._stray_acks: list[dict] = []
        self._others: list[dict] = []
        self._saw_any_ack = False

    # -- 连接 ---------------------------------------------------------------
    def connect(self) -> None:
        """建立连接。失败时给出**具体**原因（路径不存在 vs 拒绝连接）。"""
        if not os.path.exists(self.path):
            raise EngineError(
                f"socket 路径不存在：{self.path}\n"
                f"  → 引擎未运行？启动方式：./AuroraDriveUI（或 ./AuroraDriveUI --engine）\n"
                f"  → 若引擎在跑，用 --socket PATH 指定其它路径",
                EXIT_USAGE)
        if not os.path.isdir(os.path.dirname(self.path)):
            raise EngineError(f"socket 所在目录不存在：{os.path.dirname(self.path)}", EXIT_USAGE)

        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        try:
            s.connect(self.path)
        except ConnectionRefusedError as e:
            s.close()
            raise EngineError(
                f"连接被拒绝（socket 文件存在但没有进程监听）：{self.path}\n"
                f"  → 引擎可能刚退出，socket 文件是残留。\n"
                f"  → 删掉残留文件后重启引擎：rm -f '{self.path}'",
                EXIT_USAGE) from e
        except PermissionError as e:
            s.close()
            raise EngineError(
                f"权限不足，无法连接：{self.path}\n"
                f"  → 引擎 socket 是 0600，需与引擎同用户运行。", EXIT_USAGE) from e
        except OSError as e:
            s.close()
            raise EngineError(f"连接失败：{self.path} → {e}", EXIT_USAGE) from e
        self.sock = s

    def close(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None

    def __enter__(self) -> "EngineClient":
        self.connect()
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    # -- 收发 ---------------------------------------------------------------
    def send_json(self, payload: dict) -> None:
        assert self.sock is not None
        line = json.dumps(payload, ensure_ascii=False) + "\n"
        if self.verbose:
            print(f"[engine_ai] → {line.rstrip()}", file=sys.stderr)
        try:
            self.sock.sendall(line.encode("utf-8"))
        except BrokenPipeError as e:
            # 引擎把我们踢了（单客户端：UI 重连时会替换本连接），或引擎退出。
            raise EngineError(
                "连接已被引擎关闭（BrokenPipe）—— 常见原因：\n"
                "  · UI 重连把本 CLI 踢下线（引擎单客户端，后连的替换先连的）\n"
                "  · 引擎进程刚退出\n"
                "  → 重试一次；若持续发生，先停 UI 再跑本 CLI。",
                EXIT_TIMEOUT) from e
        except OSError as e:
            raise EngineError(f"发送失败：{e}", EXIT_TIMEOUT) from e

    def recv_lines(self, deadline: float):
        """在 deadline 之前不断产出 JSON 行（生成器）。

        引擎按行发 JSON；这里做**增量解析**：收到半行就等下一块，
        不假设一次 recv 拿到完整行（实测大 payload 会分片）。
        """
        assert self.sock is not None
        while time.time() < deadline:
            remaining = max(0.05, min(0.5, deadline - time.time()))
            self.sock.settimeout(remaining)
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                continue
            except OSError as e:
                raise EngineError(f"接收失败：{e}", EXIT_TIMEOUT) from e
            if not chunk:
                return  # 对端关闭
            self._buf += chunk
            while b"\n" in self._buf:
                raw, self._buf = self._buf.split(b"\n", 1)
                text = raw.decode("utf-8", errors="replace").strip()
                if not text:
                    continue
                try:
                    yield json.loads(text)
                except json.JSONDecodeError:
                    # 非 JSON 行（理论不该有）：如实回报，不吞
                    yield {"type": "_nonjson", "raw": text}

    # -- 命令 ---------------------------------------------------------------
    def command(self, payload: dict, wait_ack: bool = True) -> dict:
        """发一条命令并等回执。

        Args:
            payload: 命令 JSON（**调用方负责带 id**，见 make_command）
            wait_ack: True=等匹配 id 的 ack；等不到但收到心跳 → 降级返回

        Returns:
            {
              "acknowledged": bool,     # 是否拿到匹配的 ack
              "ack": dict | None,       # ack 原文
              "heartbeats": [dict],     # 期间收到的心跳
              "degraded": bool,         # 是否走了老引擎降级
              "sent": dict,             # 实际发出的命令
            }

        Raises:
            EngineError: 超时且**连心跳都没有**（引擎无响应）

        ── 为什么需要宽限期（ack_grace）────────────────────────────────
        心跳周期是 1s（`sendHeartbeat`）。若本 CLI 恰好在心跳 tick 前一刻
        连上，会**先收到心跳、后收到 ack** —— 那时若立刻判定"老引擎降级"
        就误报了。所以：收到第一个心跳后**再多等 ack_grace 秒**，
        期间拿到 ack 就当新引擎成功；grace 用尽仍无 ack 才降级。
        ──────────────────────────────────────────────────────────────
        """
        cmd_id = payload.get("id")
        self.send_json(payload)
        start = time.time()
        deadline = start + self.timeout
        # 收到首个心跳后的额外等待（宽限期），不超过总 deadline
        ack_deadline: float | None = None

        while True:
            now = time.time()
            if now >= deadline:
                break
            if ack_deadline is not None and now >= ack_deadline:
                break

            for msg in self.recv_lines(min(deadline, ack_deadline or deadline)):
                mtype = msg.get("type")
                if mtype == "heartbeat":
                    self.seen_heartbeats.append(msg)
                    self.last_heartbeat = msg
                    if wait_ack and cmd_id and ack_deadline is None:
                        # 首个心跳：开启宽限期（而不是立刻降级）
                        ack_deadline = min(deadline, time.time() + self.ack_grace)
                    continue
                if mtype == "ack":
                    if cmd_id is None or msg.get("id") == cmd_id:
                        self._saw_any_ack = True
                        return {
                            "acknowledged": True,
                            "ack": msg,
                            "heartbeats": list(self.seen_heartbeats),
                            "others": list(self._others),
                            "degraded": False,
                            "sent": payload,
                        }
                    # 不匹配的 ack（别的命令）：记下但继续等
                    self._stray_acks.append(msg)
                    continue
                # pong 是 ping 的**即时应答**（EngineMain.swift:1105）：
                # 对 `{"type":"ping"}` 而言 pong 就是回执，不该被当成"无 ack 降级"。
                if mtype == "pong" and payload.get("type") == "ping":
                    return {
                        "acknowledged": True,
                        "ack": {"type": "pong", "ok": True,
                                "cmd": "ping", "detail": "引擎存活",
                                "data": {"pong": msg}},
                        "heartbeats": list(self.seen_heartbeats),
                        "others": list(self._others),
                        "degraded": False,
                        "sent": payload,
                    }
                self._others.append(msg)

        # ---- 超时 / 宽限期用尽 ----
        if self.seen_heartbeats:
            reason = ("超时内只收到心跳、未收到匹配 ack（老引擎无 id/ack 支持）"
                      if ack_deadline is not None and time.time() < deadline
                      else "超时内只收到心跳、未收到匹配 ack")
            return {
                "acknowledged": False,
                "ack": None,
                "heartbeats": list(self.seen_heartbeats),
                "others": list(self._others),
                "degraded": True,
                "sent": payload,
                "degrade_reason": reason,
            }
        raise EngineError(
            f"引擎无响应（{self.timeout:g}s 内既没有 ack 也没有心跳）：{self.path}\n"
            f"  → 引擎进程可能在忙/卡住；用 `pgrep -fl AuroraDrive` 检查。",
            EXIT_TIMEOUT)


def make_command(cmd_type: str, with_id: bool = True, **fields) -> dict:
    """构造一条命令（默认带关联 id，供 ack 匹配）。"""
    payload: dict = {"type": cmd_type}
    if with_id:
        payload["id"] = uuid.uuid4().hex[:12]
    payload.update(fields)
    return payload


# ---------------------------------------------------------------------------
# 输出辅助
# ---------------------------------------------------------------------------

def emit(payload: dict, as_json: bool, stream=sys.stdout) -> None:
    """统一输出：--json 时压缩成一行（机器可读），否则格式化。"""
    if as_json:
        print(json.dumps(payload, ensure_ascii=False, sort_keys=True), file=stream)
    else:
        print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True), file=stream)


def warn(msg: str) -> None:
    print(f"⚠️  {msg}", file=sys.stderr)


def info(msg: str) -> None:
    print(f"ℹ️  {msg}", file=sys.stderr)


# ---------------------------------------------------------------------------
# 子命令实现
# ---------------------------------------------------------------------------

def _run_simple(client: EngineClient, payload: dict, args, label: str) -> int:
    """发一条命令、按 ack 结果决定退出码的通用路径（start/stop/record/...）。"""
    result = client.command(payload)
    ack = result["ack"]

    if result["degraded"]:
        warn(f"{label}：命令已发出，但引擎未回 ack（{result.get('degrade_reason','')}）"
             f" → 状态**未确认**")
        out = {
            "cmd": payload.get("type"),
            "sent": result["sent"],
            "acknowledged": False,
            "degraded": True,
            "degrade_reason": result.get("degrade_reason"),
            "heartbeat": result["heartbeats"][-1] if result["heartbeats"] else None,
        }
        emit(out, args.json)
        return EXIT_OK

    ok = bool(ack.get("ok", True))
    out = {
        "cmd": ack.get("cmd", payload.get("type")),
        "id": ack.get("id"),
        "acknowledged": True,
        "ok": ok,
        "detail": ack.get("detail"),
        "data": ack.get("data", {}),
    }
    emit(out, args.json)
    if not ok:
        warn(f"{label} 失败：{ack.get('detail') or 'ok=false'}")
        return EXIT_TIMEOUT
    return EXIT_OK


def cmd_state(client: EngineClient, args) -> int:
    """查询引擎状态：发 {"type":"state","id":...}，把 ack.data 格式化输出。"""
    payload = make_command("state")
    result = client.command(payload)
    ack = result["ack"]

    if result["degraded"]:
        warn("引擎未回 ack（老引擎可能还没有 state 命令）"
             f"：{result.get('degrade_reason','')}")
        info("降级：用最近一次心跳当状态快照（字段比 state 少）")
        hb = result["heartbeats"][-1] if result["heartbeats"] else None
        out = {
            "cmd": "state",
            "acknowledged": False,
            "degraded": True,
            "degrade_reason": result.get("degrade_reason"),
            "data": hb or {},
        }
        emit(out, args.json)
        # 降级但拿到了心跳 → 视为"拿到了降级状态"，退出码 0（如实标注）
        return EXIT_OK if hb else EXIT_TIMEOUT

    data = ack.get("data", {})
    emit(data, args.json)
    return EXIT_OK if bool(ack.get("ok", True)) else EXIT_TIMEOUT


def cmd_capture(client: EngineClient, args) -> int:
    """切换捕获源 → 真实命令是 `set_capture_mode`（EngineMain.swift:1085）。"""
    if args.mode == "fullscreen":
        payload = make_command("set_capture_mode", mode="fullscreen")
    else:  # window
        if args.window_id is None:
            raise EngineError("capture window 需要 <id> 参数", EXIT_USAGE)
        payload = make_command("set_capture_mode", mode="window", windowID=int(args.window_id))
    return _run_simple(client, payload, args, f"切换捕获源（{args.mode}）")


def cmd_capture_list(args) -> int:
    """列可捕获窗口 —— **本 CLI 不提供**（窗口列表只有 GUI 进程能拿）。"""
    raise EngineError(
        "capture-list 需 UI 侧：可捕获窗口列表只能由 GUI 进程枚举（引擎进程拿不到）。\n"
        "  → 请在 AuroraDrive UI 的预览框下拉条里选择窗口；\n"
        "  → 或直接给本 CLI 窗口 id：python3 tools/engine_ai.py capture window <id>\n"
        "  （本 CLI 不引入 pyobjc 等新依赖，故不实现该枚举）",
        EXIT_USAGE)


def cmd_record(client: EngineClient, args) -> int:
    payload = make_command("record", on=(args.state == "on"),
                           perspective=getattr(args, "perspective", "first") or "first")
    return _run_simple(client, payload, args, f"录制 {args.state}")


def cmd_start(client: EngineClient, args) -> int:
    return _run_simple(client, make_command("start"), args, "开始驾驶")


def cmd_stop(client: EngineClient, args) -> int:
    return _run_simple(client, make_command("stop"), args, "停止驾驶")


def cmd_raw(client: EngineClient, args) -> int:
    """原样发一条 JSON（调试用）。"""
    text = args.json_text.strip()
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as e:
        raise EngineError(f"raw 参数不是合法 JSON：{e}\n  收到：{text}", EXIT_USAGE) from e
    if not isinstance(payload, dict):
        raise EngineError(f"raw 需要 JSON 对象（{{...}}），收到 {type(payload).__name__}", EXIT_USAGE)
    if "id" not in payload:
        payload = dict(payload, id=uuid.uuid4().hex[:12])
        info("raw：自动补了 id（便于匹配 ack；不需要可自行带上）")
    return _run_simple(client, payload, args, "raw 命令")


# -- wait ------------------------------------------------------------------

_OPS = {
    "==": lambda a, b: a == b,
    "!=": lambda a, b: a != b,
    ">": lambda a, b: a > b,
    ">=": lambda a, b: a >= b,
    "<": lambda a, b: a < b,
    "<=": lambda a, b: a <= b,
}


def _coerce(raw: str):
    """把 CLI 字符串转成合适的类型（bool/int/float/str）。"""
    low = raw.strip().lower()
    if low == "true":
        return True
    if low == "false":
        return False
    if low in ("null", "none"):
        return None
    try:
        return int(raw)
    except ValueError:
        pass
    try:
        return float(raw)
    except ValueError:
        pass
    return raw


def _get_field(data: dict, field: str):
    """取字段（支持 `a.b` 点号路径）；不存在返回 (None, False)。"""
    cur = data
    for part in field.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None, False
        cur = cur[part]
    return cur, True


def cmd_wait(client: EngineClient, args) -> int:
    """轮询 state 直到条件满足；超时退出码 1。"""
    if args.op not in _OPS:
        raise EngineError(f"不支持的比较运算符「{args.op}」，可用：{' '.join(_OPS)}", EXIT_USAGE)

    expected = _coerce(args.value)
    deadline = time.time() + args.timeout
    attempts = 0
    last_seen = None
    last_raw: dict = {}

    while True:
        attempts += 1
        payload = make_command("state")
        # wait 的单次查询也要短超时，否则一次卡住就吃掉整个 --timeout
        client.timeout = min(DEFAULT_TIMEOUT, max(0.5, deadline - time.time()))
        try:
            result = client.command(payload)
        except EngineError as e:
            # 轮询期间被踢/断连是常态（UI 3 秒重连会替换本连接）：
            # 只要总超时没到，就重连继续等，而不是直接失败。
            if time.time() >= deadline:
                warn(f"等待超时（{args.timeout:g}s）且连接中断：{e}")
                out = {
                    "satisfied": False,
                    "timeout": True,
                    "error": str(e),
                    "field": args.field,
                    "op": args.op,
                    "expected": expected,
                    "actual": last_seen,
                    "attempts": attempts,
                }
                emit(out, args.json)
                return EXIT_TIMEOUT
            if attempts <= 2:
                warn(f"连接中断，重连后继续等待：{e}")
            try:
                client.close()
                time.sleep(0.3)
                client.connect()
            except EngineError as ce:
                if time.time() >= deadline:
                    warn(f"重连失败且已超时：{ce}")
                    return EXIT_TIMEOUT
                time.sleep(0.3)
            continue
        ack = result["ack"]

        if ack is not None and not bool(ack.get("ok", True)):
            warn(f"state 查询失败：{ack.get('detail') or 'ok=false'}")
            return EXIT_TIMEOUT

        if ack is not None:
            data = ack.get("data", {}) or {}
        else:
            # 老引擎降级：用心跳当数据源（心跳字段：isDriving/frames/speed/...）
            data = result["heartbeats"][-1] if result["heartbeats"] else {}
            if attempts == 1:
                warn("引擎未回 ack，wait 降级为「用心跳字段判断」"
                     "（字段名同心跳：isDriving/frames/speed/fps/...）")
        last_raw = data
        value, found = _get_field(data, args.field)
        last_seen = value

        if found:
            try:
                if _OPS[args.op](value, expected):
                    out = {
                        "satisfied": True,
                        "field": args.field,
                        "op": args.op,
                        "expected": expected,
                        "actual": value,
                        "attempts": attempts,
                        "acknowledged": ack is not None,
                        "state": data,
                    }
                    emit(out, args.json)
                    return EXIT_OK
            except TypeError:
                raise EngineError(
                    f"无法比较：字段 {args.field}={value!r}（{type(value).__name__}）"
                    f" 与期望 {expected!r}（{type(expected).__name__}）类型不匹配",
                    EXIT_USAGE)

        if time.time() >= deadline:
            out = {
                "satisfied": False,
                "timeout": True,
                "field": args.field,
                "op": args.op,
                "expected": expected,
                "actual": last_seen,
                "attempts": attempts,
                "acknowledged": ack is not None,
                "state": last_raw,
            }
            emit(out, args.json)
            warn(f"等待超时（{args.timeout:g}s）：{args.field} {args.op} {expected} 未满足"
                 f"（最后看到 {args.field}={last_seen!r}）")
            return EXIT_TIMEOUT

        time.sleep(0.2)


# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="engine_ai.py",
        description="AI / 脚本操作 AuroraDrive 后台引擎的 CLI（一行一 JSON over unix socket）。",
        epilog=(
            "⚠️ 引擎单客户端：本 CLI 连接时会踢掉 UI（UI 约 3 秒后自动重连）。\n"
            "   建议短促使用；自动化时先停 UI 更稳。\n"
            "退出码：0 成功 / 1 超时或 ok=false / 2 用法错误。"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--json", action="store_true",
                   help="机器可读输出（单行 JSON，sort_keys）")
    p.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT,
                   help=f"单次命令超时秒数（默认 {DEFAULT_TIMEOUT:g}）")
    p.add_argument("--socket", default=DEFAULT_SOCKET,
                   help=f"socket 路径（默认 {DEFAULT_SOCKET}）")
    p.add_argument("-v", "--verbose", action="store_true",
                   help="把发出的 JSON 打到 stderr（诊断用）")

    sub = p.add_subparsers(dest="cmd", metavar="<command>")

    sub.add_parser("state", help="查询引擎状态（格式化 JSON）")

    sub.add_parser("start", help="开始驾驶")
    sub.add_parser("stop", help="停止驾驶")

    cap = sub.add_parser("capture", help="切换捕获源")
    cap.add_argument("mode", choices=["fullscreen", "window"], help="捕获模式")
    cap.add_argument("window_id", nargs="?", type=int, help="窗口 id（mode=window 时必填）")

    sub.add_parser("capture-list", help="列可捕获窗口（本 CLI 不提供，退出码 2）")

    rec = sub.add_parser("record", help="录制开关")
    rec.add_argument("state", choices=["on", "off"], help="on=开始录制，off=停止")
    rec.add_argument("--perspective", choices=["first", "third"], default="first",
                     help="录制视角（默认 first；third=第三人称）")

    w = sub.add_parser("wait", help="轮询 state 直到条件满足")
    w.add_argument("field", help="字段名（支持点号路径，如 state.isDriving）")
    w.add_argument("op", choices=list(_OPS), help="比较运算符")
    w.add_argument("value", help="期望值（true/false/数字/字符串）")
    w.add_argument("--timeout", type=float, default=30.0,
                   help="等待总超时秒数（默认 30）")

    r = sub.add_parser("raw", help="原样发一条 JSON（调试用）")
    r.add_argument("json_text", metavar="json", help="要发送的 JSON 对象字符串")

    return p


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

#: 不需要连引擎的命令（本地判定，避免无谓占用 socket）
_OFFLINE_COMMANDS = {"capture-list"}


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if not args.cmd:
        parser.print_help()
        return EXIT_USAGE

    # 离线命令：不连引擎
    if args.cmd in _OFFLINE_COMMANDS:
        try:
            return cmd_capture_list(args)
        except EngineError as e:
            print(f"❌ {e}", file=sys.stderr)
            return e.code

    handlers = {
        "state": cmd_state,
        "start": cmd_start,
        "stop": cmd_stop,
        "capture": cmd_capture,
        "record": cmd_record,
        "wait": cmd_wait,
        "raw": cmd_raw,
    }
    handler = handlers.get(args.cmd)
    if handler is None:
        parser.print_help()
        return EXIT_USAGE

    client = EngineClient(path=args.socket, timeout=args.timeout, verbose=args.verbose)
    # 每次 command 的收集器初始化（避免跨命令串味）
    client._stray_acks = []
    client._others = []
    client._saw_any_ack = False
    try:
        with client:
            return handler(client, args)
    except EngineError as e:
        print(f"❌ {e}", file=sys.stderr)
        return e.code
    except KeyboardInterrupt:
        print("⏹  被用户中断", file=sys.stderr)
        return EXIT_TIMEOUT


if __name__ == "__main__":
    sys.exit(main())
