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
# Module Description : Scoped VC Static lint waivers for ahb_aclint.
#----------------------------------------------------------------------------
# A waiver here says "this rule is right in general, and wrong about THIS
# instance". Prefer fixing the RTL; prefer a scoped waiver over disabling the
# rule globally in rules.tcl.
#
# Every entry must carry a one-line reason. `vc_lint.tcl` runs
# `waive_hdl -not_applied` after the check and run_vclint reports the count as
# `stale=` -- a non-zero stale count means a waiver matched nothing and should
# be removed or re-scoped.
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
# design. A synchronous reset is a 2:1 mux on the D pin, and a mux in the
# meta_q -> sync_q path eats directly into the metastability settling window --
# MTBF is exponential in the time available there, so a single gate costs orders
# of magnitude. The reset mux is therefore kept on the FIRST stage only, whose D
# is the asynchronous input and has no setup relationship to lose.
#
# The cost is bounded and understood: sync_q reaches RST_VAL one clock after
# meta_q (two clocks to clear X out of power-up), and the flop is
# reset-uncontrollable -- which DFT already handles, reporting 0 violations with
# DC leaving it out of the scan chain entirely.
#
# CONDITIONAL on the reset style. In async builds both stages have a real async
# reset and this rule never fires, so an unconditional waiver would be reported
# stale in 9 of the 10 configs -- and this flow treats stale as a failure.
# ---------------------------------------------------------------------------
if {[info exists RTL_PARAM_ASYNC_RST_EN] && $RTL_PARAM_ASYNC_RST_EN == 0} {
    waive_hdl -add sync_stage2_no_reset \
              -comment "arv_synchronizer sync_q: unreset by design under ASYNC_RST_EN=0 -- a reset mux in the meta->sync path would degrade MTBF" \
              -filter {Tag=~CODING_FF_NO_RST_SET && Signal=~*u_lf_sync/sync_q}
}

# ---------------------------------------------------------------------------
# The trust-reset synchronizer in aclint_lf_tick is a reset-release
# synchronizer: its D input is a constant 1 and its state is carried entirely
# by the asynchronous assertion of trust_rstn_raw on its reset pin, with the
# release then rippling through the two stages. A flop with a tied D input is
# exactly what that structure is; there is nothing to fix. The synchronizer is
# asynchronously reset in both reset styles (aclint_lf_tick.v), so this holds
# in every config.
# ---------------------------------------------------------------------------
waive_hdl -add trust_rstn_release_sync \
          -comment "aclint_lf_tick reset-release synchronizer: constant-1 D by construction, state carried by the async reset" \
          -filter {Tag=~SYN_FF_CONST_INP && Signal=~*u_trust_rstn_sync/meta_q}

# ---------------------------------------------------------------------------
# The same two flops are asynchronously reset even in the ASYNC_RST_EN=0 build,
# which CODING_FF_NO_ASYNC (enforced only there, see rules.tcl) reports. Sanctioned
# exception: hclk_aon_en_i drops one edge before the clock stops, so a D-side
# reset would never reach the synchronizer's output and the wake would release
# trust straight from an asynchronous input. Scoped to that instance only; any
# other async flop in a sync build still fails.
# ---------------------------------------------------------------------------
if {[info exists RTL_PARAM_ASYNC_RST_EN] && $RTL_PARAM_ASYNC_RST_EN == 0} {
    waive_hdl -add trust_rstn_sync_async_by_design \
              -comment "aclint_lf_tick u_trust_rstn_sync: asynchronously reset in both reset styles by design (records a clock stop)" \
              -filter {Tag=~CODING_FF_NO_ASYNC && Signal=~*u_trust_rstn_sync/*}
}
