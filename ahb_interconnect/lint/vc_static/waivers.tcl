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
# Module Description : Design-specific VC Static lint waivers for ahb_interconnect.
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
# Registered feedback through a flop primitive (shared with the SoC envs).
#
# "Instance has input connected to output": a net that leaves an arv_ipdff on
# q_o and re-enters it on d_i through an expression written inline in the port
# map -- the default subordinate's two-cycle data-phase shift
# ({data_phase[0], addr_phase}) -- plus the AHB hready feedback into the
# manager and subordinate muxes, which is the protocol. The loop is closed
# through a flop, never combinationally. Fires on every fabric variant.
# ---------------------------------------------------------------------------
waive_hdl -add ipdff_registered_feedback \
          -comment "q_o -> inline expression -> d_i on the same flop instance: registered feedback, not a combinational loop" \
          -tag CODING_INST_CONNECTED_INPUT_OUTPUT

# ---------------------------------------------------------------------------
# arv_ipdff with a non-zero RST_VAL: bits that reset to 1 infer an async SET
# and bits that reset to 0 an async RESET, both from the same hresetn_i --
# exactly what the rule describes, and the normal implementation of a flop
# with a non-zero reset value. Here it is the fused ROM controller's
# arbitration state, which resets to 2'b01 (round-robin, port B first).
#
# CONDITIONAL on the fused top with at least one ROM slot: the flop lives in
# ahb_fused_rom_ctrl, which the generic / hiperf tops and the NR_S_X_ROM=0
# build do not instantiate.
# ---------------------------------------------------------------------------
if {$TOP eq "ahb_interconnect_fused"
    && (![info exists RTL_PARAM_NR_S_X_ROM] || $RTL_PARAM_NR_S_X_ROM != 0)} {
    waive_hdl -add dff_nonzero_rstval_setreset \
              -comment "arv_ipdff with non-zero RST_VAL (fused ROM ctrl u_arb): mixed set/reset from one reset is by design" \
              -tag CODING_TREE_SETRST_ORIG \
              -filter {Module=~arv_*dff*}
}
