//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    aclint_mtimer_count_lf
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : aclint_mtimer_count_lf.v
// Module Description : MTIME counter and per-hart MTIMECMP comparators. This
//                      is the LF-resident island: it runs entirely in the
//                      clk_lf_i domain so the timer keeps counting -- and can
//                      still assert the wake that restarts a stopped main
//                      oscillator -- when hclk_i AND hclk_aon_i are both gone.
//                      Nothing here may depend on an hclk-derived enable.
//
// WHY THE COUNTER IS PLAIN BINARY
//   The hclk_aon_i side captures it into a mirror on lf_tick, a bounded time
//   AFTER the clk_lf_i edge, when every bit has settled. A value that is only
//   ever sampled stable needs no Gray encoding, and Gray would actively hurt on
//   writes, where an arbitrary jump flips many bits at once.
//
// LOAD ONE-SHOT -- SAFETY, NOT OPTIMISATION
//   load_req_i is a level driven by the hclk_aon_i side and cleared by it one LF
//   period later. If hclk_aon_i stops while it is asserted -- exactly what deep
//   sleep does -- a level-sensitive load would re-apply the same value on every
//   clk_lf_i edge and freeze MTIME at the written value for the whole sleep. The
//   edge detect below makes that impossible: after the first load, load_req_d is
//   high and no further load occurs however long the request stays asserted.
//
//   The paired guarantee -- that the request is eventually RETIRED -- comes from
//   the hclk side holding its clock enable. That is liveness; correctness here
//   must not depend on it, and does not.
//----------------------------------------------------------------------------
`default_nettype none

module  aclint_mtimer_count_lf #(
    parameter                      NUM_HARTS  = 1,      // Number of harts (1..16)
    parameter                      LF_SYNC_EN = 1'b0,   // 1 => no clk_lf_i domain; the wake comparators are elided and wake_lf_o is held asserted
    parameter                      ARST_EN    = 1'b1    // Reset style: 1=asynchronous, 0=synchronous
) (

// LOW-FREQUENCY CLOCK & RESET
    input  wire                    clk_lf_i,            // LF clock, or hclk_aon_i under LF_SYNC_EN
    input  wire                    resetn_lf_i,         // Active-low reset (asynchronous when ARST_EN=1, synchronous otherwise)
    input  wire                    lf_en_i,             // Tick enable: 1'b1 in async mode, the LF pulse in sync mode

// MTIMECMP VALUES
    input  wire [64*NUM_HARTS-1:0] mtimecmp_i,          // Per-hart MTIMECMP (flattened)

// MTIME LOAD PORT
    input  wire                    load_req_i,          // Load request level
    input  wire             [63:0] load_val_i,          // 64-bit value to load
    input  wire              [1:0] load_we_i,           // Halves this load writes: [0]=LO, [1]=HI

// COUNTER OUTPUTS
    output wire             [63:0] mtime_lf_o,          // Binary MTIME (LF domain)
    output wire                    load_ack_lf_o,       // Load pending: high from the launch tick until the clk_lf_i edge that consumes it, so it falls ON the load, not after it. Bench probe only; no RTL consumer.
    output wire    [NUM_HARTS-1:0] wake_lf_o            // Wake-up for the SoC's LF-domain power controller to restart the main oscillator. Constant 1 under LF_SYNC_EN.
);


//=============================================================================
// 1)  LOAD REQUEST EDGE DETECT (ONE-SHOT)
//=============================================================================

wire load_req_d;

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_load_req_d (
              .clk_i(clk_lf_i), .rst_n_i(resetn_lf_i), .en_i(lf_en_i),
                                                       .d_i (load_req_i), .q_o(load_req_d));

wire   mtime_load    = load_req_i & ~load_req_d;

assign load_ack_lf_o = mtime_load &  lf_en_i;


//=============================================================================
// 2)  MTIME COUNTER
//=============================================================================
// A write REPLACES the count for that edge instead of incrementing (ACLINT 1.0
// Section 2.2): the tick the load lands on is consumed by the load, so software
// reads back exactly what it wrote rather than value+1.
//
// Halves written together arrive together -- they share one shadow and one
// request -- so a 64-bit MTIME write is ATOMIC at the counter.
//
// A half that software did NOT write must HOLD, not increment. Holding keeps
// LO's carry out of a just-loaded HI, and stops a half-write from silently
// advancing the other half by one.

wire [63:0] mtime_lf;
wire [63:0] mtime_inc = mtime_lf + 64'h1;
wire [63:0] mtime_next;

assign mtime_next[31:0]  = mtime_load ? (load_we_i[0] ? load_val_i[31:0]  : mtime_lf[31:0] ) : mtime_inc[31:0] ;
assign mtime_next[63:32] = mtime_load ? (load_we_i[1] ? load_val_i[63:32] : mtime_lf[63:32]) : mtime_inc[63:32];

arv_ipdff #(.WIDTH(64), .ARST_EN(ARST_EN)) u_mtime_lf (
              .clk_i(clk_lf_i), .rst_n_i(resetn_lf_i), .en_i(lf_en_i),
                                                       .d_i (mtime_next), .q_o(mtime_lf));

assign mtime_lf_o = mtime_lf;


//=============================================================================
// 3)  PER-HART WAKE COMPARATORS
//=============================================================================
// Built ONLY under LF_SYNC_EN=0, where they are this block's reason for
// existing: a comparator clocked by clk_lf_i is what can assert a wake with
// hclk_aon_i stopped, and so is what restarts the oscillator. Under LF_SYNC_EN
// the whole bank would run on hclk_aon_i, could not outlive a stopped clock, and
// would only duplicate irq_m_timer_o -- so it is parameterized away rather than
// left as NUM_HARTS 64-bit comparators of dead area. The wake is then held
// ASSERTED, not silent: MTIME itself runs on hclk_aon_i in that mode, so the
// clock must never stop, and a permanent wake request makes that impossible for
// a controller that honours it rather than a rule the integrator has to read.
//
// The compare is against mtime_next, the value the counter is about to take,
// which cancels the flop's LF cycle of latency: wake_lf_o rises on the same LF
// edge that mtime first reaches mtimecmp (ACLINT 1.0-rc4 Section 2.3). On a load
// edge mtime_next IS the loaded value, so the comparison is against what the
// counter actually takes.
//
// Registered, not combinational: a 64-bit compare glitches while it settles, and
// the consumer is an always-on power controller that needs a clean level.

genvar h;
generate
if (LF_SYNC_EN == 0) begin : G_WAKE

    wire [NUM_HARTS-1:0] wake_lf_r;

    for (h = 0; h < NUM_HARTS; h = h + 1) begin : G_CMP
        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_wake_lf (
                           .clk_i(clk_lf_i), .rst_n_i(resetn_lf_i), .en_i(lf_en_i),
                                                                    .d_i ((mtime_next >= mtimecmp_i[64*h +: 64])),
                                                                    .q_o (wake_lf_r[h]));
    end

    assign wake_lf_o = wake_lf_r;

end else begin : G_NO_WAKE

    assign wake_lf_o = {NUM_HARTS{1'b1}};

    // mtimecmp_i has no other consumer here; sink it per the *_unused convention.
    wire [64*NUM_HARTS-1:0] mtimecmp_unused;
    assign mtimecmp_unused = mtimecmp_i;

end
endgenerate


//=============================================================================
// 4)  PARAMETER RANGE CHECK
//=============================================================================
// pragma translate_off
generate
    if ((NUM_HARTS < 1) || (NUM_HARTS > 16)) begin : CHECK_NUM_HARTS
        initial $fatal(1, "aclint_mtimer_count_lf: NUM_HARTS (%0d) must be 1..16.", NUM_HARTS);
    end
endgenerate
// pragma translate_on

endmodule // aclint_mtimer_count_lf

`default_nettype wire
