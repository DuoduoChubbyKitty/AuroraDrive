"""Run every v3_rl test suite and enforce the >=500 assertion floor.

Usage:  /usr/local/bin/python3.11 tools/v3_rl/run_tests.py
Exit code 0 iff all assertions pass AND total >= FLOOR.
"""

import sys
from pathlib import Path

_V3RL = Path(__file__).resolve().parent          # tools/v3_rl
_ROOT = _V3RL.parents[1]                           # repo root
for p in (str(_V3RL), str(_ROOT)):
    if p not in sys.path:
        sys.path.insert(0, p)

# Import test modules as top-level names so they all share the SAME `tests._harness`
# module object (and therefore the same assertion counter).
from tests import _harness as H  # noqa: E402
from tests import test_reward  # noqa: E402
from tests import test_policy  # noqa: E402
from tests import test_data  # noqa: E402
from tests import test_eval  # noqa: E402
from tests import test_props  # noqa: E402

FLOOR = 500


def main() -> int:
    H.reset()
    suites = [("reward", test_reward), ("policy", test_policy),
              ("data", test_data), ("eval", test_eval), ("props", test_props)]
    per = {}
    for name, mod in suites:
        before = H.summary()["total"]
        mod.run()
        after = H.summary()["total"]
        per[name] = after - before
    s = H.summary()
    print("=" * 60)
    for name, cnt in per.items():
        print(f"  suite {name:8s}: {cnt:4d} assertions")
    print("-" * 60)
    print(f"  TOTAL: {s['total']} assertions, {s['failed']} failed "
          f"(floor={FLOOR})")
    if s["failed"]:
        print("\nFAILURES:")
        for f in s["failures"]:
            print(f)
        return 1
    if s["total"] < FLOOR:
        print(f"\n❌ 断言数 {s['total']} < {FLOOR} 门槛")
        return 1
    print("\n✅ 全部通过，且达到断言门槛")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
