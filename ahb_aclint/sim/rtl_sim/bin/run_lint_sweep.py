#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    run_lint_sweep.py
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Iterate the rtl_configs.CONFIGS list and run Verilator --lint-only on
# each parameter point. Catches parameter-gated generate / width / unused
# bugs that the single-config default lint cannot see.
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
from rtl_configs import CONFIGS, TOP_MODULE   # noqa: E402

CWD = Path.cwd()
LOG_DIR = CWD / "log_lint"
SUBMIT_F = CWD / "submit_lint.f"
WAIVERS = CWD / "waivers.vlt"
FLATTEN = SCRIPT_DIR / "flatten_filelist.py"
FILELIST = (CWD / "../../../rtl/verilog/filelist.f").resolve()


def regenerate_filelist():
    subprocess.run([str(FLATTEN), str(FILELIST), str(SUBMIT_F)], check=True)


def build_g_flags(overrides):
    return [f"-G{p}={v}" for p, v in sorted(overrides.items())]


def lint_one(label, overrides):
    log_path = LOG_DIR / f"{label}.log"
    cmd = [
        "verilator", "--lint-only", "-Wall", "-Wpedantic",
        "--top-module", TOP_MODULE,
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
    for label, overrides in CONFIGS:
        print(f"  lint {label:<20} ({fmt_overrides(overrides)})", end=" ", flush=True)
        rc, log = lint_one(label, overrides)
        status = "PASS" if rc == 0 else "FAIL"
        print(status)
        results.append((label, overrides, rc, log))

    print()
    print("=" * 78)
    print(f"  ahb_aclint RTL parameterization lint sweep -- {len(results)} configs")
    print("=" * 78)
    summary_lines = []
    summary_lines.append(f"{'CONFIG':<20} {'PARAMS':<46} STATUS")
    summary_lines.append("-" * 78)
    fail_count = 0
    for label, overrides, rc, log in results:
        status = "PASS" if rc == 0 else "FAIL"
        if rc != 0:
            fail_count += 1
        summary_lines.append(f"{label:<20} {fmt_overrides(overrides):<46} {status}")
    summary_lines.append("-" * 78)
    summary_lines.append(f"  total: {len(results)}    passed: {len(results) - fail_count}    failed: {fail_count}")
    summary = "\n".join(summary_lines)
    print(summary)
    (LOG_DIR / "summary.log").write_text(summary + "\n")
    sys.exit(0 if fail_count == 0 else 1)


if __name__ == "__main__":
    main()
