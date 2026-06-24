//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    aclint_mtimer_write_cdc
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : aclint_mtimer_write_cdc.v
// Module Description : Per-hart MTIMECMP write handshakes from the AHB
//                      (hclk_i) domain to the LF (clk_lf_i) domain. Each
//                      hart has independent LO and HI handshakes that share
//                      the same level-toggle pattern:
//                        + AHB-side write pulse latches the 32-bit half into
//                          a main-domain register and toggles a level.
//                        + The level is 2-FF synced into LF and edge-detected.
//                          On any edge, the LF-side captures the latched data
//                          into the resident MTIMECMP_LF register and toggles
//                          an ack level.
//                        + The ack level is 2-FF synced back to hclk and
//                          edge-detected to clear the per-hart write_busy_o
//                          flag, indicating the write is committed and a new
//                          pulse may be issued.
//                      Reset value for every MTIMECMP_LF half is all-ones so
//                      the comparator in aclint_mtimer_count_lf never asserts
//                      before firmware writes a real value.
//
// BUSY SET/CLEAR PRIORITY: each per-hart busy_lo/busy_hi flop is set by
//                      write_*_pulse_i and cleared by ack_*_main_edge using
//                      an if-elsif chain that gives SET priority. This is
//                      defensive: simultaneous set + clear is impossible by
//                      construction (the LF roundtrip is many hclk cycles
//                      and write_*_pulse_i is gated by ~busy externally),
//                      but if it ever occurred the SET wins and the next
//                      write transaction is preserved instead of silently
//                      dropped.
//----------------------------------------------------------------------------
`default_nettype none

module  aclint_mtimer_write_cdc #(
    parameter                       NUM_HARTS = 1,                      // Number of harts (1..16)
    parameter                       ARST_EN   = 1'b1                    // Reset style: 1=asynchronous, 0=synchronous
) (

// CLOCKS & RESETS
    input  wire                      hclk_i,                            // AHB clock domain
    input  wire                      hresetn_i,                         // Active-low async reset (hclk domain)
    input  wire                      clk_lf_i,                          // Low-frequency clock domain
    input  wire                      resetn_lf_i,                       // Active-low async reset (LF domain)

// AHB-SIDE WRITE INTERFACE (per-hart, flattened)
    input  wire [32*NUM_HARTS-1:0]   mtimecmp_lo_i,                     // Per-hart LO half (write data)
    input  wire [32*NUM_HARTS-1:0]   mtimecmp_hi_i,                     // Per-hart HI half (write data)
    input  wire    [NUM_HARTS-1:0]   write_lo_pulse_i,                  // Per-hart LO write strobe (1 hclk)
    input  wire    [NUM_HARTS-1:0]   write_hi_pulse_i,                  // Per-hart HI write strobe (1 hclk)
    output wire    [NUM_HARTS-1:0]   write_lo_busy_o,                   // Per-hart LO handshake in flight
    output wire    [NUM_HARTS-1:0]   write_hi_busy_o,                   // Per-hart HI handshake in flight

// MAIN-DOMAIN SHADOW REGISTERS (for AHB read-back; no CDC concern)
    output wire [32*NUM_HARTS-1:0]   mtimecmp_lo_main_o,                // Per-hart LO half (hclk-domain copy)
    output wire [32*NUM_HARTS-1:0]   mtimecmp_hi_main_o,                // Per-hart HI half (hclk-domain copy)

// LF-SIDE MTIMECMP REGISTERS (flattened, fed to the comparators)
    output wire [64*NUM_HARTS-1:0]   mtimecmp_lf_o
);


//=============================================================================
// 1)  PER-HART HANDSHAKE INSTANCES
//=============================================================================
// Each hart owns two identical mini-handshakes (LO + HI). The two halves are
// independent on purpose: firmware writes HI=all-ones then LO then HI=value
// to avoid a spurious intermediate match, and each half's CDC must complete
// without coupling to the other.

genvar hh;
generate
    for (hh = 0; hh < NUM_HARTS; hh = hh + 1) begin : G_HART

        //---------------------------------------------------------------------
        // 1.a) MAIN-DOMAIN LATCHES + LEVEL TOGGLES (one per half)
        //---------------------------------------------------------------------
        wire [31:0] data_lo_main;
        wire [31:0] data_hi_main;
        wire        write_lo_level;
        wire        write_hi_level;

        arv_ipdff #(.WIDTH(32), .RST_VAL(32'hFFFFFFFF), .ARST_EN(ARST_EN)) u_data_lo_main (
                                                      .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(write_lo_pulse_i[hh]),
                                                                                           .d_i (mtimecmp_lo_i[32*hh+:32]),
                                                                                           .q_o (data_lo_main));

        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_write_lo_level (
                               .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i( write_lo_pulse_i[hh]),
                                                                    .d_i (~write_lo_level),
                                                                    .q_o ( write_lo_level));

        arv_ipdff #(.WIDTH(32), .RST_VAL(32'hFFFFFFFF), .ARST_EN(ARST_EN)) u_data_hi_main (
                                                      .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(write_hi_pulse_i[hh]),
                                                                                           .d_i (mtimecmp_hi_i[32*hh+:32]),
                                                                                           .q_o (data_hi_main));

        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_write_hi_level (
                               .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i( write_hi_pulse_i[hh]),
                                                                    .d_i (~write_hi_level),
                                                                    .q_o ( write_hi_level));

        //---------------------------------------------------------------------
        // 1.b) hclk -> LF SYNC + EDGE DETECT + CAPTURE
        //---------------------------------------------------------------------
        // 2-FF sync via arv_synchronizer; a third LF-domain flop (_d) holds
        // the previous-cycle sync output so an XOR can detect the level edge.

        wire req_lo_lf;
        wire req_hi_lf;
        wire req_lo_lf_d;
        wire req_hi_lf_d;

        arv_synchronizer #(.W(1), .ARST_EN(ARST_EN)) u_req_lo_lf_sync (
            .clk_i    ( clk_lf_i        ),
            .resetn_i ( resetn_lf_i     ),
            .async_i  ( write_lo_level  ),
            .sync_o   ( req_lo_lf       )
        );

        arv_synchronizer #(.W(1), .ARST_EN(ARST_EN)) u_req_hi_lf_sync (
            .clk_i    ( clk_lf_i        ),
            .resetn_i ( resetn_lf_i     ),
            .async_i  ( write_hi_level  ),
            .sync_o   ( req_hi_lf       )
        );

        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_req_lo_lf_d (
                        .clk_i(clk_lf_i), .rst_n_i(resetn_lf_i), .en_i(1'b1), .d_i(req_lo_lf), .q_o(req_lo_lf_d));

        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_req_hi_lf_d (
                        .clk_i(clk_lf_i), .rst_n_i(resetn_lf_i), .en_i(1'b1), .d_i(req_hi_lf), .q_o(req_hi_lf_d));

        wire req_lo_lf_edge = req_lo_lf ^ req_lo_lf_d;
        wire req_hi_lf_edge = req_hi_lf ^ req_hi_lf_d;

        wire [31:0] mtimecmp_lo_lf;
        wire [31:0] mtimecmp_hi_lf;
        wire        ack_lo_lf_level;
        wire        ack_hi_lf_level;

        arv_ipdff #(.WIDTH(32), .RST_VAL(32'hFFFFFFFF), .ARST_EN(ARST_EN)) u_mtimecmp_lo_lf (
                                                    .clk_i(clk_lf_i), .rst_n_i(resetn_lf_i), .en_i(req_lo_lf_edge),
                                                                                             .d_i (data_lo_main),
                                                                                             .q_o (mtimecmp_lo_lf));

        arv_ipdff #(.WIDTH(32), .RST_VAL(32'hFFFFFFFF), .ARST_EN(ARST_EN)) u_mtimecmp_hi_lf (
                                                    .clk_i(clk_lf_i), .rst_n_i(resetn_lf_i), .en_i(req_hi_lf_edge),
                                                                                             .d_i (data_hi_main),
                                                                                             .q_o (mtimecmp_hi_lf));

        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_ack_lo_lf_level (
                            .clk_i(clk_lf_i), .rst_n_i(resetn_lf_i), .en_i( req_lo_lf_edge),
                                                                     .d_i (~ack_lo_lf_level),
                                                                     .q_o ( ack_lo_lf_level));

        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_ack_hi_lf_level (
                            .clk_i(clk_lf_i), .rst_n_i(resetn_lf_i), .en_i( req_hi_lf_edge),
                                                                     .d_i (~ack_hi_lf_level),
                                                                     .q_o ( ack_hi_lf_level));

        assign mtimecmp_lf_o[64*hh+:64]      = {mtimecmp_hi_lf, mtimecmp_lo_lf};
        assign mtimecmp_lo_main_o[32*hh+:32] = data_lo_main;
        assign mtimecmp_hi_main_o[32*hh+:32] = data_hi_main;

        //---------------------------------------------------------------------
        // 1.c) LF -> hclk SYNC + EDGE DETECT + BUSY CLEAR
        //---------------------------------------------------------------------
        // busy is set when the main-side level toggles (a request is pending)
        // and cleared when the ack edge returns. Setting and clearing in the
        // same cycle (impossible here given the round-trip latency, but safe
        // to express) resolves to cleared.

        wire ack_lo_main;
        wire ack_hi_main;
        wire ack_lo_main_d;
        wire ack_hi_main_d;

        arv_synchronizer #(.W(1), .ARST_EN(ARST_EN)) u_ack_lo_main_sync (
            .clk_i    ( hclk_i          ),
            .resetn_i ( hresetn_i       ),
            .async_i  ( ack_lo_lf_level ),
            .sync_o   ( ack_lo_main     )
        );

        arv_synchronizer #(.W(1), .ARST_EN(ARST_EN)) u_ack_hi_main_sync (
            .clk_i    ( hclk_i          ),
            .resetn_i ( hresetn_i       ),
            .async_i  ( ack_hi_lf_level ),
            .sync_o   ( ack_hi_main     )
        );

        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_ack_lo_main_d (
                              .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(ack_lo_main), .q_o(ack_lo_main_d));

        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_ack_hi_main_d (
                              .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(ack_hi_main), .q_o(ack_hi_main_d));

        wire ack_lo_main_edge = ack_lo_main ^ ack_lo_main_d;
        wire ack_hi_main_edge = ack_hi_main ^ ack_hi_main_d;

        wire busy_lo;
        wire busy_hi;

        // SET-priority: write pulse wins over ack edge when both fire (impossible by
        // construction, but preserved exactly per the original if-elsif chain).
        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_busy_lo (
                        .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(write_lo_pulse_i[hh] | ack_lo_main_edge),
                                                             .d_i (write_lo_pulse_i[hh]),
                                                             .q_o (busy_lo));

        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_busy_hi (
                        .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(write_hi_pulse_i[hh] | ack_hi_main_edge),
                                                             .d_i (write_hi_pulse_i[hh]),
                                                             .q_o (busy_hi));

        assign write_lo_busy_o[hh] = busy_lo;
        assign write_hi_busy_o[hh] = busy_hi;

    end
endgenerate


//=============================================================================
// 2)  PARAMETER RANGE CHECK
//=============================================================================
// pragma translate_off
generate
    if ((NUM_HARTS < 1) || (NUM_HARTS > 16)) begin : CHECK_NUM_HARTS
        initial $fatal(1, "aclint_mtimer_write_cdc: NUM_HARTS (%0d) must be 1..16.", NUM_HARTS);
    end
endgenerate
// pragma translate_on

endmodule // aclint_mtimer_write_cdc

`default_nettype wire
