//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arv_dtm_dmi_master
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arv_dtm_dmi_master.v
// Module Description : Transport-agnostic backend of the aRVern Debug Transport
//                      Module (DTM). A front-end (JTAG, cJTAG, UART or I2C) hands
//                      it a {addr, op, data} request plus a launch strobe; it runs
//                      the transaction on the core's DMI bus (an APB4 master; the
//                      arvern boundary is the slave -- see arv_debug_dm.v).
//
//                      It owns the ONE clock-domain crossing in the debug path:
//                      the transport TCK domain <-> the arvern DMI (hclk) domain,
//                      via a level-toggle req/ack handshake. Only the two 1-bit
//                      levels are synced; the request/response payloads are held
//                      stable by the handshake, so they cross safely. See the
//                      numbered sections below for the step-by-step.
//
//                      INTEGRATION: hclk_i MUST be the always-on (ungated)
//                      oscillator, not the gated core clock -- a pending DMI
//                      request is what ungates the core clock to wake a WFI-sleeping
//                      hart (arvern doc/debug_interface.md section 5).
//
//----------------------------------------------------------------------------
`default_nettype none

module  arv_dtm_dmi_master #(
    parameter                   TCK_ARST_EN = 1'b1,       // transport (tck_i) domain
    parameter                   CLK_ARST_EN = 1'b1        // DMI bus  (hclk_i) domain
) (

// JTAG / TRANSPORT DOMAIN (TCK)
    input  wire                 tck_i,                    // transport clock
    input  wire                 tck_resetn_i,             // transport-domain reset, ALREADY conditioned:
                                                          // asserts whenever ANY underlying reset asserts,
                                                          // synchronised into tck and scan-masked upstream

    input  wire                 launch_i,                 // 1-TCK strobe: start a DMI op with the inputs below
    input  wire           [6:0] req_addr_i,               // DMI address (DMI_ABITS bits)
    input  wire          [1:0]  req_op_i,                 // 1=read, 2=write (0=nop never launched)
    input  wire         [31:0]  req_data_i,               // DMI write data
    input  wire                 hardreset_i,              // dmihardreset: abort outstanding xfer + clear inflight

    output wire                 inflight_o,               // 1 = a transaction is in flight (TCK-domain level)
    output wire         [31:0]  rdata_o,                  // last completed read data (TCK domain)
    output wire          [1:0]  cstatus_o,                // last completed status: 0=success, 2=failed (TCK domain)

// arvern DMI BUS - APB4 master
    input  wire                 hclk_i,                   // MUST be the ungated oscillator (see header)
    input  wire                 hclk_resetn_i,            // hclk-domain reset, ALREADY conditioned (as above)

    output wire                 dmi_psel_o,               // APB select
    output wire                 dmi_penable_o,            // APB enable (ACCESS phase)
    output wire           [8:0] dmi_paddr_o,              // APB byte address (reg index in [DMI_ABITS+1:2])
    output wire                 dmi_pwrite_o,             // 1=write, 0=read
    output wire         [31:0]  dmi_pwdata_o,             // APB write data
    output wire          [2:0]  dmi_pprot_o,              // APB protection (driven 0)
    input  wire                 dmi_pready_i,             // APB ready (latency-agnostic wait)
    input  wire         [31:0]  dmi_prdata_i,             // APB read data
    input  wire                 dmi_pslverr_i             // APB slave error -> status failed(2)
);


//=============================================================================
// 1)  TCK-SIDE: REQUEST LATCH + LEVEL TOGGLE + INFLIGHT
//=============================================================================
// launch_i latches the request (held stable for the whole crossing) and toggles
// req_level. inflight is set on launch, cleared when ack returns or on hardreset.

// DMI address width. Fixed at the arvern core's value; not a knob (no use case
// for another width). The APB paddr port is [DMI_ABITS+1:0] = [8:0].
localparam        DMI_ABITS = 7;
localparam        REQW = DMI_ABITS + 2 + 32;              // {addr, op, data}

wire   [REQW-1:0] req_latched;
wire              req_level;
wire              ack_level;
wire              ack_tck;                                // ack_level synced into TCK
wire              ack_tck_d;
wire              inflight;

arv_ipdff #(.WIDTH(REQW), .ARST_EN(TCK_ARST_EN)) u_req_latch (
                         .clk_i(tck_i), .rst_n_i(tck_resetn_i), .en_i(launch_i),
                                                                .d_i ({req_addr_i, req_op_i, req_data_i}),
                                                                .q_o (req_latched));

arv_ipdff #(.WIDTH(1), .ARST_EN(TCK_ARST_EN))    u_req_level (
                         .clk_i(tck_i), .rst_n_i(tck_resetn_i), .en_i(launch_i),
                                                                .d_i (~req_level),
                                                                .q_o ( req_level));

// ack_level (hclk) -> TCK sync + edge detect
arv_synchronizer #(.W(1), .ARST_EN(TCK_ARST_EN)) u_ack_tck_sync (
                         .clk_i(tck_i), .rst_n_i(tck_resetn_i), .async_i(ack_level),
                                                                .sync_o (ack_tck));

arv_ipdff #(.WIDTH(1), .ARST_EN(TCK_ARST_EN))    u_ack_tck_d (
                         .clk_i(tck_i), .rst_n_i(tck_resetn_i), .en_i(1'b1),
                                                                .d_i (ack_tck),
                                                                .q_o (ack_tck_d));

wire ack_tck_edge = ack_tck ^ ack_tck_d;

// inflight: SET on launch, CLEAR on ack edge or hardreset (set wins on collision,
// which cannot occur by construction since launch is gated by ~inflight upstream).
arv_ipdff #(.WIDTH(1), .ARST_EN(TCK_ARST_EN))    u_inflight (
                         .clk_i(tck_i), .rst_n_i(tck_resetn_i), .en_i(launch_i | ack_tck_edge | hardreset_i),
                                                                .d_i (launch_i),
                                                                .q_o (inflight));

assign inflight_o = inflight;


//=============================================================================
// 2)  TCK-SIDE: RESULT CAPTURE  (hclk result regs are quasi-static at ack edge)
//=============================================================================

wire [31:0] rsp_data_h;
wire  [1:0] rsp_stat_h;

arv_ipdff #(.WIDTH(32), .ARST_EN(TCK_ARST_EN))   u_rdata_tck (
                         .clk_i(tck_i), .rst_n_i(tck_resetn_i), .en_i(ack_tck_edge),
                                                                .d_i (rsp_data_h),
                                                                .q_o (rdata_o));

arv_ipdff #(.WIDTH(2), .ARST_EN(TCK_ARST_EN))    u_cstat_tck (
                         .clk_i(tck_i), .rst_n_i(tck_resetn_i), .en_i(ack_tck_edge),
                                                                .d_i (rsp_stat_h),
                                                                .q_o (cstatus_o));


//=============================================================================
// 3)  hclk-SIDE: REQ SYNC + EDGE DETECT + HARDRESET CROSSING
//=============================================================================

wire req_h;
wire req_h_d;

arv_synchronizer #(.W(1), .ARST_EN(CLK_ARST_EN)) u_req_h_sync (
                       .clk_i(hclk_i), .rst_n_i(hclk_resetn_i), .async_i(req_level),
                                                                .sync_o (req_h));

arv_ipdff #(.WIDTH(1), .ARST_EN(CLK_ARST_EN))    u_req_h_d (
                       .clk_i(hclk_i), .rst_n_i(hclk_resetn_i), .en_i(1'b1),
                                                                .d_i (req_h),
                                                                .q_o (req_h_d));

wire req_h_edge = req_h ^ req_h_d;

// hardreset (TCK pulse) -> hclk level toggle -> sync + edge detect = abort pulse
wire hardreset_level;
wire hardreset_h;
wire hardreset_h_d;

arv_ipdff #(.WIDTH(1), .ARST_EN(TCK_ARST_EN))    u_hardreset_level (
                         .clk_i(tck_i), .rst_n_i(tck_resetn_i), .en_i(hardreset_i),
                                                                .d_i(~hardreset_level),
                                                                .q_o( hardreset_level));

arv_synchronizer #(.W(1), .ARST_EN(CLK_ARST_EN)) u_hardreset_h_sync (
                       .clk_i(hclk_i), .rst_n_i(hclk_resetn_i), .async_i(hardreset_level),
                                                                .sync_o (hardreset_h));

arv_ipdff #(.WIDTH(1), .ARST_EN(CLK_ARST_EN))    u_hardreset_h_d (
                       .clk_i(hclk_i), .rst_n_i(hclk_resetn_i), .en_i(1'b1),
                                                                .d_i (hardreset_h),
                                                                .q_o (hardreset_h_d));

wire hardreset_h_edge = hardreset_h ^ hardreset_h_d;


//=============================================================================
// 4)  hclk-SIDE: DMI BUS FSM (APB4 master)
//=============================================================================
// IDLE -> (req edge) SETUP (PSEL) -> ACCESS (PSEL+PENABLE) -> (PREADY) capture +
// toggle ack -> IDLE. PREADY is awaited (latency-agnostic). hardreset_h_edge forces
// the FSM back to IDLE from any state (forget outstanding).

localparam     [1:0] S_IDLE   = 2'd0,
                     S_SETUP  = 2'd1,
                     S_ACCESS = 2'd2;

wire           [1:0] state_q;
reg            [1:0] state_nxt;

reg           [31:0] rsp_data_nxt;
reg            [1:0] rsp_stat_nxt;
reg                  rsp_cap_en;          // capture {rdata,status} this cycle
reg                  ack_tgl_en;          // toggle ack_level this cycle

// captured request fields on the hclk side (read combinationally from the stable
// TCK-domain holding register at the req edge; latched here for a clean bus drive)
wire [DMI_ABITS-1:0] req_addr_h  = req_latched[REQW-1 -: DMI_ABITS];
wire           [1:0] req_op_h    = req_latched[33 -: 2];
wire          [31:0] req_data_h  = req_latched[31:0];

wire [DMI_ABITS-1:0] hreq_addr;
wire           [1:0] hreq_op;
wire          [31:0] hreq_data;
wire                 hreq_cap_en = (state_q == S_IDLE) & req_h_edge & ~hardreset_h_edge;

arv_ipdff #(.WIDTH(DMI_ABITS), .ARST_EN(CLK_ARST_EN)) u_hreq_addr (
                         .clk_i(hclk_i), .rst_n_i(hclk_resetn_i), .en_i(hreq_cap_en),
                                                                  .d_i (req_addr_h),
                                                                  .q_o (hreq_addr));

arv_ipdff #(.WIDTH(2),         .ARST_EN(CLK_ARST_EN)) u_hreq_op (
                         .clk_i(hclk_i), .rst_n_i(hclk_resetn_i), .en_i(hreq_cap_en),
                                                                  .d_i (req_op_h),
                                                                  .q_o (hreq_op));

arv_ipdff #(.WIDTH(32),        .ARST_EN(CLK_ARST_EN)) u_hreq_data (
                         .clk_i(hclk_i), .rst_n_i(hclk_resetn_i), .en_i(hreq_cap_en),
                                                                  .d_i (req_data_h),
                                                                  .q_o (hreq_data));

always @(*) begin
    state_nxt    = state_q;
    rsp_cap_en   = 1'b0;
    ack_tgl_en   = 1'b0;
    rsp_data_nxt = rsp_data_h;
    rsp_stat_nxt = rsp_stat_h;

    case (state_q)
        S_IDLE   : if (req_h_edge)   state_nxt = S_SETUP;
        S_SETUP  :                   state_nxt = S_ACCESS;         // APB: one SETUP cycle, then ACCESS
        S_ACCESS : if (dmi_pready_i) begin
                     // A dmihardreset landing on the SAME cycle as PREADY must forget the
                     // transaction, not retire it: gate capture + ack toggle with the abort
                     // so we neither latch the aborted op's result nor fabricate a completion
                     // (dmihardreset = "forget any outstanding DMI transaction").
                     rsp_cap_en   = ~hardreset_h_edge;
                     ack_tgl_en   = ~hardreset_h_edge;
                     rsp_data_nxt = dmi_prdata_i;
                     rsp_stat_nxt = dmi_pslverr_i ? 2'd2 : 2'd0;   // PSLVERR -> failed, else success
                     state_nxt    = S_IDLE;
                 end
        default  : state_nxt = S_IDLE;
    endcase

    // dmihardreset: forget any outstanding transaction, snap back to IDLE.
    if (hardreset_h_edge) state_nxt = S_IDLE;
end

arv_ipdff #(.WIDTH(2),  .ARST_EN(CLK_ARST_EN)) u_state (
                   .clk_i(hclk_i), .rst_n_i(hclk_resetn_i), .en_i(1'b1),
                                                            .d_i (state_nxt),
                                                            .q_o (state_q));

arv_ipdff #(.WIDTH(32), .ARST_EN(CLK_ARST_EN)) u_rsp_data_h (
                   .clk_i(hclk_i), .rst_n_i(hclk_resetn_i), .en_i(rsp_cap_en),
                                                            .d_i (rsp_data_nxt),
                                                            .q_o (rsp_data_h));

arv_ipdff #(.WIDTH(2),  .ARST_EN(CLK_ARST_EN)) u_rsp_stat_h (
                   .clk_i(hclk_i), .rst_n_i(hclk_resetn_i), .en_i(rsp_cap_en),
                                                            .d_i (rsp_stat_nxt),
                                                            .q_o (rsp_stat_h));

arv_ipdff #(.WIDTH(1),  .ARST_EN(CLK_ARST_EN)) u_ack_level (
                   .clk_i(hclk_i), .rst_n_i(hclk_resetn_i), .en_i(ack_tgl_en),
                                                            .d_i(~ack_level),
                                                            .q_o( ack_level));

// DMI bus drive (APB master). PSEL through SETUP+ACCESS; PENABLE only in ACCESS.
// Register index is placed in PADDR[DMI_ABITS+1:2] (byte address, low 2 bits 0).
assign dmi_psel_o    = (state_q == S_SETUP) | (state_q == S_ACCESS);
assign dmi_penable_o = (state_q == S_ACCESS);
assign dmi_paddr_o   = {hreq_addr, 2'b00};
assign dmi_pwrite_o  = (hreq_op == 2'd2);      // op 2=write -> PWRITE=1; else read
assign dmi_pwdata_o  = hreq_data;
assign dmi_pprot_o   = 3'b000;


endmodule // arv_dtm_dmi_master

`default_nettype wire
