//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    plic_enable
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : plic_enable.v
// Module Description : PLIC per-context interrupt-enable matrix. One bit per
//                      (context, source) pair, packed 32 sources per word.
//                      Source 0 enable is hard-tied 0 across all contexts
//                      (RAZ/WI). Lives entirely in the hclk_i domain; single
//                      cycle access -- reg_ready_o is tied high.
//
// Address map        : Context c, source-word w lives at byte offset
//                      (0x80 * c) + (0x4 * w). 32 sources per word, 32 words
//                      per context (1024 sources max). Out-of-range context
//                      or word indices RAZ/WI.
//----------------------------------------------------------------------------
`default_nettype none

module  plic_enable #(
    parameter                           NUM_SOURCES  = 31,        // Number of interrupt sources (1..1023)
    parameter                           NUM_CONTEXTS =  1,        // Number of contexts (1..32 supported)
    parameter                           REG_AW       = 12,        // Reg-bank byte-address width (enable window)
    parameter                           ARST_EN      = 1'b1       // Reset architecture: 1=async active-low, 0=synchronous (passed to arv_ipdff)
) (

// CLOCK & RESET
    input  wire                         hclk_i,                   // AHB clock
    input  wire                         hresetn_i,                // Active-low async reset (sync-deassert)

// GENERIC REGISTER-BANK INTERFACE
    input  wire                         reg_sel_i,                // Access in flight to this sub-component
    input  wire            [REG_AW-1:0] reg_addr_i,               // Byte address inside the enable window
    input  wire                         reg_wr_en_i,              // 1 = write, 0 = read
    input  wire                  [31:0] reg_wr_data_i,            // Write data
    output wire                  [31:0] reg_rd_data_o,            // Read data (0 when not selected)
    output wire                         reg_ready_o,              // Always 1 (single-cycle)

// FLAT ENABLE OUTPUT TO TARGETS
    output wire [NUM_CONTEXTS*(NUM_SOURCES+1)-1:0] enable_o       // Context c bits at [(NUM_SOURCES+1)*c +: NUM_SOURCES+1]
);


//=============================================================================
// 1)  LOCAL PARAMETERS / DERIVED CONSTANTS
//=============================================================================

localparam NUM_WORDS_PER_CTX  = ((NUM_SOURCES + 1) + 31) / 32;    // Rounded up
localparam CTX_STRIDE_LSB     = 7;                                // 0x80 = 2^7
localparam WORD_OFFSET_LSB    = 2;                                // 0x04 = 2^2


//=============================================================================
// 2)  ADDRESS DECODE
//=============================================================================

wire          [REG_AW-1-CTX_STRIDE_LSB:0] ctx_idx_full = reg_addr_i        [REG_AW-1:CTX_STRIDE_LSB];
wire [CTX_STRIDE_LSB-1-WORD_OFFSET_LSB:0] word_idx     = reg_addr_i[CTX_STRIDE_LSB-1:WORD_OFFSET_LSB];

wire ctx_in_range  = ({{(32-(REG_AW-CTX_STRIDE_LSB)){1'b0}}, ctx_idx_full} < NUM_CONTEXTS);
wire word_in_range = (word_idx < NUM_WORDS_PER_CTX[4:0]) |
                     (NUM_WORDS_PER_CTX >= 32);                   // 32-word case: any word ok

wire addr_in_range = ctx_in_range & word_in_range;

wire [NUM_CONTEXTS-1:0] ctx_sel;
genvar gc;
generate
    for (gc = 0; gc < NUM_CONTEXTS; gc = gc + 1) begin : G_CTX_SEL
        assign ctx_sel[gc] = addr_in_range & (ctx_idx_full == gc[REG_AW-1-CTX_STRIDE_LSB:0]);
    end
endgenerate


//=============================================================================
// 3)  PER-(CONTEXT, SOURCE) ENABLE FLOPS
//=============================================================================

wire [NUM_SOURCES:1] enable_reg [0:NUM_CONTEXTS-1];

genvar gs;
generate
    for (gc = 0; gc < NUM_CONTEXTS; gc = gc + 1) begin : G_EN_CTX
        for (gs = 1; gs <= NUM_SOURCES; gs = gs + 1) begin : G_EN_SRC
            arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_enable_reg (
                               .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(reg_sel_i & reg_wr_en_i & ctx_sel[gc] & (word_idx == gs[9:5])),
                                                                    .d_i (reg_wr_data_i[gs % 32]),
                                                                    .q_o (enable_reg[gc][gs]));
        end
    end
endgenerate


//=============================================================================
// 4)  FLAT ENABLE OUTPUT
//=============================================================================
// Pack [context c][source s] into enable_o[(NUM_SOURCES+1)*c + s].
// Source 0 is hard-tied 0 for every context.

generate
    for (gc = 0; gc < NUM_CONTEXTS; gc = gc + 1) begin : G_EN_OUT_CTX
        assign enable_o[(NUM_SOURCES+1)*gc + 0] = 1'b0;
        for (gs = 1; gs <= NUM_SOURCES; gs = gs + 1) begin : G_EN_OUT_SRC
            assign enable_o[(NUM_SOURCES+1)*gc + gs] = enable_reg[gc][gs];
        end
    end
endgenerate


//=============================================================================
// 5)  READ MUX
//=============================================================================
// Build a 32-bit word per (context, word) and select the addressed one. Bit
// b of word w = enable_reg[ctx][32*w + b]; bit 0 of word 0 is hard-tied 0
// (source 0). Bits whose source index > NUM_SOURCES read as 0.

// Sized casts of the unsigned parameters so the comparisons and array
// indices below stay width-clean for both DC (no VER-318 signed->unsigned)
// and Verilator (no WIDTHEXPAND/TRUNC).
localparam        [31:0] NUM_CONTEXTS_INT = NUM_CONTEXTS;
localparam         [5:0] NUM_CONTEXTS_S6  = NUM_CONTEXTS_INT[5:0];
localparam        [31:0] NUM_SOURCES_INT  = NUM_SOURCES;
localparam        [10:0] NUM_SOURCES_S11  = NUM_SOURCES_INT[10:0];
localparam               CTX_IDX_W        = (NUM_CONTEXTS > 1) ? $clog2(NUM_CONTEXTS) : 1;
localparam               SRC_IDX_W        = $clog2(NUM_SOURCES + 1);

reg  [31:0] rd_word;
reg   [5:0] cc;     // 0..NUM_CONTEXTS (max 32)
reg   [5:0] ww;     // 0..32
reg   [5:0] bb;     // 0..32
reg  [10:0] src;    // 0..NUM_SOURCES (max 1023)
always @(*) begin
    rd_word = 32'h0;
    src     = 11'h0;
    for (cc = 6'h0; cc < NUM_CONTEXTS_S6; cc = cc + 6'h1) begin
        if (ctx_sel[cc[CTX_IDX_W-1:0]]) begin
            for (ww = 6'h0; ww < 6'd32; ww = ww + 6'h1) begin
                if (word_idx == ww[4:0]) begin
                    for (bb = 6'h0; bb < 6'd32; bb = bb + 6'h1) begin
                        src = {5'h0, ww} * 11'd32 + {5'h0, bb};
                        if ((src >= 11'h1) && (src <= NUM_SOURCES_S11))
                            rd_word[bb[4:0]] = enable_reg[cc[CTX_IDX_W-1:0]][src[SRC_IDX_W-1:0]];
                    end
                end
            end
        end
    end
end

assign reg_rd_data_o = (reg_sel_i & ~reg_wr_en_i) ? rd_word : 32'h0;
assign reg_ready_o   = 1'b1;


//=============================================================================
// 6)  PARAMETER RANGE CHECK
//=============================================================================
// pragma translate_off
generate
    if ((NUM_SOURCES < 1) || (NUM_SOURCES > 1023)) begin : CHECK_NUM_SOURCES
        initial $fatal(1, "plic_enable: NUM_SOURCES (%0d) must be 1..1023.", NUM_SOURCES);
    end
    if (NUM_CONTEXTS < 1) begin : CHECK_NUM_CONTEXTS_LO
        initial $fatal(1, "plic_enable: NUM_CONTEXTS (%0d) must be >= 1.", NUM_CONTEXTS);
    end
    if (NUM_CONTEXTS > 32) begin : CHECK_NUM_CONTEXTS_HI
        initial $fatal(1, "plic_enable: NUM_CONTEXTS (%0d) must be <= 32 (context-index slice width).", NUM_CONTEXTS);
    end
    if (REG_AW <= 7) begin : CHECK_REG_AW
        initial $fatal(1, "plic_enable: REG_AW (%0d) must be > 7 (the context-index slice reg_addr_i[REG_AW-1:CTX_STRIDE_LSB] needs positive width with CTX_STRIDE_LSB=7).", REG_AW);
    end
endgenerate
// pragma translate_on


//=============================================================================
// 7)  LINT CLEANUP
//=============================================================================
// reg_addr_i[1:0] (byte lanes) ignored -- AHB top guarantees word alignment.
// reg_wr_data_i[0] is the source-0 enable for word 0 (hard-tied 0); it is
// the enable for source (32*word) when word>0 (used when NUM_SOURCES>=32).
// Sink it unconditionally so lint is clean for all NUM_SOURCES.

wire [1:0] reg_addr_lsb_unused;
assign     reg_addr_lsb_unused = reg_addr_i[1:0];

wire       reg_wr_data0_unused;
assign     reg_wr_data0_unused = reg_wr_data_i[0];

endmodule // plic_enable

`default_nettype wire
