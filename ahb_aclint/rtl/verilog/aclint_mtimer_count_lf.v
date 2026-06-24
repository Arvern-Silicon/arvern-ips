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
// Module Description : Low-frequency MTIME counter and per-hart MTIMECMP
//                      comparators. Runs entirely in the clk_lf_i domain so
//                      the timer keeps ticking (and can wake a WFI-halted
//                      hart) even when hclk_i is gated.
//----------------------------------------------------------------------------
`default_nettype none

module  aclint_mtimer_count_lf #(
    parameter                      NUM_HARTS = 1,       // Number of harts (1..16)
    parameter                      ARST_EN   = 1'b1     // Reset style: 1=asynchronous, 0=synchronous
) (

// LOW-FREQUENCY CLOCK & RESET
    input  wire                    clk_lf_i,            // Low-frequency clock (e.g. 32 kHz)
    input  wire                    resetn_lf_i,         // Active-low async reset (sync-deassert)

// MTIMECMP VALUES
    input  wire [64*NUM_HARTS-1:0] mtimecmp_lf_i,       // Per-hart MTIMECMP (flattened)

// COUNTER OUTPUTS
    output wire             [63:0] mtime_gray_lf_o,     // Gray-encoded MTIME (registered, glitch-free for CDC)
    output wire    [NUM_HARTS-1:0] irq_m_timer_lf_o     // Per-hart comparator output (registered, glitch-free)
);


//=============================================================================
// 1)  GRAY MTIME REGISTER + DERIVED BINARY VIEWS
//=============================================================================
// The counter advances by 1 binary count per clk_lf_i cycle.

wire [63:0] mtime_gray_lf;
wire [63:0] mtime_bin_now;

aclint_gray2bin #(.W(64)) u_gray2bin (
    .gray_i   ( mtime_gray_lf ),
    .binary_o ( mtime_bin_now )
);

// Next-cycle binary view (= mtime + 1)
wire [63:0] mtime_bin_next  = mtime_bin_now + 64'h1;
wire [63:0] mtime_gray_next = mtime_bin_next ^ (mtime_bin_next >> 1);


//=============================================================================
// 2)  GRAY COUNTER STATE UPDATE
//=============================================================================

arv_ipdff #(.WIDTH(64), .ARST_EN(ARST_EN)) u_mtime_gray_lf (
                   .clk_i(clk_lf_i), .rst_n_i(resetn_lf_i), .en_i(1'b1),
                                                            .d_i (mtime_gray_next),
                                                            .q_o (mtime_gray_lf));

assign mtime_gray_lf_o = mtime_gray_lf;


//=============================================================================
// 3)  PER-HART COMPARATORS (REGISTERED, +1 OFFSET)
//=============================================================================
// "mtime >= mtimecmp[h]" raises the per-hart interrupt level.
//
// The comparator uses mtime_bin_next (= mtime + 1) instead of mtime_bin_now
// to compensate for the 1-cycle clk_lf_i flop delay of irq_m_timer_lf_r.
// Without the +1 offset, the IRQ would assert one LF cycle AFTER the cycle
// in which the unregistered comparator first evaluates true; with the
// offset, irq_m_timer_lf_r asserts on the same LF edge that mtime first
// equals/exceeds mtimecmp -- matching the spec's "MTIP pending whenever
// MTIME >= MTIMECMP" semantics (RISC-V ACLINT 1.0-rc4, Section 2.3).

wire [NUM_HARTS-1:0] irq_m_timer_lf_r;

genvar h;
generate
    for (h = 0; h < NUM_HARTS; h = h + 1) begin : G_CMP
        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_irq_m_timer_lf (
                           .clk_i(clk_lf_i), .rst_n_i(resetn_lf_i), .en_i(1'b1),
                                                                    .d_i ((mtime_bin_next >= mtimecmp_lf_i[64*h +: 64])),
                                                                    .q_o (irq_m_timer_lf_r[h]));
    end
endgenerate

assign irq_m_timer_lf_o = irq_m_timer_lf_r;


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
