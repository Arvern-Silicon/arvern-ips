//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_default_subordinate
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_default_subordinate.v
// Module Description : AHB default subordinate — returns ERROR response for unmapped accesses.
//----------------------------------------------------------------------------
`default_nettype none

module  ahb_default_subordinate #(
    parameter          ARST_EN = 1'b1     // 1=async active-low reset, 0=synchronous reset
) (

// AHB CLOCK & RESET
    input  wire        hclk_i,
    input  wire        hresetn_i,

    output wire        hclk_en_o,

// AHB INTERFACE
    input  wire        hready_i,
    input  wire        hsel_i,
    input  wire  [1:0] htrans_i,

    output wire [31:0] hrdata_o,
    output wire        hreadyout_o,
    output wire        hresp_o
);


//=============================================================================
// 1)  INTERNAL WIRES/REGISTERS/PARAMETERS DECLARATION
//=============================================================================

wire                 addr_phase;
wire           [1:0] data_phase;


//=============================================================================
// 2)  DEFAULT SUBORDINATE LOGIC
//=============================================================================
// The default subordinate returns with an error response every time it is accessed

// Detect last cycle of the address phase
assign addr_phase    = hsel_i & hready_i & (htrans_i != 2'b00);

// Two cycle data phase for the error response
arv_ipdff #(.WIDTH(2), .ARST_EN(ARST_EN)) u_data_phase (
                   .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                        .d_i ({data_phase[0], addr_phase}),
                                                        .q_o ( data_phase));

// Drive AHB outputs
assign  hresp_o      = |data_phase;
assign  hreadyout_o  = ~data_phase[0];
assign  hrdata_o     =  32'h00000000;

// Enable clock
assign  hclk_en_o     = addr_phase | hresp_o;


endmodule // ahb_default_subordinate

`default_nettype wire
