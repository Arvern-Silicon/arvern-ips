#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    rtl_configs_defines.py
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : rtl_configs_defines.py
# Module Description : Print one line per config of rtl_configs.py,
#                      "<label>:<-D defines>", for the simulation bench. Every
#                      NR_* parameter is emitted: a config's overrides on top
#                      of the defaults read from the RTL, so the bench (which
#                      has its own fallbacks) builds exactly that config.
#----------------------------------------------------------------------------
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import rtl_configs  # noqa: E402

RTL = SCRIPT_DIR.parents[2] / "rtl" / "verilog" / "arv_custom_csr.v"
defaults = {m.group(1): int(m.group(2))
            for m in re.finditer(r"^parameter\s+integer\s+(NR_\w+)\s*=\s*(\d+)\s*;",
                                 RTL.read_text(), re.M)}
if len(defaults) != 6:
    sys.exit(f"rtl_configs_defines.py: expected 6 NR_* defaults in {RTL}, found {sorted(defaults)}")

for label, overrides in rtl_configs.CONFIGS:
    params = dict(defaults)
    params.update(overrides)
    print(f"{label}:" + " ".join(f"-D {k}={v}" for k, v in params.items()))
