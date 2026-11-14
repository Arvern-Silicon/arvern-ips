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
# Module Description : Design-specific VC Static lint waivers for apb_i2s.
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
# design (same waiver as ahb_aclint / arv_dtm): a reset mux in the
# meta_q -> sync_q path would eat the metastability settling window. sync_q
# reaches RST_VAL one clock after meta_q.
#
# CONDITIONAL on the reset style and a receive path (the synchroniser is
# absent with RX_EN=0), so the waiver is never stale.
# ---------------------------------------------------------------------------
if {[info exists RTL_PARAM_ASYNC_RST_EN] && $RTL_PARAM_ASYNC_RST_EN == 0 &&
    !([info exists RTL_PARAM_RX_EN] && $RTL_PARAM_RX_EN == 0)} {
    waive_hdl -add sync_stage2_no_reset \
              -comment "arv_synchronizer sync_q: unreset by design under ASYNC_RST_EN=0 -- a reset mux in the meta->sync path would degrade MTBF" \
              -filter {Tag=~CODING_FF_NO_RST_SET && Signal=~*u_rx_sync/sync_q}
}

# ---------------------------------------------------------------------------
# FORMAT resets to I2S (6'b000010): one bit of u_fmt resets to 1, the others
# to 0 -- a mixed set/reset from one reset tree, by design (the reset value is
# the documented I2S format). Always elaborated.
# ---------------------------------------------------------------------------
waive_hdl -add fmt_mixed_rstval \
          -comment "u_fmt resets to the I2S format 6'b000010: mixed set/reset from one reset is by design" \
          -tag CODING_TREE_SETRST_ORIG \
          -filter {Signal=~*u_fmt/q_o*}

# ---------------------------------------------------------------------------
# CONN_NET_FANIN_DEADLOOP on the receive FIFO's storage counter
# (g_rx.u_fifo/mcnt_nxt) with RX_FIFO_AW >= 7 is a false positive: the counter
# is the storage occupancy, incremented by every push the head cannot take and
# decremented by every head reload. The tool reports no input reaching it from
# 128 words up (and none at 64 or below, nor on the identical transmit FIFO);
# the rx_overrun test fills all 2^RX_FIFO_AW words in the fifo256 and
# rx_only_open simulation configs and reads them back in order, and coverage
# shows every counter bit toggling. CONDITIONAL on RX_FIFO_AW >= 7 with a
# receive path, so it is never stale.
# ---------------------------------------------------------------------------
set _rx_aw 5
if {[info exists RTL_PARAM_RX_FIFO_AW]} { set _rx_aw $RTL_PARAM_RX_FIFO_AW }
set _rx_en 1
if {[info exists RTL_PARAM_RX_EN]} { set _rx_en $RTL_PARAM_RX_EN }
if {$_rx_en == 1 && $_rx_aw >= 7} {
    waive_hdl -add rx_fifo_count_deadloop \
              -comment "false positive: the receive FIFO storage counter is driven by pushes and head reloads; filled to 2^AW in simulation, every bit toggles in coverage" \
              -tag CONN_NET_FANIN_DEADLOOP \
              -filter {Node=~*g_rx.u_fifo/mcnt_nxt*}
}
# ---------------------------------------------------------------------------
# CONN_NET_FANIN_DEADLOOP on the BCLK divider (u_core/bcnt_nxt[4:1]) in a
# transmit-only build with a 32-word or larger transmit FIFO is the same
# false positive: the report names an unrelated "dead load" (paddr_i[2]), the
# counter is cleared at every BCLK tick and incremented at every MCLK tick,
# and it is not reported with a receive path nor with a 2-word FIFO. The
# clk_ratios test checks every BCLK half-period for every RATIO and slot size
# in the tx_only simulation config, and coverage shows every bit toggling.
# CONDITIONAL on RX_EN=0 and TX_FIFO_AW >= 5, the configs where it fires.
# ---------------------------------------------------------------------------
set _tx_aw 5
if {[info exists RTL_PARAM_TX_FIFO_AW]} { set _tx_aw $RTL_PARAM_TX_FIFO_AW }
if {$_rx_en == 0 && $_tx_aw >= 5} {
    waive_hdl -add bclk_count_deadloop \
              -comment "false positive: the BCLK divider counts MCLK ticks; every BCLK half-period checked in simulation, every bit toggles in coverage" \
              -tag CONN_NET_FANIN_DEADLOOP \
              -filter {Node=~*u_core/bcnt_nxt*}
}
unset -nocomplain _rx_aw _rx_en _tx_aw

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
        waive_hdl -add dff_mixed_rstval_setreset \
                  -comment "arv_ipdff with a mixed RST_VAL (MDELEG field reset to Supervisor): mixed set/reset from one reset is by design" \
                  -tag CODING_TREE_SETRST_ORIG \
                  -filter {Module=~arv_*dff*}
    }
}
