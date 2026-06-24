//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_manager_if
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_manager_if.v
// Module Description : AHB manager interface (per-master front-end into the interconnect).
//
// LOOPBACK CONTRACT: `m_hready_i` (input) is expected to be wired to this
// instance's own `m_hreadyout_o` (output) at the next hierarchy level — see
// `ahb_manager_mux` / `ahb_interconnect_*`. The module is carefully written
// so that no combinational path inside it goes from `m_hready_i` back to
// `m_hreadyout_o`; the external loopback is therefore safe. Any future
// modification that closes such a path will create a combinational loop.
//----------------------------------------------------------------------------
`default_nettype none

module  ahb_manager_if #(
    parameter                  HAUSER_W = 1,         // Width of the HAUSER bus (min value is 1)
    parameter                  ARST_EN  = 1'b1       // 1=async active-low reset, 0=synchronous reset
) (

// AHB CLOCK & RESET
    input  wire                hclk_i,
    input  wire                hresetn_i,

    output wire                hclk_en_o,

// AHB MANAGER INTERFACES
    input  wire         [31:0] m_haddr_i,
    input  wire [HAUSER_W-1:0] m_hauser_i,
    input  wire          [2:0] m_hburst_i,
    input  wire          [3:0] m_hmaster_i,
    input  wire                m_hmastlock_i,
    input  wire          [3:0] m_hprot_i,
    input  wire                m_hready_i,
    input  wire                m_hsel_i,
    input  wire          [2:0] m_hsize_i,
    input  wire          [1:0] m_htrans_i,
    input  wire         [31:0] m_hwdata_i,
    input  wire                m_hwrite_i,

    output wire         [31:0] m_hrdata_o,
    output wire                m_hreadyout_o,
    output wire                m_hresp_o,

// ARBITER & ADDRESS DECODER INTERFACES
    input  wire                m_grant_i,
    output wire                m_request_o,

// MAIN AHB INTERFACE
    input  wire         [31:0] hrdata_i,
    input  wire                hreadyout_i,
    input  wire                hresp_i,

    output wire         [31:0] haddr_o,
    output wire [HAUSER_W-1:0] hauser_o,
    output wire          [2:0] hburst_o,
    output wire          [3:0] hmaster_o,
    output wire                hmastlock_o,
    output wire          [3:0] hprot_o,
    output wire                hready_o,
    output wire                hsel_o,
    output wire          [2:0] hsize_o,
    output wire          [1:0] htrans_o,
    output wire         [31:0] hwdata_o,
    output wire                hwrite_o
);


//=============================================================================
// 1)  INTERNAL WIRES/REGISTERS/PARAMETERS DECLARATION
//=============================================================================

wire                  m_aph_valid;
wire                  latch_m_aph;
wire                  m_aph_immediate_granted;
wire                  m_aph_delayed_granted;
wire                  m_aph_granted;
wire                  m_aph_pending;
wire                  m_dph_ongoing;

wire           [31:0] m_haddr_cache;
wire   [HAUSER_W-1:0] m_hauser_cache;
wire            [2:0] m_hburst_cache;
wire            [3:0] m_hmaster_cache;
wire                  m_hmastlock_cache;
wire            [3:0] m_hprot_cache;
wire            [2:0] m_hsize_cache;
wire            [1:0] m_htrans_cache;
wire                  m_hwrite_cache;


//=============================================================================
// 2)  ADDRESS AND DATA PHASE LOGIC ON THE MANAGER SIDE
//=============================================================================

// Detect last cycle of the address phase from manager
assign m_aph_valid        =  m_hsel_i & m_hready_i & m_htrans_i[1];

// We latch the address phase if the bus is not free
assign latch_m_aph        =  m_aph_valid & ~m_grant_i;

// set on latch_m_aph (priority), clear on delayed grant, hold otherwise
arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_m_aph_pending (
                      .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(latch_m_aph | m_aph_delayed_granted),
                                                           .d_i (latch_m_aph),
                                                           .q_o (m_aph_pending));

// Send the request to the arbiter as soon as hreadyout is 1
assign m_request_o             = (m_aph_valid | m_aph_pending) & hreadyout_i;

// Detect if address phase from manager is immediately granted or delayed granted
assign m_aph_immediate_granted =  m_aph_valid   & m_grant_i;
assign m_aph_delayed_granted   =  m_aph_pending & m_grant_i;
assign m_aph_granted           =  m_aph_immediate_granted | m_aph_delayed_granted;

// Data phase detection
// set on grant (priority), clear on hreadyout_i, hold otherwise
arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_m_dph_ongoing (
                      .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(m_aph_granted | hreadyout_i),
                                                           .d_i (m_aph_granted),
                                                           .q_o (m_dph_ongoing));


//=============================================================================
// 3) AHB SIGNALS ON THE MANAGER SIDE
//=============================================================================

// HREADYOUT to manager
assign m_hreadyout_o =  m_dph_ongoing  ? hreadyout_i :   // During data phase, we forward hready out from subordinate
                        m_aph_pending  ? 1'b0        :   // If there is a pending address phase -> hreadyout=0
                                         1'b1        ;   // In all other cases, we send hreadyout=1


// Data phase signals back to manager
assign m_hrdata_o    =  hrdata_i & {32{m_dph_ongoing}};
assign m_hresp_o     =  hresp_i  &     m_dph_ongoing  ;


//=============================================================================
// 4) AHB SIGNALS ON THE SUBORDINATE SIDE
//=============================================================================

// Save address phase control signals — one enabled register per field,
// all loaded together on latch_m_aph, all reset to 0.
arv_ipdff #(.WIDTH(32),       .ARST_EN(ARST_EN)) u_m_haddr_cache (
                                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(latch_m_aph), .d_i(m_haddr_i),     .q_o(m_haddr_cache));

arv_ipdff #(.WIDTH(HAUSER_W), .ARST_EN(ARST_EN)) u_m_hauser_cache (
                                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(latch_m_aph), .d_i(m_hauser_i),    .q_o(m_hauser_cache));

arv_ipdff #(.WIDTH(3),        .ARST_EN(ARST_EN)) u_m_hburst_cache (
                                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(latch_m_aph), .d_i(m_hburst_i),    .q_o(m_hburst_cache));

arv_ipdff #(.WIDTH(4),        .ARST_EN(ARST_EN)) u_m_hmaster_cache (
                                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(latch_m_aph), .d_i(m_hmaster_i),   .q_o(m_hmaster_cache));

arv_ipdff #(.WIDTH(1),        .ARST_EN(ARST_EN)) u_m_hmastlock_cache (
                                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(latch_m_aph), .d_i(m_hmastlock_i), .q_o(m_hmastlock_cache));

arv_ipdff #(.WIDTH(4),        .ARST_EN(ARST_EN)) u_m_hprot_cache (
                                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(latch_m_aph), .d_i(m_hprot_i),     .q_o(m_hprot_cache));

arv_ipdff #(.WIDTH(3),        .ARST_EN(ARST_EN)) u_m_hsize_cache (
                                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(latch_m_aph), .d_i(m_hsize_i),     .q_o(m_hsize_cache));

arv_ipdff #(.WIDTH(2),        .ARST_EN(ARST_EN)) u_m_htrans_cache (
                                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(latch_m_aph), .d_i(m_htrans_i),    .q_o(m_htrans_cache));

arv_ipdff #(.WIDTH(1),        .ARST_EN(ARST_EN)) u_m_hwrite_cache (
                                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(latch_m_aph), .d_i(m_hwrite_i),    .q_o(m_hwrite_cache));


// Address phase signals
assign haddr_o       = m_aph_pending ? m_haddr_cache     : m_haddr_i    ;
assign hburst_o      = m_aph_pending ? m_hburst_cache    : m_hburst_i   ;
assign hmaster_o     = m_aph_pending ? m_hmaster_cache   : m_hmaster_i  ;
assign hmastlock_o   = m_aph_pending ? m_hmastlock_cache : m_hmastlock_i;
assign hprot_o       = m_aph_pending ? m_hprot_cache     : m_hprot_i    ;
assign hsize_o       = m_aph_pending ? m_hsize_cache     : m_hsize_i    ;
assign hauser_o      = m_aph_pending ? m_hauser_cache    : m_hauser_i   ;
assign htrans_o      = m_aph_pending ? m_htrans_cache    : m_htrans_i   ;
assign hwrite_o      = m_aph_pending ? m_hwrite_cache    : m_hwrite_i   ;
assign hsel_o        = m_grant_i; // grant implies (m_aph_valid | m_aph_pending)

// HREADY signal to subordinates.
// Non-active managers drive hready_o=1 so the AND-reduce in ahb_manager_mux
// (line `assign hready_o = &hready_int;`) is governed by the active manager's
// m_hready_i alone.
assign hready_o      =  m_hready_i    | ~m_aph_immediate_granted;


// Data phase signals to subordinates
assign hwdata_o      =  m_hwdata_i    & {32{m_dph_ongoing}};

// Clock enable signal
assign hclk_en_o     = latch_m_aph             | m_aph_pending         |
                       m_aph_immediate_granted | m_aph_delayed_granted | m_dph_ongoing ;


endmodule // ahb_manager_if


`default_nettype wire
