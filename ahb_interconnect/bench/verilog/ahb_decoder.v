//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_decoder
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_decoder.v
// Module Description : Behavioural AHB address decoder for the testbench.
//----------------------------------------------------------------------------

module  ahb_decoder (

// DECODER INTERFACES
    decoder_addr_i,
    decoder_1hot_o
);

// DECODER INTERFACES
//======================================
input         [31:0] decoder_addr_i;
output         [3:0] decoder_1hot_o;


//=============================================================================
// AHB DECODER
//=============================================================================

assign decoder_1hot_o[0]  = (decoder_addr_i>=32'h00400000) & (decoder_addr_i<(32'h00400800)); // 2048B ROM
assign decoder_1hot_o[1]  = (decoder_addr_i>=32'h00401000) & (decoder_addr_i<(32'h00401800)); // 2048B SRAM
assign decoder_1hot_o[2]  = (decoder_addr_i>=32'h00402000) & (decoder_addr_i<(32'h00402080)); //  128B PERIPH #0
assign decoder_1hot_o[3]  = (decoder_addr_i>=32'h00403000) & (decoder_addr_i<(32'h00403080)); //  128B PERIPH #1


endmodule