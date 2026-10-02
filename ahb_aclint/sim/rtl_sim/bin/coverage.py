#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    coverage.py (ahb_aclint)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Functional-coverage collection, shared by BOTH regression entry points:
#
#   run_all          single default config -> report only, no gate
#   run_all -sweep   every config          -> gate, fails the regression
#
# Shared on purpose: the test list lives only in sim_configs.py, so the two
# entry points cannot drift apart. One implementation, two callers.
#----------------------------------------------------------------------------

from sim_configs import MANDATORY_COVER_BINS, SWEEP_ONLY_COVER_BINS

MARKER = "COVERAGE HIT:"


def collect(log_root):
    """Union the 'COVERAGE HIT: <bin>' markers across every log under log_root."""
    hit = set()
    for log_path in log_root.rglob("*.log"):
        for line in log_path.read_text(errors="ignore").splitlines():
            if MARKER in line:
                # The bin name is the last whitespace-delimited token: the
                # Verilog emit space-pads through a fixed-width reg.
                name = line.split(MARKER, 1)[1].split()
                if name:
                    hit.add(name[-1])
    return hit


def report(log_root, single_config, width=90):
    """Print a coverage report and return the bins that should FAIL the caller.

    single_config=True  (bare run_all): bins listed in SWEEP_ONLY_COVER_BINS are
                        unreachable by construction, so they are reported as
                        expected-absent and never fail. A gate that always failed
                        would just teach everyone to ignore the line.
    single_config=False (sweep): every mandatory bin must be hit somewhere.
    """
    hit      = collect(log_root)
    required = [b for b in MANDATORY_COVER_BINS
                if not (single_config and b in SWEEP_ONLY_COVER_BINS)]
    missing  = [b for b in required if b not in hit]
    expected = [b for b in MANDATORY_COVER_BINS
                if single_config and b in SWEEP_ONLY_COVER_BINS and b not in hit]

    scope = "default config only" if single_config else "union across all configs"
    lines = ["=" * width,
             f"  functional coverage -- {len(required) - len(missing)}/{len(required)}"
             f" required bins hit ({scope})",
             "=" * width]

    for b in expected:
        lines.append(f"  not reachable in this config, covered by run_all -sweep -> {b}")
    for b in missing:
        lines.append(f"  COVERAGE GAP: required bin never hit -> {b}")

    if missing:
        lines.append(f"  -> coverage FAILED ({len(missing)} bin(s) unexercised)")
    elif single_config:
        lines.append("  -> coverage OK for this config "
                     "(the gate with teeth is run_all -sweep)")
    else:
        lines.append("  -> coverage PASSED (all mandatory bins exercised)")

    text = "\n".join(lines)
    print()
    print(text)
    (log_root / "coverage.log").write_text(text + "\n")
    return missing
