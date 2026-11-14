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
# Module Description : Design-specific VC Static lint waivers for apb_usb_host.
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
# arv_synchronizer's SECOND stage carries no reset under ASYNC_RST_EN=0, by
# design (same waiver as ahb_aclint / arv_dtm / apb_i2s): a reset mux in the
# meta_q -> sync_q path would eat the metastability settling window. sync_q
# reaches RST_VAL one clock after meta_q.
#
# CONDITIONAL on the reset style, so the waiver is never stale.
# ---------------------------------------------------------------------------
if {[info exists RTL_PARAM_ASYNC_RST_EN] && $RTL_PARAM_ASYNC_RST_EN == 0} {
    waive_hdl -add sync_stage2_no_reset \
              -comment "arv_synchronizer sync_q: unreset by design under ASYNC_RST_EN=0 -- a reset mux in the meta->sync path would degrade MTBF" \
              -filter {Tag=~CODING_FF_NO_RST_SET && Signal=~*_sync/sync_q}
}


# ---------------------------------------------------------------------------
# Documented mixed reset value: CTRL resets to 0x6 (BOOT = IDLE0 = 1, EN = 0,
# doc "Register map"), one flop vector with set and reset bits from one reset
# tree, by design. Always elaborated.
# ---------------------------------------------------------------------------
waive_hdl -add ctrl_mixed_rstval \
          -comment "u_ctrl_lo resets to CTRL[2:0] = 3'b110 (BOOT, IDLE0 set): mixed set/reset from one reset is by design" \
          -tag CODING_TREE_SETRST_ORIG \
          -filter {Signal=~*u_ctrl_lo/q_o*}

# ---------------------------------------------------------------------------
# MDELEG reset values come from MDELEG_RST. A field reset to Supervisor (2'b01)
# makes one flop of the 2-bit u_mdeleg_wr_priv / u_mdeleg_rd_priv vector reset
# to 1 and the other to 0: VC Static reports the set/reset mix of one reset
# tree (CODING_TREE_SETRST_ORIG). Mixed set/reset values are by design -- the
# reset value is a parameter, and 2'b01 is the only legal code that mixes them.
#
# CONDITIONAL on an MDELEG_RST override with a field at 2'b01; the default
# 9'h10F resets both fields to 2'b11.
# ---------------------------------------------------------------------------
if {[info exists RTL_PARAM_MDELEG_RST]
    && [regexp {'[hH]([0-9a-fA-F]+)} $RTL_PARAM_MDELEG_RST -> _mdeleg_rst_hex]} {
    scan $_mdeleg_rst_hex %x _mdeleg_rst
    if {(($_mdeleg_rst & 3) == 1) || ((($_mdeleg_rst >> 2) & 3) == 1)} {
        waive_hdl -add mdeleg_mixed_rstval \
                  -comment "MDELEG field reset to Supervisor (2'b01): mixed set/reset from one reset is by design" \
                  -tag CODING_TREE_SETRST_ORIG \
                  -filter {Signal=~*u_mdeleg_*_priv/q_o*}
    }
}
