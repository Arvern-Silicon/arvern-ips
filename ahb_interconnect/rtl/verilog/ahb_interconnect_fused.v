//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_interconnect_fused
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_interconnect_fused.v
// Module Description : Fused AHB interconnect variant (interconnect + memory controllers fused).
//
// `hclk_en_o` is an ADVISORY enable for an external clock gate at the SoC
// level. The fabric itself runs on `hclk_i` unconditionally. The signal is
// the OR-reduce of the per-block enables (NX manager/subordinate mux,
// default subordinates, and every fused ROM / SRAM controller).
//----------------------------------------------------------------------------
`default_nettype none

module  ahb_interconnect_fused (

// AHB CLOCK & RESET
    hclk_i,
    hresetn_i,

    hclk_en_o,

// EXECUTABLE AHB BUS MANAGER INTERFACE
    m_x_haddr_i,
    m_x_hauser_i,
    m_x_hburst_i,
    m_x_hmastlock_i,
    m_x_hprot_i,
    m_x_hsize_i,
    m_x_htrans_i,
    m_x_hwdata_i,
    m_x_hwrite_i,

    m_x_hrdata_o,
    m_x_hready_o,
    m_x_hresp_o,

// NON-EXECUTABLE AHB MANAGER INTERFACES
    m_nx_haddr_i,
    m_nx_hauser_i,
    m_nx_hburst_i,
    m_nx_hmastlock_i,
    m_nx_hprot_i,
    m_nx_hsize_i,
    m_nx_htrans_i,
    m_nx_hwdata_i,
    m_nx_hwrite_i,

    m_nx_hrdata_o,
    m_nx_hready_o,
    m_nx_hresp_o,

// ARBITER INTERFACE for NON-EXECUTABLE MANAGERS
    m_nx_grant_i,
    m_nx_request_o,

// ADDRESS DECODER INTERFACES (FOR ALL SUBORDINATES)
    s_decoder_1hot_i,
    s_decoder_addr_o,

// ADDRESS DECODER INTERFACES (FOR EXECUTABLE SUBORDINATES ONLY)
    s_x_decoder_1hot_i,
    s_x_decoder_addr_o,

// FUSED ROM CONTROLLER MEMORY INTERFACES
    rom_dout_i,
    rom_addr_o,
    rom_cen_o,
    rom_clk_o,

// FUSED SRAM CONTROLLER MEMORY INTERFACES
    sram_dout_i,
    sram_addr_o,
    sram_cen_o,
    sram_clk_o,
    sram_din_o,
    sram_wen_o,

// OTHER AHB SUBORDINATE INTERFACES
    s_nx_hrdata_i,
    s_nx_hreadyout_i,
    s_nx_hresp_i,

    s_nx_haddr_o,
    s_nx_hauser_o,
    s_nx_hburst_o,
    s_nx_hmaster_o,
    s_nx_hmastlock_o,
    s_nx_hprot_o,
    s_nx_hready_o,
    s_nx_hsel_o,
    s_nx_hsize_o,
    s_nx_htrans_o,
    s_nx_hwdata_o,
    s_nx_hwrite_o
);

// PARAMETERs
//======================================
parameter                          NR_M         = 2;                       // Number of non-executable AHB Managers
parameter                          NR_S_X_ROM   = 1;                       // Number of fused ROM controllers (low decoder bits)
parameter                          NR_S_X_SRAM  = 1;                       // Number of fused SRAM controllers (high decoder bits)
parameter                          NR_S_NX      = 3;                       // Number of AHB Subordinates in non-executable space
parameter                          HAUSER_W     = 1;                       // Width of the HAUSER bus (min value is 1)
parameter [0:0]                    FIXED_B_PRIO = 1'b0;                    // Arbitration scheme for ALL fused ROM/SRAM controllers:
                                                                           //   1'b0 = round-robin (toggle priority, default)
                                                                           //   1'b1 = fixed Port-B priority (data bus wins;
                                                                           //          removes a_hsel_i from the memory-address
                                                                           //          mux fan-in for tighter timing).
parameter                          ASYNC_RST_EN = 1'b1;                    // 1=async active-low reset, 0=synchronous reset
localparam                         NR_S_X       = NR_S_X_ROM+NR_S_X_SRAM;  // Total number of executable subordinates
localparam                         NR_S         = NR_S_X+NR_S_NX;          // Total number of AHB Subordinates

// AHB CLOCK & RESET
//======================================
input  wire                        hclk_i;
input  wire                        hresetn_i;

output wire                        hclk_en_o;

// EXECUTABLE AHB BUS MANAGER INTERFACE
//========================================
input  wire                 [31:0] m_x_haddr_i;
input  wire         [HAUSER_W-1:0] m_x_hauser_i;
input  wire                  [2:0] m_x_hburst_i;
input  wire                        m_x_hmastlock_i;
input  wire                  [3:0] m_x_hprot_i;
input  wire                  [2:0] m_x_hsize_i;
input  wire                  [1:0] m_x_htrans_i;
input  wire                 [31:0] m_x_hwdata_i;
input  wire                        m_x_hwrite_i;

output wire                 [31:0] m_x_hrdata_o;
output wire                        m_x_hready_o;
output wire                        m_x_hresp_o;

// NON-EXECUTABLE AHB MANAGER INTERFACES
//========================================
input  wire          [32*NR_M-1:0] m_nx_haddr_i;
input  wire    [HAUSER_W*NR_M-1:0] m_nx_hauser_i;
input  wire           [3*NR_M-1:0] m_nx_hburst_i;
input  wire             [NR_M-1:0] m_nx_hmastlock_i;
input  wire           [4*NR_M-1:0] m_nx_hprot_i;
input  wire           [3*NR_M-1:0] m_nx_hsize_i;
input  wire           [2*NR_M-1:0] m_nx_htrans_i;
input  wire          [32*NR_M-1:0] m_nx_hwdata_i;
input  wire             [NR_M-1:0] m_nx_hwrite_i;

output wire          [32*NR_M-1:0] m_nx_hrdata_o;
output wire             [NR_M-1:0] m_nx_hready_o;
output wire             [NR_M-1:0] m_nx_hresp_o;

// ARBITER INTERFACE for NON-EXECUTABLE MANAGERS
//================================================
input  wire             [NR_M-1:0] m_nx_grant_i;
output wire             [NR_M-1:0] m_nx_request_o;

// ADDRESS DECODER INTERFACES (FOR ALL SUBORDINATES)
//====================================================
input  wire             [NR_S-1:0] s_decoder_1hot_i;
output wire                 [31:0] s_decoder_addr_o;

// ADDRESS DECODER INTERFACES (FOR EXECUTABLE SUBORDINATES ONLY)
//===============================================================
input  wire           [NR_S_X-1:0] s_x_decoder_1hot_i;
output wire                 [31:0] s_x_decoder_addr_o;

// FUSED ROM CONTROLLER MEMORY INTERFACES
//=========================================
input  wire    [32*NR_S_X_ROM-1:0] rom_dout_i;
output wire    [30*NR_S_X_ROM-1:0] rom_addr_o;
output wire       [NR_S_X_ROM-1:0] rom_cen_o;
output wire       [NR_S_X_ROM-1:0] rom_clk_o;

// FUSED SRAM CONTROLLER MEMORY INTERFACES
//=========================================
input  wire   [32*NR_S_X_SRAM-1:0] sram_dout_i;
output wire   [30*NR_S_X_SRAM-1:0] sram_addr_o;
output wire      [NR_S_X_SRAM-1:0] sram_cen_o;
output wire      [NR_S_X_SRAM-1:0] sram_clk_o;
output wire   [32*NR_S_X_SRAM-1:0] sram_din_o;
output wire    [4*NR_S_X_SRAM-1:0] sram_wen_o;

// NON-EXECUTABLE AHB SUBORDINATE INTERFACES
//===========================================
input  wire       [32*NR_S_NX-1:0] s_nx_hrdata_i;
input  wire          [NR_S_NX-1:0] s_nx_hreadyout_i;
input  wire          [NR_S_NX-1:0] s_nx_hresp_i;

output wire       [32*NR_S_NX-1:0] s_nx_haddr_o;
output wire [HAUSER_W*NR_S_NX-1:0] s_nx_hauser_o;
output wire        [3*NR_S_NX-1:0] s_nx_hburst_o;
output wire        [4*NR_S_NX-1:0] s_nx_hmaster_o;
output wire          [NR_S_NX-1:0] s_nx_hmastlock_o;
output wire        [4*NR_S_NX-1:0] s_nx_hprot_o;
output wire          [NR_S_NX-1:0] s_nx_hready_o;
output wire          [NR_S_NX-1:0] s_nx_hsel_o;
output wire        [3*NR_S_NX-1:0] s_nx_hsize_o;
output wire        [2*NR_S_NX-1:0] s_nx_htrans_o;
output wire       [32*NR_S_NX-1:0] s_nx_hwdata_o;
output wire          [NR_S_NX-1:0] s_nx_hwrite_o;

//=============================================================================
// 0)  PARAMETER RANGE CHECKS
//=============================================================================
// HMASTER ID array (section 2) holds 15 entries (4'h1..4'hF, 4'h0 reserved
// for the executable manager). NR_M must fit.

// pragma translate_off
generate
    if ((NR_M < 1) || (NR_M > 15)) begin : CHECK_NR_M
        initial $fatal(1, "ahb_interconnect_fused: NR_M (%0d) is out of range [1,15].", NR_M);
    end
    if (NR_S_X_ROM < 1) begin : CHECK_NR_S_X_ROM
        initial $fatal(1, "ahb_interconnect_fused: NR_S_X_ROM (%0d) must be >= 1.", NR_S_X_ROM);
    end
    if (NR_S_X_SRAM < 1) begin : CHECK_NR_S_X_SRAM
        initial $fatal(1, "ahb_interconnect_fused: NR_S_X_SRAM (%0d) must be >= 1.", NR_S_X_SRAM);
    end
    if (NR_S_NX < 1) begin : CHECK_NR_S_NX
        initial $fatal(1, "ahb_interconnect_fused: NR_S_NX (%0d) must be >= 1.", NR_S_NX);
    end
    if (HAUSER_W < 1) begin : CHECK_HAUSER_W
        initial $fatal(1, "ahb_interconnect_fused: HAUSER_W (%0d) must be >= 1.", HAUSER_W);
    end
     if ((ASYNC_RST_EN != 0) && (ASYNC_RST_EN != 1)) begin : CHECK_ASYNC_RST_EN
        initial $fatal(1, "ahb_interconnect_fused: ASYNC_RST_EN (%0d) must be 0 or 1.", ASYNC_RST_EN);
    end
endgenerate
// pragma translate_on


//=============================================================================
// 1)  INTERNAL WIRES/REGISTERS/PARAMETERS DECLARATION
//=============================================================================

//-----------------------------------------------
// Signals for the non-executable paths
//-----------------------------------------------

wire               [4*15-1:0] m_nx_hmaster;
wire        [4*(15-NR_M)-1:0] m_nx_hmaster_unused;

wire                   [31:0] nx_hrdata;
wire                          nx_hreadyout;
wire                          nx_hresp;
wire                   [31:0] nx_haddr;
wire           [HAUSER_W-1:0] nx_hauser;
wire                    [2:0] nx_hburst;
wire                    [3:0] nx_hmaster;
wire                          nx_hmastlock;
wire                    [3:0] nx_hprot;
wire                          nx_hready_unused;
wire                          nx_hsel;
wire                    [2:0] nx_hsize;
wire                    [1:0] nx_htrans;
wire                   [31:0] nx_hwdata;
wire                          nx_hwrite;

wire                          nx_dflt_decoder;
wire                          nx_dflt_hsel;
wire                   [31:0] nx_dflt_hrdata;
wire                          nx_dflt_hreadyout;
wire                          nx_dflt_hresp;
wire                   [31:0] nx_dflt_haddr_unused;
wire           [HAUSER_W-1:0] nx_dflt_hauser_unused;
wire                    [2:0] nx_dflt_hburst_unused;
wire                    [3:0] nx_dflt_hmaster_unused;
wire                          nx_dflt_hmastlock_unused;
wire                    [3:0] nx_dflt_hprot_unused;
wire                          nx_dflt_hready;
wire                    [2:0] nx_dflt_hsize_unused;
wire                    [1:0] nx_dflt_htrans;
wire                   [31:0] nx_dflt_hwdata_unused;
wire                          nx_dflt_hwrite_unused;

wire          [32*NR_S_X-1:0] nx_hrdata_from_x;
wire             [NR_S_X-1:0] nx_hreadyout_from_x;
wire             [NR_S_X-1:0] nx_hresp_from_x;
wire          [32*NR_S_X-1:0] nx_haddr_to_x;
wire           [3*NR_S_X-1:0] nx_hburst_to_x;
wire           [4*NR_S_X-1:0] nx_hmaster_to_x;
wire             [NR_S_X-1:0] nx_hmastlock_to_x;
wire           [4*NR_S_X-1:0] nx_hprot_to_x;
wire             [NR_S_X-1:0] nx_hready_to_x;
wire           [3*NR_S_X-1:0] nx_hsize_to_x;
wire    [HAUSER_W*NR_S_X-1:0] nx_hauser_to_x;
wire           [2*NR_S_X-1:0] nx_htrans_to_x;
wire          [32*NR_S_X-1:0] nx_hwdata_to_x;
wire             [NR_S_X-1:0] nx_hwrite_to_x;
wire             [NR_S_X-1:0] nx_hsel_to_x;

wire                          nx_hclk_en;
wire                          nx_hclk_en_manager_mux;
wire                          nx_hclk_en_subordinate_mux;
wire                          nx_hclk_en_dflt_subordinate;


//-----------------------------------------------
// Signals for the executable paths
//-----------------------------------------------

wire                          x_dflt_decoder;
wire                          x_dflt_hsel;
wire                   [31:0] x_dflt_hrdata;
wire                          x_dflt_hreadyout;
wire                          x_dflt_hresp;
wire                   [31:0] x_dflt_haddr_unused;
wire           [HAUSER_W-1:0] x_dflt_hauser_unused;
wire                    [2:0] x_dflt_hburst_unused;
wire                    [3:0] x_dflt_hmaster_unused;
wire                          x_dflt_hmastlock_unused;
wire                    [3:0] x_dflt_hprot_unused;
wire                          x_dflt_hready;
wire                    [2:0] x_dflt_hsize_unused;
wire                    [1:0] x_dflt_htrans;
wire                   [31:0] x_dflt_hwdata_unused;
wire                          x_dflt_hwrite_unused;

wire          [32*NR_S_X-1:0] x_hrdata_from_x;
wire             [NR_S_X-1:0] x_hreadyout_from_x;
wire             [NR_S_X-1:0] x_hresp_from_x;
wire          [32*NR_S_X-1:0] x_haddr_to_x;
wire    [HAUSER_W*NR_S_X-1:0] x_hauser_to_x;
wire           [3*NR_S_X-1:0] x_hburst_to_x;
wire           [4*NR_S_X-1:0] x_hmaster_to_x;
wire             [NR_S_X-1:0] x_hmastlock_to_x;
wire           [4*NR_S_X-1:0] x_hprot_to_x;
wire             [NR_S_X-1:0] x_hready_to_x;
wire           [3*NR_S_X-1:0] x_hsize_to_x;
wire           [2*NR_S_X-1:0] x_htrans_to_x;
wire          [32*NR_S_X-1:0] x_hwdata_to_x;
wire             [NR_S_X-1:0] x_hwrite_to_x;
wire             [NR_S_X-1:0] x_hsel_to_x;

wire                          x_hclk_en;
wire         [NR_S_X_ROM-1:0] x_hclk_en_fused_rom;
wire        [NR_S_X_SRAM-1:0] x_hclk_en_fused_sram;
wire                          x_hclk_en_subordinate_mux;
wire                          x_hclk_en_dflt_subordinate;


//////======================================================================================================================//////
//////======================================================================================================================//////
//////                                                                                                                      //////
//////                                       NON-EXECUTABLE SECTION OF THE INTERCONNECT                                     //////
//////                                                                                                                      //////
//////======================================================================================================================//////
//////======================================================================================================================//////

//=============================================================================
// 2)  AHB MANAGER MULTIPLEXOR
//=============================================================================

// HMASTER assignments for each manager
assign m_nx_hmaster = {4'hF, 4'hE, 4'hD, 4'hC, 4'hB, 4'hA, 4'h9, 4'h8,
                       4'h7, 4'h6, 4'h5, 4'h4, 4'h3, 4'h2, 4'h1      };  // 4'h0 is reserved for the executable manager

ahb_manager_mux #(.NR_M(NR_M), .HAUSER_W(HAUSER_W), .ARST_EN(ASYNC_RST_EN)) ahb_manager_mux_inst_nx (

// AHB CLOCK & RESET
    .hclk_i            ( hclk_i                   ),
    .hresetn_i         ( hresetn_i                ),

    .hclk_en_o         ( nx_hclk_en_manager_mux   ),

// AHB MANAGER INTERFACES
    .m_haddr_i         ( m_nx_haddr_i             ),
    .m_hauser_i        ( m_nx_hauser_i            ),
    .m_hburst_i        ( m_nx_hburst_i            ),
    .m_hmaster_i       ( m_nx_hmaster[4*NR_M-1:0] ),
    .m_hmastlock_i     ( m_nx_hmastlock_i         ),
    .m_hprot_i         ( m_nx_hprot_i             ),
    .m_hready_i        ( m_nx_hready_o            ),
    .m_hsel_i          ( {NR_M{1'b1}}             ),
    .m_hsize_i         ( m_nx_hsize_i             ),
    .m_htrans_i        ( m_nx_htrans_i            ),
    .m_hwdata_i        ( m_nx_hwdata_i            ),
    .m_hwrite_i        ( m_nx_hwrite_i            ),

    .m_hrdata_o        ( m_nx_hrdata_o            ),
    .m_hreadyout_o     ( m_nx_hready_o            ),
    .m_hresp_o         ( m_nx_hresp_o             ),

// ARBITER & ADDRESS DECODER INTERFACES
    .m_grant_i         ( m_nx_grant_i             ),
    .m_request_o       ( m_nx_request_o           ),

// MAIN AHB INTERFACE
    .hrdata_i          ( nx_hrdata                ),
    .hreadyout_i       ( nx_hreadyout             ),
    .hresp_i           ( nx_hresp                 ),

    .haddr_o           ( nx_haddr                 ),
    .hauser_o          ( nx_hauser                ),
    .hburst_o          ( nx_hburst                ),
    .hmaster_o         ( nx_hmaster               ),
    .hmastlock_o       ( nx_hmastlock             ),
    .hprot_o           ( nx_hprot                 ),
    .hready_o          ( nx_hready_unused         ),
    .hsel_o            ( nx_hsel                  ),
    .hsize_o           ( nx_hsize                 ),
    .htrans_o          ( nx_htrans                ),
    .hwdata_o          ( nx_hwdata                ),
    .hwrite_o          ( nx_hwrite                )
);

assign m_nx_hmaster_unused = m_nx_hmaster[4*15-1:4*NR_M];


//=============================================================================
// 3)  AHB SUBORDINATE MULTIPLEXOR
//=============================================================================

ahb_subordinate_mux #(.NR_S(NR_S+1), .HAUSER_W(HAUSER_W), .ARST_EN(ASYNC_RST_EN)) ahb_subordinate_mux_inst_nx (

// AHB CLOCK & RESET
    .hclk_i            ( hclk_i                                                                                    ),
    .hresetn_i         ( hresetn_i                                                                                 ),

    .hclk_en_o         ( nx_hclk_en_subordinate_mux                                                                ),

// AHB SUBORDINATE INTERFACES & ADDRESS DECODER
    .s_decoder_i       ({nx_dflt_decoder,          s_decoder_1hot_i[NR_S-1:NR_S_X],  s_decoder_1hot_i[NR_S_X-1:0] }),

    .s_hrdata_i        ({nx_dflt_hrdata,           s_nx_hrdata_i,                    nx_hrdata_from_x             }),
    .s_hreadyout_i     ({nx_dflt_hreadyout,        s_nx_hreadyout_i,                 nx_hreadyout_from_x          }),
    .s_hresp_i         ({nx_dflt_hresp,            s_nx_hresp_i,                     nx_hresp_from_x              }),

    .s_haddr_o         ({nx_dflt_haddr_unused,     s_nx_haddr_o,                     nx_haddr_to_x                }),
    .s_hauser_o        ({nx_dflt_hauser_unused,    s_nx_hauser_o,                    nx_hauser_to_x               }),
    .s_hburst_o        ({nx_dflt_hburst_unused,    s_nx_hburst_o,                    nx_hburst_to_x               }),
    .s_hmaster_o       ({nx_dflt_hmaster_unused,   s_nx_hmaster_o,                   nx_hmaster_to_x              }),
    .s_hmastlock_o     ({nx_dflt_hmastlock_unused, s_nx_hmastlock_o,                 nx_hmastlock_to_x            }),
    .s_hprot_o         ({nx_dflt_hprot_unused,     s_nx_hprot_o,                     nx_hprot_to_x                }),
    .s_hready_o        ({nx_dflt_hready,           s_nx_hready_o,                    nx_hready_to_x               }),
    .s_hsel_o          ({nx_dflt_hsel,             s_nx_hsel_o,                      nx_hsel_to_x                 }),
    .s_hsize_o         ({nx_dflt_hsize_unused,     s_nx_hsize_o,                     nx_hsize_to_x                }),
    .s_htrans_o        ({nx_dflt_htrans,           s_nx_htrans_o,                    nx_htrans_to_x               }),
    .s_hwdata_o        ({nx_dflt_hwdata_unused,    s_nx_hwdata_o,                    nx_hwdata_to_x               }),
    .s_hwrite_o        ({nx_dflt_hwrite_unused,    s_nx_hwrite_o,                    nx_hwrite_to_x               }),

// MAIN AHB INTERFACE
    .hrdata_o          ( nx_hrdata                                                                                 ),
    .hreadyout_o       ( nx_hreadyout                                                                              ),
    .hresp_o           ( nx_hresp                                                                                  ),

    .haddr_i           ( nx_haddr                                                                                  ),
    .hauser_i          ( nx_hauser                                                                                 ),
    .hburst_i          ( nx_hburst                                                                                 ),
    .hmaster_i         ( nx_hmaster                                                                                ),
    .hmastlock_i       ( nx_hmastlock                                                                              ),
    .hprot_i           ( nx_hprot                                                                                  ),
    .hready_i          ( nx_hreadyout                                                                              ),  // Standard AHB hready propagation — see ahb_interconnect_generic header.
    .hsel_i            ( nx_hsel                                                                                   ),
    .hsize_i           ( nx_hsize                                                                                  ),
    .htrans_i          ( nx_htrans                                                                                 ),
    .hwdata_i          ( nx_hwdata                                                                                 ),
    .hwrite_i          ( nx_hwrite                                                                                 )
);

// Default decoder selected when all bits of the main decoder are 0
assign nx_dflt_decoder  = ~(|s_decoder_1hot_i);

// Assign address going to the decoder
assign s_decoder_addr_o =  nx_haddr;


//=============================================================================
// 4)  DEFAULT AHB SUBORDINATE
//=============================================================================

ahb_default_subordinate #(.ARST_EN(ASYNC_RST_EN)) ahb_default_subordinate_inst_nx (

// AHB CLOCK & RESET
    .hclk_i            ( hclk_i                      ),
    .hresetn_i         ( hresetn_i                   ),

    .hclk_en_o         ( nx_hclk_en_dflt_subordinate ),

// AHB INTERFACE
    .hready_i          ( nx_dflt_hready              ),
    .hsel_i            ( nx_dflt_hsel                ),
    .htrans_i          ( nx_dflt_htrans              ),

    .hrdata_o          ( nx_dflt_hrdata              ),
    .hreadyout_o       ( nx_dflt_hreadyout           ),
    .hresp_o           ( nx_dflt_hresp               )
);


//////======================================================================================================================//////
//////======================================================================================================================//////
//////                                                                                                                      //////
//////                                       EXECUTABLE SECTION OF THE INTERCONNECT                                         //////
//////                                                                                                                      //////
//////======================================================================================================================//////
//////======================================================================================================================//////

//=============================================================================
// 5)  AHB SUBORDINATE MULTIPLEXOR
//=============================================================================

ahb_subordinate_mux #(.NR_S(NR_S_X+1), .HAUSER_W(HAUSER_W), .ARST_EN(ASYNC_RST_EN)) ahb_subordinate_mux_inst_x (

// AHB CLOCK & RESET
    .hclk_i            ( hclk_i                                         ),
    .hresetn_i         ( hresetn_i                                      ),

    .hclk_en_o         ( x_hclk_en_subordinate_mux                      ),

// AHB SUBORDINATE INTERFACES & ADDRESS DECODER
    .s_decoder_i       ({x_dflt_decoder,           s_x_decoder_1hot_i  }),

    .s_hrdata_i        ({x_dflt_hrdata,            x_hrdata_from_x     }),
    .s_hreadyout_i     ({x_dflt_hreadyout,         x_hreadyout_from_x  }),
    .s_hresp_i         ({x_dflt_hresp,             x_hresp_from_x      }),

    .s_hsel_o          ({x_dflt_hsel,              x_hsel_to_x         }),
    .s_haddr_o         ({x_dflt_haddr_unused,      x_haddr_to_x        }),
    .s_hauser_o        ({x_dflt_hauser_unused,     x_hauser_to_x       }),
    .s_hburst_o        ({x_dflt_hburst_unused,     x_hburst_to_x       }),
    .s_hmaster_o       ({x_dflt_hmaster_unused,    x_hmaster_to_x      }),
    .s_hmastlock_o     ({x_dflt_hmastlock_unused,  x_hmastlock_to_x    }),
    .s_hprot_o         ({x_dflt_hprot_unused,      x_hprot_to_x        }),
    .s_hready_o        ({x_dflt_hready,            x_hready_to_x       }),
    .s_hsize_o         ({x_dflt_hsize_unused,      x_hsize_to_x        }),
    .s_htrans_o        ({x_dflt_htrans,            x_htrans_to_x       }),
    .s_hwdata_o        ({x_dflt_hwdata_unused,     x_hwdata_to_x       }),
    .s_hwrite_o        ({x_dflt_hwrite_unused,     x_hwrite_to_x       }),

// MAIN AHB INTERFACE
    .hrdata_o          ( m_x_hrdata_o                                   ),
    .hreadyout_o       ( m_x_hready_o                                   ),
    .hresp_o           ( m_x_hresp_o                                    ),

    .haddr_i           ( m_x_haddr_i                                    ),
    .hauser_i          ( m_x_hauser_i                                   ),
    .hburst_i          ( m_x_hburst_i                                   ),
    .hmaster_i         ( 4'h0                                           ),  // 4'h0 is assigned to the executable manager
    .hmastlock_i       ( m_x_hmastlock_i                                ),
    .hprot_i           ( m_x_hprot_i                                    ),
    .hready_i          ( m_x_hready_o                                   ),  // Standard AHB hready propagation — see ahb_interconnect_generic header.
    .hsel_i            ( 1'b1                                           ),
    .hsize_i           ( m_x_hsize_i                                    ),
    .htrans_i          ( m_x_htrans_i                                   ),
    .hwdata_i          ( m_x_hwdata_i                                   ),
    .hwrite_i          ( m_x_hwrite_i                                   )
);


// Default decoder selected when all bits of the main decoder are 0
assign x_dflt_decoder     = ~(|s_x_decoder_1hot_i);

// Assign address going to the decoder
assign s_x_decoder_addr_o =  m_x_haddr_i;


//=============================================================================
// 6)  DEFAULT AHB SUBORDINATE
//=============================================================================

ahb_default_subordinate #(.ARST_EN(ASYNC_RST_EN)) ahb_default_subordinate_inst_x (

// AHB CLOCK & RESET
    .hclk_i            ( hclk_i                      ),
    .hresetn_i         ( hresetn_i                   ),

    .hclk_en_o         ( x_hclk_en_dflt_subordinate  ),

// AHB INTERFACE
    .hready_i          ( x_dflt_hready               ),
    .hsel_i            ( x_dflt_hsel                 ),
    .htrans_i          ( x_dflt_htrans               ),

    .hrdata_o          ( x_dflt_hrdata               ),
    .hreadyout_o       ( x_dflt_hreadyout            ),
    .hresp_o           ( x_dflt_hresp                )
);

//=============================================================================
// 7)  FUSED EXECUTABLE-MEMORY CONTROLLERS
//=============================================================================
//
// Each fused controller (ROM or SRAM) replaces an {ahb_manager_mux + ahb_arbiter_2m
// + external AHB subordinate} triple from the legacy hiperf interconnect.  Port A
// is driven by the executable manager (instruction fetch, read-only); Port B is
// driven by the granted non-executable manager (data, read+write for SRAM, read +
// 2-cycle ERROR for ROM).  Arbitration between A and B is internal to the fused
// controller.
//
// Subordinate-index layout in the executable decoder:
//   [0                .. NR_S_X_ROM-1]      → ahb_fused_rom_ctrl  instances
//   [NR_S_X_ROM .. NR_S_X-1]                → ahb_fused_sram_ctrl instances

genvar i;
generate
    for (i = 0; i < NR_S_X_ROM; i = i + 1) begin : AHB_FUSED_ROM

        ahb_fused_rom_ctrl #(
            .FIXED_B_PRIO      ( FIXED_B_PRIO                    ),
            .ARST_EN           ( ASYNC_RST_EN                    )
        ) ahb_fused_rom_ctrl_inst (

        // AHB CLOCK & RESET
            .hclk_i            ( hclk_i                          ),
            .hresetn_i         ( hresetn_i                       ),

            .hclk_en_o         ( x_hclk_en_fused_rom[i]          ),

        // PORT A — instruction fetch (executable manager)
            .a_haddr_i         ( x_haddr_to_x[32*i+:32]          ),
            .a_hsel_i          ( x_hsel_to_x[i]                  ),
            .a_htrans_i        ( x_htrans_to_x[2*i+:2]           ),
            .a_hready_i        ( x_hready_to_x[i]                ),

            .a_hrdata_o        ( x_hrdata_from_x[32*i+:32]       ),
            .a_hreadyout_o     ( x_hreadyout_from_x[i]           ),
            .a_hresp_o         ( x_hresp_from_x[i]               ),

        // PORT B — data (non-executable manager); writes return ERROR
            .b_haddr_i         ( nx_haddr_to_x[32*i+:32]         ),
            .b_hsel_i          ( nx_hsel_to_x[i]                 ),
            .b_htrans_i        ( nx_htrans_to_x[2*i+:2]          ),
            .b_hwrite_i        ( nx_hwrite_to_x[i]               ),
            .b_hready_i        ( nx_hready_to_x[i]               ),

            .b_hrdata_o        ( nx_hrdata_from_x[32*i+:32]      ),
            .b_hreadyout_o     ( nx_hreadyout_from_x[i]          ),
            .b_hresp_o         ( nx_hresp_from_x[i]              ),

        // ROM MACRO
            .rom_dout_i        ( rom_dout_i[32*i+:32]            ),
            .rom_addr_o        ( rom_addr_o[30*i+:30]            ),
            .rom_cen_o         ( rom_cen_o[i]                    ),
            .rom_clk_o         ( rom_clk_o[i]                    )
        );

    end
endgenerate

genvar j;
generate
    for (j = 0; j < NR_S_X_SRAM; j = j + 1) begin : AHB_FUSED_SRAM

        localparam k = NR_S_X_ROM + j;   // slot index in executable decoder

        ahb_fused_sram_ctrl #(
            .FIXED_B_PRIO      ( FIXED_B_PRIO                    ),
            .ARST_EN           ( ASYNC_RST_EN                    )
        ) ahb_fused_sram_ctrl_inst (

        // AHB CLOCK & RESET
            .hclk_i            ( hclk_i                          ),
            .hresetn_i         ( hresetn_i                       ),

            .hclk_en_o         ( x_hclk_en_fused_sram[j]         ),

        // PORT A — instruction fetch (executable manager)
            .a_haddr_i         ( x_haddr_to_x[32*k+:32]          ),
            .a_hready_i        ( x_hready_to_x[k]                ),
            .a_hsize_i         ( x_hsize_to_x[3*k+:3]            ),
            .a_htrans_i        ( x_htrans_to_x[2*k+:2]           ),
            .a_hsel_i          ( x_hsel_to_x[k]                  ),

            .a_hrdata_o        ( x_hrdata_from_x[32*k+:32]       ),
            .a_hreadyout_o     ( x_hreadyout_from_x[k]           ),
            .a_hresp_o         ( x_hresp_from_x[k]               ),

        // PORT B — data (non-executable manager)
            .b_haddr_i         ( nx_haddr_to_x[32*k+:32]         ),
            .b_hready_i        ( nx_hready_to_x[k]               ),
            .b_hsize_i         ( nx_hsize_to_x[3*k+:3]           ),
            .b_htrans_i        ( nx_htrans_to_x[2*k+:2]          ),
            .b_hwdata_i        ( nx_hwdata_to_x[32*k+:32]        ),
            .b_hwrite_i        ( nx_hwrite_to_x[k]               ),
            .b_hsel_i          ( nx_hsel_to_x[k]                 ),

            .b_hrdata_o        ( nx_hrdata_from_x[32*k+:32]      ),
            .b_hreadyout_o     ( nx_hreadyout_from_x[k]          ),
            .b_hresp_o         ( nx_hresp_from_x[k]              ),

        // SRAM MACRO
            .sram_dout_i       ( sram_dout_i[32*j+:32]           ),
            .sram_addr_o       ( sram_addr_o[30*j+:30]           ),
            .sram_cen_o        ( sram_cen_o[j]                   ),
            .sram_clk_o        ( sram_clk_o[j]                   ),
            .sram_din_o        ( sram_din_o[32*j+:32]            ),
            .sram_wen_o        ( sram_wen_o[4*j+:4]              )
        );

    end
endgenerate




//=============================================================================
// 8)  CLOCK ENABLE SIGNALS
//=============================================================================


// Build AHB interconnect clock enable signal for non-executable path
assign nx_hclk_en         =  nx_hclk_en_dflt_subordinate |
                             nx_hclk_en_subordinate_mux  |
                             nx_hclk_en_manager_mux;


// Build AHB interconnect clock enable signal for executable path
assign x_hclk_en          =  x_hclk_en_dflt_subordinate  |
                             x_hclk_en_subordinate_mux   |
                           (|x_hclk_en_fused_rom)        |
                           (|x_hclk_en_fused_sram)       ;


// Combine final clock enable signals
assign  hclk_en_o         =  nx_hclk_en | x_hclk_en      ;


//=============================================================================
// 9)  UNUSED-SIGNAL TIE-OFFS
//=============================================================================
// The fused ROM/SRAM controllers do not consume the full AHB sideband bundle:
//   - Port A is read-only         → no hwdata/hwrite
//   - hburst/hmaster/hmastlock/hprot/hauser are not propagated to memory
//   - ROM-slot bits of nx_hwdata and nx_hsize are unused (ROM ignores them)
// These signals are still produced by ahb_subordinate_mux and would otherwise
// raise verilator UNUSEDSIGNAL warnings.  Reducing them into a sink wire keeps
// the lint clean without a global waiver.

wire _unused_ok = &{1'b0,
                    nx_hburst_to_x,
                    nx_hmaster_to_x,
                    nx_hmastlock_to_x,
                    nx_hprot_to_x,
                    nx_hauser_to_x,
                    nx_hsize_to_x  [3*NR_S_X_ROM-1:0],
                    nx_hwdata_to_x[32*NR_S_X_ROM-1:0],
                    x_hauser_to_x,
                    x_hburst_to_x,
                    x_hmaster_to_x,
                    x_hmastlock_to_x,
                    x_hprot_to_x,
                    x_hwdata_to_x,
                    x_hwrite_to_x,
                    x_hsize_to_x   [3*NR_S_X_ROM-1:0],
                    1'b0};


endmodule // ahb_interconnect_fused


`default_nettype wire
