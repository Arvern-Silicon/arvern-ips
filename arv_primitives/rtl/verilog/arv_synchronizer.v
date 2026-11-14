//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arv_synchronizer
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arv_synchronizer.v
// Module Description : Parameterizable W-bit 2-FF synchronizer for crossing
//                      a level signal from one clock domain into clk_i.
//
//                      Reset architecture is selectable via ARST_EN, the reset value
//                      via RST_VAL (default 0; set all-1s for an idle-high line so it
//                      does not glitch low out of reset). With ARST_EN=0 only the
//                      first stage is reset, so sync_o reaches RST_VAL on the second
//                      edge: a synchronous reset must span two destination edges.
//                      Unlike the ordinary flops in this IP family, the synchronizer
//                      does NOT reuse arv_ipdff, because a synchronous-reset flop
//                      adds a 2:1 mux on the D pin -- and a mux on the SECOND stage
//                      (in the meta_q -> sync_q path) eats into the metastability
//                      settling window and degrades MTBF exponentially. The two
//                      reset styles are therefore hand-written (the sync-reset mux
//                      is kept on the first stage only).
//
//                      Simulation only, with `ARV_SYNC_JITTER defined: a bit whose
//                      input changed is, at random, captured one edge late (section 3).
//----------------------------------------------------------------------------
`default_nettype none

module  arv_synchronizer #(
    parameter           W       = 1,          // Width of the signal to synchronize
    parameter [W-1:0]   RST_VAL = {W{1'b0}},  // Reset value (e.g. all-1s for
                                              // an idle-high line, avoiding a reset-0 glitch)
    parameter           ARST_EN = 1'b1        // Reset style: 1=asynchronous, 0=synchronous
) (

// CLOCK & RESET (destination domain)
    input  wire         clk_i,               // Destination clock
    input  wire         rst_n_i,             // Active-low reset (async assert if ARST_EN=1, else sync)

// CROSSING
    input  wire [W-1:0] async_i,             // Source-domain signal (level)
    output wire [W-1:0] sync_o               // Synchronized output in clk_i domain
);


//=============================================================================
// 1)  2-FF SYNCHRONIZER  (meta flop -> sync flop)
//=============================================================================

reg [W-1:0] meta_q;                          // metastability-resolving first stage
reg [W-1:0] sync_q;                          // resynchronized second stage
wire [W-1:0] meta_d;                         // first-stage input: async_i (section 3)

assign sync_o = sync_q;

generate
    if (ARST_EN) begin : g_async_rst                // Asynchronous active-low reset on both stages

        always @(posedge clk_i or negedge rst_n_i)
            if (!rst_n_i) begin
                meta_q <= RST_VAL;
                sync_q <= RST_VAL;
            end else begin
                meta_q <= meta_d;
                sync_q <= meta_q;
            end

    end else begin : g_sync_rst                     // Synchronous reset on the input stage only

        always @(posedge clk_i) begin
            meta_q <= rst_n_i ? meta_d : RST_VAL;   // reset mux stays on the FIRST stage only
            sync_q <= meta_q;                       // (second stage kept mux-free for MTBF)
        end
    end
endgenerate


//=============================================================================
// 2)  PARAMETER RANGE CHECK
//=============================================================================
// pragma translate_off
generate
    if (W < 1) begin : CHECK_W
        initial $fatal(1, "arv_synchronizer: W (%0d) must be >= 1.", W);
    end
endgenerate
// pragma translate_on


//=============================================================================
// 3)  METASTABILITY MODEL  (simulation only: `ARV_SYNC_JITTER)
//=============================================================================
// Without the define (synthesis, lint, every flow by default) the first stage
// samples async_i. With it, each bit whose input changed is captured one edge
// late at random -- the first stage resolved to the old value -- never on two
// edges in a row: a change reaches sync_o on the second or third edge, and
// the W bits of a bundle may arrive on different edges. The draws are made on
// the falling edge of clk_i, seeded from `SEED (when the bench defines it)
// and the instance path, so a run is reproducible from its seed.
`ifdef ARV_SYNC_JITTER
// pragma translate_off
// The model's own state is not design state: outside code coverage
// verilator coverage_off
reg     [W-1:0] jit_sel;                     // hold the bit on the next rising edge
reg     [W-1:0] jit_held;                    // bits held (late) on the last rising edge
reg [8*128-1:0] jit_name;                    // instance path, hashed into the seed
integer         jit_seed;
reg      [31:0] jit_r;                       // one draw
integer         jit_cnt;                     // late captures so far
integer         jit_i, jit_b, jit_p;

initial begin
    $sformat(jit_name, "%m");
`ifdef SEED
    jit_seed = `SEED;
`else
    jit_seed = 1;
`endif
    for (jit_i = 0; jit_i < 128; jit_i = jit_i + 1)
        jit_seed = jit_seed * 31 + {24'd0, jit_name[8*jit_i +: 8]};
    jit_sel  = {W{1'b0}};
    jit_held = {W{1'b0}};
    jit_cnt  = 0;
end

always @(negedge clk_i)
    for (jit_b = 0; jit_b < W; jit_b = jit_b + 1) begin
        jit_r          = $random(jit_seed);
        jit_sel[jit_b] = jit_r[0] & ~jit_held[jit_b];
    end

// A change is compared with !== (an X on the input or the first stage counts
// as one), so jit_held and jit_sel never carry an X: an X there would hold
// the first stage at X on every edge, however long the input is stable
always @(posedge clk_i) begin
    for (jit_p = 0; jit_p < W; jit_p = jit_p + 1)
        jit_held[jit_p] = jit_sel[jit_p] & (async_i[jit_p] !== meta_q[jit_p]);
    if (rst_n_i && (|jit_held)) begin
        jit_cnt = jit_cnt + 1;
        if (jit_cnt == 1)
            $display("ARV_SYNC_JITTER: %m: first late capture at %0t", $time);
    end
end
// verilator coverage_on

assign meta_d = (jit_sel & meta_q) | (~jit_sel & async_i);
// pragma translate_on
`else
assign meta_d = async_i;
`endif

endmodule // arv_synchronizer

`default_nettype wire
