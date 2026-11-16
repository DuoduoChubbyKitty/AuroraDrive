"""Minimal assertion harness (no external deps; pytest is unavailable offline).

Every call to check()/check_close()/check_raises() increments a global counter so
we can enforce a total-assertion floor (>=500) and prove tests actually ran.
"""

from __future__ import annotations

import traceback

_STATE = {"total": 0, "failed": 0, "failures": []}


def reset() -> None:
    _STATE["total"] = 0
    _STATE["failed"] = 0
    _STATE["failures"] = []


def check(cond: bool, msg: str) -> None:
    _STATE["total"] += 1
    if not cond:
        _STATE["failed"] += 1
        tb = "".join(traceback.format_stack(limit=4)[:-1])
        _STATE["failures"].append(f"FAIL: {msg}\n{tb}")


def check_eq(a, b, msg: str = "") -> None:
    check(a == b, f"{msg} (got {a!r}, expected {b!r})")


def check_close(a: float, b: float, tol: float = 1e-6, msg: str = "") -> None:
    import math

    ok = (math.isnan(a) and math.isnan(b)) or abs(a - b) <= tol
    check(ok, f"{msg} (got {a!r}, expected {b!r} +- {tol})")


def check_raises(fn, exc_type, msg: str = "") -> None:
    try:
        fn()
    except exc_type:
        check(True, msg)
        return
    except Exception as e:  # noqa: BLE001
        check(False, f"{msg}: raised {type(e).__name__} not {exc_type.__name__}")
        return
    check(False, f"{msg}: did not raise {exc_type.__name__}")


def summary() -> dict:
    return dict(_STATE)
