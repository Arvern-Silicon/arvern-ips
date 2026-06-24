//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_manager_mux
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_manager_mux.v
// Module Description : Manager-side mux that drives the AHB bus from the granted master.
//----------------------------------------------------------------------------
`default_nettype none

module  ahb_manager_mux #(
    parameter                       NR_M     = 3,             // Number of AHB Managers
    parameter                       HAUSER_W = 1,             // Width of the HAUSER bus (min value is 1)
    parameter                       ARST_EN  = 1'b1           // 1=async active-low reset, 0=synchronous reset
) (

// AHB CLOCK & RESET
    input wire                      hclk_i,
    input wire                      hresetn_i,

    output wire                     hclk_en_o,

// AHB MANAGER INTERFACES
    input  wire       [32*NR_M-1:0] m_haddr_i,
    input  wire [HAUSER_W*NR_M-1:0] m_hauser_i,
    input  wire        [3*NR_M-1:0] m_hburst_i,
    input  wire        [4*NR_M-1:0] m_hmaster_i,
    input  wire          [NR_M-1:0] m_hmastlock_i,
    input  wire        [4*NR_M-1:0] m_hprot_i,
    input  wire          [NR_M-1:0] m_hready_i,
    input  wire          [NR_M-1:0] m_hsel_i,
    input  wire        [3*NR_M-1:0] m_hsize_i,
    input  wire        [2*NR_M-1:0] m_htrans_i,
    input  wire       [32*NR_M-1:0] m_hwdata_i,
    input  wire          [NR_M-1:0] m_hwrite_i,

    output wire       [32*NR_M-1:0] m_hrdata_o,
    output wire          [NR_M-1:0] m_hreadyout_o,
    output wire          [NR_M-1:0] m_hresp_o,

// ARBITER & ADDRESS DECODER INTERFACES
    input  wire          [NR_M-1:0] m_grant_i,
    output wire          [NR_M-1:0] m_request_o,

// MAIN AHB INTERFACE
    input  wire              [31:0] hrdata_i,
    input  wire                     hreadyout_i,
    input  wire                     hresp_i,

    output wire              [31:0] haddr_o,
    output wire      [HAUSER_W-1:0] hauser_o,
    output wire               [2:0] hburst_o,
    output wire               [3:0] hmaster_o,
    output wire                     hmastlock_o,
    output wire               [3:0] hprot_o,
    output wire                     hready_o,
    output wire                     hsel_o,
    output wire               [2:0] hsize_o,
    output wire               [1:0] htrans_o,
    output wire              [31:0] hwdata_o,
    output wire                     hwrite_o
);


//=============================================================================
// 1)  INTERNAL WIRES/REGISTERS/PARAMETERS DECLARATION
//=============================================================================

wire            [NR_M-1:0] hclk_en_if;

wire         [32*NR_M-1:0] haddr_int;
wire          [3*NR_M-1:0] hburst_int;
wire          [4*NR_M-1:0] hmaster_int;
wire            [NR_M-1:0] hmastlock_int;
wire          [4*NR_M-1:0] hprot_int;
wire            [NR_M-1:0] hready_int;
wire            [NR_M-1:0] hsel_int;
wire          [3*NR_M-1:0] hsize_int;
wire   [HAUSER_W*NR_M-1:0] hauser_int;
wire          [2*NR_M-1:0] htrans_int;
wire         [32*NR_M-1:0] hwdata_int;
wire            [NR_M-1:0] hwrite_int;


//=============================================================================
// 2)  UTILITY FUNCTIONS
//=============================================================================

// OR-combine functions: used for data-phase signals where manager_if already
// gates the output with m_dph_ongoing so only one manager drives non-zero.
function         [31:0] mux_to_32b;
    input [32*NR_M-1:0] data;
    integer             ii;
    begin
        mux_to_32b = 32'h00000000;
        for (ii = 0; ii < NR_M; ii = ii + 1)
            mux_to_32b = mux_to_32b | data[32*ii+:32];
    end
endfunction

// Grant-aware MUX functions: used for address-phase signals.
// manager_if forwards addresses early (without waiting for grant), so multiple
// managers may drive non-zero simultaneously. The grant one-hot select ensures
// only the winning manager's address reaches the subordinate.
function         [31:0] grant_mux_32b;
    input [NR_M-1:0] grant;
    input [32*NR_M-1:0] data;
    integer             ii;
    begin
        grant_mux_32b = 32'h00000000;
        for (ii = 0; ii < NR_M; ii = ii + 1)
            grant_mux_32b = grant_mux_32b | (data[32*ii+:32] & {32{grant[ii]}});
    end
endfunction

function          [3:0] grant_mux_4b;
    input [NR_M-1:0] grant;
    input [4*NR_M-1:0] data;
    integer             ii;
    begin
        grant_mux_4b = 4'h0;
        for (ii = 0; ii < NR_M; ii = ii + 1)
            grant_mux_4b = grant_mux_4b | (data[4*ii+:4] & {4{grant[ii]}});
    end
endfunction

function          [2:0] grant_mux_3b;
    input [NR_M-1:0] grant;
    input [3*NR_M-1:0] data;
    integer             ii;
    begin
        grant_mux_3b = 3'h0;
        for (ii = 0; ii < NR_M; ii = ii + 1)
            grant_mux_3b = grant_mux_3b | (data[3*ii+:3] & {3{grant[ii]}});
    end
endfunction

function          [1:0] grant_mux_2b;
    input [NR_M-1:0] grant;
    input [2*NR_M-1:0] data;
    integer             ii;
    begin
        grant_mux_2b = 2'h0;
        for (ii = 0; ii < NR_M; ii = ii + 1)
            grant_mux_2b = grant_mux_2b | (data[2*ii+:2] & {2{grant[ii]}});
    end
endfunction

function        [HAUSER_W-1:0] grant_mux_hauser;
    input [NR_M-1:0] grant;
    input [HAUSER_W*NR_M-1:0] data;
    integer                    ii;
    begin
        grant_mux_hauser = {HAUSER_W{1'b0}};
        for (ii = 0; ii < NR_M; ii = ii + 1)
            grant_mux_hauser = grant_mux_hauser | (data[HAUSER_W*ii+:HAUSER_W] & {HAUSER_W{grant[ii]}});
    end
endfunction

function              [0:0] grant_mux_1b;
    input [NR_M-1:0] grant;
    input [NR_M-1:0] data;
    integer                 ii;
    begin
        grant_mux_1b = 1'b0;
        for (ii = 0; ii < NR_M; ii = ii + 1)
            grant_mux_1b = grant_mux_1b | (data[ii] & grant[ii]);
    end
endfunction



//=============================================================================
// 3)  AHB MANAGER INTERFACES
//=============================================================================

genvar ii;
generate
    for (ii = 0; ii < NR_M; ii = ii + 1) begin : AHB_MANAGER_IF
        ahb_manager_if #(.HAUSER_W(HAUSER_W), .ARST_EN(ARST_EN)) ahb_manager_if_inst (

        // AHB CLOCK & RESET
            .hclk_i            ( hclk_i                            ),
            .hresetn_i         ( hresetn_i                         ),

            .hclk_en_o         ( hclk_en_if[ii]                    ),

        // AHB MANAGER INTERFACES
            .m_haddr_i         ( m_haddr_i[32*ii+:32]              ),
            .m_hburst_i        ( m_hburst_i[3*ii+:3]               ),
            .m_hmaster_i       ( m_hmaster_i[4*ii+:4]              ),
            .m_hmastlock_i     ( m_hmastlock_i[ii]                 ),
            .m_hprot_i         ( m_hprot_i[4*ii+:4]                ),
            .m_hready_i        ( m_hready_i[ii]                    ),
            .m_hsel_i          ( m_hsel_i[ii]                      ),
            .m_hsize_i         ( m_hsize_i[3*ii+:3]                ),
            .m_hauser_i        ( m_hauser_i[HAUSER_W*ii+:HAUSER_W] ),
            .m_htrans_i        ( m_htrans_i[2*ii+:2]               ),
            .m_hwdata_i        ( m_hwdata_i[32*ii+:32]             ),
            .m_hwrite_i        ( m_hwrite_i[ii]                    ),

            .m_hrdata_o        ( m_hrdata_o[32*ii+:32]             ),
            .m_hreadyout_o     ( m_hreadyout_o[ii]                 ),
            .m_hresp_o         ( m_hresp_o[ii]                     ),

        // ARBITER & ADDRESS DECODER INTERFACES
            .m_grant_i         ( m_grant_i[ii]                     ),
            .m_request_o       ( m_request_o[ii]                   ),

        // MAIN AHB INTERFACE
            .hrdata_i          ( hrdata_i                          ),
            .hreadyout_i       ( hreadyout_i                       ),
            .hresp_i           ( hresp_i                           ),

            .haddr_o           ( haddr_int[32*ii+:32]              ),
            .hburst_o          ( hburst_int[3*ii+:3]               ),
            .hmaster_o         ( hmaster_int[4*ii+:4]              ),
            .hmastlock_o       ( hmastlock_int[ii]                 ),
            .hprot_o           ( hprot_int[4*ii+:4]                ),
            .hready_o          ( hready_int[ii]                    ),
            .hsel_o            ( hsel_int[ii]                      ),
            .hsize_o           ( hsize_int[3*ii+:3]                ),
            .hauser_o          ( hauser_int[HAUSER_W*ii+:HAUSER_W] ),
            .htrans_o          ( htrans_int[2*ii+:2]               ),
            .hwdata_o          ( hwdata_int[32*ii+:32]             ),
            .hwrite_o          ( hwrite_int[ii]                    )
        );
    end
endgenerate

// Combine the AHB signals of all managers
//
// CORRECTNESS INVARIANTS:
//   * m_grant_i is one-hot in every cycle (guaranteed by `ahb_arbiter_2m` and
//     equivalent external arbiters). Required for the grant-aware MUXes
//     below to behave as 1-of-N selectors.
//   * At most one m_dph_ongoing[i] is high in any cycle. Established by
//     (a) one-hot grant above + (b) m_request_o gated by hreadyout_i
//     (`ahb_manager_if.v`), which prevents a new grant during a
//     pending data phase. Required for the OR-combine of hwdata_int.
// Violating either invariant turns the corresponding combine into a
// multi-driver collision (silent data corruption).
//
// Address-phase signals: use grant-aware MUX (manager_if forwards early without grant)
assign haddr_o     =  grant_mux_32b   ( m_grant_i, haddr_int   );
assign hprot_o     =  grant_mux_4b    ( m_grant_i, hprot_int   );
assign hmaster_o   =  grant_mux_4b    ( m_grant_i, hmaster_int );
assign hburst_o    =  grant_mux_3b    ( m_grant_i, hburst_int  );
assign hsize_o     =  grant_mux_3b    ( m_grant_i, hsize_int   );
assign hauser_o    =  grant_mux_hauser( m_grant_i, hauser_int  );
assign htrans_o    =  grant_mux_2b    ( m_grant_i, htrans_int  );
assign hmastlock_o =  grant_mux_1b    ( m_grant_i, hmastlock_int );
assign hwrite_o    =  grant_mux_1b    ( m_grant_i, hwrite_int  );
// Data-phase signals: manager_if gates with m_dph_ongoing so only one drives non-zero
assign hwdata_o    =  mux_to_32b      ( hwdata_int  );
// Structural signals: unchanged
assign hready_o    = &hready_int;
assign hsel_o      = |hsel_int;

// Combine clock enable of each manager interface
assign hclk_en_o   = |hclk_en_if;


endmodule // ahb_manager_mux

`default_nettype wire
