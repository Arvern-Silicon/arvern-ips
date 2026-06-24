//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_fused_sram_ctrl
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_fused_sram_ctrl.v
// Module Description : AHB SRAM controller fused into the interconnect data path.
//
// Memory-macro contract: assumes a SINGLE-CYCLE SRAM (read data valid in
// the cycle following the read command, no wait state from the macro).
// `m0_dph_ongoing` and `m1_dph_ongoing` are cleared unconditionally in
// the next cycle after grant, so a slow SRAM macro would lose read data.
//
// Port-level conventions:
//   * Port A (instruction fetch) is read-only and always 32-bit. `a_hsize_i`
//     and the low 2 bits of `a_haddr_i` are intentionally unused.
//   * Port B (data) supports byte / halfword / word reads and writes via
//     `b_hsize_i` and the byte-strobe logic (`sram_wen_o`).
//   * Coherency between Port A and Port B is the master's responsibility
//     (FENCE.I or equivalent) — Port A bypasses the RPW forwarding path.
//----------------------------------------------------------------------------
`default_nettype none

module  ahb_fused_sram_ctrl #(
    // FIXED_B_PRIO selects the arbitration scheme between Port A and Port B:
    //   1'b0 (default) - Toggle priority: 1:1 round-robin between M0 and M1
    //   1'b1           - Fixed priority for Port B (data bus): M1 always wins when requesting.
    parameter         [0:0] FIXED_B_PRIO = 1'b0,
    parameter               ARST_EN      = 1'b1   // 1=async active-low reset, 0=synchronous reset
) (

// AHB CLOCK & RESET
    input  wire             hclk_i,
    input  wire             hresetn_i,
    output wire             hclk_en_o,

// AHB INTERFACE PORT A - Instruction fetch (read-only)
    input  wire      [31:0] a_haddr_i,
    input  wire             a_hready_i,
    input  wire       [2:0] a_hsize_i,
    input  wire       [1:0] a_htrans_i,
    input  wire             a_hsel_i,
    output wire      [31:0] a_hrdata_o,
    output wire             a_hreadyout_o,
    output wire             a_hresp_o,

// AHB INTERFACE PORT B - Data read/write
    input  wire      [31:0] b_haddr_i,
    input  wire             b_hready_i,
    input  wire       [2:0] b_hsize_i,
    input  wire       [1:0] b_htrans_i,
    input  wire      [31:0] b_hwdata_i,
    input  wire             b_hwrite_i,
    input  wire             b_hsel_i,
    output wire      [31:0] b_hrdata_o,
    output wire             b_hreadyout_o,
    output wire             b_hresp_o,

// SRAM INTERFACE
    input  wire      [31:0] sram_dout_i,
    output wire      [29:0] sram_addr_o,
    output wire             sram_cen_o,
    output wire             sram_clk_o,
    output wire      [31:0] sram_din_o,
    output wire       [3:0] sram_wen_o
 );


//=============================================================================
// 0)  INTERNAL BUS (manager-mux output / sram-controller input)
//=============================================================================

wire        bus_hready_to_sub;
wire [31:0] bus_hrdata;
wire  [1:0] bus_htrans;
wire [31:0] bus_hwdata;
wire        bus_hwrite;
wire        bus_hsel;


//=============================================================================
// 1)  MANAGER INTERFACE - PORT A  (M0, instruction fetch, read-only)
//=============================================================================

wire        m0_aph_valid;
wire        m0_latch_aph;
wire        m0_aph_immediate_granted;
wire        m0_aph_delayed_granted;
wire        m0_aph_granted;
wire        m0_aph_pending;
wire        m0_dph_ongoing;
wire        m0_grant;
wire        m0_request;

wire [31:0] m0_haddr_cache;
wire  [1:0] m0_htrans_cache;

wire [31:0] m0_haddr_to_sub;
wire  [1:0] m0_htrans_to_sub;
wire        m0_hsel_to_sub;
wire        m0_hready_to_sub;
wire        m0_hclk_en;

// Address-phase detection
assign m0_aph_valid             =  a_hsel_i & a_hready_i & a_htrans_i[1];
assign m0_latch_aph             =  m0_aph_valid & ~m0_grant;
assign m0_aph_immediate_granted =  m0_aph_valid   & m0_grant;
assign m0_aph_delayed_granted   =  m0_aph_pending & m0_grant;
assign m0_aph_granted           =  m0_aph_immediate_granted | m0_aph_delayed_granted;

// set on latch (priority), clear on delayed grant, hold otherwise
arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_m0_aph_pending (
                       .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(m0_latch_aph | m0_aph_delayed_granted),
                                                            .d_i (m0_latch_aph),
                                                            .q_o (m0_aph_pending));

// unconditional next-state (explicit else 0): en=1, d=m0_aph_granted
arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_m0_dph_ongoing (
                       .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                            .d_i (m0_aph_granted),
                                                            .q_o (m0_dph_ongoing));

// Cache APH control signals while we wait for grant (loaded on m0_latch_aph).
// No hsize/hwrite cache: Port A is read-only and always 32-bit.
arv_ipdff #(.WIDTH(32), .ARST_EN(ARST_EN)) u_m0_haddr_cache (
                        .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(m0_latch_aph),
                                                             .d_i (a_haddr_i),
                                                             .q_o (m0_haddr_cache));

arv_ipdff #(.WIDTH(2),  .ARST_EN(ARST_EN)) u_m0_htrans_cache (
                         .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(m0_latch_aph),
                                                              .d_i (a_htrans_i),
                                                              .q_o (m0_htrans_cache));

// Request to arbiter
assign m0_request       = (m0_aph_valid | m0_aph_pending);

// Manager-side responses
assign a_hreadyout_o    = m0_dph_ongoing  ? 1'b1 :
                          m0_aph_pending  ? 1'b0 :
                                            1'b1 ;

// M0 bypasses bus_hrdata: 32-bit-only + FENCE.I → no byte-mask, no RPW forward.
// No m0_dph_ongoing gate either — single-subordinate point-to-point fabric, so
// the manager only samples a_hrdata_o in its own dph (HRDATA is a don't-care
// outside that window per AHB-Lite). a_hrdata_o is now a pure wire from SRAM.
assign a_hrdata_o       = sram_dout_i;
assign a_hresp_o        = 1'b0;

// Subordinate-side outputs (M0 is read-only, so no hwrite drive)
assign m0_haddr_to_sub  = m0_aph_pending ? m0_haddr_cache  : a_haddr_i ;
assign m0_htrans_to_sub = m0_aph_pending ? m0_htrans_cache : a_htrans_i;
assign m0_hsel_to_sub   = m0_grant; // grant implies (m_aph_valid | m_aph_pending)
assign m0_hready_to_sub = a_hready_i | ~m0_aph_immediate_granted;

// Per-port clock enable
assign m0_hclk_en       = m0_latch_aph             | m0_aph_pending         |
                          m0_aph_immediate_granted | m0_aph_delayed_granted |
                          m0_dph_ongoing;


//=============================================================================
// 2)  MANAGER INTERFACE - PORT B  (M1, data read/write)
//=============================================================================

wire        m1_aph_valid;
wire        m1_latch_aph;
wire        m1_aph_immediate_granted;
wire        m1_aph_delayed_granted;
wire        m1_aph_granted;
wire        m1_aph_pending;
wire        m1_dph_ongoing;
wire        m1_grant;
wire        m1_request;

wire [31:0] m1_haddr_cache;
wire  [2:0] m1_hsize_cache;
wire  [1:0] m1_htrans_cache;
wire        m1_hwrite_cache;

wire [31:0] m1_haddr_to_sub;
wire  [2:0] m1_hsize_to_sub;
wire  [1:0] m1_htrans_to_sub;
wire [31:0] m1_hwdata_to_sub;
wire        m1_hwrite_to_sub;
wire        m1_hsel_to_sub;
wire        m1_hready_to_sub;
wire        m1_hclk_en;

assign m1_aph_valid             =  b_hsel_i & b_hready_i & b_htrans_i[1];
assign m1_latch_aph             =  m1_aph_valid & ~m1_grant;
assign m1_aph_immediate_granted =  m1_aph_valid   & m1_grant;
assign m1_aph_delayed_granted   =  m1_aph_pending & m1_grant;
assign m1_aph_granted           =  m1_aph_immediate_granted | m1_aph_delayed_granted;

// set on latch (priority), clear on delayed grant, hold otherwise
arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_m1_aph_pending (
                       .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(m1_latch_aph | m1_aph_delayed_granted),
                                                            .d_i (m1_latch_aph),
                                                            .q_o (m1_aph_pending));

// unconditional next-state (explicit else 0): en=1, d=m1_aph_granted
arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_m1_dph_ongoing (
                       .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                            .d_i (m1_aph_granted),
                                                            .q_o (m1_dph_ongoing));

// Cache APH control signals while we wait for grant (loaded on m1_latch_aph).
arv_ipdff #(.WIDTH(32), .ARST_EN(ARST_EN)) u_m1_haddr_cache (
                        .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(m1_latch_aph),
                                                             .d_i (b_haddr_i),
                                                             .q_o (m1_haddr_cache));

arv_ipdff #(.WIDTH(3),  .ARST_EN(ARST_EN)) u_m1_hsize_cache (
                        .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(m1_latch_aph),
                                                             .d_i (b_hsize_i),
                                                             .q_o (m1_hsize_cache));

arv_ipdff #(.WIDTH(2),  .ARST_EN(ARST_EN)) u_m1_htrans_cache (
                         .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(m1_latch_aph),
                                                              .d_i (b_htrans_i),
                                                              .q_o (m1_htrans_cache));

arv_ipdff #(.WIDTH(1),  .ARST_EN(ARST_EN)) u_m1_hwrite_cache (
                         .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(m1_latch_aph),
                                                              .d_i (b_hwrite_i),
                                                              .q_o (m1_hwrite_cache));

assign m1_request       = (m1_aph_valid | m1_aph_pending);

assign b_hreadyout_o    = m1_dph_ongoing  ? 1'b1 :
                          m1_aph_pending  ? 1'b0 :
                                            1'b1 ;

assign b_hrdata_o       = bus_hrdata & {32{m1_dph_ongoing}};
assign b_hresp_o        = 1'b0;

assign m1_haddr_to_sub  = m1_aph_pending ? m1_haddr_cache  : b_haddr_i ;
assign m1_hsize_to_sub  = m1_aph_pending ? m1_hsize_cache  : b_hsize_i ;
assign m1_htrans_to_sub = m1_aph_pending ? m1_htrans_cache : b_htrans_i;
assign m1_hwrite_to_sub = m1_aph_pending ? m1_hwrite_cache : b_hwrite_i;
assign m1_hwdata_to_sub = b_hwdata_i & {32{m1_dph_ongoing}};
assign m1_hsel_to_sub   = m1_grant;
assign m1_hready_to_sub = b_hready_i | ~m1_aph_immediate_granted;

assign m1_hclk_en       = m1_latch_aph             | m1_aph_pending         |
                          m1_aph_immediate_granted | m1_aph_delayed_granted |
                          m1_dph_ongoing;


//=============================================================================
// 3)  ARBITER  (selectable scheme via FIXED_B_PRIO)
//=============================================================================
//
// FIXED_B_PRIO=0 — Toggle priority (1:1 fairness, default).
// FIXED_B_PRIO=1 — Fixed Port-B priority: arb_grant[1] = m1_request, which
//                   has no a_hsel_i fan-in. The downstream sram_addr_internal
//                   mux therefore sees an a_hsel_i-free select.
//

wire  [1:0] arb_request;
wire  [1:0] arb_grant;

assign arb_request = {m1_request, m0_request};

generate
if (FIXED_B_PRIO) begin : gen_arb_fixed
    // M1 always wins when requesting. M0 only wins if M1 is idle.
    assign arb_grant = {arb_request[1], arb_request[0] & ~arb_request[1]};
end else begin : gen_arb_rr
    wire toggle_priority;

    // arb_grant is one-hot, so arb_grant[0] selects next value directly.
    arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_toggle_priority (
                            .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(arb_grant[0] | arb_grant[1]),
                                                                 .d_i (arb_grant[0]),
                                                                 .q_o (toggle_priority));

    assign arb_grant   = toggle_priority ? {                  arb_request[1], arb_request[0] & ~arb_request[1]} : // Toggled priority: 1.M1 / 2.M0
                                           {~arb_request[0] & arb_request[1], arb_request[0]                  } ; // Default priority: 1.M0 / 2.M1
end
endgenerate

assign m0_grant    = arb_grant[0];
assign m1_grant    = arb_grant[1];


//=============================================================================
// 4)  MANAGER MUX  (combine M0 + M1 onto the internal bus)
//=============================================================================

// Address-phase signals: grant-aware MUX (manager_if forwards early without grant
// so multiple managers may drive non-zero on the per-manager wires).
// haddr/hsize bypass this mux — haddr feeds sram_addr_internal directly
// (M0-default + M1 override), and hsize is M1-only since M0 is read-only.
assign bus_htrans       = (m0_htrans_to_sub & { 2{arb_grant[0]}}) | (m1_htrans_to_sub & { 2{arb_grant[1]}});
assign bus_hwrite       =                                           (m1_hwrite_to_sub &     arb_grant[1]  );

// Data-phase signals: manager_if gates with m_dph_ongoing so only one drives non-zero
assign bus_hwdata       =                     m1_hwdata_to_sub;

// Structural signals
assign bus_hsel         =  m0_hsel_to_sub   | m1_hsel_to_sub;
assign bus_hready_to_sub=  m0_hready_to_sub & m1_hready_to_sub;


//=============================================================================
// 5)  SRAM CONTROLLER  (FSM, write buffer, hwdata pause / RPW forwarding)
//=============================================================================

localparam IDLE               = 3'b000;
localparam READ               = 3'b010;
localparam READ_PENDING_WRITE = 3'b011;
localparam WRITE              = 3'b100;

localparam RPW_BIT            = 0;
localparam READ_BIT           = 1;
localparam WRITE_BIT          = 2;

wire           [2:0] state;
reg            [2:0] state_nxt;

wire                 sub_aph_valid;
wire                 sub_aph_write;
wire                 sub_aph_read;

wire                 sram_rd_cmd;
wire           [3:0] sram_rd_cmd_post;
wire                 sram_wr_cmd_pre;
wire                 sram_wr_cmd;
wire                 sram_wr_pause;
wire                 sram_wr_restore;
wire                 sram_wr_active;

wire          [31:0] hwdata_pause;
wire                 sram_read_from_pause;
wire           [3:0] sram_read_from_pause_post;

wire [29:0] sram_wr_addr_buf;
wire           [3:0] sram_wr_en_buf;
wire           [3:0] sram_wr_en_nxt;

wire [29:0] sram_addr_internal;

// Detect valid AHB transaction
assign sub_aph_valid    = bus_hsel & bus_hready_to_sub & bus_htrans[1];
assign sub_aph_write    = sub_aph_valid &  bus_hwrite;
assign sub_aph_read     = sub_aph_valid & ~bus_hwrite;

// Next-state logic
always @* begin
    case (state)
        IDLE: begin
            if      (sub_aph_write) state_nxt = WRITE;
            else if (sub_aph_read ) state_nxt = READ;
            else                    state_nxt = IDLE;
        end
        READ: begin
            if      (sub_aph_write) state_nxt = WRITE;
            else if (sub_aph_read ) state_nxt = READ;
            else                    state_nxt = IDLE;
        end
        WRITE: begin
            if      (sub_aph_read ) state_nxt = READ_PENDING_WRITE;
            else if (sub_aph_write) state_nxt = WRITE;
            else                    state_nxt = IDLE;
        end
        READ_PENDING_WRITE: begin
            if      (sub_aph_write) state_nxt = WRITE;
            else if (sub_aph_read ) state_nxt = READ_PENDING_WRITE;
            else                    state_nxt = IDLE;
        end
        default:                    state_nxt = IDLE;
    endcase
end

arv_ipdff #(.WIDTH(3), .RST_VAL(IDLE), .ARST_EN(ARST_EN)) u_state (
                              .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                                   .d_i (state_nxt),
                                                                   .q_o (state));

assign sram_rd_cmd      = state_nxt[READ_BIT];
assign sram_wr_cmd_pre  = state_nxt[WRITE_BIT];
assign sram_wr_cmd      = state    [WRITE_BIT];
assign sram_wr_pause    = state    [WRITE_BIT] &  sub_aph_read;
assign sram_wr_restore  = state    [RPW_BIT]   & ~sub_aph_read;

// Compute write strobes (writes are M1-only — Port A is read-only)
assign sram_wr_en_nxt = {((m1_hsize_to_sub[1:0]==2'b00) && (m1_haddr_to_sub[1:0]==2'b11)) || ((m1_hsize_to_sub[1:0]==2'b01) && (m1_haddr_to_sub[1]==1'b1)) || (m1_hsize_to_sub[1:0]==2'b10),
                         ((m1_hsize_to_sub[1:0]==2'b00) && (m1_haddr_to_sub[1:0]==2'b10)) || ((m1_hsize_to_sub[1:0]==2'b01) && (m1_haddr_to_sub[1]==1'b1)) || (m1_hsize_to_sub[1:0]==2'b10),
                         ((m1_hsize_to_sub[1:0]==2'b00) && (m1_haddr_to_sub[1:0]==2'b01)) || ((m1_hsize_to_sub[1:0]==2'b01) && (m1_haddr_to_sub[1]==1'b0)) || (m1_hsize_to_sub[1:0]==2'b10),
                         ((m1_hsize_to_sub[1:0]==2'b00) && (m1_haddr_to_sub[1:0]==2'b00)) || ((m1_hsize_to_sub[1:0]==2'b01) && (m1_haddr_to_sub[1]==1'b0)) || (m1_hsize_to_sub[1:0]==2'b10)};

// Write-command buffers, both loaded on sram_wr_cmd_pre.
arv_ipdff #(.WIDTH(30), .ARST_EN(ARST_EN)) u_sram_wr_addr_buf (
                          .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(sram_wr_cmd_pre),
                                                               .d_i (m1_haddr_to_sub[31:2]),
                                                               .q_o (sram_wr_addr_buf));

arv_ipdff #(.WIDTH(4), .RST_VAL(4'b1111), .ARST_EN(ARST_EN)) u_sram_wr_en_buf (
                                          .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(sram_wr_cmd_pre),
                                                                               .d_i (sram_wr_en_nxt),
                                                                               .q_o (sram_wr_en_buf));

// Paused write data, captured on sram_wr_pause.
arv_ipdff #(.WIDTH(32), .ARST_EN(ARST_EN)) u_hwdata_pause (
                      .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(sram_wr_pause),
                                                           .d_i (bus_hwdata),
                                                           .q_o (hwdata_pause));

assign sram_wr_active = (sram_wr_cmd & ~sram_wr_pause) | sram_wr_restore;

assign sram_wen_o     = ~(sram_wr_en_buf & {4{sram_wr_active}});

assign sram_din_o     = (bus_hwdata    & {32{sram_wr_cmd & ~sram_wr_pause}}) |
                        (hwdata_pause  & {32{sram_wr_restore             }}) ;

// Read-from-pause forwarding. Qualified with arb_grant[1] so the 30-bit
// comparator stays off the M0 critical path (M0 never needs RPW per FENCE.I).
assign sram_read_from_pause = arb_grant[1] & sram_rd_cmd & state_nxt[RPW_BIT] & (sram_wr_addr_buf == m1_haddr_to_sub[31:2]);

// Registered read-data select strobes (unconditional next-state: en=1).
arv_ipdff #(.WIDTH(4), .ARST_EN(ARST_EN)) u_sram_read_from_pause_post (
                                  .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                                       .d_i ({4{sram_read_from_pause}} & sram_wr_en_buf),
                                                                       .q_o (   sram_read_from_pause_post));

arv_ipdff #(.WIDTH(4), .ARST_EN(ARST_EN)) u_sram_rd_cmd_post (
                         .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                              .d_i ({4{sram_rd_cmd}} & ~({4{sram_read_from_pause}} & sram_wr_en_buf)),
                                                              .q_o (   sram_rd_cmd_post));

assign bus_hrdata = (sram_dout_i  & {{8{sram_rd_cmd_post[3]         }},
                                     {8{sram_rd_cmd_post[2]         }},
                                     {8{sram_rd_cmd_post[1]         }},
                                     {8{sram_rd_cmd_post[0]         }}}) |
                    (hwdata_pause & {{8{sram_read_from_pause_post[3]}},
                                     {8{sram_read_from_pause_post[2]}},
                                     {8{sram_read_from_pause_post[1]}},
                                     {8{sram_read_from_pause_post[0]}}});

// SRAM address mux: M0-default to keep M0 read off the arb_grant fan-in.
// In idle (cen=1) sram_addr_o is a don't-care, so defaulting to M0 is safe.
assign sram_addr_internal = sram_wr_active ? sram_wr_addr_buf      :
                            arb_grant[1]   ? m1_haddr_to_sub[31:2] :
                                             m0_haddr_to_sub[31:2] ;

assign sram_addr_o   = sram_addr_internal;
assign sram_cen_o    = ~(sram_rd_cmd | sram_wr_active);
assign sram_clk_o    =   hclk_i;


//=============================================================================
// 6)  CLOCK ENABLE AGGREGATION
//=============================================================================

wire   sub_hclk_en;
assign sub_hclk_en = sub_aph_valid | (state != IDLE);

assign hclk_en_o   = m0_hclk_en | m1_hclk_en | sub_hclk_en;


//=============================================================================
// 7)  LINT CLEANUP
//=============================================================================

wire   bus_htrans0_unused;
assign bus_htrans0_unused = bus_htrans[0];

// a_hsize_i is intentionally unused (Port A is 32-bit-only).
wire   a_hsize_unused;
assign a_hsize_unused     = |a_hsize_i;

// M0 is 32-bit-only, so the lower 2 byte-offset bits never drive the SRAM.
wire   m0_haddr_low_unused;
assign m0_haddr_low_unused = |m0_haddr_to_sub[1:0];

// SRAM controller supports up to 32-bit (HSIZE=3'b010), so HSIZE[2] is unused.
wire   m1_hsize_high_unused;
assign m1_hsize_high_unused = m1_hsize_to_sub[2];


endmodule // ahb_fused_sram_ctrl

`default_nettype wire
