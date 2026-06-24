//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    plic_priority
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : plic_priority.v
// Module Description : PLIC per-source priority register file. One PRIO_BITS-
//                      wide register per interrupt source (1..NUM_SOURCES).
//                      Source 0 is reserved by the PLIC spec: its priority is
//                      hard-tied 0 and any write to its address is ignored.
//                      Reads of source indices > NUM_SOURCES return 0 (RAZ)
//                      and writes are dropped (WI).
//
//                      Lives entirely in the hclk_i domain; single-cycle
//                      access -- reg_ready_o is tied high.
//
// Address map        : byte offset 4*src selects source `src`. Word data
//                      packs the priority value in the LSBs of the 32-bit
//                      word ([PRIO_BITS-1:0]); upper bits are RAZ/WI.
//----------------------------------------------------------------------------
`default_nettype none

module  plic_priority #(
    parameter                       NUM_SOURCES = 31,        // Number of interrupt sources (1..1023)
    parameter                       PRIO_BITS   =  3,        // Priority width per source (1..7)
    parameter                       REG_AW      = 12,        // Reg-bank byte-address width (priority window)
    parameter                       ARST_EN     = 1'b1       // Reset architecture: 1=async active-low, 0=synchronous (passed to arv_ipdff)
) (

// CLOCK & RESET
    input  wire                     hclk_i,                  // AHB clock
    input  wire                     hresetn_i,               // Active-low async reset (sync-deassert)

// GENERIC REGISTER-BANK INTERFACE
    input  wire                     reg_sel_i,               // Access in flight to this sub-component
    input  wire        [REG_AW-1:0] reg_addr_i,              // Byte address inside the priority window
    input  wire                     reg_wr_en_i,             // 1 = write, 0 = read
    input  wire              [31:0] reg_wr_data_i,           // Write data
    output wire              [31:0] reg_rd_data_o,           // Read data (0 when not selected)
    output wire                     reg_ready_o,             // Always 1 (single-cycle)

// FLAT PRIORITY OUTPUT TO ARBITERS
    output wire [PRIO_BITS*(NUM_SOURCES+1)-1:0] priority_o   // [s] = source s priority; s=0 always 0
);


//=============================================================================
// 1)  ADDRESS DECODE
//=============================================================================
// Source index = reg_addr_i[REG_AW-1:2]. Source 0 has its own decode but is
// hard-tied 0 below (writes ignored). In-range sources are 1..NUM_SOURCES.

wire [REG_AW-3:0] src_word_index = reg_addr_i[REG_AW-1:2];
wire              addr_in_range  = (src_word_index <= NUM_SOURCES[REG_AW-3:0]) &
                                   (src_word_index != {(REG_AW-2){1'b0}}     ) ;

wire [NUM_SOURCES:0] src_sel;
assign               src_sel[0] = 1'b0;    // Source 0 never matches a real write

genvar gs;
generate
    for (gs = 1; gs <= NUM_SOURCES; gs = gs + 1) begin : G_SRC_SEL
        assign src_sel[gs] = addr_in_range & (src_word_index == gs[REG_AW-3:0]);
    end
endgenerate


//=============================================================================
// 2)  PER-SOURCE PRIORITY REGISTERS
//=============================================================================
// One PRIO_BITS-wide flop per source (1..NUM_SOURCES). Reset to 0. Writes
// only land when the access targets this source's address and is a write
// transfer. Source 0 has no flop -- its priority is a hard-tied constant.

wire [PRIO_BITS-1:0] prio_reg [1:NUM_SOURCES];

generate
    for (gs = 1; gs <= NUM_SOURCES; gs = gs + 1) begin : G_PRIO_REG
        arv_ipdff #(.WIDTH(PRIO_BITS), .ARST_EN(ARST_EN)) u_prio_reg (
                                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(reg_sel_i & reg_wr_en_i & src_sel[gs]),
                                                                      .d_i (reg_wr_data_i[PRIO_BITS-1:0]),
                                                                      .q_o (prio_reg[gs])
        );
    end
endgenerate


//=============================================================================
// 3)  FLAT PRIORITY OUTPUT
//=============================================================================
// Pack source 0 (always 0) at the LSBs through source NUM_SOURCES at the
// MSBs. Each entry is PRIO_BITS wide.

assign priority_o[PRIO_BITS-1:0] = {PRIO_BITS{1'b0}};  // Source 0 hard-tied 0

generate
    for (gs = 1; gs <= NUM_SOURCES; gs = gs + 1) begin : G_PRIO_OUT
        assign priority_o[PRIO_BITS*gs +: PRIO_BITS] = prio_reg[gs];
    end
endgenerate


//=============================================================================
// 4)  READ MUX
//=============================================================================
// Returns {pad, prio_reg[src]} for a selected in-range source, zero otherwise
// (source 0 and out-of-range RAZ). Upper bits above PRIO_BITS are 0.

reg  [PRIO_BITS-1:0] rd_prio;
integer ii;
always @(*) begin
    rd_prio = {PRIO_BITS{1'b0}};
    for (ii = 1; ii <= NUM_SOURCES; ii = ii + 1) begin
        if (src_sel[ii]) rd_prio = prio_reg[ii];
    end
end

wire [31:0] rd_mux_w      = {{(32-PRIO_BITS){1'b0}}, rd_prio};

assign      reg_rd_data_o = (reg_sel_i & ~reg_wr_en_i) ? rd_mux_w : 32'h0;
assign      reg_ready_o   = 1'b1;


//=============================================================================
// 5)  PARAMETER RANGE CHECK
//=============================================================================
// pragma translate_off
generate
    if ((NUM_SOURCES < 1) || (NUM_SOURCES > 1023)) begin : CHECK_NUM_SOURCES
        initial $fatal(1, "plic_priority: NUM_SOURCES (%0d) must be 1..1023.", NUM_SOURCES);
    end
    if ((PRIO_BITS < 1) || (PRIO_BITS > 7)) begin : CHECK_PRIO_BITS
        initial $fatal(1, "plic_priority: PRIO_BITS (%0d) must be 1..7.", PRIO_BITS);
    end
    if (REG_AW < 4) begin : CHECK_REG_AW
        initial $fatal(1, "plic_priority: REG_AW (%0d) must be >= 4.", REG_AW);
    end
endgenerate
// pragma translate_on


//=============================================================================
// 6)  LINT CLEANUP
//=============================================================================

wire [31:0] reg_wr_data_unused;
assign      reg_wr_data_unused  = {reg_wr_data_i[31:PRIO_BITS], {PRIO_BITS{1'b0}}};

wire  [1:0] reg_addr_lsb_unused;
assign      reg_addr_lsb_unused = reg_addr_i[1:0];

endmodule // plic_priority

`default_nettype wire
