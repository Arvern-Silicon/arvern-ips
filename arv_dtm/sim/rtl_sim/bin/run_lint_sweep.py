#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    run_lint_sweep.py (arv_dtm)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Iterate rtl_configs.CONFIGS and run Verilator --lint-only on each
# (top, parameter) point. Catches parameter-gated generate / width / unused
# bugs that the plain default lint (defaults only) cannot see.
#
# Usage: run from sim/rtl_sim/run/ as `./run_lint -sweep` (the bash wrapper
# in run_lint forwards here when -sweep is passed).
#
# Layout: each config gets its own log file under ./log_lint/<label>.log;
# a summary table is printed and dropped at ./log_lint/summary.log.
#----------------------------------------------------------------------------

import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
from rtl_configs import CONFIGS   # noqa: E402

CWD = Path.cwd()
LOG_DIR = CWD / "log_lint"
SUBMIT_F = CWD / "submit_lint.f"
WAIVERS = CWD / "waivers_lint.vlt"
FLATTEN = SCRIPT_DIR / "flatten_filelist.py"
FILELIST = (CWD / "../../../rtl/verilog/filelist.f").resolve()


def regenerate_filelist():
    subprocess.run([str(FLATTEN), str(FILELIST), str(SUBMIT_F)], check=True)


def build_g_flags(overrides):
    return [f"-G{p}={v}" for p, v in sorted(overrides.items())]


def lint_one(label, top, overrides):
    log_path = LOG_DIR / f"{label}.log"
    cmd = [
        "verilator", "--lint-only", "-Wall", "-Wpedantic",
        "--top-module", top,
    ] + build_g_flags(overrides) + [
        str(WAIVERS), "-f", str(SUBMIT_F),
    ]
    with log_path.open("w") as fh:
        fh.write("CMD: " + " ".join(cmd) + "\n")
        fh.write("-" * 78 + "\n")
        fh.flush()
        rc = subprocess.run(cmd, stdout=fh, stderr=subprocess.STDOUT).returncode
    return rc, log_path


def fmt_overrides(overrides):
    if not overrides:
        return "(defaults)"
    return " ".join(f"{p}={v}" for p, v in sorted(overrides.items()))


def main():
    if LOG_DIR.exists():
        shutil.rmtree(LOG_DIR)
    LOG_DIR.mkdir()
    regenerate_filelist()

    results = []
    for label, top, overrides in CONFIGS:
        print(f"  lint {label:<20} {top:<16} ({fmt_overrides(overrides)})",
              end=" ", flush=True)
        rc, log = lint_one(label, top, overrides)
        status = "PASS" if rc == 0 else "FAIL"
        print(status)
        results.append((label, top, overrides, rc, log))

    print()
    print("=" * 78)
    print(f"  arv_dtm RTL parameterization lint sweep -- {len(results)} configs")
    print("=" * 78)
    summary_lines = []
    summary_lines.append(f"{'CONFIG':<20} {'TOP':<16} {'PARAMS':<30} STATUS")
    summary_lines.append("-" * 78)
    fail_count = 0
    for label, top, overrides, rc, log in results:
        status = "PASS" if rc == 0 else "FAIL"
        if rc != 0:
            fail_count += 1
        summary_lines.append(
            f"{label:<20} {top:<16} {fmt_overrides(overrides):<30} {status}")
    summary_lines.append("-" * 78)
    summary_lines.append(
        f"  total: {len(results)}    passed: {len(results) - fail_count}    "
        f"failed: {fail_count}")
    summary = "\n".join(summary_lines)
    print(summary)
    (LOG_DIR / "summary.log").write_text(summary + "\n")
    sys.exit(0 if fail_count == 0 else 1)


if __name__ == "__main__":
    main()
