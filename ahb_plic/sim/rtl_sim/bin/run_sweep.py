#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    run_sweep.py (ahb_plic)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Iterate sim_configs.SIM_CONFIGS and run each test under each compatible
# configuration. For each (config, test) tuple:
#   1. Symlink the test stimulus to stimulus.v
#   2. Run iverilog with the config's -D defines (+ -D NODUMP + -D SEED)
#   3. Execute the resulting simv
#   4. Log to ./log_sweep/<config>/<test>.log
#
# At the end, print a per-config summary table and an overall pass/fail
# count. Exit non-zero if any test failed.
#----------------------------------------------------------------------------

import random
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
from sim_configs import SIM_CONFIGS, MANDATORY_COVER_BINS   # noqa: E402

CWD = Path.cwd()
LOG_ROOT = CWD / "log_sweep"
SUBMIT_F = CWD / "submit_sim.f"
BENCH_SUBMIT_F = (CWD / "../../../bench/verilog/submit.f").resolve()
SRC_DIR = (CWD / "../src").resolve()
FLATTEN = SCRIPT_DIR / "flatten_filelist.py"
STIMULUS_LINK = CWD / "stimulus.v"


def regenerate_filelist():
    subprocess.run([str(FLATTEN), str(BENCH_SUBMIT_F), str(SUBMIT_F)], check=True)


def setup_stimulus(test):
    src = SRC_DIR / f"{test}.v"
    if not src.exists():
        return None
    if STIMULUS_LINK.exists() or STIMULUS_LINK.is_symlink():
        STIMULUS_LINK.unlink()
    STIMULUS_LINK.symlink_to(src)
    return src


def build_d_flags(defines, seed):
    flags = [f"-D{p}={v}" for p, v in sorted(defines.items())]
    flags.append(f"-D SEED={seed}")
    flags.append("-D NODUMP")
    return flags


def run_one(config_label, defines, test, log_dir):
    log_path = log_dir / f"{test}.log"
    src = setup_stimulus(test)
    if src is None:
        log_path.write_text(f"SKIP: stimulus file not found: ../src/{test}.v\n")
        return "MISS"

    seed = random.randint(0, 2**31 - 1)
    # Compile
    for f in CWD.glob("simv"):
        f.unlink()
    compile_cmd = ["iverilog", "-o", "simv", "-c", str(SUBMIT_F)]
    # Each -D is given as one shell token (-DKEY=VAL); seed/nodump split as -D KEY too
    for p, v in sorted(defines.items()):
        compile_cmd += [f"-D{p}={v}"]
    compile_cmd += [f"-DSEED={seed}", "-DNODUMP"]

    with log_path.open("w") as fh:
        fh.write("CONFIG: " + config_label + "\n")
        fh.write("DEFINES: " + " ".join(f"{p}={v}" for p, v in sorted(defines.items())) + "\n")
        fh.write("TEST: " + test + "\n")
        fh.write("CMD: " + " ".join(compile_cmd) + "\n")
        fh.write("-" * 78 + "\n")
        fh.flush()
        rc = subprocess.run(compile_cmd, stdout=fh, stderr=subprocess.STDOUT).returncode
        if rc != 0:
            return "COMPILE_FAIL"
        # Run
        run_cmd = ["./simv"]
        fh.write("-" * 78 + " RUN\n")
        fh.flush()
        rc = subprocess.run(run_cmd, stdout=fh, stderr=subprocess.STDOUT).returncode

    log_text = log_path.read_text()
    if "SIMULATION PASSED" in log_text:
        return "PASS"
    if "SIMULATION FAILED" in log_text:
        return "FAIL"
    return "INCONCLUSIVE"


def fmt_defines(defines):
    if not defines:
        return "(defaults)"
    return " ".join(f"{p}={v}" for p, v in sorted(defines.items()))


def collect_coverage(log_root):
    """Union the 'COVERAGE HIT: <bin>' lines across every per-config log."""
    hit = set()
    for log_path in log_root.rglob("*.log"):
        for line in log_path.read_text(errors="ignore").splitlines():
            marker = "COVERAGE HIT:"
            if marker in line:
                # bin name is the last whitespace-delimited token (the emit
                # is space-padded by the Verilog %s on a fixed-width reg).
                name = line.split(marker, 1)[1].split()
                if name:
                    hit.add(name[-1])
    return hit


def report_coverage(log_root):
    """Return the list of mandatory bins never hit in any config."""
    hit = collect_coverage(log_root)
    missing = [b for b in MANDATORY_COVER_BINS if b not in hit]
    lines = []
    lines.append("=" * 90)
    lines.append(f"  functional coverage gate -- {len(MANDATORY_COVER_BINS) - len(missing)}"
                 f"/{len(MANDATORY_COVER_BINS)} mandatory bins hit (union across all configs)")
    lines.append("=" * 90)
    if missing:
        for b in missing:
            lines.append(f"  COVERAGE GAP: mandatory bin never hit in any config -> {b}")
        lines.append(f"  -> coverage FAILED ({len(missing)} bin(s) unexercised)")
    else:
        lines.append("  -> coverage PASSED (all mandatory bins exercised)")
    report = "\n".join(lines)
    print()
    print(report)
    (log_root / "coverage.log").write_text(report + "\n")
    return missing


def main():
    if LOG_ROOT.exists():
        shutil.rmtree(LOG_ROOT)
    LOG_ROOT.mkdir()
    regenerate_filelist()

    all_results = []
    for config_label, defines, test_list in SIM_CONFIGS:
        config_dir = LOG_ROOT / config_label
        config_dir.mkdir()
        print(f"\n=== config: {config_label}  ({fmt_defines(defines)})")
        for test in test_list:
            print(f"  {test:<28}", end=" ", flush=True)
            status = run_one(config_label, defines, test, config_dir)
            print(status)
            all_results.append((config_label, defines, test, status))

    # cleanup stimulus link
    if STIMULUS_LINK.exists() or STIMULUS_LINK.is_symlink():
        STIMULUS_LINK.unlink()
    for f in CWD.glob("simv"):
        f.unlink()

    # Summary
    print()
    print("=" * 90)
    print(f"  ahb_plic simulation sweep -- {len(all_results)} (config, test) runs")
    print("=" * 90)
    summary_lines = []
    summary_lines.append(f"{'CONFIG':<14} {'TEST':<28} {'DEFINES':<32} STATUS")
    summary_lines.append("-" * 90)
    counts = {"PASS": 0, "FAIL": 0, "COMPILE_FAIL": 0, "INCONCLUSIVE": 0, "MISS": 0}
    for cfg, defines, test, status in all_results:
        counts[status] = counts.get(status, 0) + 1
        summary_lines.append(f"{cfg:<14} {test:<28} {fmt_defines(defines):<32} {status}")
    summary_lines.append("-" * 90)
    summary_lines.append(
        f"  total: {len(all_results)}    "
        f"passed: {counts['PASS']}    failed: {counts['FAIL']}    "
        f"compile-fail: {counts['COMPILE_FAIL']}    missing: {counts['MISS']}"
    )
    summary = "\n".join(summary_lines)
    print(summary)
    (LOG_ROOT / "summary.log").write_text(summary + "\n")

    # Suite-level functional-coverage gate (teeth: fails the regression).
    missing_bins = report_coverage(LOG_ROOT)

    failed = counts["FAIL"] + counts["COMPILE_FAIL"] + counts["INCONCLUSIVE"] + counts["MISS"]
    sys.exit(0 if (failed == 0 and not missing_bins) else 1)


if __name__ == "__main__":
    main()
