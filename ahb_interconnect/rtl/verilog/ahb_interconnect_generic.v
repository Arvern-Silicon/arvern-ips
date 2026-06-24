//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_interconnect_generic
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_interconnect_generic.v
// Module Description : Generic AHB interconnect: standard manager/subordinate muxes + arbiter.
//
// `hclk_en_o` is an ADVISORY enable for an external clock gate at the SoC
// level. The fabric itself runs on `hclk_i` unconditionally. The signal is
// the OR-reduce of the per-block enables (manager mux, subordinate mux,
// default subordinate).
//----------------------------------------------------------------------------
`default_nettype none

module  ahb_interconnect_generic #(
    parameter                       NR_M         = 3,         // Number of AHB Managers
    parameter                       NR_S         = 5,         // Number of AHB Subordinates
    parameter                       HAUSER_W     = 1,         // Width of the HAUSER bus (min value is 1)
    parameter                       ASYNC_RST_EN = 1'b1       // 1=async active-low reset, 0=synchronous reset
) (

// AHB CLOCK & RESET
    input  wire                     hclk_i,
    input  wire                     hresetn_i,

    output wire                     hclk_en_o,

// AHB MANAGER INTERFACES
    input  wire       [32*NR_M-1:0] m_haddr_i,
    input  wire [HAUSER_W*NR_M-1:0] m_hauser_i,
    input  wire        [3*NR_M-1:0] m_hburst_i,
    input  wire          [NR_M-1:0] m_hmastlock_i,
    input  wire        [4*NR_M-1:0] m_hprot_i,
    input  wire        [3*NR_M-1:0] m_hsize_i,
    input  wire        [2*NR_M-1:0] m_htrans_i,
    input  wire       [32*NR_M-1:0] m_hwdata_i,
    input  wire          [NR_M-1:0] m_hwrite_i,

    output wire       [32*NR_M-1:0] m_hrdata_o,
    output wire          [NR_M-1:0] m_hready_o,
    output wire          [NR_M-1:0] m_hresp_o,

// ARBITER INTERFACES
    input  wire          [NR_M-1:0] m_grant_i,
    output wire          [NR_M-1:0] m_request_o,

// ADDRESS DECODER INTERFACES
    input  wire          [NR_S-1:0] s_decoder_1hot_i,
    output wire              [31:0] s_decoder_addr_o,

// AHB SUBORDINATE INTERFACES
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
    output wire          [NR_S-1:0] s_hwrite_o
);


//=============================================================================
// 0)  PARAMETER RANGE CHECKS
//=============================================================================
// HMASTER ID array (section 2) holds 16 entries (4'h0..4'hF). NR_M must fit.

// pragma translate_off
generate
    if ((NR_M < 1) || (NR_M > 16)) begin : CHECK_NR_M
        initial $fatal(1, "ahb_interconnect_generic: NR_M (%0d) is out of range [1,16].", NR_M);
    end
    if (NR_S < 1) begin : CHECK_NR_S
        initial $fatal(1, "ahb_interconnect_generic: NR_S (%0d) must be >= 1.", NR_S);
    end
    if (HAUSER_W < 1) begin : CHECK_HAUSER_W
        initial $fatal(1, "ahb_interconnect_generic: HAUSER_W (%0d) must be >= 1.", HAUSER_W);
    end
     if ((ASYNC_RST_EN != 0) && (ASYNC_RST_EN != 1)) begin : CHECK_ASYNC_RST_EN
        initial $fatal(1, "ahb_interconnect_generic: ASYNC_RST_EN (%0d) must be 0 or 1.", ASYNC_RST_EN);
    end
endgenerate
// pragma translate_on


//=============================================================================
// 1)  INTERNAL WIRES/REGISTERS/PARAMETERS DECLARATION
//=============================================================================

wire            [4*16-1:0] m_hmaster;
wire     [4*(16-NR_M)-1:0] m_hmaster_unused;

wire                [31:0] haddr;
wire        [HAUSER_W-1:0] hauser;
wire                 [2:0] hburst;
wire                 [3:0] hmaster;
wire                       hmastlock;
wire                 [3:0] hprot;
wire                [31:0] hrdata;
wire                       hreadyout;
wire                       hready_unused;
wire                       hresp;
wire                       hsel;
wire                 [2:0] hsize;
wire                 [1:0] htrans;
wire                [31:0] hwdata;
wire                       hwrite;

wire                       dflt_decoder;
wire                       dflt_hsel;
wire                [31:0] dflt_hrdata;
wire                       dflt_hreadyout;
wire                       dflt_hresp;

wire                [31:0] dflt_haddr_unused;
wire        [HAUSER_W-1:0] dflt_hauser_unused;
wire                 [2:0] dflt_hburst_unused;
wire                 [3:0] dflt_hmaster_unused;
wire                       dflt_hmastlock_unused;
wire                 [3:0] dflt_hprot_unused;
wire                       dflt_hready;
wire                 [2:0] dflt_hsize_unused;
wire                 [1:0] dflt_htrans;
wire                [31:0] dflt_hwdata_unused;
wire                       dflt_hwrite_unused;

wire                       hclk_en_manager_mux;
wire                       hclk_en_subordinate_mux;
wire                       hclk_en_dflt_subordinate;


//=============================================================================
// 2)  AHB MANAGER MULTIPLEXOR
//=============================================================================

// HMASTER assignments for each manager
assign m_hmaster = {4'hF, 4'hE, 4'hD, 4'hC, 4'hB, 4'hA, 4'h9, 4'h8,
                    4'h7, 4'h6, 4'h5, 4'h4, 4'h3, 4'h2, 4'h1, 4'h0};


ahb_manager_mux #(.NR_M(NR_M), .HAUSER_W(HAUSER_W), .ARST_EN(ASYNC_RST_EN)) ahb_manager_mux_inst (

// AHB CLOCK & RESET
    .hclk_i            ( hclk_i                ),
    .hresetn_i         ( hresetn_i             ),

    .hclk_en_o         ( hclk_en_manager_mux   ),

// AHB MANAGER INTERFACES
    .m_haddr_i         ( m_haddr_i             ),
    .m_hauser_i        ( m_hauser_i            ),
    .m_hburst_i        ( m_hburst_i            ),
    .m_hmaster_i       ( m_hmaster[4*NR_M-1:0] ),
    .m_hmastlock_i     ( m_hmastlock_i         ),
    .m_hprot_i         ( m_hprot_i             ),
    .m_hready_i        ( m_hready_o            ),
    .m_hsel_i          ( {NR_M{1'b1}}          ),
    .m_hsize_i         ( m_hsize_i             ),
    .m_htrans_i        ( m_htrans_i            ),
    .m_hwdata_i        ( m_hwdata_i            ),
    .m_hwrite_i        ( m_hwrite_i            ),

    .m_hrdata_o        ( m_hrdata_o            ),
    .m_hreadyout_o     ( m_hready_o            ),
    .m_hresp_o         ( m_hresp_o             ),

// ARBITER & ADDRESS DECODER INTERFACES
    .m_grant_i         ( m_grant_i             ),
    .m_request_o       ( m_request_o           ),

// MAIN AHB INTERFACE
    .hrdata_i          ( hrdata                ),
    .hreadyout_i       ( hreadyout             ),
    .hresp_i           ( hresp                 ),

    .haddr_o           ( haddr                 ),
    .hauser_o          ( hauser                ),
    .hburst_o          ( hburst                ),
    .hmaster_o         ( hmaster               ),
    .hmastlock_o       ( hmastlock             ),
    .hprot_o           ( hprot                 ),
    .hready_o          ( hready_unused         ),
    .hsel_o            ( hsel                  ),
    .hsize_o           ( hsize                 ),
    .htrans_o          ( htrans                ),
    .hwdata_o          ( hwdata                ),
    .hwrite_o          ( hwrite                )
);

assign m_hmaster_unused = m_hmaster[4*16-1:4*NR_M];


//=============================================================================
// 3)  AHB SUBORDINATE MULTIPLEXOR
//=============================================================================

ahb_subordinate_mux #(.NR_S(NR_S+1), .HAUSER_W(HAUSER_W), .ARST_EN(ASYNC_RST_EN)) ahb_subordinate_mux_inst (

// AHB CLOCK & RESET
    .hclk_i            ( hclk_i                                     ),
    .hresetn_i         ( hresetn_i                                  ),

    .hclk_en_o         ( hclk_en_subordinate_mux                    ),

// AHB SUBORDINATE INTERFACES & ADDRESS DECODER
    .s_decoder_i       ({dflt_decoder,           s_decoder_1hot_i  }),

    .s_hrdata_i        ({dflt_hrdata,            s_hrdata_i        }),
    .s_hreadyout_i     ({dflt_hreadyout,         s_hreadyout_i     }),
    .s_hresp_i         ({dflt_hresp,             s_hresp_i         }),

    .s_haddr_o         ({dflt_haddr_unused,      s_haddr_o         }),
    .s_hauser_o        ({dflt_hauser_unused,     s_hauser_o        }),
    .s_hburst_o        ({dflt_hburst_unused,     s_hburst_o        }),
    .s_hmaster_o       ({dflt_hmaster_unused,    s_hmaster_o       }),
    .s_hmastlock_o     ({dflt_hmastlock_unused,  s_hmastlock_o     }),
    .s_hprot_o         ({dflt_hprot_unused,      s_hprot_o         }),
    .s_hready_o        ({dflt_hready,            s_hready_o        }),
    .s_hsel_o          ({dflt_hsel,              s_hsel_o          }),
    .s_hsize_o         ({dflt_hsize_unused,      s_hsize_o         }),
    .s_htrans_o        ({dflt_htrans,            s_htrans_o        }),
    .s_hwdata_o        ({dflt_hwdata_unused,     s_hwdata_o        }),
    .s_hwrite_o        ({dflt_hwrite_unused,     s_hwrite_o        }),

// MAIN AHB INTERFACE
    .hrdata_o          ( hrdata                                     ),
    .hreadyout_o       ( hreadyout                                  ),
    .hresp_o           ( hresp                                      ),

    .haddr_i           ( haddr                                      ),
    .hauser_i          ( hauser                                     ),
    .hburst_i          ( hburst                                     ),
    .hmaster_i         ( hmaster                                    ),
    .hmastlock_i       ( hmastlock                                  ),
    .hprot_i           ( hprot                                      ),
    .hready_i          ( hreadyout                                  ), // Standard AHB hready propagation:
                                                                       // the combined hreadyout from this cycle is what every
                                                                       // slave samples as hready next cycle (enables pipelining
                                                                       // and back-to-back transfers from the same slave).
    .hsel_i            ( hsel                                       ),
    .hsize_i           ( hsize                                      ),
    .htrans_i          ( htrans                                     ),
    .hwdata_i          ( hwdata                                     ),
    .hwrite_i          ( hwrite                                     )
);

// Default decoder selected when all bits of the main decoder are 0
assign dflt_decoder     = ~(|s_decoder_1hot_i);

// Assign address going to the decoder
assign s_decoder_addr_o =  haddr;

// Build AHB interconnect clock enable signal
assign hclk_en_o        =  hclk_en_dflt_subordinate |
                           hclk_en_subordinate_mux  |
                           hclk_en_manager_mux;


//=============================================================================
// 4)  DEFAULT AHB SUBORDINATE
//=============================================================================

ahb_default_subordinate #(.ARST_EN(ASYNC_RST_EN)) ahb_default_subordinate_inst (

// AHB CLOCK & RESET
    .hclk_i            ( hclk_i                   ),
    .hresetn_i         ( hresetn_i                ),

    .hclk_en_o         ( hclk_en_dflt_subordinate ),

// AHB INTERFACE
    .hready_i          ( dflt_hready              ),
    .hsel_i            ( dflt_hsel                ),
    .htrans_i          ( dflt_htrans              ),

    .hrdata_o          ( dflt_hrdata              ),
    .hreadyout_o       ( dflt_hreadyout           ),
    .hresp_o           ( dflt_hresp               )
);

endmodule // ahb_interconnect_generic


`default_nettype wire
