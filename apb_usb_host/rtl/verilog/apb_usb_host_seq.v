//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    apb_usb_host_seq
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : apb_usb_host_seq.v
// Module Description : Port sequencer of apb_usb_host: port state machine,
//                      frame and millisecond timers, keep-alives, the
//                      transaction engine (SETUP / IN / OUT on the serial
//                      engine), control transfers, the enumeration sequence
//                      with its configuration-descriptor parser, polling
//                      and the software control-transfer handshake.
//
//   Frame:   1500 bit ticks of the serial engine. In RECOVERY, ENUM and RUN
//            each frame starts with a keep-alive; a transaction starts only
//            before tick 1200 and after the frame's keep-alive. After a NAK
//            or an error the next attempt waits for the next frame.
//   Errors:  three consecutive transaction errors (a keep-alive that finds
//            the bus busy included) fail the step, the poll or the
//            transfer; a control transfer also fails after 500 ms without
//            progress (time waiting for software excluded).
//   Parser:  an accepted IN data packet of an enumeration request is read
//            back from the hidden report buffer one byte per cycle
//            (buf_rd_idx_o); nothing else is read from a packet.
//----------------------------------------------------------------------------
`default_nettype none

module  apb_usb_host_seq #(
    parameter               CTRL_EN      = 0,           // software control transfers
    parameter               ASYNC_RST_EN = 1            // Reset style: 1=async active-low reset, 0=synchronous reset
) (
    input  wire             clk_i,
    input  wire             rst_n_i,

// CONFIGURATION AND COMMANDS (from the registers)
    input  wire             en_i,                       // CTRL.EN
    input  wire             boot_i,                     // CTRL.BOOT
    input  wire             idle0_i,                    // CTRL.IDLE0
    input  wire       [7:0] poll_ms_i,                  // CTRL.POLL_MS
    input  wire             cmd_restart_i,              // CMD pulses
    input  wire             cmd_xstart_i,
    input  wire             cmd_xnext_i,
    input  wire             cmd_xabort_i,
    input  wire      [63:0] setup_i,                    // SETUP1, SETUP0
    input  wire       [6:0] xlen_i,                     // XFER.LEN written by software

// BUFFERS (in the wrapper)
    output wire       [3:0] buf_rd_idx_o,               // hidden buffer byte read by the parser
    input  wire       [7:0] buf_rd_byte_i,
    input  wire       [7:0] xd_rd_byte_i,               // XDATA byte at sie_tx_idx_i
    output wire             rx_dest_o,                  // received bytes go to XDATA (else the hidden buffer)
    output wire             rpt_commit_o,               // a report: swap the buffers
    output wire       [3:0] rpt_len_o,
    output wire             run_o,                      // the port is in RUN

// STATUS
    output wire       [3:0] state_o,
    output wire             fs_dev_o,
    output wire       [3:0] err_o,
    output wire       [3:0] step_o,
    output wire       [1:0] attempt_o,
    output wire             xbusy_o,
    output wire             xpkt_o,
    output wire       [2:0] xres_o,
    output wire       [3:0] xlen_in_o,
    output wire      [31:0] dev_id_o,                   // {idProduct, idVendor}
    output wire      [24:0] dev_if_o,                   // {BOOT, protocol, subclass, interface}
    output wire      [25:0] dev_ep_o,                   // {bMaxPacketSize0, bInterval, wMaxPacketSize, endpoint}

// EVENTS (one cycle)
    output wire             ev_report_o,
    output wire             ev_ready_o,
    output wire             ev_detach_o,
    output wire             ev_fail_o,
    output wire             ev_xpkt_o,
    output wire             ev_xin_o,                   // ev_xpkt_o of an IN packet: XFER.LEN = xlen_in_o in that cycle
    output wire             ev_xdone_o,
    output wire             ev_state_o,
    output wire             ev_tmo_o,                   // diagnostics
    output wire             ev_bad_o,
    output wire             ev_other_o,
    output wire             ev_stall_o,
    output wire             ev_busrst_o,
    output wire             ev_dup_o,

// SERIAL ENGINE
    output wire             sie_start_o,
    output wire       [1:0] sie_kind_o,
    output wire       [3:0] sie_pid_o,
    output wire       [6:0] sie_addr_o,
    output wire       [3:0] sie_ep_o,
    output wire       [3:0] sie_len_o,
    output wire             sie_resp_o,
    input  wire       [3:0] sie_tx_idx_i,
    output wire       [7:0] sie_tx_byte_o,
    output wire             sie_reset_o,
    output wire             sie_abort_o,
    input  wire             sie_busy_i,
    input  wire             sie_done_i,
    input  wire       [2:0] sie_res_i,
    input  wire       [3:0] sie_rx_pid_i,
    input  wire       [3:0] sie_rx_len_i,
    input  wire             sie_tick_i,
    input  wire       [1:0] sie_line_i,
    input  wire             sie_se0_long_i
);


//=============================================================================
// 1)  PARAMETERS
//=============================================================================

// pragma translate_off
generate
    if ((CTRL_EN != 0) && (CTRL_EN != 1)) begin : CHECK_CTRL_EN
        initial $fatal(1, "apb_usb_host_seq: CTRL_EN (%0d) must be 0 or 1.", CTRL_EN);
    end
    if ((ASYNC_RST_EN != 0) && (ASYNC_RST_EN != 1)) begin : CHECK_ASYNC_RST_EN
        initial $fatal(1, "apb_usb_host_seq: ASYNC_RST_EN (%0d) must be 0 or 1.", ASYNC_RST_EN);
    end
endgenerate
// pragma translate_on

localparam              ARST_EN = (ASYNC_RST_EN != 0);
localparam              XF      = (CTRL_EN != 0);
localparam              REM_W   = XF ? 16 : 8;          // data-stage length counter

// Port states (STATUS.STATE)
localparam        [3:0] P_OFF   = 4'd0,  P_DET   = 4'd1,  P_DEB   = 4'd2,  P_RST   = 4'd3,
                        P_REC   = 4'd4,  P_ENUM  = 4'd5,  P_RUN   = 4'd6,  P_BACK  = 4'd7,
                        P_FAIL  = 4'd8,  P_UNSUP = 4'd9,  P_FS    = 4'd10;

// STATUS.ERR
localparam        [3:0] E_TMO   = 4'd1,  E_BAD   = 4'd2,  E_OTHER = 4'd3,  E_STALL = 4'd4,
                        E_PROG  = 4'd5,  E_MALF  = 4'd6,  E_HUB   = 4'd7,  E_NOHID = 4'd8,
                        E_MPS   = 4'd9;

// XFER.RESULT
localparam        [2:0] X_OK    = 3'd0,  X_STALL = 3'd1,  X_ERR   = 3'd2,  X_ABORT = 3'd3,
                        X_DET   = 3'd4,  X_REF   = 3'd5;

// PIDs
localparam        [3:0] PID_OUT = 4'h1,  PID_IN  = 4'h9,  PID_SETUP = 4'hD,
                        PID_D0  = 4'h3,  PID_D1  = 4'hB,
                        PID_ACK = 4'h2,  PID_NAK = 4'hA,  PID_STALL = 4'hE;

// Serial engine kinds and results
localparam        [1:0] K_KEEP  = 2'd0,  K_TOKEN = 2'd1,  K_DATA  = 2'd2,  K_ACK   = 2'd3;
localparam        [2:0] R_OK    = 3'd0,  R_TMO   = 3'd1,  R_BAD   = 3'd2;

// Transaction kinds, phases and results
localparam        [1:0] TK_SETUP = 2'd0, TK_IN   = 2'd1,  TK_OUT  = 2'd2;
localparam        [1:0] T_IDLE  = 2'd0,  T_TOK   = 2'd1,  T_DAT   = 2'd2,  T_ACK   = 2'd3;
localparam        [2:0] TR_OK   = 3'd0,  TR_NAK  = 3'd1,  TR_STALL = 3'd2, TR_ERR  = 3'd3,
                        TR_DUP  = 3'd4;

// Control-transfer stages
localparam        [2:0] C_IDLE  = 3'd0,  C_SETUP = 3'd1,  C_DIN   = 3'd2,  C_DOUT  = 3'd3,
                        C_STIN  = 3'd4,  C_STOUT = 3'd5,  C_PARSE = 3'd6,  C_SW    = 3'd7;

// Timings (frame boundaries, one more than the documented milliseconds: a state
// timed to N ms lasts N to N+1 ms)
localparam        [8:0] MS_DEB  = 9'd101, MS_RST  = 9'd61,  MS_REC  = 9'd11,
                        MS_ADDR = 9'd11,  MS_BACK = 9'd101, MS_PROG = 9'd501;
localparam       [10:0] F_LAST  = 11'd1499;              // ticks per frame - 1
localparam       [10:0] F_LIMIT = 11'd1200;              // no transaction starts after this tick


//=============================================================================
// 2)  DECLARATIONS
//=============================================================================

wire              [3:0] pst;                            // port state
wire              [3:0] step;                           // enumeration step (1-8)
wire              [2:0] cst;                            // control stage
wire              [1:0] tph;                            // transaction phase
wire              [1:0] tk;                             // transaction kind
wire              [2:0] tpend;                          // result pending behind the ACK
wire              [3:0] tlen;                           // received data length
wire              [1:0] errc;                           // consecutive transaction errors
wire              [1:0] attempt;
wire             [10:0] fcnt;                           // frame tick
wire             [10:0] fcnt_nxt;
wire              [8:0] mcnt;                           // milliseconds
wire                    ka_pend;                        // keep-alive due
wire                    ka_busy;                        // the serial engine runs the keep-alive
wire                    nxtf;                           // wait for the next frame
wire                    start_q;                        // serial-engine start pulse
wire                    abort_q;                        // serial-engine abort pulse
wire                    deb_fs;                         // the debounced J is a full-speed J
wire                    addr1;                          // the device has address 1
wire                    ctog;                           // control toggle
wire                    itog;                           // interrupt-endpoint toggle
wire                    polling;                        // the transaction is a poll
wire                    sw_x;                           // the control transfer is software's
wire                    awaitr;                         // SET_ADDRESS recovery wait
wire                    xabq;                           // XFER_ABORT pending behind the transaction in flight
wire                    xabort;
wire                    xstart_ok;                      // CMD.XFER_START accepted
wire        [REM_W-1:0] rem;                            // data-stage bytes left
wire              [3:0] olen;                           // OUT packet length
wire              [3:0] pidx;                           // parser byte in the packet
wire              [7:0] poff;                           // parser offset in the descriptor
wire              [8:0] pnext;                          // offset of the next descriptor
wire              [3:0] prel;                           // byte in the current descriptor
wire              [1:0] dtype;                          // 0 other, 1 configuration, 2 interface, 3 endpoint
wire              [7:0] ptot;                           // wTotalLength, at most 255
wire                    cand;                           // the current interface qualifies
wire                    alt0;
wire                    found;                          // interface and endpoint selected
wire                    ep_in;
wire                    ep_int;
wire                    pstop;                          // the parser has what it needs
wire              [3:0] perr;                           // parser verdict (0 none)
wire              [7:0] cfgval;
wire              [3:0] err;
wire              [3:0] estep;
wire                    xbusy;
wire                    xpkt;
wire              [2:0] xres;
wire             [31:0] dev_id;
wire             [23:0] dev_if;
wire                    dev_boot;
wire              [3:0] dev_ep;
wire              [6:0] dev_mps;
wire              [7:0] dev_int;
wire              [6:0] dev_mps0;
wire                    dev_hub;

wire                    ms_tick;
wire                    ka_state;
wire                    line_lsj;
wire                    line_fsj;
wire                    slot;
wire                    exp_tog;
wire              [7:0] setup_b;                        // setup byte at sie_tx_idx_i
wire       [REM_W-1:0] wlength;
wire              [7:0] interval;
wire              [7:0] pbyte;
wire              [3:0] rx_min_len;
wire              [3:0] out_len;

reg               [3:0] pst_nxt;
reg               [3:0] step_nxt;
reg               [2:0] cst_nxt;
reg               [1:0] tph_nxt;
reg               [1:0] tk_nxt;
reg               [2:0] tpend_nxt;
reg               [3:0] tlen_nxt;
reg               [1:0] errc_nxt;
reg               [1:0] attempt_nxt;
reg               [8:0] mcnt_nxt;
reg                     ka_pend_nxt;
reg                     ka_busy_nxt;
reg                     nxtf_nxt;
reg                     start_nxt;
reg                     abort_nxt;
reg                     deb_fs_nxt;
reg                     addr1_nxt;
reg                     ctog_nxt;
reg                     itog_nxt;
reg                     polling_nxt;
reg                     sw_x_nxt;
reg                     awaitr_nxt;
reg                     xabq_nxt;
reg         [REM_W-1:0] rem_nxt;
reg               [3:0] olen_nxt;
reg               [3:0] pidx_nxt;
reg               [7:0] poff_nxt;
reg               [8:0] pnext_nxt;
reg               [3:0] prel_nxt;
reg               [1:0] dtype_nxt;
reg               [7:0] ptot_nxt;
reg                     cand_nxt;
reg                     alt0_nxt;
reg                     found_nxt;
reg                     ep_in_nxt;
reg                     ep_int_nxt;
reg                     pstop_nxt;
reg               [3:0] perr_nxt;
reg               [7:0] cfgval_nxt;
reg               [3:0] err_nxt;
reg               [3:0] estep_nxt;
reg                     xbusy_nxt;
reg                     xpkt_nxt;
reg               [2:0] xres_nxt;
reg              [31:0] dev_id_nxt;
reg              [23:0] dev_if_nxt;
reg                     dev_boot_nxt;
reg               [3:0] dev_ep_nxt;
reg               [6:0] dev_mps_nxt;
reg               [7:0] dev_int_nxt;
reg               [6:0] dev_mps0_nxt;
reg                     dev_hub_nxt;

reg                     tdone;                          // a transaction ends this cycle
reg               [2:0] tres;                           // its result
reg               [3:0] tecls;                          // its error class (E_TMO / E_BAD / E_OTHER)
reg                     c_done;                         // the control transfer ends this cycle
reg               [2:0] c_res;                          // X_OK / X_STALL / X_ERR
reg                     fail;                           // a failure in the sense of the contract
reg               [3:0] fail_err;
reg                     unsup;
reg                     ev_report;
reg                     ev_ready;
reg                     ev_detach;
reg                     ev_xpkt;
reg                     ev_xin;
reg                     ev_xdone;
reg                     ev_tmo;
reg                     ev_bad;
reg                     ev_other;
reg                     ev_stall;
reg                     ev_dup;
reg                     commit;


//=============================================================================
// 3)  COMBINATIONAL HELPERS
//=============================================================================

assign fcnt_nxt = (fcnt == F_LAST) ? 11'd0 : (fcnt + 11'd1);
assign ms_tick  = sie_tick_i & (fcnt == F_LAST);
assign ka_state = (pst == P_REC) | (pst == P_ENUM) | (pst == P_RUN);
assign line_lsj = (sie_line_i == 2'b01);
assign line_fsj = (sie_line_i == 2'b10);
assign xabort   = cmd_xabort_i | xabq;
assign xstart_ok = cmd_xstart_i & ~xbusy & (pst == P_RUN);
assign slot     = ~ka_pend & ~ka_busy & ~nxtf & ~sie_busy_i & ~start_q & (fcnt < F_LIMIT);
assign exp_tog  = polling ? itog : ctog;
assign interval = (poll_ms_i != 8'd0) ? poll_ms_i : dev_int;

// Setup bytes of the enumeration requests (step) or of software (setup_i)
function [7:0] f_setup;
    input [3:0] st;
    input [2:0] i;
    input [7:0] cv;
    input [7:0] ifn;
    begin
        f_setup = 8'h00;
        case (st)
        4'd1, 4'd4, 4'd5: case (i)                      // GET_DESCRIPTOR
            3'd0: f_setup = 8'h80;
            3'd1: f_setup = 8'h06;
            3'd3: f_setup = (st == 4'd5) ? 8'h02 : 8'h01;
            3'd6: f_setup = (st == 4'd1) ? 8'h08 : (st == 4'd4) ? 8'h12 : 8'hFF;
            default: f_setup = 8'h00;
            endcase
        4'd3: if (i == 3'd1) f_setup = 8'h05;           // SET_ADDRESS(1)
              else if (i == 3'd2) f_setup = 8'h01;
        4'd6: if (i == 3'd1) f_setup = 8'h09;           // SET_CONFIGURATION
              else if (i == 3'd2) f_setup = cv;
        default: case (i)                               // 7 SET_PROTOCOL(boot), 8 SET_IDLE(0)
            3'd0: f_setup = 8'h21;
            3'd1: f_setup = (st == 4'd7) ? 8'h0B : 8'h0A;
            3'd4: f_setup = ifn;
            default: f_setup = 8'h00;
            endcase
        endcase
    end
endfunction

wire              [7:0] sw_setup_b = setup_i[{sie_tx_idx_i[2:0], 3'b000} +: 8];

assign setup_b  = (XF & sw_x) ? sw_setup_b : f_setup(step, sie_tx_idx_i[2:0], cfgval, dev_if[7:0]);
assign wlength  = (XF & sw_x) ? setup_i[63:64-REM_W]
                : {{(REM_W-8){1'b0}}, (step == 4'd1) ? 8'd8 : (step == 4'd4) ? 8'd18 : (step == 4'd5) ? 8'd255 : 8'd0};

assign sie_tx_byte_o = (tk == TK_SETUP) ? setup_b : xd_rd_byte_i;

// Software OUT packet: XFER.LEN limited to 8 and to the bytes left
assign rx_min_len = (rem < 8) ? rem[3:0] : 4'd8;
assign out_len    = ((xlen_i > 7'd8) ? 4'd8 : xlen_i[3:0]) > rx_min_len ? rx_min_len
                  : ((xlen_i > 7'd8) ? 4'd8 : xlen_i[3:0]);

assign pbyte        = buf_rd_byte_i;
assign buf_rd_idx_o = pidx;


//=============================================================================
// 4)  NEXT STATE
//=============================================================================

always @(*) begin
    pst_nxt      = pst;
    step_nxt     = step;
    cst_nxt      = cst;
    tph_nxt      = tph;
    tk_nxt       = tk;
    tpend_nxt    = tpend;
    tlen_nxt     = tlen;
    errc_nxt     = errc;
    attempt_nxt  = attempt;
    mcnt_nxt     = mcnt;
    ka_pend_nxt  = ka_pend;
    ka_busy_nxt  = ka_busy;
    nxtf_nxt     = nxtf;
    start_nxt    = 1'b0;
    abort_nxt    = 1'b0;
    deb_fs_nxt   = deb_fs;
    addr1_nxt    = addr1;
    ctog_nxt     = ctog;
    itog_nxt     = itog;
    polling_nxt  = polling;
    sw_x_nxt     = sw_x;
    awaitr_nxt   = awaitr;
    xabq_nxt     = 1'b0;
    rem_nxt      = rem;
    olen_nxt     = olen;
    pidx_nxt     = pidx;
    poff_nxt     = poff;
    pnext_nxt    = pnext;
    prel_nxt     = prel;
    dtype_nxt    = dtype;
    ptot_nxt     = ptot;
    cand_nxt     = cand;
    alt0_nxt     = alt0;
    found_nxt    = found;
    ep_in_nxt    = ep_in;
    ep_int_nxt   = ep_int;
    pstop_nxt    = pstop;
    perr_nxt     = perr;
    cfgval_nxt   = cfgval;
    err_nxt      = err;
    estep_nxt    = estep;
    xbusy_nxt    = xbusy;
    xpkt_nxt     = xpkt;
    xres_nxt     = xres;
    dev_id_nxt   = dev_id;
    dev_if_nxt   = dev_if;
    dev_boot_nxt = dev_boot;
    dev_ep_nxt   = dev_ep;
    dev_mps_nxt  = dev_mps;
    dev_int_nxt  = dev_int;
    dev_mps0_nxt = dev_mps0;
    dev_hub_nxt  = dev_hub;

    tdone     = 1'b0;
    tres      = TR_OK;
    tecls     = E_OTHER;
    c_done    = 1'b0;
    c_res     = X_OK;
    fail      = 1'b0;
    fail_err  = E_OTHER;
    unsup     = 1'b0;
    ev_report = 1'b0;
    ev_ready  = 1'b0;
    ev_detach = 1'b0;
    ev_xpkt   = 1'b0;
    ev_xin    = 1'b0;
    ev_xdone  = 1'b0;
    ev_tmo    = 1'b0;
    ev_bad    = 1'b0;
    ev_other  = 1'b0;
    ev_stall  = 1'b0;
    ev_dup    = 1'b0;
    commit    = 1'b0;

    //-------------------------------------------------------------------------
    // Timers and keep-alive
    //-------------------------------------------------------------------------
    if (ms_tick) begin
        mcnt_nxt = (mcnt == 9'h1FF) ? mcnt : (mcnt + 9'd1);
        nxtf_nxt = 1'b0;
        if (ka_state) ka_pend_nxt = 1'b1;
    end

    if (ka_pend & ~ka_busy & ~sie_busy_i & ~start_q & (tph == T_IDLE)) begin
        ka_pend_nxt = 1'b0;
        ka_busy_nxt = 1'b1;
        start_nxt   = 1'b1;
    end

    if (ka_busy & sie_done_i) begin
        ka_busy_nxt = 1'b0;
        if (sie_res_i != R_OK) begin                    // bus busy at the keep-alive
            ev_other = 1'b1;
            errc_nxt = errc + 2'd1;
            if (errc == 2'd2) begin
                fail     = 1'b1;
                fail_err = E_OTHER;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Transaction engine
    //-------------------------------------------------------------------------
    if (~ka_busy & sie_done_i) begin
        case (tph)
        T_TOK: begin
            if (tk == TK_IN) begin
                tlen_nxt = sie_rx_len_i;
                if (sie_res_i != R_OK) begin
                    tdone = 1'b1;
                    tres  = TR_ERR;
                    tecls = (sie_res_i == R_TMO) ? E_TMO : (sie_res_i == R_BAD) ? E_BAD : E_OTHER;
                end else if (sie_rx_pid_i == PID_NAK) begin
                    tdone = 1'b1;
                    tres  = TR_NAK;
                end else if (sie_rx_pid_i == PID_STALL) begin
                    tdone = 1'b1;
                    tres  = TR_STALL;
                end else if ((sie_rx_pid_i == PID_D0) | (sie_rx_pid_i == PID_D1)) begin
                    tph_nxt   = T_ACK;
                    start_nxt = 1'b1;
                    tpend_nxt = ((sie_rx_pid_i == PID_D1) == exp_tog) ? TR_OK : TR_DUP;
                end else begin
                    tdone = 1'b1;
                    tres  = TR_ERR;
                end
            end else if (sie_res_i != R_OK) begin       // bus busy at the token
                tdone = 1'b1;
                tres  = TR_ERR;
            end else begin
                tph_nxt   = T_DAT;
                start_nxt = 1'b1;
            end
        end
        T_DAT: begin
            tdone = 1'b1;
            tres  = (sie_res_i != R_OK)           ? TR_ERR
                  : (sie_rx_pid_i == PID_ACK)     ? TR_OK
                  : (sie_rx_pid_i == PID_NAK)     ? TR_NAK
                  : (sie_rx_pid_i == PID_STALL)   ? TR_STALL
                  :                                 TR_ERR;
            tecls = (sie_res_i == R_TMO) ? E_TMO : (sie_res_i == R_BAD) ? E_BAD : E_OTHER;
        end
        T_ACK: begin
            tdone = 1'b1;
            tres  = tpend;
        end
        default: ;
        endcase
    end

    if (tdone) begin
        tph_nxt = T_IDLE;
        case (tres)
        TR_ERR: begin
            nxtf_nxt = 1'b1;
            errc_nxt = errc + 2'd1;
            ev_tmo   = (tecls == E_TMO);
            ev_bad   = (tecls == E_BAD);
            ev_other = (tecls == E_OTHER);
        end
        TR_NAK: begin
            nxtf_nxt = 1'b1;
            errc_nxt = 2'd0;
        end
        TR_STALL: begin
            errc_nxt = 2'd0;
            ev_stall = 1'b1;
        end
        TR_DUP: begin
            errc_nxt = 2'd0;
            ev_dup   = 1'b1;
        end
        default: errc_nxt = 2'd0;
        endcase
    end

    //-------------------------------------------------------------------------
    // Control transfer
    //-------------------------------------------------------------------------
    case (cst)
    C_SETUP: begin
        if (tdone) begin
            if (tres == TR_OK) begin
                mcnt_nxt = 9'd0;
                ctog_nxt = 1'b1;
                rem_nxt  = wlength;
                if (wlength == {REM_W{1'b0}})
                    cst_nxt = C_STIN;
                else if (setup_b_dir(sw_x, setup_i[7]))
                    cst_nxt = C_DIN;
                else begin
                    cst_nxt  = C_DOUT;
                    xpkt_nxt = 1'b1;                    // the buffer is free
                    ev_xpkt  = 1'b1;
                end
            end
        end else if ((tph == T_IDLE) & slot) begin
            tk_nxt      = TK_SETUP;
            tph_nxt     = T_TOK;
            start_nxt   = 1'b1;
            polling_nxt = 1'b0;
        end
    end

    C_DIN: begin
        if (tdone) begin
            if (tres == TR_OK) begin
                mcnt_nxt = 9'd0;
                ctog_nxt = ~ctog;
                rem_nxt  = (rem > {{(REM_W-4){1'b0}}, tlen}) ? (rem - {{(REM_W-4){1'b0}}, tlen}) : {REM_W{1'b0}};
                if (XF & sw_x) begin
                    cst_nxt     = C_SW;
                    xpkt_nxt    = 1'b1;
                    ev_xpkt     = 1'b1;
                    ev_xin      = 1'b1;
                end else begin
                    cst_nxt  = C_PARSE;
                    pidx_nxt = 4'd0;
                end
            end
        end else if ((tph == T_IDLE) & slot) begin
            tk_nxt      = TK_IN;
            tph_nxt     = T_TOK;
            start_nxt   = 1'b1;
            polling_nxt = 1'b0;
        end
    end

    C_SW: begin                                         // waiting for software (no progress timeout)
        mcnt_nxt = 9'd0;
        if (cmd_xnext_i & xpkt) begin
            xpkt_nxt = 1'b0;
            cst_nxt  = ((tlen < 4'd8) | (rem == {REM_W{1'b0}})) ? C_STOUT : C_DIN;
        end
    end

    C_DOUT: begin
        if (tdone) begin
            if (tres == TR_OK) begin
                mcnt_nxt = 9'd0;
                ctog_nxt = ~ctog;
                rem_nxt  = rem - {{(REM_W-4){1'b0}}, olen};
                xpkt_nxt = 1'b1;
                ev_xpkt  = 1'b1;
                if (rem == {{(REM_W-4){1'b0}}, olen}) begin
                    cst_nxt  = C_STIN;
                    xpkt_nxt = 1'b0;
                    ev_xpkt  = 1'b0;
                end
            end
        end else if ((tph == T_IDLE) & xpkt) begin
            mcnt_nxt = 9'd0;                            // waiting for software
            if (cmd_xnext_i) begin
                xpkt_nxt = 1'b0;
                olen_nxt = out_len;
            end
        end else if ((tph == T_IDLE) & slot) begin
            tk_nxt      = TK_OUT;
            tph_nxt     = T_TOK;
            start_nxt   = 1'b1;
            polling_nxt = 1'b0;
        end
    end

    C_STIN: begin
        if (tdone) begin
            if ((tres == TR_OK) & (tlen == 4'd0)) begin
                c_done = 1'b1;
            end else if ((tres == TR_OK) | (tres == TR_DUP)) begin
                errc_nxt = errc + 2'd1;                 // DATA0 or not empty: a transaction error
                nxtf_nxt = 1'b1;
                ev_other = 1'b1;
            end
        end else if ((tph == T_IDLE) & slot) begin
            ctog_nxt    = 1'b1;
            tk_nxt      = TK_IN;
            tph_nxt     = T_TOK;
            start_nxt   = 1'b1;
            polling_nxt = 1'b0;
        end
    end

    C_STOUT: begin
        if (tdone) begin
            if (tres == TR_OK) c_done = 1'b1;
        end else if ((tph == T_IDLE) & slot) begin
            ctog_nxt    = 1'b1;
            olen_nxt    = 4'd0;
            tk_nxt      = TK_OUT;
            tph_nxt     = T_TOK;
            start_nxt   = 1'b1;
            polling_nxt = 1'b0;
        end
    end

    C_PARSE: begin
        if ((pidx == tlen) | pstop | (perr != 4'd0)) begin
            cst_nxt = ((tlen < 4'd8) | (rem == {REM_W{1'b0}}) | pstop | (perr != 4'd0)) ? C_STOUT : C_DIN;
        end else begin
            pidx_nxt = pidx + 4'd1;
            poff_nxt = poff + 8'd1;
            case (step)
            4'd1: begin                                 // device descriptor, 8 bytes
                if (poff == 8'd4) dev_hub_nxt  = (pbyte == 8'h09);
                if (poff == 8'd7) dev_mps0_nxt = pbyte[6:0];
                if (poff == 8'd7) perr_nxt     = (pbyte != 8'd8) ? E_MPS : 4'd0;
            end
            4'd4: begin                                 // device descriptor, 18 bytes
                if (poff == 8'd8)  dev_id_nxt[7:0]   = pbyte;
                if (poff == 8'd9)  dev_id_nxt[15:8]  = pbyte;
                if (poff == 8'd10) dev_id_nxt[23:16] = pbyte;
                if (poff == 8'd11) dev_id_nxt[31:24] = pbyte;
            end
            default: begin                              // 5: configuration descriptor walk
                prel_nxt = (prel == 4'hF) ? prel : (prel + 4'd1);
                if ({1'b0, poff} == pnext) begin        // descriptor start: bLength
                    prel_nxt  = 4'd1;
                    pnext_nxt = {1'b0, poff} + {1'b0, pbyte};
                    if ((pbyte == 8'd0) | (poff != 8'd0) & (({1'b0, poff} + {1'b0, pbyte}) > {1'b0, ptot}))
                        perr_nxt = E_MALF;
                end else if (prel == 4'd1) begin        // bDescriptorType
                    dtype_nxt = (pbyte == 8'h02) ? 2'd1 : (pbyte == 8'h04) ? 2'd2
                              : (pbyte == 8'h05) ? 2'd3 : 2'd0;
                    if (pbyte == 8'h04) cand_nxt = 1'b0;
                end else begin
                    case (dtype)
                    2'd1: begin                         // configuration
                        if (prel == 4'd2) ptot_nxt   = pbyte;
                        if (prel == 4'd3) ptot_nxt   = (pbyte != 8'd0) ? 8'hFF : ptot;
                        if (prel == 4'd5) cfgval_nxt = pbyte;
                    end
                    2'd2: if (~found) begin             // interface
                        if (prel == 4'd2) dev_if_nxt[7:0]   = pbyte;
                        if (prel == 4'd3) alt0_nxt          = (pbyte == 8'd0);
                        if (prel == 4'd5) cand_nxt          = alt0 & (pbyte == 8'h03);
                        if (prel == 4'd6) dev_if_nxt[15:8]  = pbyte;
                        if (prel == 4'd7) dev_if_nxt[23:16] = pbyte;
                    end
                    2'd3: if (cand & ~found) begin      // endpoint of a qualifying interface
                        if (prel == 4'd2) begin
                            dev_ep_nxt = pbyte[3:0];
                            ep_in_nxt  = pbyte[7];
                        end
                        if (prel == 4'd3) ep_int_nxt  = (pbyte[1:0] == 2'b11);
                        if (prel == 4'd4) dev_mps_nxt = pbyte[6:0];
                        if (prel == 4'd5) begin
                            if (pbyte[2:0] != 3'd0) dev_mps_nxt = 7'h7F;
                        end
                        if (prel == 4'd6) begin
                            dev_int_nxt = (pbyte == 8'd0) ? 8'd1 : pbyte;
                            if (ep_in & ep_int) begin
                                if ((dev_mps == 7'd0) | (dev_mps > 7'd8))
                                    perr_nxt  = E_MPS;
                                else begin
                                    found_nxt = 1'b1;
                                    pstop_nxt = 1'b1;
                                end
                            end
                        end
                    end
                    default: ;
                    endcase
                end
                if ((poff != 8'd0) & ((poff + 8'd1) == ptot) & (pnext_nxt != {1'b0, ptot})) begin
                    pstop_nxt = 1'b1;
                end else if (((poff + 8'd1) == ptot) & (poff != 8'd0)) begin
                    pstop_nxt = 1'b1;
                end
            end
            endcase
        end
    end

    default: ;                                          // C_IDLE
    endcase

    // Control-transfer failures
    if ((cst != C_IDLE) & (cst != C_PARSE) & (cst != C_SW) & tdone) begin
        if (tres == TR_STALL) begin
            c_done = 1'b1;
            c_res  = X_STALL;
        end else if ((tres == TR_ERR) & (errc == 2'd2)) begin
            c_done = 1'b1;
            c_res  = X_ERR;
        end
    end
    if ((cst != C_IDLE) & (cst != C_SW) & ms_tick & (mcnt == MS_PROG - 9'd1) & ~(cst == C_DOUT & xpkt)) begin
        c_done   = 1'b1;
        c_res    = X_ERR;
        tecls    = E_PROG;
    end
    if (c_done) begin
        cst_nxt = C_IDLE;
        tph_nxt = (c_res == X_OK) ? tph_nxt : T_IDLE;
    end

    //-------------------------------------------------------------------------
    // Port
    //-------------------------------------------------------------------------
    case (pst)
    P_OFF: ;

    P_DET: begin
        if (line_lsj | line_fsj) begin
            pst_nxt     = P_DEB;
            deb_fs_nxt  = line_fsj;
            mcnt_nxt    = 9'd0;
            attempt_nxt = 2'd0;
        end
    end

    P_DEB: begin
        if (deb_fs ? ~line_fsj : ~line_lsj)
            pst_nxt = P_DET;
        else if (mcnt >= MS_DEB)
            pst_nxt = deb_fs ? P_FS : P_RST;
        if (pst_nxt == P_RST) step_nxt = 4'd1;
    end

    P_RST: begin
        if (mcnt >= MS_RST) begin
            pst_nxt  = P_REC;
            mcnt_nxt = 9'd0;
        end
    end

    P_REC: begin
        if (mcnt >= MS_REC) begin
            pst_nxt = P_ENUM;
            if (step != 4'd2) begin                     // first enumeration step: forget the device
                step_nxt     = 4'd1;
                dev_id_nxt   = 32'd0;
                dev_if_nxt   = 24'd0;
                dev_boot_nxt = 1'b0;
                dev_ep_nxt   = 4'd0;
                dev_mps_nxt  = 7'd0;
                dev_int_nxt  = 8'd0;
                dev_mps0_nxt = 7'd0;
                dev_hub_nxt  = 1'b0;
            end else begin
                step_nxt     = 4'd3;
            end
            cst_nxt   = C_SETUP;
            mcnt_nxt  = 9'd0;
            sw_x_nxt  = 1'b0;
            addr1_nxt = 1'b0;
            poff_nxt  = 8'd0;
            perr_nxt  = 4'd0;
            pstop_nxt = 1'b0;
        end
    end

    P_ENUM: begin
        if (awaitr) begin                               // SET_ADDRESS recovery
            if (mcnt >= MS_ADDR) begin
                awaitr_nxt = 1'b0;
                addr1_nxt  = 1'b1;
                step_nxt   = 4'd4;
                cst_nxt    = C_SETUP;
                poff_nxt   = 8'd0;
            end
        end else if (c_done) begin
            if ((step == 4'd7) | (step == 4'd8)) begin  // optional steps
                if ((step == 4'd7) & (c_res == X_OK)) dev_boot_nxt = 1'b1;
                if ((step == 4'd7) & idle0_i) begin
                    step_nxt = 4'd8;
                    cst_nxt  = C_SETUP;
                end else begin
                    pst_nxt  = P_RUN;
                    mcnt_nxt = 9'd0;
                    itog_nxt = 1'b0;
                    attempt_nxt = attempt;
                    ev_ready = 1'b1;
                end
            end else if (c_res != X_OK) begin
                fail     = 1'b1;
                fail_err = (c_res == X_STALL) ? E_STALL : tecls;
            end else if (perr != 4'd0) begin
                if (perr == E_MALF) begin
                    fail     = 1'b1;
                    fail_err = E_MALF;
                end else begin
                    unsup    = 1'b1;
                    fail_err = perr;
                end
            end else begin
                case (step)
                4'd1: begin
                    if (dev_hub) begin
                        unsup    = 1'b1;
                        fail_err = E_HUB;
                    end else begin
                        step_nxt = 4'd2;                // second bus reset
                        pst_nxt  = P_RST;
                        mcnt_nxt = 9'd0;
                    end
                end
                4'd3: begin
                    awaitr_nxt = 1'b1;
                    mcnt_nxt   = 9'd0;
                end
                4'd4: begin
                    step_nxt  = 4'd5;
                    cst_nxt   = C_SETUP;
                    poff_nxt  = 8'd0;
                    pnext_nxt = 9'd0;
                    ptot_nxt  = 8'hFF;
                    found_nxt = 1'b0;
                    cand_nxt  = 1'b0;
                    pstop_nxt = 1'b0;
                end
                4'd5: begin
                    if (~found) begin
                        unsup    = 1'b1;
                        fail_err = E_NOHID;
                    end else begin
                        step_nxt = 4'd6;
                        cst_nxt  = C_SETUP;
                    end
                end
                default: begin                          // 6: configured
                    itog_nxt = 1'b0;
                    if ((dev_if[15:8] == 8'd1) & boot_i) begin
                        step_nxt = 4'd7;
                        cst_nxt  = C_SETUP;
                    end else if (idle0_i) begin
                        step_nxt = 4'd8;
                        cst_nxt  = C_SETUP;
                    end else begin
                        pst_nxt  = P_RUN;
                        mcnt_nxt = 9'd0;
                        ev_ready = 1'b1;
                    end
                end
                endcase
            end
        end
    end

    P_RUN: begin
        if (XF & xstart_ok) begin
            xbusy_nxt = 1'b1;
            xpkt_nxt  = 1'b0;
            xres_nxt  = X_OK;
            sw_x_nxt  = 1'b1;
        end
        if (XF & xbusy & (cst == C_IDLE) & (tph == T_IDLE) & ~c_done) begin
            cst_nxt  = C_SETUP;                         // start the software transfer after the poll in progress
            mcnt_nxt = 9'd0;
        end
        xabq_nxt = XF & xbusy & xabort & (tph != T_IDLE);
        if (XF & xbusy & xabort & (tph == T_IDLE)) begin
            cst_nxt   = C_IDLE;
            xbusy_nxt = 1'b0;
            xpkt_nxt  = 1'b0;
            xres_nxt  = X_ABORT;
            ev_xdone  = 1'b1;
            sw_x_nxt  = 1'b0;
            mcnt_nxt  = 9'd0;
        end
        if (XF & c_done) begin
            xbusy_nxt = 1'b0;
            xpkt_nxt  = 1'b0;
            xres_nxt  = c_res;
            ev_xdone  = 1'b1;
            sw_x_nxt  = 1'b0;
            mcnt_nxt  = 9'd0;
            if (c_res == X_ERR) begin
                fail     = 1'b1;
                fail_err = tecls;
            end
        end
        if (~xbusy & (cst == C_IDLE)) begin
            if (polling & tdone) begin                  // poll result
                case (tres)
                TR_OK: begin
                    itog_nxt    = ~itog;
                    attempt_nxt = 2'd0;
                    if (tlen != 4'd0) begin
                        commit    = 1'b1;
                        ev_report = 1'b1;
                    end
                end
                TR_NAK, TR_DUP: attempt_nxt = 2'd0;
                TR_STALL: begin
                    fail     = 1'b1;
                    fail_err = E_STALL;
                end
                default: if (errc == 2'd2) begin
                    fail     = 1'b1;
                    fail_err = tecls;
                end
                endcase
                polling_nxt = (tres == TR_ERR) & (errc != 2'd2);   // retry next frame
            end else if ((tph == T_IDLE) & slot & (polling | (mcnt >= {1'b0, interval}))) begin
                if (~polling) mcnt_nxt = 9'd0;
                tk_nxt      = TK_IN;
                tph_nxt     = T_TOK;
                start_nxt   = 1'b1;
                polling_nxt = 1'b1;
            end
        end
    end

    P_BACK: begin
        if (mcnt >= MS_BACK) begin
            pst_nxt  = P_RST;
            mcnt_nxt = 9'd0;
            step_nxt = 4'd1;
        end
    end

    default: ;                                          // P_FAIL, P_UNSUP, P_FS: wait for a detach
    endcase

    // Failures and unsupported devices
    if (fail) begin
        attempt_nxt = (attempt == 2'd2) ? attempt : (attempt + 2'd1);
        pst_nxt     = (attempt == 2'd2) ? P_FAIL : P_BACK;
        err_nxt     = fail_err;
        estep_nxt   = (pst == P_ENUM) ? step : 4'd0;
        mcnt_nxt    = 9'd0;
    end
    if (unsup) begin
        pst_nxt   = P_UNSUP;
        err_nxt   = fail_err;
        estep_nxt = step;
    end

    // Disconnect, restart, disable
    if (sie_se0_long_i & (pst != P_OFF) & (pst != P_DET) & (pst != P_DEB) & (pst != P_RST)) begin
        pst_nxt   = P_DET;
        ev_detach = (pst == P_RUN);
    end
    if (cmd_restart_i & (pst >= P_REC) & (pst != P_FS)) begin
        pst_nxt     = P_RST;
        attempt_nxt = 2'd0;
        step_nxt    = 4'd1;
        mcnt_nxt    = 9'd0;
        err_nxt     = 4'd0;
        estep_nxt   = 4'd0;
    end
    if (~en_i) begin
        pst_nxt      = P_OFF;
        err_nxt      = 4'd0;
        estep_nxt    = 4'd0;
        dev_id_nxt   = 32'd0;
        dev_if_nxt   = 24'd0;
        dev_boot_nxt = 1'b0;
        dev_ep_nxt   = 4'd0;
        dev_mps_nxt  = 7'd0;
        dev_int_nxt  = 8'd0;
        dev_mps0_nxt = 7'd0;
    end else if ((pst == P_OFF)) begin
        pst_nxt = P_DET;
    end

    // Leaving the port's active states: stop everything in flight
    if ((pst_nxt != pst) & ((pst_nxt == P_OFF) | (pst_nxt == P_DET) | (pst_nxt == P_RST) | (pst_nxt == P_BACK)
                          | (pst_nxt == P_FAIL) | (pst_nxt == P_UNSUP))) begin
        abort_nxt   = 1'b1;
        start_nxt   = 1'b0;
        tph_nxt     = T_IDLE;
        cst_nxt     = C_IDLE;
        ka_pend_nxt = 1'b0;
        ka_busy_nxt = 1'b0;
        errc_nxt    = 2'd0;
        polling_nxt = 1'b0;
        awaitr_nxt  = 1'b0;
        mcnt_nxt    = 9'd0;
        if (XF & (xbusy | xstart_ok) & ~ev_xdone) begin // a transfer running or starting, not ending
            xbusy_nxt = 1'b0;
            xpkt_nxt  = 1'b0;
            xres_nxt  = X_DET;
            ev_xdone  = 1'b1;
            sw_x_nxt  = 1'b0;
        end
    end
    if (pst_nxt == P_RUN) begin
        err_nxt   = (pst != P_RUN) ? 4'd0 : err_nxt;
        estep_nxt = (pst != P_RUN) ? 4'd0 : estep_nxt;
    end

    // Software commands that cannot start a transfer
    if (XF & cmd_xstart_i & ((pst != P_RUN) | xbusy)) begin
        if (~ev_xdone) xres_nxt = X_REF;                // a transfer ending in this cycle keeps its result
        ev_xdone = 1'b1;
    end
end

// Direction of the data stage: device-to-host for every enumeration request
// with a data stage, bmRequestType[7] for software
function setup_b_dir;
    input sw;
    input dir;
    begin
        setup_b_dir = sw ? dir : 1'b1;
    end
endfunction


//=============================================================================
// 5)  REGISTERS
//=============================================================================

arv_ipdff #(.WIDTH(4),  .ARST_EN(ARST_EN)) u_pst     (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(pst_nxt),     .q_o(pst));
arv_ipdff #(.WIDTH(4),  .ARST_EN(ARST_EN)) u_step    (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(step_nxt),    .q_o(step));
arv_ipdff #(.WIDTH(3),  .ARST_EN(ARST_EN)) u_cst     (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(cst_nxt),     .q_o(cst));
arv_ipdff #(.WIDTH(2),  .ARST_EN(ARST_EN)) u_tph     (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(tph_nxt),     .q_o(tph));
arv_ipdff #(.WIDTH(2),  .ARST_EN(ARST_EN)) u_tk      (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(tk_nxt),      .q_o(tk));
arv_ipdff #(.WIDTH(3),  .ARST_EN(ARST_EN)) u_tpend   (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(tpend_nxt),   .q_o(tpend));
arv_ipdff #(.WIDTH(4),  .ARST_EN(ARST_EN)) u_tlen    (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(tlen_nxt),    .q_o(tlen));
arv_ipdff #(.WIDTH(2),  .ARST_EN(ARST_EN)) u_errc    (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(errc_nxt),    .q_o(errc));
arv_ipdff #(.WIDTH(2),  .ARST_EN(ARST_EN)) u_attempt (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(attempt_nxt), .q_o(attempt));
arv_ipdff #(.WIDTH(9),  .ARST_EN(ARST_EN)) u_mcnt    (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(mcnt_nxt),    .q_o(mcnt));
arv_ipdff #(.WIDTH(11), .ARST_EN(ARST_EN)) u_fcnt    (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(sie_tick_i), .d_i(fcnt_nxt),    .q_o(fcnt));
arv_ipdff #(.WIDTH(12), .ARST_EN(ARST_EN)) u_flags   (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1),
    .d_i({ka_pend_nxt, ka_busy_nxt, nxtf_nxt, start_nxt, abort_nxt, deb_fs_nxt, addr1_nxt, ctog_nxt, itog_nxt, polling_nxt, sw_x_nxt, awaitr_nxt}),
    .q_o({ka_pend,     ka_busy,     nxtf,     start_q,   abort_q,   deb_fs,     addr1,     ctog,     itog,     polling,     sw_x,     awaitr}));

generate
    if (XF) begin : g_xfer_q
        arv_ipdff #(.WIDTH(6), .ARST_EN(ARST_EN)) u_xfer (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1),
            .d_i({xabq_nxt, xbusy_nxt, xpkt_nxt, xres_nxt}), .q_o({xabq, xbusy, xpkt, xres}));
    end else begin : g_no_xfer_q
        assign {xabq, xbusy, xpkt, xres} = 6'd0;
        wire   xfer_q_unused = |{xabq_nxt, xbusy_nxt, xpkt_nxt, xres_nxt};
    end
endgenerate
arv_ipdff #(.WIDTH(REM_W), .ARST_EN(ARST_EN)) u_rem  (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(rem_nxt),     .q_o(rem));
arv_ipdff #(.WIDTH(4),  .ARST_EN(ARST_EN)) u_olen    (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(olen_nxt),    .q_o(olen));
arv_ipdff #(.WIDTH(4),  .ARST_EN(ARST_EN)) u_pidx    (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(pidx_nxt),    .q_o(pidx));
arv_ipdff #(.WIDTH(8),  .ARST_EN(ARST_EN)) u_poff    (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(poff_nxt),    .q_o(poff));
arv_ipdff #(.WIDTH(9),  .ARST_EN(ARST_EN)) u_pnext   (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(pnext_nxt),   .q_o(pnext));
arv_ipdff #(.WIDTH(4),  .ARST_EN(ARST_EN)) u_prel    (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(prel_nxt),    .q_o(prel));
arv_ipdff #(.WIDTH(2),  .ARST_EN(ARST_EN)) u_dtype   (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(dtype_nxt),   .q_o(dtype));
arv_ipdff #(.WIDTH(8),  .ARST_EN(ARST_EN)) u_ptot    (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(ptot_nxt),    .q_o(ptot));
arv_ipdff #(.WIDTH(6),  .ARST_EN(ARST_EN)) u_pflags  (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1),
    .d_i({cand_nxt, alt0_nxt, found_nxt, ep_in_nxt, ep_int_nxt, pstop_nxt}),
    .q_o({cand,     alt0,     found,     ep_in,     ep_int,     pstop}));
arv_ipdff #(.WIDTH(4),  .ARST_EN(ARST_EN)) u_perr    (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(perr_nxt),    .q_o(perr));
arv_ipdff #(.WIDTH(8),  .ARST_EN(ARST_EN)) u_cfgval  (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(cfgval_nxt),  .q_o(cfgval));
arv_ipdff #(.WIDTH(8),  .ARST_EN(ARST_EN)) u_err     (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1),
                                                      .d_i({err_nxt, estep_nxt}), .q_o({err, estep}));

arv_ipdff #(.WIDTH(32), .ARST_EN(ARST_EN)) u_dev_id  (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(dev_id_nxt),  .q_o(dev_id));
arv_ipdff #(.WIDTH(25), .ARST_EN(ARST_EN)) u_dev_if  (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1),
                                                      .d_i({dev_boot_nxt, dev_if_nxt}), .q_o({dev_boot, dev_if}));
arv_ipdff #(.WIDTH(27), .ARST_EN(ARST_EN)) u_dev_ep  (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1),
                                                      .d_i({dev_hub_nxt, dev_mps0_nxt, dev_int_nxt, dev_mps_nxt, dev_ep_nxt}),
                                                      .q_o({dev_hub,     dev_mps0,     dev_int,     dev_mps,     dev_ep}));


//=============================================================================
// 6)  OUTPUTS
//=============================================================================

wire              [3:0] pst_q;
arv_ipdff #(.WIDTH(4), .ARST_EN(ARST_EN)) u_pst_q (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(pst), .q_o(pst_q));

assign rx_dest_o    = XF & sw_x & (cst == C_DIN);
assign rpt_commit_o = commit;
assign rpt_len_o    = tlen;
assign run_o        = (pst == P_RUN);

assign state_o      = pst;
assign fs_dev_o     = (pst == P_FS);
assign err_o        = err;
assign step_o       = estep;
assign attempt_o    = attempt;
assign xbusy_o      = XF & xbusy;
assign xpkt_o       = XF & xpkt;
assign xres_o       = XF ? xres : 3'd0;
assign xlen_in_o    = XF ? tlen : 4'd0;
assign dev_id_o     = dev_id;
assign dev_if_o     = {dev_boot, dev_if};
assign dev_ep_o     = {dev_mps0, dev_int, dev_mps, dev_ep};

assign ev_report_o  = ev_report;
assign ev_ready_o   = ev_ready;
assign ev_detach_o  = ev_detach;
assign ev_fail_o    = (pst != pst_q) & ((pst == P_BACK) | (pst == P_FAIL) | (pst == P_UNSUP));
assign ev_xpkt_o    = XF & ev_xpkt;
assign ev_xin_o     = XF & ev_xin;
assign ev_xdone_o   = XF & ev_xdone;
assign ev_state_o   = (pst != pst_q);
assign ev_tmo_o     = ev_tmo;
assign ev_bad_o     = ev_bad;
assign ev_other_o   = ev_other;
assign ev_stall_o   = ev_stall;
assign ev_busrst_o  = (pst == P_RST) & (pst_q != P_RST);
assign ev_dup_o     = ev_dup;

// Serial engine
assign sie_start_o  = start_q;
assign sie_kind_o   = ka_busy ? K_KEEP : (tph == T_TOK) ? K_TOKEN : (tph == T_DAT) ? K_DATA : K_ACK;
assign sie_pid_o    = (tph == T_TOK) ? ((tk == TK_SETUP) ? PID_SETUP : (tk == TK_IN) ? PID_IN : PID_OUT)
                    : (tph == T_DAT) ? (((tk != TK_SETUP) & ctog) ? PID_D1 : PID_D0)
                    :                  PID_ACK;
assign sie_addr_o   = {6'd0, addr1};
assign sie_ep_o     = polling ? dev_ep : 4'd0;
assign sie_len_o    = (tk == TK_SETUP) ? 4'd8 : olen;
assign sie_resp_o   = ((tph == T_TOK) & (tk == TK_IN)) | (tph == T_DAT);
assign sie_reset_o  = (pst == P_RST);
assign sie_abort_o  = abort_q;

wire                    tx_idx_unused = sie_tx_idx_i[3];

// Without software control transfers the commands and the transfer events are dead
generate
    if (!XF) begin : g_no_xfer
        wire            xfer_unused = cmd_xstart_i | xstart_ok | xabort | ev_xpkt | ev_xin | ev_xdone | (|sw_setup_b);
    end
endgenerate

endmodule // apb_usb_host_seq

`default_nettype wire
