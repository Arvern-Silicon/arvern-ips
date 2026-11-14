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
# Module Description : Design-specific VC Static lint waivers for apb_spi.
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
# CONDITIONAL on the reset style and a receive path (the lane synchronisers
# are absent with RX_EN=0), so the waiver is never stale.
# ---------------------------------------------------------------------------
if {[info exists RTL_PARAM_ASYNC_RST_EN] && $RTL_PARAM_ASYNC_RST_EN == 0 &&
    !([info exists RTL_PARAM_RX_EN] && $RTL_PARAM_RX_EN == 0)} {
    waive_hdl -add sync_stage2_no_reset \
              -comment "arv_synchronizer sync_q: unreset by design under ASYNC_RST_EN=0 -- a reset mux in the meta->sync path would degrade MTBF" \
              -filter {Tag=~CODING_FF_NO_RST_SET && Signal=~*_sync/sync_q}
}

# ---------------------------------------------------------------------------
# Documented mixed reset values: the lane outputs reset to the driven idle
# bus (u_io: spi_io_oe_o = spi_io_o = 4'b1101, doc "Ports", pins out of
# reset) and CTRL resets to 0x010 (TX_IDLE = 1). One flop vector with set and
# reset bits from one reset tree is by design. Always elaborated.
# ---------------------------------------------------------------------------
waive_hdl -add io_mixed_rstval \
          -comment "u_io resets to the driven idle bus {oe, io} = 8'b1101_1101: mixed set/reset from one reset is by design" \
          -tag CODING_TREE_SETRST_ORIG \
          -filter {Signal=~*u_io/q_o*}
waive_hdl -add ctrl_mixed_rstval \
          -comment "u_ctrl resets to CTRL = 0x010 (TX_IDLE = 1): mixed set/reset from one reset is by design" \
          -tag CODING_TREE_SETRST_ORIG \
          -filter {Signal=~*u_ctrl/q_o*}

# ---------------------------------------------------------------------------
# CONN_NET_FANIN_DEADLOOP on the receive FIFO's storage counter
# (g_rx.u_fifo/mcnt_nxt) with RX_FIFO_AW >= 7 is a false positive, the one
# apb_i2s waives on the same FIFO: the counter is the storage occupancy,
# incremented by every push the head cannot take and decremented by every head
# reload. The rx_stall test fills all 2^RX_FIFO_AW words in the fifo256
# simulation config and reads them back in order, and coverage shows every
# counter bit toggling. CONDITIONAL on RX_FIFO_AW >= 7 with a receive path, so
# it is never stale.
# ---------------------------------------------------------------------------
set _rx_aw 4
if {[info exists RTL_PARAM_RX_FIFO_AW]} { set _rx_aw $RTL_PARAM_RX_FIFO_AW }
set _rx_en 1
if {[info exists RTL_PARAM_RX_EN]} { set _rx_en $RTL_PARAM_RX_EN }
if {$_rx_en == 1 && $_rx_aw >= 7} {
    waive_hdl -add rx_fifo_count_deadloop \
              -comment "false positive: the receive FIFO storage counter is driven by pushes and head reloads; filled to 2^AW in simulation, every bit toggles in coverage" \
              -tag CONN_NET_FANIN_DEADLOOP \
              -filter {Node=~*g_rx.u_fifo/mcnt_nxt*}
}
unset -nocomplain _rx_aw _rx_en

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
