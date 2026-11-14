//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    apb_usb_host
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : apb_usb_host.v
// Module Description : Compact low-speed USB host for one HID device, APB4
//                      completer: registers, interrupt, report buffers and
//                      the MDELEG privilege gate around the port sequencer
//                      (apb_usb_host_seq) and the serial engine
//                      (apb_usb_host_sie). Contract: doc/apb_usb_host.md.
//
//   0x00 INFO        RO     0x24 REPORT_INFO RO     0x40-0x7C REPORT  RO
//   0x04 CTRL        RW     0x28 XFER        RW     0x80-0xBC XDATA   RW
//   0x08 CMD         WO     0x2C SETUP0      RW     0xC0 MDELEG       RW (M-mode only)
//   0x0C STATUS      RO     0x30 SETUP1      RW
//   0x10 IRQ_EN      RW     0x34 DIAG0       RO/W
//   0x14 IRQ_PEND    RO/W1C 0x38 DIAG1       RO
//   0x18 DEV_ID      RO
//   0x1C DEV_IF      RO
//   0x20 DEV_EP      RO
//----------------------------------------------------------------------------
`default_nettype none

module  apb_usb_host #(
    parameter                     CLK_HZ           = 48000000,  // pclk_i frequency (Hz)
    parameter                     FS_EN            = 0,         // full speed (reserved: 1 does not build)
    parameter                     CTRL_EN          = 0,         // software control transfers
    parameter                     DIAG_EN          = 0,         // diagnostic counters
    parameter                     ADDRW            = 8,         // APB address width (8-16)
    parameter               [8:0] MDELEG_RST       = 9'h10F,    // MDELEG[8:0] reset value (default: M-mode only, PSLVERR)
    parameter                     ASYNC_RST_EN     = 1          // Reset style: 1=async active-low reset, 0=synchronous reset
) (

// APB CLOCK & RESET
    input  wire                   pclk_i,                       // bus clock and USB timebase (gated by pclk_en_o at the SoC-level ICG)
    input  wire                   presetn_i,                    // active-low reset, style per ASYNC_RST_EN
    output wire                   pclk_en_o,                    // clock request

// APB INTERFACE
    input  wire                   psel_i,
    input  wire                   penable_i,
    input  wire       [ADDRW-1:0] paddr_i,
    input  wire                   pwrite_i,
    input  wire            [31:0] pwdata_i,
    input  wire             [3:0] pstrb_i,
    input  wire             [2:0] pprot_i,                      // protection ([0] privileged; [2:1] not used)
    input  wire                   psmode_i,                     // aRVern S-mode sideband
    output wire            [31:0] prdata_o,
    output wire                   pready_o,
    output wire                   pslverr_o,                    // error (access refused by MDELEG with RESP=1)

// USB PORT
    input  wire                   usb_dp_i,                     // D+ pad read-back (asynchronous)
    input  wire                   usb_dm_i,                     // D- pad read-back (asynchronous)
    output wire                   usb_dp_o,                     // D+ driven value
    output wire                   usb_dm_o,                     // D- driven value
    output wire                   usb_oe_o,                     // D+/D- output enable

// INTERRUPT
    output wire                   irq_o                         // OR of IRQ_PEND & IRQ_EN
);


//=============================================================================
// 1)  PARAMETERS
//=============================================================================

// pragma translate_off
generate
    if (FS_EN != 0) begin : CHECK_FS_EN
        initial $fatal(1, "apb_usb_host: FS_EN (%0d) is reserved; only 0 is supported.", FS_EN);
    end
    if ((CTRL_EN != 0) && (CTRL_EN != 1)) begin : CHECK_CTRL_EN
        initial $fatal(1, "apb_usb_host: CTRL_EN (%0d) must be 0 or 1.", CTRL_EN);
    end
    if ((DIAG_EN != 0) && (DIAG_EN != 1)) begin : CHECK_DIAG_EN
        initial $fatal(1, "apb_usb_host: DIAG_EN (%0d) must be 0 or 1.", DIAG_EN);
    end
    if ((ADDRW < 8) || (ADDRW > 16)) begin : CHECK_ADDRW
        initial $fatal(1, "apb_usb_host: ADDRW (%0d) must be 8 to 16.", ADDRW);
    end
    if ((MDELEG_RST[1:0] == 2'b10) || (MDELEG_RST[3:2] == 2'b10) || (MDELEG_RST[7:4] != 4'h0)) begin : CHECK_MDELEG_RST
        initial $fatal(1, "apb_usb_host: MDELEG_RST (9'h%03h) holds a reserved privilege code or a reserved bit.", MDELEG_RST);
    end
    if ((ASYNC_RST_EN != 0) && (ASYNC_RST_EN != 1)) begin : CHECK_ASYNC_RST_EN
        initial $fatal(1, "apb_usb_host: ASYNC_RST_EN (%0d) must be 0 or 1.", ASYNC_RST_EN);
    end
endgenerate
// pragma translate_on

// Full speed is not implemented: a build with FS_EN != 0 stops in synthesis too
generate
    if (FS_EN != 0) begin : g_fs_reserved
        apb_usb_host_FS_EN_is_reserved u_fs_reserved ();
    end
endgenerate

localparam              ARST_EN  = (ASYNC_RST_EN != 0);
localparam              XF       = (CTRL_EN != 0);
localparam              DG       = (DIAG_EN != 0);
localparam              DEC_WD   = ADDRW - 2;

localparam        [1:0] MDELEG_WR_PRIV_RST = MDELEG_RST[1:0];
localparam        [1:0] MDELEG_RD_PRIV_RST = MDELEG_RST[3:2];
localparam              MDELEG_RESP_RST    = MDELEG_RST[8];
localparam        [1:0] MDELEG_PRIV_RSVD   = 2'b10;

// Register word addresses
localparam [DEC_WD-1:0] REG_INFO     = 'h00,
                        REG_CTRL     = 'h01,
                        REG_CMD      = 'h02,
                        REG_STATUS   = 'h03,
                        REG_IRQ_EN   = 'h04,
                        REG_IRQ_PEND = 'h05,
                        REG_DEV_ID   = 'h06,
                        REG_DEV_IF   = 'h07,
                        REG_DEV_EP   = 'h08,
                        REG_RPT_INFO = 'h09,
                        REG_XFER     = 'h0A,
                        REG_SETUP0   = 'h0B,
                        REG_SETUP1   = 'h0C,
                        REG_DIAG0    = 'h0D,
                        REG_DIAG1    = 'h0E,
                        REG_REPORT0  = 'h10,
                        REG_REPORT1  = 'h11,
                        REG_XDATA0   = 'h20,
                        REG_XDATA1   = 'h21,
                        REG_MDELEG   = 'h30;


//=============================================================================
// 2)  DECLARATIONS
//=============================================================================

wire                    acc_valid;
wire                    acc_write;
wire                    acc_read;
wire       [DEC_WD-1:0] acc_addr;
wire                    acc_allowed;
wire                    reg_wr;
wire                    reg_rd;
wire                    machine_mode;
wire                    supervisor_mode;
wire              [1:0] privilege_mode;
wire              [1:0] mdeleg_wr_priv;
wire              [1:0] mdeleg_rd_priv;
wire                    mdeleg_resp;
wire             [31:0] mdeleg;
wire                    acc_q;                          // a transfer ended on the last edge

wire                    ctrl_en;
wire                    ctrl_boot;
wire                    ctrl_idle0;
wire              [7:0] ctrl_poll;
wire              [6:0] irq_en;
wire              [6:0] irq_pend;
wire             [63:0] setup;
wire              [6:0] xlen;
wire             [63:0] xdata;
wire            [127:0] rbuf;                           // receive buffer [63:0], visible report [127:64]
wire              [3:0] rlen;
wire              [7:0] rseq;
wire             [31:0] diag0;
wire             [31:0] diag1;

// Sequencer
wire              [3:0] buf_rd_idx;
wire              [7:0] buf_rd_byte;
wire              [7:0] xd_rd_byte;
wire                    rx_dest;
wire                    rpt_commit;
wire              [3:0] rpt_len;
wire                    run;
wire              [3:0] state;
wire                    fs_dev;
wire              [3:0] err;
wire              [3:0] step;
wire              [1:0] attempt;
wire                    xbusy;
wire                    xpkt;
wire              [2:0] xres;
wire              [3:0] xlen_in;
wire             [31:0] dev_id;
wire             [24:0] dev_if;
wire             [25:0] dev_ep;
wire                    ev_report;
wire                    ev_ready;
wire                    ev_detach;
wire                    ev_fail;
wire                    ev_xpkt;
wire                    ev_xin;
wire                    ev_xdone;
wire                    ev_state;
wire                    ev_tmo;
wire                    ev_bad;
wire                    ev_other;
wire                    ev_stall;
wire                    ev_busrst;
wire                    ev_dup;

// Serial engine
wire                    sie_start;
wire              [1:0] sie_kind;
wire              [3:0] sie_pid;
wire              [6:0] sie_addr;
wire              [3:0] sie_ep;
wire              [3:0] sie_len;
wire                    sie_resp;
wire              [3:0] sie_tx_idx;
wire              [7:0] sie_tx_byte;
wire                    sie_reset;
wire                    sie_abort;
wire                    sie_busy;
wire                    sie_done;
wire              [2:0] sie_res;
wire              [3:0] sie_rx_pid;
wire              [3:0] sie_rx_len;
wire                    sie_rx_we;
wire              [3:0] sie_rx_idx;
wire              [7:0] sie_rx_byte;
wire                    sie_tick;
wire              [1:0] sie_line;
wire                    sie_se0_long;


//=============================================================================
// 3)  APB ACCESS, PRIVILEGE AND DECODE
//=============================================================================

assign acc_valid       =  psel_i & penable_i;
assign acc_write       =  acc_valid &  pwrite_i;
assign acc_read        =  acc_valid & ~pwrite_i;
assign acc_addr        =  paddr_i[ADDRW-1:2];
assign reg_wr          =  acc_write & acc_allowed;
assign reg_rd          =  acc_read  & acc_allowed;
assign pready_o        =  1'b1;

assign machine_mode    =  pprot_i[0] & ~psmode_i;
assign supervisor_mode =  pprot_i[0] &  psmode_i;
assign privilege_mode  =  machine_mode    ? 2'b11 :
                          supervisor_mode ? 2'b01 :
                                            2'b00 ;

wire                sel_ctrl     = (acc_addr == REG_CTRL    );
wire                sel_cmd      = (acc_addr == REG_CMD     );
wire                sel_irq_en   = (acc_addr == REG_IRQ_EN  );
wire                sel_irq_pend = (acc_addr == REG_IRQ_PEND);
wire                sel_xfer     = (acc_addr == REG_XFER    );
wire                sel_setup0   = (acc_addr == REG_SETUP0  );
wire                sel_setup1   = (acc_addr == REG_SETUP1  );
wire                sel_diag0    = (acc_addr == REG_DIAG0   );
wire                sel_xdata0   = (acc_addr == REG_XDATA0  );
wire                sel_xdata1   = (acc_addr == REG_XDATA1  );
wire                sel_mdeleg   = (acc_addr == REG_MDELEG  );

wire          [3:0] wr_lane      = pstrb_i & {4{reg_wr}};

// MDELEG: WR_PRIV[1:0], RD_PRIV[3:2], RESP[8]; Machine-mode only
wire                mdeleg_priv_wr       = acc_write & sel_mdeleg & pstrb_i[0] & machine_mode;
wire                mdeleg_resp_wr       = acc_write & sel_mdeleg & pstrb_i[1] & machine_mode;
wire          [1:0] mdeleg_wr_priv_wdata = (pwdata_i[1:0] == MDELEG_PRIV_RSVD) ? 2'b11 : pwdata_i[1:0];
wire          [1:0] mdeleg_rd_priv_wdata = (pwdata_i[3:2] == MDELEG_PRIV_RSVD) ? 2'b11 : pwdata_i[3:2];

arv_ipdff #(.WIDTH(2), .RST_VAL(MDELEG_WR_PRIV_RST), .ARST_EN(ARST_EN)) u_mdeleg_wr_priv (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(mdeleg_priv_wr), .d_i(mdeleg_wr_priv_wdata), .q_o(mdeleg_wr_priv));

arv_ipdff #(.WIDTH(2), .RST_VAL(MDELEG_RD_PRIV_RST), .ARST_EN(ARST_EN)) u_mdeleg_rd_priv (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(mdeleg_priv_wr), .d_i(mdeleg_rd_priv_wdata), .q_o(mdeleg_rd_priv));

arv_ipdff #(.WIDTH(1), .RST_VAL(MDELEG_RESP_RST), .ARST_EN(ARST_EN)) u_mdeleg_resp (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(mdeleg_resp_wr), .d_i(pwdata_i[8]), .q_o(mdeleg_resp));

assign mdeleg       =  {23'h000000, mdeleg_resp, 4'h0, mdeleg_rd_priv, mdeleg_wr_priv};

wire                wr_allowed   = sel_mdeleg ? machine_mode : (privilege_mode >= mdeleg_wr_priv);
wire                rd_allowed   = sel_mdeleg ? machine_mode : (privilege_mode >= mdeleg_rd_priv);

assign acc_allowed  =  pwrite_i ? wr_allowed : rd_allowed;
assign pslverr_o    =  acc_valid & mdeleg_resp & ~acc_allowed;


//=============================================================================
// 4)  CONTROL REGISTERS AND COMMANDS
//=============================================================================

// CTRL: EN[0], BOOT[1], IDLE0[2], POLL_MS[15:8]
arv_ipdff #(.WIDTH(3), .RST_VAL(3'b110), .ARST_EN(ARST_EN)) u_ctrl_lo (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(wr_lane[0] & sel_ctrl), .d_i(pwdata_i[2:0]),
    .q_o({ctrl_idle0, ctrl_boot, ctrl_en}));

arv_ipdff #(.WIDTH(8), .ARST_EN(ARST_EN)) u_ctrl_poll (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(wr_lane[1] & sel_ctrl), .d_i(pwdata_i[15:8]), .q_o(ctrl_poll));

wire                cmd_restart  = wr_lane[0] & sel_cmd & pwdata_i[0];
wire                cmd_xstart   = wr_lane[0] & sel_cmd & pwdata_i[1];
wire                cmd_xnext    = wr_lane[0] & sel_cmd & pwdata_i[2];
wire                cmd_xabort   = wr_lane[0] & sel_cmd & pwdata_i[3];

// IRQ_EN; IRQ_PEND: REPORT[0], READY[1], DETACH[2], FAIL[3], XFER_PKT[4],
// XFER_DONE[5], STATE[6]; a cause set in the same cycle as its W1C stays set
arv_ipdff #(.WIDTH(7), .ARST_EN(ARST_EN)) u_irq_en (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(wr_lane[0] & sel_irq_en), .d_i(pwdata_i[6:0]), .q_o(irq_en));

wire          [6:0] irq_set      = {ev_state, ev_xdone, ev_xpkt, ev_fail, ev_detach, ev_ready, ev_report};
wire          [6:0] irq_w1c      = pwdata_i[6:0] & {7{wr_lane[0] & sel_irq_pend}};

wire          [6:0] irq_pend_nxt = (irq_pend & ~irq_w1c) | irq_set;

arv_ipdff #(.WIDTH(7), .ARST_EN(ARST_EN)) u_irq_pend (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(irq_pend_nxt), .q_o(irq_pend));

assign irq_o = |(irq_pend & irq_en);


//=============================================================================
// 5)  SOFTWARE CONTROL TRANSFERS (CTRL_EN)
//=============================================================================

genvar gi;
generate
    if (XF) begin : g_xfer
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_lane
            arv_ipdff #(.WIDTH(8), .ARST_EN(ARST_EN)) u_setup0 (
                .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(wr_lane[gi] & sel_setup0),
                .d_i(pwdata_i[8*gi +: 8]), .q_o(setup[8*gi +: 8]));
            arv_ipdff #(.WIDTH(8), .ARST_EN(ARST_EN)) u_setup1 (
                .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(wr_lane[gi] & sel_setup1),
                .d_i(pwdata_i[8*gi +: 8]), .q_o(setup[32 + 8*gi +: 8]));
        end
        for (gi = 0; gi < 8; gi = gi + 1) begin : g_xdata
            wire bus_we = wr_lane[gi % 4] & ((gi < 4) ? sel_xdata0 : sel_xdata1);
            wire usb_we = sie_rx_we & rx_dest & (sie_rx_idx == gi);
            arv_ipdff #(.WIDTH(8), .ARST_EN(ARST_EN)) u_xdata (
                .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(bus_we | usb_we),
                .d_i(usb_we ? sie_rx_byte : pwdata_i[8*(gi % 4) +: 8]), .q_o(xdata[8*gi +: 8]));
        end
        arv_ipdff #(.WIDTH(7), .ARST_EN(ARST_EN)) u_xlen (
            .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i((wr_lane[0] & sel_xfer) | ev_xin),
            .d_i(ev_xin ? {3'd0, xlen_in} : pwdata_i[6:0]), .q_o(xlen));
        assign xd_rd_byte = xdata[{sie_tx_idx[2:0], 3'b000} +: 8];
    end else begin : g_no_xfer
        assign setup      = 64'd0;
        assign xdata      = 64'd0;
        assign xlen       = 7'd0;
        assign xd_rd_byte = 8'd0;
        wire   xfer_unused = |{sel_setup0, sel_setup1, sel_xdata0, sel_xdata1, sel_xfer, ev_xin, xlen_in, rx_dest};
    end
endgenerate


//=============================================================================
// 6)  REPORT BUFFERS
//=============================================================================
// rbuf[63:0] receives the serial engine's bytes; rbuf[127:64] is the visible
// report, loaded from it in one cycle when a report is committed.

generate
    for (gi = 0; gi < 8; gi = gi + 1) begin : g_rbuf
        localparam [3:0] BYTE_IDX = gi;
        wire usb_we = sie_rx_we & ~rx_dest & (sie_rx_idx == BYTE_IDX);
        arv_ipdff #(.WIDTH(8), .ARST_EN(ARST_EN)) u_rx (
            .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(usb_we), .d_i(sie_rx_byte), .q_o(rbuf[8*gi +: 8]));
    end
endgenerate

arv_ipdff #(.WIDTH(64), .ARST_EN(ARST_EN)) u_rvis (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(rpt_commit), .d_i(rbuf[63:0]), .q_o(rbuf[127:64]));

// REPORT_INFO: cleared when the port leaves RUN
wire                rinfo_clr    = ~run & ((rlen != 4'd0) | (rseq != 8'd0));
wire         [11:0] rinfo_nxt    = rinfo_clr ? 12'd0 : {rseq + 8'd1, rpt_len};

arv_ipdff #(.WIDTH(12), .ARST_EN(ARST_EN)) u_rinfo (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(rpt_commit | rinfo_clr), .d_i(rinfo_nxt), .q_o({rseq, rlen}));

wire         [63:0] rvis         = rbuf[127:64];
wire         [63:0] rhid         = rbuf[63:0];

assign buf_rd_byte = rhid[{buf_rd_idx[2:0], 3'b000} +: 8];

wire                bufidx_unused = buf_rd_idx[3];
wire                apb_unused    = |{paddr_i[1:0], pprot_i[2:1], pwdata_i[31:16], pwdata_i[7], wr_lane[3:2]};


//=============================================================================
// 7)  DIAGNOSTICS (DIAG_EN)
//=============================================================================

generate
    if (DG) begin : g_diag
        wire        clr = wr_lane[0] & sel_diag0;
        wire  [5:0] inc = {ev_dup, ev_busrst, ev_stall, ev_other, ev_bad, ev_tmo};
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_d0
            wire [7:0] c = diag0[8*gi +: 8];
            arv_ipdff #(.WIDTH(8), .ARST_EN(ARST_EN)) u_cnt (
                .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(clr | (inc[gi] & ~(&c))),
                .d_i(clr ? 8'd0 : (c + 8'd1)), .q_o(diag0[8*gi +: 8]));
        end
        for (gi = 0; gi < 2; gi = gi + 1) begin : g_d1
            wire [15:0] c = diag1[16*gi +: 16];
            arv_ipdff #(.WIDTH(16), .ARST_EN(ARST_EN)) u_cnt (
                .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(clr | (inc[4 + gi] & ~(&c))),
                .d_i(clr ? 16'd0 : (c + 16'd1)), .q_o(diag1[16*gi +: 16]));
        end
    end else begin : g_no_diag
        assign diag0 = 32'd0;
        assign diag1 = 32'd0;
        wire   diag_unused = |{sel_diag0, ev_dup, ev_busrst, ev_stall, ev_other, ev_bad, ev_tmo};
    end
endgenerate


//=============================================================================
// 8)  READ DATA, CLOCK REQUEST
//=============================================================================

wire         [31:0] rd_mux =
    ({32{acc_addr == REG_INFO    }} & {28'h1000000, 1'b0, DG ? 1'b1 : 1'b0, XF ? 1'b1 : 1'b0, 1'b0}) |
    ({32{sel_ctrl                }} & {16'h0000, ctrl_poll, 5'h00, ctrl_idle0, ctrl_boot, ctrl_en})    |
    ({32{acc_addr == REG_STATUS  }} & {12'h000, step, 2'b00, attempt, err, xbusy, fs_dev, sie_line, state}) |
    ({32{sel_irq_en              }} & {25'h0000000, irq_en})                                          |
    ({32{sel_irq_pend            }} & {25'h0000000, irq_pend})                                        |
    ({32{acc_addr == REG_DEV_ID  }} & dev_id)                                                         |
    ({32{acc_addr == REG_DEV_IF  }} & {7'h00, dev_if})                                                |
    ({32{acc_addr == REG_DEV_EP  }} & {1'b0, dev_ep[25:19], dev_ep[18:11], 5'h00, dev_ep[10:0]})      |
    ({32{acc_addr == REG_RPT_INFO}} & {16'h0000, rseq, 4'h0, rlen})                                   |
    ({32{sel_xfer                }} & {20'h00000, xres, xpkt, 1'b0, xlen})                            |
    ({32{sel_setup0              }} & setup[31:0])                                                    |
    ({32{sel_setup1              }} & setup[63:32])                                                   |
    ({32{sel_diag0               }} & diag0)                                                          |
    ({32{acc_addr == REG_DIAG1   }} & diag1)                                                          |
    ({32{acc_addr == REG_REPORT0 }} & rvis[31:0])                                                     |
    ({32{acc_addr == REG_REPORT1 }} & rvis[63:32])                                                    |
    ({32{sel_xdata0              }} & xdata[31:0])                                                    |
    ({32{sel_xdata1              }} & xdata[63:32])                                                   |
    ({32{sel_mdeleg              }} & mdeleg);

assign prdata_o = rd_mux & {32{reg_rd}};

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_acc_q (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(acc_valid), .q_o(acc_q));

assign pclk_en_o = psel_i | ctrl_en | (state != 4'd0) | usb_oe_o | acc_q;


//=============================================================================
// 9)  SEQUENCER AND SERIAL ENGINE
//=============================================================================

apb_usb_host_seq #(.CTRL_EN(CTRL_EN), .ASYNC_RST_EN(ASYNC_RST_EN)) u_seq (
    .clk_i          (pclk_i),
    .rst_n_i        (presetn_i),
    .en_i           (ctrl_en),
    .boot_i         (ctrl_boot),
    .idle0_i        (ctrl_idle0),
    .poll_ms_i      (ctrl_poll),
    .cmd_restart_i  (cmd_restart),
    .cmd_xstart_i   (cmd_xstart),
    .cmd_xnext_i    (cmd_xnext),
    .cmd_xabort_i   (cmd_xabort),
    .setup_i        (setup),
    .xlen_i         (xlen),
    .buf_rd_idx_o   (buf_rd_idx),
    .buf_rd_byte_i  (buf_rd_byte),
    .xd_rd_byte_i   (xd_rd_byte),
    .rx_dest_o      (rx_dest),
    .rpt_commit_o   (rpt_commit),
    .rpt_len_o      (rpt_len),
    .run_o          (run),
    .state_o        (state),
    .fs_dev_o       (fs_dev),
    .err_o          (err),
    .step_o         (step),
    .attempt_o      (attempt),
    .xbusy_o        (xbusy),
    .xpkt_o         (xpkt),
    .xres_o         (xres),
    .xlen_in_o      (xlen_in),
    .dev_id_o       (dev_id),
    .dev_if_o       (dev_if),
    .dev_ep_o       (dev_ep),
    .ev_report_o    (ev_report),
    .ev_ready_o     (ev_ready),
    .ev_detach_o    (ev_detach),
    .ev_fail_o      (ev_fail),
    .ev_xpkt_o      (ev_xpkt),
    .ev_xin_o       (ev_xin),
    .ev_xdone_o     (ev_xdone),
    .ev_state_o     (ev_state),
    .ev_tmo_o       (ev_tmo),
    .ev_bad_o       (ev_bad),
    .ev_other_o     (ev_other),
    .ev_stall_o     (ev_stall),
    .ev_busrst_o    (ev_busrst),
    .ev_dup_o       (ev_dup),
    .sie_start_o    (sie_start),
    .sie_kind_o     (sie_kind),
    .sie_pid_o      (sie_pid),
    .sie_addr_o     (sie_addr),
    .sie_ep_o       (sie_ep),
    .sie_len_o      (sie_len),
    .sie_resp_o     (sie_resp),
    .sie_tx_idx_i   (sie_tx_idx),
    .sie_tx_byte_o  (sie_tx_byte),
    .sie_reset_o    (sie_reset),
    .sie_abort_o    (sie_abort),
    .sie_busy_i     (sie_busy),
    .sie_done_i     (sie_done),
    .sie_res_i      (sie_res),
    .sie_rx_pid_i   (sie_rx_pid),
    .sie_rx_len_i   (sie_rx_len),
    .sie_tick_i     (sie_tick),
    .sie_line_i     (sie_line),
    .sie_se0_long_i (sie_se0_long)
);

apb_usb_host_sie #(.CLK_HZ(CLK_HZ), .ASYNC_RST_EN(ASYNC_RST_EN)) u_sie (
    .clk_i      (pclk_i),
    .rst_n_i    (presetn_i),
    .start_i    (sie_start),
    .kind_i     (sie_kind),
    .pid_i      (sie_pid),
    .addr_i     (sie_addr),
    .ep_i       (sie_ep),
    .len_i      (sie_len),
    .resp_i     (sie_resp),
    .tx_idx_o   (sie_tx_idx),
    .tx_byte_i  (sie_tx_byte),
    .reset_i    (sie_reset),
    .abort_i    (sie_abort),
    .busy_o     (sie_busy),
    .done_o     (sie_done),
    .res_o      (sie_res),
    .rx_pid_o   (sie_rx_pid),
    .rx_len_o   (sie_rx_len),
    .rx_we_o    (sie_rx_we),
    .rx_idx_o   (sie_rx_idx),
    .rx_byte_o  (sie_rx_byte),
    .tick_o     (sie_tick),
    .line_o     (sie_line),
    .se0_long_o (sie_se0_long),
    .usb_dp_i   (usb_dp_i),
    .usb_dm_i   (usb_dm_i),
    .usb_dp_o   (usb_dp_o),
    .usb_dm_o   (usb_dm_o),
    .usb_oe_o   (usb_oe_o)
);

endmodule // apb_usb_host

`default_nettype wire
