//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    plic_pending
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : plic_pending.v
// Module Description : PLIC per-source pending bits and in-service flops, plus
//                      the level-triggered gateway logic.
//                      Source 0 has no flop.
//                      The gateway behaviour per source s in [1..NUM_SOURCES]:
//                        - pending[s] set when ~in_service[s] & irq_src_i[s].
//                        - pending[s] cleared when claim_pulse_i & (claim_id == s).
//                          Claim wins over level-set on the same source same cycle.
//                        - in_service[s] set on claim_pulse_i & (claim_id == s);
//                          cleared on complete_pulse_i & (complete_id == s).
//                          claim and complete cannot reference the same
//                          source on the same cycle in practice (AHB
//                          serialises), but should they collide the priority
//                          is: claim sets, complete clears -> claim wins
//                          (set has priority over clear for in_service).
//
//                      AHB-side: read-only register window. Writes are
//                      silently dropped. 32 bits per word, bit b of word w =
//                      pending[32*w + b]; bit 0 of word 0 (source 0) reads 0.
//                      Source indices above NUM_SOURCES read 0.
//----------------------------------------------------------------------------
`default_nettype none

module  plic_pending #(
    parameter                          NUM_SOURCES = 31,        // Number of interrupt sources (1..1023)
    parameter                          REG_AW      = 12,        // Reg-bank byte-address width (pending window)
    parameter                          ARST_EN     = 1'b1       // Reset architecture: 1=async active-low, 0=synchronous (passed to arv_ipdff)
) (

// CLOCK & RESET
    input  wire                        hclk_i,                  // AHB clock
    input  wire                        hresetn_i,               // Active-low async reset (sync-deassert)

// LEVEL-TRIGGERED INTERRUPT INPUTS
    input  wire        [NUM_SOURCES:0] irq_src_i,               // External interrupt level lines; irq_src_i[0] unused

// CLAIM / COMPLETE SIDE-BAND FROM PER-CONTEXT TARGETS
    input  wire                        claim_pulse_i,           // 1-cycle pulse: claim accepted
    input  wire                 [10:0] claim_source_id_i,       // Source ID being claimed (0 if pulse low)
    input  wire                        complete_pulse_i,        // 1-cycle pulse: complete written
    input  wire                 [10:0] complete_source_id_i,    // Source ID being completed

// GENERIC REGISTER-BANK INTERFACE
    input  wire                        reg_sel_i,               // Access in flight to this sub-component
    input  wire           [REG_AW-1:0] reg_addr_i,              // Byte address inside the pending window
    input  wire                        reg_wr_en_i,             // 1 = write (silently ignored), 0 = read
    input  wire                 [31:0] reg_wr_data_i,           // Write data (silently dropped)
    output wire                 [31:0] reg_rd_data_o,           // Read data (0 when not selected)
    output wire                        reg_ready_o,             // Always 1 (single-cycle)

// FLAT PENDING + IN-SERVICE OUTPUT TO TARGETS / TOP
    output wire        [NUM_SOURCES:0] pending_o,               // [0] = 1'b0; [s] = pending[s]
    output wire        [NUM_SOURCES:0] in_service_o             // [0] = 1'b0; [s] = in_service[s] (used by hclk_en_o at the top)
);


//=============================================================================
// 1)  ADDRESS DECODE (READ ONLY)
//=============================================================================
// Word index = reg_addr_i[REG_AW-1:2]. Only the lower five bits select a
// real word within the 0x80-byte pending region (32 words = 1024 sources).
// Words above ceil((NUM_SOURCES+1)/32)-1 RAZ.

localparam NUM_WORDS = ((NUM_SOURCES + 1) + 31) / 32;                          // Rounded up

wire [REG_AW-3:0] word_index_full = reg_addr_i[REG_AW-1:2];
wire        [4:0] word_idx        = word_index_full[4:0];
wire              word_in_range   = (word_index_full < NUM_WORDS[REG_AW-3:0]);


//=============================================================================
// 2)  PER-SOURCE PENDING + IN-SERVICE FLOPS
//=============================================================================
// One flop pair per source (1..NUM_SOURCES). Source 0 has no flop.
// Gateway logic per source s:
//
//   pending_next   = claim_match[s]        ? 1'b0
//                  : (~in_service[s] & irq_src_i[s]) ? 1'b1
//                  :                        pending[s];
//   in_service_next= claim_match[s]        ? 1'b1
//                  : complete_match[s]     ? 1'b0
//                  :                        in_service[s];

wire [NUM_SOURCES:1] pending;
wire [NUM_SOURCES:1] in_service;

genvar gs;
generate
    for (gs = 1; gs <= NUM_SOURCES; gs = gs + 1) begin : G_GATEWAY

        wire claim_match    = claim_pulse_i    & (claim_source_id_i    == gs[10:0]);
        wire complete_match = complete_pulse_i & (complete_source_id_i == gs[10:0]);

        // pending[gs]: claim clears (wins), gateway sets when not in service.
        // The flop only changes on a claim (clear) or a gateway-set; otherwise
        // it holds -> en_i = claim_match | (~in_service & irq_src), d_i =
        // ~claim_match (1 on the set path, 0 on the claim-clear path).
        wire pending_en = claim_match | (~in_service[gs] & irq_src_i[gs]);
        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_pending (
                       .clk_i (hclk_i), .rst_n_i(hresetn_i), .en_i( pending_en),
                                                             .d_i (~claim_match),
                                                             .q_o ( pending[gs]));

        // in_service[gs]: claim sets (wins), complete clears. en_i fires on
        // either event; d_i = claim_match (1 sets on claim, 0 clears on the
        // complete-only path).
        wire in_service_en = claim_match | complete_match;
        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_in_service (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(in_service_en),
                                                                .d_i (claim_match),
                                                                .q_o (in_service[gs])
        );
    end
endgenerate


//=============================================================================
// 3)  FLAT PENDING OUTPUT
//=============================================================================

assign pending_o[0]    = 1'b0;  // Source 0 hard-tied 0
assign in_service_o[0] = 1'b0;  // Source 0 hard-tied 0

generate
    for (gs = 1; gs <= NUM_SOURCES; gs = gs + 1) begin : G_PEND_OUT
        assign pending_o[gs]    = pending[gs];
        assign in_service_o[gs] = in_service[gs];
    end
endgenerate


//=============================================================================
// 4)  READ MUX
//=============================================================================
// 32 bits per word; bit b = pending[32*word + b] when that source is in
// range, otherwise 0. Word 0 bit 0 (source 0) is 0.

// Sized casts of the unsigned parameters so the comparisons and array
// indices below stay width-clean for both DC (no VER-318 signed->unsigned)
// and Verilator (no WIDTHEXPAND/TRUNC).
localparam        [31:0] NUM_SOURCES_INT = NUM_SOURCES;
localparam        [10:0] NUM_SOURCES_S11 = NUM_SOURCES_INT[10:0];
localparam               SRC_IDX_W       = $clog2(NUM_SOURCES + 1);

reg  [31:0] rd_word;
reg   [5:0] bb;     // 0..32
reg  [10:0] src;    // 0..NUM_SOURCES (max 1023)
always @(*) begin
    rd_word = 32'h0;
    src     = 11'h0;
    if (word_in_range) begin
        for (bb = 6'h0; bb < 6'd32; bb = bb + 6'h1) begin
            src = {6'h0, word_idx} * 11'd32 + {5'h0, bb};
            if ((src >= 11'h1) && (src <= NUM_SOURCES_S11))
                rd_word[bb[4:0]] = pending[src[SRC_IDX_W-1:0]];
        end
    end
end

assign reg_rd_data_o = (reg_sel_i & ~reg_wr_en_i) ? rd_word : 32'h0;
assign reg_ready_o   = 1'b1;


//=============================================================================
// 5)  PARAMETER RANGE CHECK
//=============================================================================
// pragma translate_off
generate
    if ((NUM_SOURCES < 1) || (NUM_SOURCES > 1023)) begin : CHECK_NUM_SOURCES
        initial $fatal(1, "plic_pending: NUM_SOURCES (%0d) must be 1..1023.", NUM_SOURCES);
    end
    if (REG_AW < 7) begin : CHECK_REG_AW
        initial $fatal(1, "plic_pending: REG_AW (%0d) must be >= 7.", REG_AW);
    end
endgenerate
// pragma translate_on


//=============================================================================
// 6)  LINT CLEANUP
//=============================================================================

wire [31:0] reg_wr_data_unused;
assign      reg_wr_data_unused  = reg_wr_data_i;

wire        irq_src0_unused;
assign      irq_src0_unused     = irq_src_i[0];

wire  [1:0] reg_addr_lsb_unused;
assign      reg_addr_lsb_unused = reg_addr_i[1:0];

endmodule // plic_pending

`default_nettype wire
