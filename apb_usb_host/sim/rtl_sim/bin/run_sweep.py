#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    run_sweep.py (apb_usb_host)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Run (config, test) pairs of sim_configs.py in parallel, each in its own work
# directory under ./work_sweep/, and report a summary plus the mandatory
# functional-coverage bins.
#
# Usage (from sim/rtl_sim/run/, normally through run_all):
#   run_sweep.py [<config> ...] [-regression] [-tests t1,t2] [-j N]
#                [-sim verilator|iverilog] [-seed N] [-log <dir>]
#     <config> ...   these SIM_CONFIGS labels (default: every config)
#     -regression    the REGRESSION_CONFIGS labels
#     -tests         only these tests of each config's list
#     -j N           parallel jobs (default: the number of CPUs)
#     -sim           simulator (default verilator: the port's timers make every
#                    test hundreds of milliseconds of bus time, which Icarus
#                    runs about 15 times slower)
#     -seed N        one seed for every run (default: random per run)
#     -log <dir>     log directory (default ./log_sweep; ./log_triage for
#                    targeted reruns keeps a sweep's logs)
#
# A port test simulates up to seconds of bus time: the coverage bins and the
# verdicts come from each run's log, <log>/<config>/<test>.log.
#----------------------------------------------------------------------------

import os
import random
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
from sim_configs import SIM_CONFIGS, REGRESSION_CONFIGS, MANDATORY_COVER_BINS, TB_TOP   # noqa: E402

CWD = Path.cwd()
WORK_ROOT = CWD / "work_sweep"
SUBMIT_F = CWD / "submit_sim.f"
BENCH_SUBMIT_F = (CWD / "../../../bench/verilog/submit.f").resolve()
SRC_DIR = (CWD / "../src").resolve()
FLATTEN = SCRIPT_DIR / "flatten_filelist.py"
PUBLIC_VLT = SCRIPT_DIR / "cov_public.vlt"


def regenerate_filelist():
    subprocess.run([sys.executable, str(FLATTEN), str(BENCH_SUBMIT_F), str(SUBMIT_F)],
                   check=True, stdout=subprocess.DEVNULL)


def build_cmd(sim, defines, seed, work):
    if sim == "iverilog":
        cmd = ["iverilog", "-o", str(work / "simv"), "-c", str(SUBMIT_F), "-I", str(work)]
        cmd += [f"-D{p}={v}" for p, v in sorted(defines.items())]
        return cmd + [f"-DSEED={seed}", "-DNODUMP"], [str(work / "simv")]
    cmd = ["verilator", "--binary", "--timing", "-O3", "-j", "2", "--x-initial", "unique",
           "-Wno-fatal", "-Wno-TIMESCALEMOD", "-Wno-LATCH", "-Wno-WIDTHEXPAND", "--quiet-exit",
           f"+incdir+{work}", str(PUBLIC_VLT), "-f", str(SUBMIT_F),
           "--top-module", TB_TOP, "--Mdir", str(work / "obj"), "-o", "sim"]
    cmd += [f"+define+{p}={v}" for p, v in sorted(defines.items())]
    # Every variable without an initialiser starts random (seeded per run), so
    # a flop that relies on its initial value instead of its reset shows up
    return cmd + [f"+define+SEED={seed}", "+define+NODUMP"], \
        [str(work / "obj" / "sim"), "+verilator+rand+reset+2", f"+verilator+seed+{seed % 2147483646 + 1}"]


def run_one(sim, config_label, defines, test, log_dir, fixed_seed):
    log_path = log_dir / f"{test}.log"
    src = SRC_DIR / f"{test}.v"
    if not src.exists():
        log_path.write_text(f"MISSING: stimulus file not found: ../src/{test}.v\n")
        return "MISS"
    work = WORK_ROOT / f"{config_label}__{test}"
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    (work / "stimulus.v").symlink_to(src)

    seed = fixed_seed if fixed_seed is not None else random.randint(0, 2**31 - 1)
    bcmd, rcmd = build_cmd(sim, defines, seed, work)
    with log_path.open("w") as fh:
        fh.write("CONFIG: " + config_label + "\n")
        fh.write("DEFINES: " + fmt_defines(defines) + "\n")
        fh.write("TEST: " + test + "\n")
        fh.write("SEED: %d\n" % seed)
        fh.write("CMD: " + " ".join(bcmd) + "\n")
        fh.write("-" * 78 + "\n")
        fh.flush()
        rc = subprocess.run(bcmd, stdout=fh, stderr=subprocess.STDOUT, cwd=work).returncode
        if rc != 0:
            return "COMPILE_FAIL"
        fh.write("-" * 78 + " RUN\n")
        fh.flush()
        subprocess.run(rcmd, stdout=fh, stderr=subprocess.STDOUT, cwd=work)

    log_text = log_path.read_text(errors="ignore")
    shutil.rmtree(work, ignore_errors=True)
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
    return " ".join(f"{p.replace('USB_TB_', '')}={v}" for p, v in sorted(defines.items()))


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
    args = sys.argv[1:]
    wanted, tests, jobs, sim, seed, log_root, regression = [], None, os.cpu_count() or 4, "verilator", None, CWD / "log_sweep", False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-regression":
            regression = True
        elif a == "-tests":
            i += 1; tests = args[i].split(",")
        elif a == "-j":
            i += 1; jobs = int(args[i])
        elif a == "-sim":
            i += 1; sim = args[i]
        elif a == "-seed":
            i += 1; seed = int(args[i])
        elif a == "-log":
            i += 1; log_root = Path(args[i]).resolve()
        else:
            wanted.append(a)
        i += 1
    if sim not in ("verilator", "iverilog"):
        sys.exit(f"run_sweep.py: unknown simulator '{sim}'")
    if regression:
        wanted += REGRESSION_CONFIGS
    known = [c[0] for c in SIM_CONFIGS]
    for w in wanted:
        if w not in known:
            sys.exit(f"run_sweep.py: unknown config '{w}' (have: {', '.join(known)})")
    configs = [c for c in SIM_CONFIGS if not wanted or c[0] in wanted]

    if log_root.exists():
        shutil.rmtree(log_root)
    log_root.mkdir(parents=True)
    WORK_ROOT.mkdir(exist_ok=True)
    regenerate_filelist()

    pairs = []
    for config_label, defines, test_list in configs:
        (log_root / config_label).mkdir()
        for test in test_list:
            if tests is None or test in tests:
                pairs.append((config_label, defines, test))
    print(f"  {len(pairs)} runs, {jobs} in parallel, {sim}")

    def job(p):
        status = run_one(sim, p[0], p[1], p[2], log_root / p[0], seed)
        print(f"  {p[0]:<16} {p[2]:<28} {status}", flush=True)
        return (p[0], p[1], p[2], status)

    with ThreadPoolExecutor(max_workers=jobs) as ex:
        all_results = list(ex.map(job, pairs))

    print()
    print("=" * 100)
    print(f"  apb_usb_host simulation sweep -- {len(all_results)} (config, test) runs")
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
    (log_root / "summary.log").write_text(summary + "\n")

    missing_bins = report_coverage(log_root) if not tests and not regression else []
    failed = counts["FAIL"] + counts["COMPILE_FAIL"] + counts["INCONCLUSIVE"] + counts["MISS"]
    sys.exit(0 if (failed == 0 and not missing_bins) else 1)


if __name__ == "__main__":
    main()
