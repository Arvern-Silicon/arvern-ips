#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    gen_rtl_params.py
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : gen_rtl_params.py
# Module Description : Emit an rtl_params.tcl for one parameter config of this
#                      IP. Shared by the synthesis and VC Static flows so a
#                      config cannot mean different things to each.
#----------------------------------------------------------------------------
# WHY THIS FILE EXISTS
#
# Simulation, Verilator lint and VC Static lint all sweep an IP's parameter
# configs. The single source of truth is sim/rtl_sim/bin/rtl_configs.py --
# shared with the Verilator lint sweep and (where present) the synthesis
# sweep, so a config cannot mean one thing to one flow and another to the
# next. This script is the one translation from that table to the Tcl the
# Synopsys tools read.
#
# IDENTICAL IN EVERY IP. rtl_configs.py comes in two shapes and both are
# accepted:
#   - (label, params)       with a module-level TOP_MODULE   -- single-top IPs
#   - (label, top, params)  one top per config                -- multi-top IPs
#                                                               (arv_dtm,
#                                                               ahb_interconnect)
#
# OUTPUT (rtl_params.tcl)
#   RTL_CONFIG_LABEL      the config's label
#   RTL_TOP               the module to elaborate for this config
#   RTL_PARAM_<NAME>      one per overridden parameter, so a downstream script
#                         can test one without re-parsing ELABORATE_PARAMS.
#                         ARST_EN (the arv_primitives spelling, used by arv_dtm
#                         and the sub-blocks) is ALSO emitted as
#                         RTL_PARAM_ASYNC_RST_EN, because rules.tcl keys its
#                         reset-style rule selection on that name.
#   ELABORATE_PARAMS      the -parameters string for `elaborate`, or "" for
#                         RTL defaults
#----------------------------------------------------------------------------

import argparse
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
try:
    import rtl_configs  # noqa: E402
except ImportError as exc:                       # pragma: no cover
    sys.exit(f"gen_rtl_params.py: cannot import rtl_configs from {SCRIPT_DIR}: {exc}")

CONFIGS = rtl_configs.CONFIGS
TOP_MODULE = getattr(rtl_configs, "TOP_MODULE", None)


def normalise(entry):
    """Return (label, top, params) for either CONFIGS shape."""
    if len(entry) == 3:
        return entry
    if len(entry) == 2:
        if TOP_MODULE is None:
            sys.exit("gen_rtl_params.py: rtl_configs.py uses (label, params) entries "
                     "but defines no TOP_MODULE")
        label, params = entry
        return label, TOP_MODULE, params
    sys.exit(f"gen_rtl_params.py: malformed rtl_configs entry: {entry!r}")


ENTRIES = [normalise(e) for e in CONFIGS]


def resolve(sel):
    """Return (label, top, params) for a 1-based index or a config label."""
    if sel is None:
        return ENTRIES[0]
    if str(sel).isdigit():
        i = int(sel)
        if not (1 <= i <= len(ENTRIES)):
            sys.exit(f"gen_rtl_params.py: config index {i} out of range 1..{len(ENTRIES)}")
        return ENTRIES[i - 1]
    for e in ENTRIES:
        if e[0] == sel:
            return e
    known = ", ".join(e[0] for e in ENTRIES)
    sys.exit(f"gen_rtl_params.py: unknown config '{sel}' (have: {known})")


def write_params(label, top, params, out_path, force_sync_reset=False):
    eff = dict(params)
    if force_sync_reset:
        # Use whichever spelling the IP's top already uses, else the AHB one.
        key = "ARST_EN" if "ARST_EN" in eff else "ASYNC_RST_EN"
        eff[key] = 0

    lines = [
        "#" + "-" * 76,
        "# AUTO-GENERATED -- do not edit. Source: sim/rtl_sim/bin/rtl_configs.py",
        f"# Config: {label}  (top: {top})",
        "#" + "-" * 76,
        "",
        f'set RTL_CONFIG_LABEL "{label}"',
        f'set RTL_TOP "{top}"',
    ]
    for k, v in sorted(eff.items()):
        lines.append(f"set RTL_PARAM_{k} {v}")
    if "ARST_EN" in eff and "ASYNC_RST_EN" not in eff:
        lines.append(f"set RTL_PARAM_ASYNC_RST_EN {eff['ARST_EN']}")

    if eff:
        assigns = ",".join(f"{k}={v}" for k, v in sorted(eff.items()))
        lines.append(f'set ELABORATE_PARAMS "-parameters \\"{assigns}\\""')
    else:
        lines.append("# RTL defaults -- no -parameters override")
        lines.append('set ELABORATE_PARAMS ""')

    out_path.write_text("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser(description="Generate rtl_params.tcl for one RTL config")
    ap.add_argument("--rtl-config", dest="cfg", default=None,
                    help="1-based index or label from sim/rtl_sim/bin/rtl_configs.py")
    ap.add_argument("--list-configs", action="store_true",
                    help="print '<idx>\\t<label>\\t<top + params>' for every config")
    ap.add_argument("--with-sync-reset", action="store_true",
                    help="force the synchronous reset style on top of the selected config")
    ap.add_argument("-o", "--output", default=None,
                    help="path of the rtl_params.tcl to write (required unless --list-configs)")
    args = ap.parse_args()

    if not args.list_configs and args.output is None:
        ap.error("-o/--output is required unless --list-configs")

    if args.list_configs:
        tops = sorted({e[1] for e in ENTRIES})
        print(f"# RTL sweep set ({len(ENTRIES)} configs, tops: {', '.join(tops)})")
        print("# Shared with: run_lint -sweep, run_vclint -rtl_sweep, run_syn -rtl_sweep (where present)")
        for i, (label, top, params) in enumerate(ENTRIES, 1):
            desc = " ".join(f"{k}={v}" for k, v in sorted(params.items())) or "(defaults)"
            print(f"{i}\t{label}\ttop={top} {desc}")
        return

    label, top, params = resolve(args.cfg)
    write_params(label, top, params, Path(args.output), args.with_sync_reset)
    print(label)


if __name__ == "__main__":
    main()
