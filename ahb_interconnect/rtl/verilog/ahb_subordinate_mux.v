//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_subordinate_mux
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_subordinate_mux.v
// Module Description : Subordinate-side mux selecting hrdata / hreadyout / hresp from the active slave.
//----------------------------------------------------------------------------
`default_nettype none

module  ahb_subordinate_mux #(
    parameter                       NR_S     = 5,                   // Number of AHB Subordinates
    parameter                       HAUSER_W = 1,                   // Width of the HAUSER bus (min value is 1)
    parameter                       ARST_EN  = 1'b1                 // 1=async active-low reset, 0=synchronous reset
) (

// AHB CLOCK & RESET
    input  wire                     hclk_i,
    input  wire                     hresetn_i,

    output wire                     hclk_en_o,

// AHB SUBORDINATE INTERFACES & ADDRESS DECODER
    input  wire          [NR_S-1:0] s_decoder_i,

    input  wire       [32*NR_S-1:0] s_hrdata_i,
    input  wire          [NR_S-1:0] s_hreadyout_i,
    input  wire          [NR_S-1:0] s_hresp_i,

    output wire       [32*NR_S-1:0] s_haddr_o,
    output wire [HAUSER_W*NR_S-1:0] s_hauser_o,
    output wire        [3*NR_S-1:0] s_hburst_o,
    output wire        [4*NR_S-1:0] s_hmaster_o,
    output wire          [NR_S-1:0] s_hmastlock_o,
    output wire        [4*NR_S-1:0] s_hprot_o,
    output wire          [NR_S-1:0] s_hready_o,
    output wire          [NR_S-1:0] s_hsel_o,
    output wire        [3*NR_S-1:0] s_hsize_o,
    output wire        [2*NR_S-1:0] s_htrans_o,
    output wire       [32*NR_S-1:0] s_hwdata_o,
    output wire          [NR_S-1:0] s_hwrite_o,

// MAIN AHB INTERFACE
    output wire              [31:0] hrdata_o,
    output wire                     hreadyout_o,
    output wire                     hresp_o,

    input  wire              [31:0] haddr_i,
    input  wire      [HAUSER_W-1:0] hauser_i,
    input  wire               [2:0] hburst_i,
    input  wire               [3:0] hmaster_i,
    input  wire                     hmastlock_i,
    input  wire               [3:0] hprot_i,
    input  wire                     hready_i,
    input  wire                     hsel_i,
    input  wire               [2:0] hsize_i,
    input  wire               [1:0] htrans_i,
    input  wire              [31:0] hwdata_i,
    input  wire                     hwrite_i
);


//=============================================================================
// 1)  UTILITY FUNCTIONS
//=============================================================================

function        [31:0] mux_to_32b;
   input [NR_S-1:0] select;
   input [32*NR_S-1:0] data;
   integer             ii;
   begin
      mux_to_32b = 32'h00000000;
      for (ii = 0; ii < NR_S; ii = ii + 1)
         mux_to_32b = mux_to_32b | ({32{select[ii]}} & data[32*ii +: 32]);
   end
endfunction


//=============================================================================
// 2)  INTERNAL WIRES/REGISTERS/PARAMETERS DECLARATION
//=============================================================================

wire                 addr_phase;
wire      [NR_S-1:0] hsel_latched;


//=============================================================================
// 3)  SUBORDINATE MUX
//=============================================================================

// Detect last cycle of the address phase
assign addr_phase    = hsel_i & hready_i & (htrans_i != 2'b00);

// Latch the HSEL to allow the selection of the proper subordinate signals during the data phase
arv_ipdff #(.WIDTH(NR_S), .ARST_EN(ARST_EN)) u_hsel_latched (
                        .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(addr_phase),
                                                             .d_i (s_hsel_o),
                                                             .q_o (hsel_latched));

// Drive AHB outputs to the Manager side
assign hrdata_o      = mux_to_32b(hsel_latched, s_hrdata_i);
assign hreadyout_o   = &((~hsel_latched) | s_hreadyout_i); // Combine the HREADYOUT of all subordinates
assign hresp_o       = |(  hsel_latched  & s_hresp_i    ); // Combine the HRESP of all subordinates
assign s_hsel_o      =     s_decoder_i;                    // HSEL output comes from the external address decoder

// Drive AHB outputs to the Subordinate side
assign s_haddr_o     = {NR_S{ haddr_i      }};
assign s_hauser_o    = {NR_S{ hauser_i     }};
assign s_hburst_o    = {NR_S{ hburst_i     }};
assign s_hmaster_o   = {NR_S{ hmaster_i    }};
assign s_hmastlock_o = {NR_S{ hmastlock_i  }};
assign s_hprot_o     = {NR_S{ hprot_i      }};
assign s_hready_o    = {NR_S{ hready_i     }};
assign s_hsize_o     = {NR_S{ hsize_i      }};
assign s_htrans_o    = {NR_S{ htrans_i     }};
assign s_hwdata_o    = {NR_S{ hwdata_i     }};
assign s_hwrite_o    = {NR_S{ hwrite_i     }};

// Enable clock
assign hclk_en_o     = addr_phase;


endmodule // ahb_subordinate_mux


`default_nettype wire
