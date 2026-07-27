#!/usr/bin/env python3
"""Constrained-random regression driver.

Runs the random test across many seeds and reports the union of coverage bins hit,
not the per-seed figure. Coverage closure is a property of the regression as a whole:
a single seed that happens to hit every bin proves nothing about the generator, and a
seed that misses one says nothing either. The number that matters is how many seeds it
takes before the union stops growing.

Any scoreboard mismatch, assertion failure, or non-PASS result fails the whole run.
"""

import re
import subprocess
import sys

SIM = "./obj_dir/simv"

BIN_GROUPS = {
    "address kind":    ("cv_addr", 3),
    "strobe shape":    ("cv_strb", 4),
    "response":        ("cv_resp", 2),
    "fifo occupancy":  ("cv_occ",  5),
}

NUM = re.compile(r"=(\d+)")


def run_seed(seed, ntxn):
    out = subprocess.run(
        [SIM, "+test=random", f"+seed={seed}", f"+n={ntxn}"],
        capture_output=True, text=True, timeout=900).stdout

    hit = set()
    for line in out.splitlines():
        for label, (tag, _n) in BIN_GROUPS.items():
            if line.startswith(f"[COVERAGE] {label}"):
                for i, v in enumerate(int(x) for x in NUM.findall(line)):
                    if v > 0:
                        hit.add(f"{tag}[{i}]")
        if line.startswith("[COVERAGE] cross"):
            vals = [int(x) for x in re.findall(r"(\d+)", line)]
            # flat order is [a0r0 a0r1 a1r0 a1r1 a2r0 a2r1]; indices 3 and 4 are the
            # illegal crosses and are excluded from the coverage denominator.
            for i, v in enumerate(vals):
                if v > 0 and i not in (3, 4):
                    hit.add(f"cv_cross[{i}]")

    m = re.search(r"mismatches=(\d+)", out)
    a = re.search(r"\[ASSERT\] checked=(\d+) failed=(\d+)", out)
    o = re.search(r"outstanding=(\d+)", out)
    t = re.search(r"pushed=(\d+)", out)

    return {
        "hit": hit,
        "mismatch": int(m.group(1)) if m else -1,
        "checked": int(a.group(1)) if a else 0,
        "failed": int(a.group(2)) if a else -1,
        "outstanding": int(o.group(1)) if o else -1,
        "pushed": int(t.group(1)) if t else 0,
        "pass": "=== RESULT: PASS ===" in out,
        "raw": out,
    }


def main():
    nseeds = int(sys.argv[1]) if len(sys.argv) > 1 else 50
    ntxn = int(sys.argv[2]) if len(sys.argv) > 2 else 300

    total_bins = 3 + 4 + 2 + 5 + 4   # 2 illegal crosses excluded
    union = set()
    closed_at = None
    tot_pushed = tot_checked = tot_mismatch = tot_failed = 0
    failures = []

    for s in range(1, nseeds + 1):
        r = run_seed(s, ntxn)
        before = len(union)
        union |= r["hit"]
        tot_pushed += r["pushed"]
        tot_checked += r["checked"]
        tot_mismatch += max(r["mismatch"], 0)
        tot_failed += max(r["failed"], 0)

        if not r["pass"] or r["mismatch"] != 0 or r["failed"] != 0 or r["outstanding"] != 0:
            failures.append(s)
            print(f"seed {s:3d}  FAIL  mismatch={r['mismatch']} "
                  f"assert_failed={r['failed']} outstanding={r['outstanding']}")
            print(r["raw"][-1500:])
        else:
            grew = len(union) - before
            print(f"seed {s:3d}  pass  txn={r['pushed']:5d}  "
                  f"cumulative bins {len(union):2d}/{total_bins}"
                  + (f"  (+{grew})" if grew else ""))

        if closed_at is None and len(union) == total_bins:
            closed_at = s

    print()
    print("=" * 62)
    print(f"seeds run             : {nseeds}")
    print(f"transactions pushed   : {tot_pushed}")
    print(f"assertion checks      : {tot_checked}")
    print(f"assertion failures    : {tot_failed}")
    print(f"scoreboard mismatches : {tot_mismatch}")
    print(f"coverage (union)      : {len(union)}/{total_bins} = "
          f"{100.0*len(union)/total_bins:.1f}%")
    print(f"closure seed          : {closed_at if closed_at else 'NOT CLOSED'}")
    if len(union) < total_bins:
        print(f"unhit bins            : {sorted(set(_all_bins()) - union)}")
    print(f"failing seeds         : {failures if failures else 'none'}")
    print("=" * 62)
    return 1 if failures else 0


def _all_bins():
    out = []
    for tag, n in [("cv_addr", 3), ("cv_strb", 4), ("cv_resp", 2), ("cv_occ", 5)]:
        out += [f"{tag}[{i}]" for i in range(n)]
    out += [f"cv_cross[{i}]" for i in range(6) if i not in (3, 4)]
    return out


if __name__ == "__main__":
    sys.exit(main())
