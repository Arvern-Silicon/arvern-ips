#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Module:    waivers.tcl
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : waivers.tcl
# Module Description : Design-specific VC Static lint waivers for apb_periph_example.
#----------------------------------------------------------------------------
# Sourced by vc_lint.tcl after check_hdl, so waived violations are classified
# as they are found. Waived items still appear in report.lint_waived.txt.
#
# `waive_hdl -not_applied` runs after the check and run_vclint reports the count
# as `stale=` -- a non-zero stale count means a waiver matched nothing and
# should be removed or re-scoped. Gate a waiver on RTL_PARAM_* (from
# results/rtl_params.tcl, generated out of rtl_configs.py) when the RTL it
# covers is only elaborated in some configs, so the stale signal stays honest.
#----------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# The aRVern *_unused sink-wire convention (shared with the core, see
# arvern/lint/vc_static/waivers.tcl). A wire whose name ends in _unused exists
# precisely to document a signal that is deliberately not consumed -- an
# unloaded net is the intended state, not a finding.
#
# Scope note: waives by signal name only, so it covers every tag that can fire
# on such a net (CONN_NET_UNLOADED, CONN_INTERNAL_NET_UNLOADED,
# CONN_PORT_UNLOADED). Nothing without the suffix is waived.
# ---------------------------------------------------------------------------
waive_hdl -add unused_sink_wires \
          -comment "Deliberate *_unused sink wires: unloaded by design (aRVern convention)" \
          -filter {Signal=~*_unused*}

# ---------------------------------------------------------------------------
# arv_ipdff with a mixed RST_VAL: bits that reset to 1 infer an async SET and
# bits that reset to 0 an async RESET, both from presetn_i -- the normal
# implementation of a flop with a non-zero reset value. Here it is an MDELEG
# privilege field (u_mdeleg_wr_priv / u_mdeleg_rd_priv) reset to Supervisor,
# 2'b01, the only legal code that mixes the two.
#
# CONDITIONAL on an MDELEG_RST override with a field at 2'b01; the default
# 9'h10F resets both fields to 2'b11.
# ---------------------------------------------------------------------------
if {[info exists RTL_PARAM_MDELEG_RST]
    && [regexp {'[hH]([0-9a-fA-F]+)} $RTL_PARAM_MDELEG_RST -> _mdeleg_rst_hex]} {
    scan $_mdeleg_rst_hex %x _mdeleg_rst
    if {(($_mdeleg_rst & 3) == 1) || ((($_mdeleg_rst >> 2) & 3) == 1)} {
        waive_hdl -add dff_mixed_rstval_setreset \
                  -comment "arv_ipdff with a mixed RST_VAL (MDELEG field reset to Supervisor): mixed set/reset from one reset is by design" \
                  -tag CODING_TREE_SETRST_ORIG \
                  -filter {Module=~arv_*dff*}
    }
}
