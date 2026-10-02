//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    aclint_lf_tick
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : aclint_lf_tick.v
// Module Description : Observes clk_lf_i from the hclk_aon_i domain and turns it
//                      into a one-cycle enable, so the MTIMER's slow state is a
//                      clock ENABLE rather than a second clock domain. Also
//                      reports when that observation is trustworthy.
//
// THE TICK LANDS AFTER THE EDGE
//   lf_tick_o pulses 2-4 hclk_aon_i cycles after each clk_lf_i rising edge, so
//   whatever moves on it moves 3-5 cycles after that edge (see the budgets). That
//   ordering is what makes both directions ordinary registered paths: LF flops
//   have settled by the time it fires, and an hclk_aon_i register that changes
//   only on the tick is stable for nearly a full LF period before the next LF
//   edge samples it. No Gray coding, no handshake.
//
//   Both directions rest on the max_delay exceptions in
//   synthesis/synopsys/constraints.tcl. Unlike a handshake this structure is not
//   self-protecting: a missing constraint fails silently in simulation.
//
// TICK TIMING AND THE TWO BUDGETS (single source; constraints.tcl and
// aclint_mtimer_wr_shadow.v refer here)
//   The sampling pipeline is 4 flops deep: synchronizer (2) + one extra stage +
//   the edge-detect delay flop. Call the clk_lf_i rising edge t0 and the first
//   hclk_aon_i edge after it e1, with t0 < e1 <= t0 + T. The tick is high
//   between e3 and e4, so everything that moves ON the tick moves at e4.
//   e1 is the first edge that CAN capture t0, not the one that must: t0 landing
//   in its setup window lets the synchronizer's first stage resolve to the old
//   value, so the capture slips to e2 and the tick with it. Hence the tick lands
//   3 to 5 hclk after the LF edge, and the two budgets take opposite ends:
//     * LF -> hclk: LF flops launch at t0, the hclk side captures at
//       e4 >= t0 + 3T.  Budget: 3 * CLOCK_PERIOD.
//     * hclk -> LF: hclk flops launch at e4 <= t0 + 5T, the LF side samples
//       at t0 + T_lf.   Budget: CLK_LF_PERIOD - 5 * CLOCK_PERIOD.
//   The extra stage is what gives the first budget its margin: a 2-FF
//   synchronizer alone captures as early as 2T after the LF edge, leaving
//   exactly 2T with nothing for clock uncertainty. It costs one flop and one
//   hclk of tick latency, invisible at LF rates.
//
// TIMING REQUIREMENT -- PER PHASE, NOT PER PERIOD
//   EACH clk_lf_i PHASE MUST BE >= 2 hclk_aon_i PERIODS -- both of them, since a
//   narrow LOW phase leaves lf_sync stuck at 1 and loses the rising edge just as
//   a narrow HIGH phase does.
//
//   clk_lf_i MUST ALSO BE RUNNING BEFORE THE SYSTEM LEAVES RESET, AND NEVER STOP.
//   The tick this module produces is MTIME's clock enable under LF_SYNC_EN=1 and
//   its clock under LF_SYNC_EN=0, so an absent clk_lf_i is not a degraded timebase
//   -- it is no timebase. Tying clk_lf_i to hclk_aon_i does not collapse the
//   crossing harmlessly: it breaks the phase rule above and no tick is ever
//   produced. See doc/ahb_aclint.md, "Clocks".
//
// TRUST AFTER A CLOCK STOP
//   On resumption the sampling pipeline holds a mix of pre-stop and fresh values,
//   so its edge detector can fire with no defined relationship to any clk_lf_i
//   edge. Consumers capture 64-bit LF state on the tick, so a mis-timed one takes
//   MTIME mid-increment -- torn, not merely stale.
//
//   No flop clocked by hclk_aon_i can detect that its own clock stopped, so
//   hclk_aon_en_i reports it: deasserted synchronously on the last running
//   edge, asserted asynchronously on wake before the clock restarts. Trust is
//   withdrawn on that last edge and re-established only after the pipeline has
//   been refilled (Section 2).
//----------------------------------------------------------------------------
`default_nettype none

module  aclint_lf_tick #(
    parameter            ARST_EN  = 1'b1    // Reset style: 1=asynchronous, 0=synchronous
) (

// ALWAYS-ON AHB-FREQUENCY DOMAIN
    input  wire          hclk_aon_i,        // Always-on AHB-frequency clock (NEVER gated)
    input  wire          hresetn_i,         // Active-low reset (hclk domain)

// LOW-FREQUENCY DOMAIN
    input  wire          clk_lf_i,          // Low-frequency clock, sampled here AS DATA

// OSCILLATOR CONTROLLER
    input  wire          hclk_aon_en_i,     // 1 = hclk_aon_i is, or is about to be, running. Deasserted synchronously
                                            // one edge BEFORE the clock stops; asserted asynchronously on wake, before it restarts.

// DFT
    input  wire          scan_mode_i,       // 1 = scan/test mode; isolates the clock-as-data path. Tie LOW functionally.

// OUTPUTS (hclk_aon_i domain)
    output wire          lf_tick_o,          // 1 cycle, asserted 2-4 hclk after each clk_lf_i rising edge; consumers move on the following edge.
    output wire          lf_trust_rstn_o     // Active-low reset for hclk-side state derived from ticks (async assert, sync release).
);


//=============================================================================
// 1)  CLK_LF AS DATA -> RISING-EDGE TICK
//=============================================================================

wire lf_sync;
wire lf_sync_s3;
wire lf_sync_d;
wire clk_lf_data;

// Keeps clk_lf_i off the synchronizer's D pin in scan (pre-DFT DRC D10).
arv_and #(.N(2)) u_clk_lf_isolate (
    .a_i ( {clk_lf_i, ~scan_mode_i} ),
    .z_o ( clk_lf_data              )
);

arv_synchronizer #(.W(1), .ARST_EN(ARST_EN)) u_lf_sync (
    .clk_i    ( hclk_aon_i  ),
    .rst_n_i  ( hresetn_i   ),
    .async_i  ( clk_lf_data ),
    .sync_o   ( lf_sync     )
);

// Third sampling stage: moves the tick (and everything that moves on it) one
// hclk later, which is what gives the LF -> hclk crossing a 3T budget instead
// of exactly 2T. See the header.
arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_lf_sync_s3 (
              .clk_i(hclk_aon_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                       .d_i (lf_sync), .q_o(lf_sync_s3));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_lf_sync_d (
              .clk_i(hclk_aon_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                       .d_i (lf_sync_s3), .q_o(lf_sync_d));

wire tick_raw = lf_sync_s3 & ~lf_sync_d;


//=============================================================================
// 2)  TRUST
//=============================================================================
// warm_cnt refills the 4-deep sampling pipeline of Section 1 before ticks are
// trusted again. Its reset, trust_rstn, asserts as soon as hresetn_i or
// hclk_aon_en_i drops and releases two hclk_aon_i edges later through a
// synchronizer, so a release coinciding with a running clock edge (a wake
// arriving after the enable dropped but before the clock stopped) cannot leave
// warm_cnt or the mirror-valid flop metastable.
//
// The synchronizer is asynchronously reset in BOTH reset styles. hclk_aon_en_i
// drops only one edge before the clock stops, so a reset applied through a
// D-pin mux would never reach the synchronizer's output, and the wake would
// release trust_rstn straight from the asynchronous hclk_aon_en_i. Like the
// oscillator controller, it must record an event while no clock runs.
//
// The final AND with trust_rstn_raw is the scan bypass: with scan_mode_i=1 the
// OR holds the release path high and trust_rstn = trust_rstn_raw = hresetn_i,
// controllable from the pin (the synchronizer's flops are on the scan chain --
// DRC D3 otherwise). The first OR takes hclk_aon_en_i out of the reset in scan
// mode, so the DFT flow needs no test-constant declaration for it.

wire hclk_aon_en_or_scan;
wire trust_rstn_raw;
wire trust_rstn_rel;
wire trust_rstn_rel_or_scan;
wire trust_rstn;

arv_or #(.N(2)) u_hclk_aon_en_scan_bypass (
    .a_i ( {hclk_aon_en_i, scan_mode_i} ),
    .z_o (  hclk_aon_en_or_scan         )
);

arv_and #(.N(2)) u_trust_rstn_raw (
    .a_i ( {hresetn_i, hclk_aon_en_or_scan} ),
    .z_o ( trust_rstn_raw                   )
);

arv_synchronizer #(.W(1), .RST_VAL(1'b0), .ARST_EN(1'b1)) u_trust_rstn_sync (
    .clk_i    ( hclk_aon_i     ),
    .rst_n_i  ( trust_rstn_raw ),
    .async_i  ( 1'b1           ),
    .sync_o   ( trust_rstn_rel )
);

arv_or #(.N(2)) u_trust_rstn_rel_scan_bypass (
    .a_i ( {trust_rstn_rel, scan_mode_i} ),
    .z_o (  trust_rstn_rel_or_scan       )
);

arv_and #(.N(2)) u_trust_rstn (
    .a_i ( {trust_rstn_raw, trust_rstn_rel_or_scan} ),
    .z_o (  trust_rstn                              )
);

// Trusted once the pipeline has been refreshed: 4 edges after the (synchronized)
// reset release, i.e. after the last pre-stop sample has left lf_sync_d.
wire [2:0] warm_cnt;
wire [2:0] warm_nxt = (warm_cnt == 3'd4) ? 3'd4 : (warm_cnt + 3'd1);

arv_ipdff #(.WIDTH(3), .ARST_EN(ARST_EN)) u_warm_cnt (
              .clk_i(hclk_aon_i), .rst_n_i(trust_rstn), .en_i(1'b1),
                                                        .d_i (warm_nxt), .q_o(warm_cnt));

wire trusted = (warm_cnt == 3'd4);

assign lf_tick_o       = tick_raw & trusted;
assign lf_trust_rstn_o = trust_rstn;

endmodule // aclint_lf_tick

`default_nettype wire
