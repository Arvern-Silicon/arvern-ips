#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    run_sweep.py (apb_gpio)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Iterate sim_configs.SIM_CONFIGS and run each test under each configuration.
# For each (config, test) pair:
#   1. Symlink the test stimulus to stimulus.v
#   2. Run iverilog with the config's -D defines (+ -D NODUMP + -D SEED)
#   3. Execute the resulting simv
#   4. Log to ./log_sweep/<config>/<test>.log
#
# At the end, print a per-run summary table and an overall count. A test that
# reports SIMULATION SKIPPED is counted apart and does not fail the sweep.
# Exit non-zero if any run failed, did not compile or was inconclusive.
#   run_sweep.py                 every config
#   run_sweep.py <label> ...     only those configs
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
    subprocess.run([sys.executable, str(FLATTEN), str(BENCH_SUBMIT_F), str(SUBMIT_F)],
                   check=True, stdout=subprocess.DEVNULL)


def setup_stimulus(test):
    src = SRC_DIR / f"{test}.v"
    if not src.exists():
        return None
    if STIMULUS_LINK.exists() or STIMULUS_LINK.is_symlink():
        STIMULUS_LINK.unlink()
    STIMULUS_LINK.symlink_to(src)
    return src


def run_one(config_label, defines, test, log_dir):
    log_path = log_dir / f"{test}.log"
    if setup_stimulus(test) is None:
        log_path.write_text(f"MISSING: stimulus file not found: ../src/{test}.v\n")
        return "MISS"

    seed = random.randint(0, 2**31 - 1)
    for f in CWD.glob("simv"):
        f.unlink()
    compile_cmd = ["iverilog", "-o", "simv", "-c", str(SUBMIT_F)]
    for p, v in sorted(defines.items()):
        compile_cmd += [f"-D{p}={v}"]
    compile_cmd += [f"-DSEED={seed}", "-DNODUMP"]

    with log_path.open("w") as fh:
        fh.write("CONFIG: " + config_label + "\n")
        fh.write("DEFINES: " + fmt_defines(defines) + "\n")
        fh.write("TEST: " + test + "\n")
        fh.write("CMD: " + " ".join(compile_cmd) + "\n")
        fh.write("-" * 78 + "\n")
        fh.flush()
        rc = subprocess.run(compile_cmd, stdout=fh, stderr=subprocess.STDOUT).returncode
        if rc != 0:
            return "COMPILE_FAIL"
        fh.write("-" * 78 + " RUN\n")
        fh.flush()
        subprocess.run(["./simv"], stdout=fh, stderr=subprocess.STDOUT)

    log_text = log_path.read_text(errors="ignore")
    if "SIMULATION FAILED" in log_text:
        return "FAIL"
    if "SIMULATION PASSED" in log_text:
        return "PASS"
    if "SIMULATION SKIPPED" in log_text:
        return "SKIP"
    return "INCONCLUSIVE"


def fmt_defines(defines):
    if not defines:
        return "(defaults)"
    return " ".join(f"{p.replace('GPIO_TB_', '')}={v}" for p, v in sorted(defines.items()))


def report_coverage(log_root):
    """Mandatory 'COVERAGE HIT: <bin>' lines (sim_configs.MANDATORY_COVER_BINS)."""
    if not MANDATORY_COVER_BINS:
        return []
    hit = set()
    for log_path in log_root.rglob("*.log"):
        for line in log_path.read_text(errors="ignore").splitlines():
            if "COVERAGE HIT:" in line:
                name = line.split("COVERAGE HIT:", 1)[1].split()
                if name:
                    hit.add(name[-1])
    missing = [b for b in MANDATORY_COVER_BINS if b not in hit]
    for b in missing:
        print(f"  COVERAGE GAP: mandatory bin never hit in any config -> {b}")
    if not missing:
        print(f"  functional coverage gate -- {len(MANDATORY_COVER_BINS)}/{len(MANDATORY_COVER_BINS)} mandatory bins hit")
    return missing


def main():
    wanted = sys.argv[1:]
    known = [c[0] for c in SIM_CONFIGS]
    for w in wanted:
        if w not in known:
            sys.exit(f"run_sweep.py: unknown config '{w}' (have: {', '.join(known)})")
    configs = [c for c in SIM_CONFIGS if not wanted or c[0] in wanted]

    if LOG_ROOT.exists():
        shutil.rmtree(LOG_ROOT)
    LOG_ROOT.mkdir()
    regenerate_filelist()

    all_results = []
    for config_label, defines, test_list in configs:
        config_dir = LOG_ROOT / config_label
        config_dir.mkdir()
        print(f"\n=== config: {config_label}  ({fmt_defines(defines)})")
        for test in test_list:
            print(f"  {test:<28}", end=" ", flush=True)
            status = run_one(config_label, defines, test, config_dir)
            print(status)
            all_results.append((config_label, defines, test, status))

    if STIMULUS_LINK.exists() or STIMULUS_LINK.is_symlink():
        STIMULUS_LINK.unlink()
    for f in CWD.glob("simv"):
        f.unlink()

    print()
    print("=" * 100)
    print(f"  apb_gpio simulation sweep -- {len(all_results)} (config, test) runs")
    print("=" * 100)
    lines = [f"{'CONFIG':<18} {'TEST':<24} {'DEFINES':<46} STATUS", "-" * 100]
    counts = {"PASS": 0, "SKIP": 0, "FAIL": 0, "COMPILE_FAIL": 0, "INCONCLUSIVE": 0, "MISS": 0}
    for cfg, defines, test, status in all_results:
        counts[status] = counts.get(status, 0) + 1
        lines.append(f"{cfg:<18} {test:<24} {fmt_defines(defines):<46} {status}")
    lines.append("-" * 100)
    lines.append(
        f"  total: {len(all_results)}    passed: {counts['PASS']}    skipped: {counts['SKIP']}    "
        f"failed: {counts['FAIL']}    compile-fail: {counts['COMPILE_FAIL']}    "
        f"inconclusive: {counts['INCONCLUSIVE']}    missing: {counts['MISS']}"
    )
    summary = "\n".join(lines)
    print(summary)
    (LOG_ROOT / "summary.log").write_text(summary + "\n")

    missing_bins = report_coverage(LOG_ROOT)
    failed = counts["FAIL"] + counts["COMPILE_FAIL"] + counts["INCONCLUSIVE"] + counts["MISS"]
    sys.exit(0 if (failed == 0 and not missing_bins) else 1)


if __name__ == "__main__":
    main()
