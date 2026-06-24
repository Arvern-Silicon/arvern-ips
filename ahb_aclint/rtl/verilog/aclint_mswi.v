//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    aclint_mswi
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : aclint_mswi.v
// Module Description : ACLINT Machine-Software-Interrupt (MSWI) register
//                      bank. One 32-bit register per hart at offset 4*hart.
//                      Bit[0] is the MSIP flag (drives irq_m_software_o);
//                      bits [31:1] are reserved (read as 0, writes ignored).
//                      Lives entirely in the hclk_i domain; single-cycle
//                      access — reg_ready_o is tied high.
//----------------------------------------------------------------------------
`default_nettype none

module  aclint_mswi #(
    parameter                     NUM_HARTS =  1,     // Number of harts (1..16)
    parameter                     REG_AW    = 12,     // Reg-bank byte-address width (MSWI window)
    parameter                     ARST_EN   = 1'b1    // Reset style: 1=asynchronous, 0=synchronous
) (

// CLOCK & RESET (hclk DOMAIN ONLY)
    input  wire                   hclk_i,             // AHB clock
    input  wire                   hresetn_i,          // Active-low async reset (sync-deassert)

// GENERIC REGISTER-BANK INTERFACE
    input  wire                   reg_sel_i,          // Access in flight to this sub-component
    input  wire      [REG_AW-1:0] reg_addr_i,         // Byte address inside the MSWI window
    input  wire                   reg_wr_en_i,        // 1 = write, 0 = read
    input  wire            [31:0] reg_wr_data_i,      // Write data
    output wire            [31:0] reg_rd_data_o,      // Read data (0 when not selected)
    output wire                   reg_ready_o,        // Always 1 (single-cycle)

// PER-HART MSIP OUTPUT
    output wire   [NUM_HARTS-1:0] irq_m_software_o
);


//=============================================================================
// 1)  ADDRESS DECODE
//=============================================================================
// Per-hart 32-bit register at offset 4*hart. Hart index = reg_addr_i[2 +: 4].

localparam [31:0]       NUM_HARTS_INT   = NUM_HARTS;
localparam [REG_AW-1:0] NUM_HARTS_CAST  = NUM_HARTS_INT[REG_AW-1:0];

wire       [REG_AW-1:0] hart_word_index = (reg_addr_i >> 2);
wire              [3:0] hart_idx        =  hart_word_index[3:0];
wire                    addr_in_range   = (hart_word_index < NUM_HARTS_CAST);

wire    [NUM_HARTS-1:0] hart_sel;
genvar gh;
generate
    for (gh = 0; gh < NUM_HARTS; gh = gh + 1) begin : G_HART_SEL
        assign hart_sel[gh] = addr_in_range & (hart_idx == gh[3:0]);
    end
endgenerate


//=============================================================================
// 2)  PER-HART MSIP REGISTER
//=============================================================================
// One flop per hart for bit[0]. Reset to 0.

wire [NUM_HARTS-1:0] msip;

generate
    for (gh = 0; gh < NUM_HARTS; gh = gh + 1) begin : G_MSIP_REG
        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_msip (
                     .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(reg_sel_i & reg_wr_en_i & hart_sel[gh]),
                                                          .d_i (reg_wr_data_i[0]),
                                                          .q_o (msip[gh]));
    end
endgenerate

assign irq_m_software_o = msip;


//=============================================================================
// 3)  READ MUX
//=============================================================================
// Returns {31'h0, msip[hart]} for a selected hart, zero otherwise.

reg  [31:0] rd_mux;
integer ii;
always @(*) begin
    rd_mux = 32'h0;
    for (ii = 0; ii < NUM_HARTS; ii = ii + 1) begin
        if (hart_sel[ii]) rd_mux = {31'h0, msip[ii]};
    end
end

assign reg_rd_data_o = (reg_sel_i & ~reg_wr_en_i) ? rd_mux : 32'h0;
assign reg_ready_o   = 1'b1;


//=============================================================================
// 4)  PARAMETER RANGE CHECK
//=============================================================================
// pragma translate_off
generate
    if ((NUM_HARTS < 1) || (NUM_HARTS > 16)) begin : CHECK_NUM_HARTS
        initial $fatal(1, "aclint_mswi: NUM_HARTS (%0d) must be 1..16.", NUM_HARTS);
    end
    if (REG_AW < 6) begin : CHECK_REG_AW
        initial $fatal(1, "aclint_mswi: REG_AW (%0d) must be >= 6.", REG_AW);
    end
endgenerate
// pragma translate_on


//=============================================================================
// 5)  LINT CLEANUP
//=============================================================================

wire        hart_word_index_unused;
assign      hart_word_index_unused = |hart_word_index[REG_AW-1:4];

wire [30:0] reg_wr_data_unused;
assign      reg_wr_data_unused     =  reg_wr_data_i[31:1];

endmodule // aclint_mswi

`default_nettype wire
