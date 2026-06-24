//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arv_ccsr_rdonly
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arv_ccsr_rdonly.v
// Module Description : Read mux for externally-sourced Custom Read-Only CSR
//                      values. This module has no internal storage; it
//                      selects one of NR_REG 32-bit input slices via a
//                      one-hot per-register enable.
//----------------------------------------------------------------------------
`default_nettype none

module  arv_ccsr_rdonly #(
    parameter                     NR_REG  = 2                 // Number of CSR Read-Only registers
) (

// READ-ONLY VALUES FROM OUTSIDE WORLD
    input  wire [(NR_REG*32)-1:0] ccsr_reg_value_i,

// INTERFACE TO CUSTOM CSR REGISTERS
    input  wire      [NR_REG-1:0] ccsr_reg_en_i,
    output wire            [31:0] ccsr_rdata_o
);


//////======================================================================================================================//////
//////======================================================================================================================//////
//////                                                                                                                      //////
//////                                                CSR READ-ONLY REGISTERS                                               //////
//////                                                                                                                      //////
//////======================================================================================================================//////
//////======================================================================================================================//////

// OR-mux over NR_REG 32-bit entries gated by a one-hot `select`.
// CONTRACT: `select` MUST be one-hot or all-zero. A multi-hot select
// produces the bitwise OR of the chosen entries (not an error).
function automatic   [31:0] mux_to_32b;
    input [(NR_REG*32)-1:0] data;
    input [NR_REG-1:0] select;
    integer                 ii;
    begin
        mux_to_32b = 32'h00000000;
        for (ii = 0; ii < NR_REG; ii = ii + 1)
            mux_to_32b   = mux_to_32b | ({32{select[ii]}} & data[32*ii+:32]);
    end
endfunction

assign      ccsr_rdata_o = mux_to_32b(ccsr_reg_value_i,  ccsr_reg_en_i);


//////======================================================================================================================//////
//////                                          PARAMETER RANGE CHECK                                                       //////
//////======================================================================================================================//////
// Aborts elaboration if NR_REG is out of bounds. Slices [NR_REG-1:0] in
// this module require NR_REG >= 1. Upper bound is 64 (RO banks occupy a
// single 64-register CSR address range per privilege level).
// pragma translate_off
generate
    if ((NR_REG < 1) || (NR_REG > 64)) begin : CHECK_NR_REG
        initial $fatal(1, "arv_ccsr_rdonly: NR_REG (%0d) must be 1..64.", NR_REG);
    end
endgenerate
// pragma translate_on

endmodule // arv_ccsr_rdonly

`default_nettype wire
