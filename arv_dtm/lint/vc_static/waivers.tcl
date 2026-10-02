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
# Module Description : Design-specific VC Static lint waivers for arv_dtm.
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
# Which transport is being linted. Four of the five tops ARE a transport; the
# arv_dtm wrapper selects one with DTM_TYPE. Most waivers below only apply to
# some transports, and are gated on this so they cannot report stale in the
# configs where the RTL they cover is not even elaborated.
# ---------------------------------------------------------------------------
set _transport "unknown"
switch -glob -- $TOP {
    *_jtag   { set _transport "jtag"  }
    *_uart   { set _transport "uart"  }
    *_i2c    { set _transport "i2c"   }
    *_cjtag  { set _transport "cjtag" }
    arv_dtm  {
        set _t 0
        if {[info exists RTL_PARAM_DTM_TYPE]} { set _t $RTL_PARAM_DTM_TYPE }
        set _transport [lindex {jtag uart i2c cjtag} $_t]
    }
}
set _syncrst [expr {[info exists RTL_PARAM_ASYNC_RST_EN] && $RTL_PARAM_ASYNC_RST_EN == 0}]
puts "\[vc_lint\] arv_dtm waivers: transport=$_transport sync_reset=$_syncrst"

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
# Gated on the transport (below): the JTAG top declares no *_unused sink, so
# an unconditional entry would read as stale in the jtag_* configs.
if {$_transport ne "jtag" || $TOP eq "arv_dtm"} {
    waive_hdl -add unused_sink_wires \
              -comment "Deliberate *_unused sink wires: unloaded by design (aRVern convention)" \
              -filter {Signal=~*_unused*}
}

# ---------------------------------------------------------------------------
# Registered feedback through a flop primitive (shared with the SoC envs).
#
# "Instance has input connected to output": a net that leaves an arv_ipdff on
# q_o and re-enters it on d_i through an expression written inline in the port
# map -- the DMI master's level-toggle handshake flops (.d_i(~req_level)), the
# cJTAG escape counter / toggles, the JTAG wake toggle. The loop is closed
# through a flop, never combinationally. Fires on every transport.
# ---------------------------------------------------------------------------
waive_hdl -add ipdff_registered_feedback \
          -comment "q_o -> inline expression -> d_i on the same flop instance: registered feedback, not a combinational loop" \
          -tag CODING_INST_CONNECTED_INPUT_OUTPUT

# ---------------------------------------------------------------------------
# Reset synchronisers built from arv_synchronizer with async_i tied to 1'b1:
# the TAP's u_tap_rst_sync / u_hclk_rst_sync and the cJTAG front end's
# u_clk_rst_sync. Async assertion through rst_n_i, release by shifting a
# constant 1 through two stages -- the tied input IS the mechanism. Same
# disposition as the core's post-reset one-shot flops (tied_input_oneshot_ff).
#
# Scoped to the reset synchronisers by instance name; a tied data input
# anywhere else stays reported. JTAG and cJTAG only (UART / I2C have no TAP).
# ---------------------------------------------------------------------------
if {$_transport eq "jtag" || $_transport eq "cjtag"} {
    waive_hdl -add reset_synchronizer_tied_input \
              -comment "Reset synchroniser: async_i tied to 1'b1 is the release mechanism (async assert, sync release)" \
              -tag SYN_FF_CONST_INP \
              -filter {Signal=~*rst_sync/meta_q*}
}

# ---------------------------------------------------------------------------
# arv_ipdff with a non-zero RST_VAL: bits that reset to 1 infer an async SET
# and bits that reset to 0 an async RESET, both from one reset -- the normal
# implementation of a flop with a non-zero reset value. The TAP's u_ir resets
# to IR_IDCODE and u_state to S_TLR by spec; the UART's u_ab_div resets to the
# default baud divider. I2C has none.
# ---------------------------------------------------------------------------
if {$_transport ne "i2c"} {
    waive_hdl -add dff_nonzero_rstval_setreset \
              -comment "arv_ipdff with non-zero RST_VAL (TAP u_ir / u_state, UART u_ab_div): mixed set/reset from one reset is by design" \
              -tag CODING_TREE_SETRST_ORIG \
              -filter {Module=~arv_*dff*}
}

# ---------------------------------------------------------------------------
# The RX FIFO storage array (arv_dtm_rxfifo mem) has no reset: standard RAM
# inference, a flush only moves the pointers. Both reset rules object to an
# unreset register; only the one matching the build's reset style is enabled,
# so the tag list is what keeps this entry from reading stale in either.
# Serial transports only -- the FIFO sits behind the command interpreter
# (arv_dtm_cmd) that UART and I2C share.
# ---------------------------------------------------------------------------
if {$_transport eq "uart" || $_transport eq "i2c"} {
    waive_hdl -add rxfifo_storage_no_reset \
              -comment "arv_dtm_rxfifo mem: RAM-style storage array, unreset by design (flush moves pointers only)" \
              -tag {CODING_FF_NO_RST_SET CODING_RST_ASYNC_FF} \
              -filter {Signal=~*u_rxfifo/mem*}
}

# ---------------------------------------------------------------------------
# INHERITED from ahb_aclint: arv_synchronizer's SECOND stage carries no reset
# under a synchronous reset style, by design -- a reset mux in the
# meta_q -> sync_q path would eat into the metastability settling window. The
# reset mux is kept on the first stage only. Every transport has at least one
# such synchroniser on its clk_i side (u_rx_sync, u_req_h_sync, ...).
# ---------------------------------------------------------------------------
if {$_syncrst} {
    waive_hdl -add sync_stage2_no_reset \
              -comment "arv_synchronizer sync_q: unreset by design under a sync reset style -- a reset mux in the meta->sync path would degrade MTBF" \
              -filter {Tag=~CODING_FF_NO_RST_SET && Signal=~*sync_q}
}

# ---------------------------------------------------------------------------
# The probe-clock domain is ALWAYS asynchronously reset, whatever ARST_EN says.
#
# arv_dtm_tap.v and arv_dtm_cjtag.v both fix TCK_ARST = 1'b1: TCK / TCKC come
# from the external probe and may not be running, so a synchronous reset could
# never initialise that domain. ARST_EN governs only the clk_i / hclk_i side.
# In a sync-reset build the TCK-domain flops (TAP state, IR, wake toggle, the
# TCK-side reset synchroniser, the OScan1 activation FSM) are therefore
# reported against CODING_FF_NO_ASYNC, and are correct.
#
# By tag: the TCK-domain flops are arv_ipdff / arv_synchronizer instances like
# every other flop, so there is no module to scope on, and waive_hdl cannot
# filter by clock. A clk_i-side flop mistakenly left async in a sync build
# would be hidden here -- accepted, and the reason the TCK_ARST rationale is
# restated at each site in the RTL. JTAG and cJTAG only.
# ---------------------------------------------------------------------------
if {$_syncrst && ($_transport eq "jtag" || $_transport eq "cjtag")} {
    waive_hdl -add tck_domain_async_reset \
              -comment "TCK / TCKC domain: async reset by design (TCK_ARST=1) -- the probe clock may not be running" \
              -tag CODING_FF_NO_ASYNC
}

# ---------------------------------------------------------------------------
# CONN_NET_FANIN_DEADLOOP / CONN_NET_FANOUT_DEADLOOP on the OScan1 activation
# counter / phase (arv_dtm_cjtag act_cnt[4:3], act_phase[2:1]).
#
# The rule claims "none of the inputs have any effect on" those bits (and, for
# act_phase, that they affect no output). The RTL says otherwise, and so does
# the hardware: act_cnt counts the 24-bit GRL phase to 5'd23 (bit 4 set) before
# act_phase advances to the CP; act_phase[2:1] select P_CP_BODY / P_CP_POST,
# whose exit sets `online` and with it tmsc_oe_o. cJTAG activation works on
# silicon-equivalent FPGA hardware with a stock probe.
#
# The reported population is consistent with a depth-limited traversal of the
# increment carry chain: bit [3] upward is reported, lower bits never are, and
# the "dead loads" listed are the .en_i(1'b1) pins of the neighbouring
# constant-enable flops. Treated as an analysis artefact of this rule on
# registered next-state feedback; waived by tag, scoped to the module, so the
# same rule stays live everywhere else.
# ---------------------------------------------------------------------------
if {$_transport eq "cjtag"} {
    waive_hdl -add cjtag_activation_counter_deadloop \
              -comment "OScan1 activation counter / phase: rule cannot see the tmsc-derived control through the carry chain; functional on hardware" \
              -tag {CONN_NET_FANIN_DEADLOOP CONN_NET_FANOUT_DEADLOOP} \
              -filter {Module=~arv_dtm_cjtag}
}
unset -nocomplain _transport _syncrst _t
