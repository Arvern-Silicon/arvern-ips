//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    aclint_mtimer_wr_shadow
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : aclint_mtimer_wr_shadow.v
// Module Description : Moves MTIMECMP and MTIME write data from the AHB side to
//                      the LF domain with no handshake, and so without ever
//                      back-pressuring the bus. Nothing here is clocked by
//                      clk_lf_i.
//
//     AHB write --> stage 1 --> stage 2 --> read directly by the LF domain
//                   hclk_i      hclk_aon_i
//                   wr strobe   lf_tick_i
//
// WHY TWO STAGES, ON DIFFERENT CLOCKS
//   Stage 1 accepts a write on any cycle, so hreadyout_o never drops. Its enable
//   is an AHB strobe, which cannot occur while hclk_i is gated, so the gated
//   clock costs it nothing and keeps the bank still whenever the bus is idle.
//
//   Stage 2 moves only on lf_tick_i, hence only just after a clk_lf_i edge,
//   which leaves it stable for nearly a whole LF period before the LF side
//   samples it. It must be always-on: lf_tick_i ignores bus activity, and the LF
//   side has to read a settled value with hclk_i gated.
//
//   Collapsing the two would put the AHB write and the LF sampling edge in
//   direct conflict, leaving only a bus stall or a race. stage1 -> stage2 is not
//   a domain crossing: the SDC declares one clock across hclk_i and hclk_aon_i.
//
// THE LF SIDE READS STAGE 2 -- THERE IS NO THIRD COPY
//   Stage 2 moves on the tick, at most 5 hclk after the clk_lf_i edge (see
//   aclint_lf_tick.v, "tick timing and the two budgets"), so measured against
//   the next clk_lf_i edge it offers a setup margin of an LF period less 5 hclk
//   -- the CLK_LF_PERIOD - 5*CLOCK_PERIOD exception in constraints.tcl -- and a
//   hold margin of at least 3 hclk. A comparator on that path spends
//   nanoseconds of that budget, so re-registering it in the LF domain would buy
//   nothing and cost 64 flops per hart.
//
//   It follows that MTIMECMP is reset by hresetn_i and NOT by resetn_lf_i -- the
//   opposite of MTIME. ACLINT 1.0-rc4 Section 2.3 leaves the reset value
//   unspecified, and a warm reset of the AHB domain also resets the hart that
//   programmed the deadline, so disarming is coherent. mtimer_warm_reset pins it.
//
// THE MTIME LOAD IS COUNTED, NOT ACKNOWLEDGED
//   This side can see the LF edges, so it counts instead of handshaking: raise
//   load_req_o on one tick, and the clk_lf_i edge before the next tick is
//   guaranteed to have consumed it, so drop it there. No ack, no busy flag, and
//   none of the reset-domain failure modes a toggle handshake has.
//
//   Safety lives on the LF side, which edge-detects load_req_o: if hclk_aon_i
//   stops mid-request, a level-sensitive load would repeat on every LF edge.
//   wr_pending_o is liveness only -- it asks the integrator to keep the clock
//   alive until the request retires.
//----------------------------------------------------------------------------
`default_nettype none

module  aclint_mtimer_wr_shadow #(
    parameter                       NUM_HARTS = 1,       // Number of harts (1..16)
    parameter                       ARST_EN   = 1'b1     // Reset style: 1=asynchronous, 0=synchronous
) (

// CLOCKS & RESETS
    input  wire                      hclk_i,             // AHB clock (gated by hclk_en_o at the SoC-level ICG)
    input  wire                      hclk_aon_i,         // Always-on AHB-frequency clock (NEVER gated)
    input  wire                      hresetn_i,          // Active-low reset (both)

// LF OBSERVATION
    input  wire                      lf_tick_i,          // 1 cycle, just after each clk_lf_i rising edge

// AHB-SIDE WRITE PORT (accepted unconditionally -- never back-pressured)
    input  wire               [31:0] wr_data_i,          // Write data
    input  wire    [NUM_HARTS-1:0]   mtimecmp_lo_wr_i,   // Per-hart MTIMECMP_LO write strobe
    input  wire    [NUM_HARTS-1:0]   mtimecmp_hi_wr_i,   // Per-hart MTIMECMP_HI write strobe
    input  wire                      mtime_lo_wr_i,      // MTIME_LO write strobe
    input  wire                      mtime_hi_wr_i,      // MTIME_HI write strobe

// AHB-SIDE READ-BACK (reflects what was written)
    output wire [64*NUM_HARTS-1:0]   mtimecmp_main_o,    // Per-hart MTIMECMP as last written
    output wire               [63:0] mtime_wr_main_o,    // Pending MTIME write value

// TO THE LF SIDE (hclk_aon_i registers, read across the boundary)
    output wire [64*NUM_HARTS-1:0]   mtimecmp_cmp_o,     // Per-hart MTIMECMP for the LF comparator (stage 2)
    output wire                      load_req_o,         // MTIME load request level (changes only on lf_tick_i)
    output wire               [63:0] load_val_o,         // MTIME load value (changes only on lf_tick_i)
    output wire                [1:0] load_we_o,          // Which halves this load writes: [0]=LO, [1]=HI

// READ-PATH SELECTS (per half -- a write to one half must not expose the other
// half's shadow, which holds the last value WRITTEN there, not the live count)
    output wire                      mtime_lo_pending_o, // LO shadow is authoritative
    output wire                      mtime_hi_pending_o, // HI shadow is authoritative

// CLOCK-ENABLE ADVISORY
    output wire                      wr_pending_o        // Hold hclk_en_o while high (liveness, not safety)
);


//=============================================================================
// 1)  PER-HART MTIMECMP
//=============================================================================

genvar hh;
generate
    for (hh = 0; hh < NUM_HARTS; hh = hh + 1) begin : G_HART

        wire [31:0] cmp_lo_s1, cmp_hi_s1;
        wire [31:0] cmp_lo_s2, cmp_hi_s2;

        // Stage 1 -- accepts the AHB write on any cycle.
        arv_ipdff #(.WIDTH(32), .RST_VAL(32'hFFFFFFFF), .ARST_EN(ARST_EN)) u_cmp_lo_s1 (
                      .clk_i(hclk_i),     .rst_n_i(hresetn_i), .en_i(mtimecmp_lo_wr_i[hh]),
                                                               .d_i (wr_data_i), .q_o(cmp_lo_s1));

        arv_ipdff #(.WIDTH(32), .RST_VAL(32'hFFFFFFFF), .ARST_EN(ARST_EN)) u_cmp_hi_s1 (
                      .clk_i(hclk_i),     .rst_n_i(hresetn_i), .en_i(mtimecmp_hi_wr_i[hh]),
                                                               .d_i (wr_data_i), .q_o(cmp_hi_s1));

        // Stage 2 -- moves ONLY on the tick, i.e. just after an LF edge.
        arv_ipdff #(.WIDTH(32), .RST_VAL(32'hFFFFFFFF), .ARST_EN(ARST_EN)) u_cmp_lo_s2 (
                      .clk_i(hclk_aon_i), .rst_n_i(hresetn_i), .en_i(lf_tick_i),
                                                               .d_i (cmp_lo_s1), .q_o(cmp_lo_s2));

        arv_ipdff #(.WIDTH(32), .RST_VAL(32'hFFFFFFFF), .ARST_EN(ARST_EN)) u_cmp_hi_s2 (
                      .clk_i(hclk_aon_i), .rst_n_i(hresetn_i), .en_i(lf_tick_i),
                                                               .d_i (cmp_hi_s1), .q_o(cmp_hi_s2));

        assign mtimecmp_cmp_o [64*hh +: 64] = {cmp_hi_s2, cmp_lo_s2};
        assign mtimecmp_main_o[64*hh +: 64] = {cmp_hi_s1, cmp_lo_s1};
    end
endgenerate

// A MTIMECMP write needs ONE tick to reach the comparator: the tick moves stage
// 1 into stage 2, and the comparator reads stage 2. Until that tick the
// comparator still sees the OLD deadline.
//
// Without this hold, `sw mtimecmp; wfi` -- the canonical tickless idle -- lets
// every clock request drop while the new deadline is still stranded in stage 1.
// The oscillator stops, the comparator never matches, and nothing wakes the
// chip. Unlike the MTIME write hazards below, that one does not self-correct.
//
// cmp_recent falls on the same edge that loads stage 2, which is exactly right:
// from then on stage 2 holds the deadline and needs no further clock.
wire cmp_any_wr = (|mtimecmp_lo_wr_i) | (|mtimecmp_hi_wr_i);

wire cmp_recent;

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_cmp_recent (
              .clk_i(hclk_aon_i), .rst_n_i(hresetn_i), .en_i(cmp_any_wr | lf_tick_i),
                                                       .d_i (cmp_any_wr), .q_o(cmp_recent));


//=============================================================================
// 2)  MTIME WRITE DATA
//=============================================================================
// The two halves share one 64-bit shadow and one request, so a HI-then-LO pair
// written back to back lands on the counter as a single atomic load. A load
// still carries per-half write enables, because sharing the shadow must not mean
// writing one half implies writing the other.

wire [31:0] mtime_lo_s1, mtime_hi_s1;

arv_ipdff #(.WIDTH(32), .ARST_EN(ARST_EN)) u_mtime_lo_s1 (
              .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(mtime_lo_wr_i),
                                                   .d_i (wr_data_i), .q_o(mtime_lo_s1));

arv_ipdff #(.WIDTH(32), .ARST_EN(ARST_EN)) u_mtime_hi_s1 (
              .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(mtime_hi_wr_i),
                                                   .d_i (wr_data_i), .q_o(mtime_hi_s1));

wire [63:0] load_val;

assign load_val_o      = load_val;
assign mtime_wr_main_o = {mtime_hi_s1, mtime_lo_s1};


//=============================================================================
// 3)  LOAD REQUEST -- OPEN LOOP, RETIRED BY COUNTING TICKS
//=============================================================================
// load_pend records which halves are waiting. A launch moves them into load_req
// / load_we / load_val, which then hold for exactly one tick-to-tick interval --
// guaranteed to contain the one clk_lf_i edge that consumes them.
//
// A launch waits for a QUIET tick, one with no write since the previous tick.
// That is what batches a HI-then-LO pair into a single atomic load: launching on
// a tick that fell BETWEEN the two stores would put new-HI with stale-LO on the
// counter, a value firmware never wrote. It costs one LF period of write
// latency, invisible beside the one the load already waits for.
//
// ~load_req is redundant given wr_recent, and kept as a guard. The LF side
// consumes by EDGE, so load_req must fall between two loads or the second never
// happens; shortening the wr_recent wait to reclaim that LF period would
// silently swallow a write without it.

wire [1:0] load_pend;
wire [1:0] load_we;
wire       load_req;
wire       wr_recent;

wire [1:0] wr_now       = {mtime_hi_wr_i, mtime_lo_wr_i};
wire       mtime_any_wr = |wr_now;

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_wr_recent (
              .clk_i(hclk_aon_i), .rst_n_i(hresetn_i), .en_i(mtime_any_wr | lf_tick_i),
                                                       .d_i (mtime_any_wr), .q_o(wr_recent));

wire       load_launch   = lf_tick_i & (|load_pend) & ~wr_recent & ~load_req;

// Accumulate, don't overwrite: HI and LO arrive on separate cycles. A write
// landing ON the launch tick belongs to the NEXT load -- stage 1 and load_val
// update on that same edge, so this launch carries the pre-write value.
wire [1:0] load_pend_nxt = load_launch ? wr_now : (load_pend | wr_now);

arv_ipdff #(.WIDTH(2), .ARST_EN(ARST_EN)) u_load_pend (
              .clk_i(hclk_aon_i), .rst_n_i(hresetn_i), .en_i(mtime_any_wr | load_launch),
                                                       .d_i (load_pend_nxt), .q_o(load_pend));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_load_req (
              .clk_i(hclk_aon_i), .rst_n_i(hresetn_i), .en_i(lf_tick_i),
                                                       .d_i (load_launch), .q_o(load_req));

// Which halves to apply. The other half's stage-1 shadow holds the last value
// SOFTWARE wrote there, not the live count, so applying it would clobber that
// half with something stale (0 out of reset).
arv_ipdff #(.WIDTH(2), .ARST_EN(ARST_EN)) u_load_we (
              .clk_i(hclk_aon_i), .rst_n_i(hresetn_i), .en_i(load_launch),
                                                       .d_i (load_pend), .q_o(load_we));

// Declared after load_launch by necessity: vcst rejects the forward reference
// that Verilator would silently infer as an implicit net.
arv_ipdff #(.WIDTH(64), .ARST_EN(ARST_EN)) u_load_val_s2 (
              .clk_i(hclk_aon_i), .rst_n_i(hresetn_i), .en_i(load_launch),
                                                       .d_i ({mtime_hi_s1, mtime_lo_s1}), .q_o(load_val));

assign load_req_o = load_req;
assign load_we_o  = load_we;

// Continuous across the launch edge: load_pend clears exactly as load_req sets
// and load_we captures, so the select never glitches low mid-flight. It falls on
// the retiring tick -- the same tick that refreshes the mirror.
assign mtime_lo_pending_o = load_pend[0] | (load_req & load_we[0]);
assign mtime_hi_pending_o = load_pend[1] | (load_req & load_we[1]);

assign wr_pending_o = (|load_pend) | load_req | wr_recent | cmp_recent;


//=============================================================================
// 4)  PARAMETER RANGE CHECK
//=============================================================================
// pragma translate_off
generate
    if ((NUM_HARTS < 1) || (NUM_HARTS > 16)) begin : CHECK_NUM_HARTS
        initial $fatal(1, "aclint_mtimer_wr_shadow: NUM_HARTS (%0d) must be 1..16.", NUM_HARTS);
    end
endgenerate
// pragma translate_on

endmodule // aclint_mtimer_wr_shadow

`default_nettype wire
