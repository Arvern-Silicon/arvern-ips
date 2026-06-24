//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arv_ccsr_rdwr
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arv_ccsr_rdwr.v
// Module Description : Implementation of Custom Read-Write CSR registers.
//----------------------------------------------------------------------------
`default_nettype none

module  arv_ccsr_rdwr #(
    parameter                     NR_REG  = 2,       // Number of CSR Read-Write registers
    parameter                     ARST_EN = 1'b1     // 1=async active-low reset, 0=synchronous reset
) (

// AHB CLOCK & RESET
    input wire                    hclk_i,            // module clock
    input wire                    hresetn_i,         // active-low async reset (sync-deassert required at IP boundary)
    output wire                   hclk_en_o,         // clock-gate enable = OR of per-register write pulses; forwarded to parent

// READ-WRITE VALUES TO OUTSIDE WORLD
    output wire [(NR_REG*32)-1:0] ccsr_reg_value_o,

// INTERFACE TO CUSTOM CSR REGISTERS
    input  wire      [NR_REG-1:0] ccsr_reg_en_i,
    input  wire            [31:0] ccsr_wdata_i,
    input  wire                   ccsr_wen_i,

    output wire            [31:0] ccsr_rdata_o
);


//////======================================================================================================================//////
//////======================================================================================================================//////
//////                                                                                                                      //////
//////                                                CSR READ-WRITE REGISTERS                                              //////
//////                                                                                                                      //////
//////======================================================================================================================//////
//////======================================================================================================================//////

wire         [NR_REG-1:0] ccsr_reg_wr_vector;

genvar ii;
generate
    for (ii = 0; ii < NR_REG; ii = ii + 1) begin : CCSR_RW

        wire [31:0] ccsr_reg;
        wire        ccsr_reg_wr  = (ccsr_reg_en_i[ii] & ccsr_wen_i) ;

        arv_ipdff #(.WIDTH(32), .ARST_EN(ARST_EN)) u_ccsr_reg (
                          .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(ccsr_reg_wr),
                                                               .d_i (ccsr_wdata_i),
                                                               .q_o (ccsr_reg));

        assign ccsr_reg_value_o[32*ii+:32] = ccsr_reg;
        assign ccsr_reg_wr_vector[ii]      = ccsr_reg_wr;
    end

endgenerate

//////======================================================================================================================//////
//////======================================================================================================================//////
//////                                                                                                                      //////
//////                                                    READ MUX                                                          //////
//////                                                                                                                      //////
//////======================================================================================================================//////
//////======================================================================================================================//////

// OR-mux over NR_REG 32-bit entries gated by a one-hot `select`.
// CONTRACT: `select` MUST be one-hot or all-zero. A multi-hot select
// produces the bitwise OR of the chosen entries (not an error).
function automatic   [31:0] mux_to_32b;
    input [(NR_REG*32)-1:0] data;
    input [NR_REG-1:0] select;
    integer                 jj;
    begin
        mux_to_32b = 32'h00000000;
        for (jj = 0; jj < NR_REG; jj = jj + 1)
            mux_to_32b   = mux_to_32b | ({32{select[jj]}} & data[32*jj+:32]);
    end
endfunction

assign     ccsr_rdata_o  = mux_to_32b(ccsr_reg_value_o,  ccsr_reg_en_i);

assign     hclk_en_o     = |ccsr_reg_wr_vector;


//////======================================================================================================================//////
//////                                          PARAMETER RANGE CHECK                                                       //////
//////======================================================================================================================//////
// Aborts elaboration if NR_REG is out of bounds. Slices [NR_REG-1:0] in
// this module require NR_REG >= 1. Upper bound matches the worst-case
// per-instance allocation in the parent (User-RW is the largest at 256).
// pragma translate_off
generate
    if ((NR_REG < 1) || (NR_REG > 256)) begin : CHECK_NR_REG
        initial $fatal(1, "arv_ccsr_rdwr: NR_REG (%0d) must be 1..256.", NR_REG);
    end
endgenerate
// pragma translate_on

endmodule // arv_ccsr_rdwr

`default_nettype wire
