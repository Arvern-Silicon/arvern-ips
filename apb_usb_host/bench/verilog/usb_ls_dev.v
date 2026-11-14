//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    usb_ls_dev
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : usb_ls_dev.v
// Module Description : Behavioural low-speed (1.5 Mb/s) USB HID device with
//                      always-on checks of the host, for the apb_usb_host
//                      bench. Written from the apb_usb_host contract, USB 2.0
//                      (chapters 7, 8, 9) and HID 1.11, not from any RTL.
//
//  Bench wiring (Verilog strengths resolve the bus):
//
//      wire dp, dm;
//      assign dp = host_oe ? host_dp_o : 1'bz;     // host drivers, strong
//      assign dm = host_oe ? host_dm_o : 1'bz;
//      assign (weak0, highz1) dp = 1'b0;           // host 15 kOhm, weaker than the pull-up
//      assign (weak0, highz1) dm = 1'b0;
//      usb_ls_dev #(.NAME("dev")) dev (.dp(dp), .dm(dm), .host_oe(host_oe), ...);
//
//  The device puts pull1 on D- (low speed) or on D+ (full-speed profile)
//  while attached, and drives both lines strong only while it transmits.
//  With USB_LS_DEV_EXT_BUS defined (a simulator without drive strengths) the
//  model drives nothing: the bench resolves the bus from drv_en / drv_dp /
//  drv_dm / pu_on / pu_fs by hierarchical reference and the ports are inputs.
//  host_oe is a monitor input: the debounce, detached-drive, EOP-release,
//  full-speed-drive and both-driving collision checks need it. Tie it to 0
//  when the host has no visible output enable (those checks then stay quiet).
//
//  Timing is real time (ns): every edge the model drives is scheduled at an
//  absolute time t0 + i * Tdev, Tdev = 666.667 ns / (1 + ppm * 1e-6), so the
//  programmed rate offset never accumulates rounding. The receiver decodes
//  edge by edge: the number of bit cells between two transitions is the
//  rounded ratio of their distance to the nominal bit time, which re-aligns
//  on every transition and tolerates any host within a few percent.
//
//  Device behaviour (spec-derived choices where the request was open):
//   - Bus reset seen after 2.5 us of host SE0 (TDETRST, usb_20.txt:9483):
//     address 0, deconfigured, toggles and halts cleared, HID protocol back
//     to report (HID 7.2.6), report FIFOs kept.
//   - SET_ADDRESS / SET_CONFIGURATION / SET_INTERFACE / SET_IDLE /
//     SET_PROTOCOL / SET_REPORT / features take effect when the status stage
//     completes, which is the host's ACK of the status ZLP for an IN status
//     and the device's ACK of the host ZLP for an OUT status (9.4.6 says the
//     address changes only after the status stage, usb_20.txt:15132). The new
//     address is answered set_addr_recovery() ns later (default 0, <= 2 ms,
//     usb_20.txt:14528); in between the device answers no address.
//   - A token to an endpoint that does not exist in the current
//     configuration / alternate setting is ignored (no response); EP0 control
//     requests the device does not support get a STALL in the data or status
//     stage (the SETUP itself is always ACKed, 8.5.3). An IN after the end of
//     the IN data stage is STALLed.
//   - Interrupt IN: next FIFO report, or NAK when empty (or the last report
//     again in repeat mode). The toggle advances and the FIFO pops only on
//     the host's ACK; with no ACK within 17 bit times (the device times out
//     between 16 and 18, usb_20.txt:10368) the same packet and toggle go out
//     at the next IN.
//   - Fault F_TOGGLE sends the packet with the inverted toggle and keeps the
//     report and the toggle on ACK (a repeated old packet, which the host
//     must acknowledge and discard, 8.6.4). F_SILENT: the device does not
//     respond, as if it had not received the packet (nothing is accepted).
//     A corrupted handshake (F_CRC / F_PID / F_STUFF on an ACK) models a lost
//     ACK: the OUT/SETUP data is accepted and the host's retransmission is
//     then ACKed and discarded (8.6.3). NAK / STALL / HOLD on a SETUP or OUT
//     mean the data was not accepted.
//   - Full-speed profile: D+ pull-up, the device never drives and never
//     decodes; any host drive is counted by FS_DRIVE.
//
//  Host checks (each with chk_en[] and chk_cnt[], message with $time):
//   RATE      bit rate within RATE_TOL_PPM, least-squares over each packet
//             (allowance + 3 * RATE_GRID_NS / span for a host on a clock grid)
//   JITTER    consecutive / paired transitions (Table 7-5 LS: 71 / 44 ns)
//   EOP       host SE0 1.25-1.50 us (TLEOPT) followed by J
//   EOP_REL   host drives J for more than 1 bit after its SE0 before release
//             (usb_20.txt:10330: "drive J for one bit time and then turn off")
//   IPD       host data after its token, host handshake after device data:
//             2 to 7.5 bit times (7.1.18.1)
//   TIMEOUT   host transmits < 18 bit times after its IN token or data packet
//             that the device left unanswered (7.1.19.1)
//   BUS_IDLE  host packet or keep-alive started after < 2 bit times of J
//   CRC, STUFF, PID   host packet integrity (sync, PID check bits, framing)
//   ADDR      token address = device address; any token within 2 ms of the
//             SET_ADDRESS status stage (9.2.6.3) is an error
//   RESET     host bus reset shorter than RST_MIN_NS (TDRSTR 50 ms)
//   DEBOUNCE  host drives before DEBOUNCE_NS of attachment (TATTDB 100 ms)
//   KEEPALIVE gap between host transmissions (packet SOP or keep-alive SE0)
//             above KA_GAP_MAX_NS from the end of a
//             reset; a gap ended by a bus reset is a back-off (counted
//             apart), a gap ended by a detach is ignored
//   TOGGLE    host DATA PIDs: SETUP DATA0, OUT data stage from DATA1,
//             status OUT DATA1 (retransmissions after a lost ACK allowed)
//   DETACHED  host drives while detached, except within DETACH_GRACE_NS
//   STATUS    control transfer abandoned (new SETUP or bus reset) before its
//             status stage, unless the device STALLed it or a fault hit it
//   COLLISION host and device both driving, or x/z on the bus while someone
//             drives (device resume K overlapping the host's K is legal)
//   PROTOCOL  out-of-sequence host packets: DATA without OUT/SETUP, handshake
//             without device data, NAK/STALL from the host, ACK of a corrupt
//             packet, SOF/PRE at low speed, wrong-size SETUP / OUT data
//   FS_DRIVE  host drives the bus of a full-speed device
//
//  Task API (call hierarchically, e.g. dev.attach(dev.P_KBD)):
//   attach(profile)            profile < 0 keeps the loaded descriptors
//   detach
//   load_profile(profile), desc_set(region, idx, val), desc_len(region, n)
//                              regions R_DEV, R_CFG, R_REP0, R_REP1, R_STR0..3
//   push_report(len, data64)   to EP1; push_report_ep(ep, len, data64)
//   flush_reports, set_repeat_last(en)
//   set_rate_ppm(ppm)          -15000..15000
//   set_resp_delay(min, max)   in 1/100 bit time, 200..650 legal
//   set_addr_recovery(ns), set_seed(s)
//   inject_fault(kind, tok, ep, req, dtype, stage, skip, count, arg)
//   clear_faults
//   drive_resume(ms)           device K on an idle bus for ms (blocks)
//   chk_enable(id, en), chk_clear, set_verbosity(v), dump_summary
//  Verbosity: 0 errors + summary, 1 attach/reset/control transfers/reports/
//  faults, 2 every packet, 3 packet timing.
//----------------------------------------------------------------------------
`include "timescale.v"
`default_nettype none

module usb_ls_dev #(
    parameter NAME            = "usbdev",   // message prefix
    parameter PROFILE         = 0,          // profile loaded at time 0
    parameter AUTO_ATTACH     = 0,          // 1: attach PROFILE at time 0
    parameter SEED            = 1,          // response-delay and babble seed
    parameter VERBOSE         = 1,          // initial verbosity
    parameter JIT_NEXT_NS     = 71,         // host jitter, consecutive transitions
    parameter JIT_PAIR_NS     = 44,         // host jitter, paired transitions
    parameter RATE_TOL_PPM    = 500,        // host bit-rate tolerance
    parameter RATE_GRID_NS    = 0,          // host edge grid (0: jitter-free host)
    parameter TOL_NS          = 50,         // measurement margin on bit-time bounds
    parameter KA_GAP_MAX_NS   = 1010000,    // keep-alive: max gap between host transmissions
    parameter RST_MIN_NS      = 50000000,   // bus reset minimum (root port)
    parameter DEBOUNCE_NS     = 100000000,  // attach debounce
    parameter SETADDR_RCY_NS  = 2000000,    // SET_ADDRESS recovery the host must allow
    parameter DETACH_GRACE_NS = 10000       // host drive tolerated after a detach
) (
    inout  wire        dp,                  // D+
    inout  wire        dm,                  // D-
    input  wire        host_oe,             // host output enable (monitor only)
    output wire        attached,            // pull-up connected
    output wire        suspended,           // bus idle > 3 ms
    output wire  [6:0] address,             // device address in effect
    output wire        configured,          // a configuration is selected
    output wire  [2:0] dev_state,           // DS_* below
    output wire [31:0] err_count            // sum of the enabled checkers' counts
);

//=============================================================================
// 1)  CONSTANTS
//=============================================================================

localparam real BIT_NS     = 2000.0 / 3.0;  // low-speed bit time
localparam real LS_SETTLE  = 2.0;           // line-change settle window (ns)
localparam      DEV_TO_BITS = 17;           // device handshake timeout (16..18)

// Line states (low-speed polarity: J = D- high)
localparam [2:0] L_SE0 = 3'd0, L_J = 3'd1, L_K = 3'd2, L_SE1 = 3'd3, L_X = 3'd4;

// PIDs
localparam [3:0] P_OUT   = 4'b0001, P_IN    = 4'b1001, P_SOF   = 4'b0101, P_SETUP = 4'b1101,
                 P_DATA0 = 4'b0011, P_DATA1 = 4'b1011, P_DATA2 = 4'b0111, P_MDATA = 4'b1111,
                 P_ACK   = 4'b0010, P_NAK   = 4'b1010, P_STALL = 4'b1110, P_NYET  = 4'b0110,
                 P_PRE   = 4'b1100;

// Checkers
localparam C_RATE = 0, C_JITTER = 1, C_EOP = 2, C_EOPREL = 3, C_IPD = 4, C_TIMEOUT = 5,
           C_IDLE = 6, C_CRC = 7, C_STUFF = 8, C_PID = 9, C_ADDR = 10, C_RESET = 11,
           C_DEBOUNCE = 12, C_KEEPALIVE = 13, C_TOGGLE = 14, C_DETACHED = 15, C_STATUS = 16,
           C_COLL = 17, C_PROTO = 18, C_FSDRV = 19;
localparam NCHK = 20;

// Device states
localparam DS_DETACHED = 0, DS_ATTACHED = 1, DS_DEFAULT = 2, DS_ADDRESS = 3, DS_CONFIGURED = 4;

// Profiles
localparam P_KBD = 0, P_MOUSE = 1, P_GAMEPAD = 2, P_COMPOSITE = 3, P_HUB = 4, P_VENDOR = 5,
           P_ALT_FIRST = 6, P_TOTAL8 = 7, P_MPS0 = 8, P_MPS_BIG = 9, P_BINT0 = 10, P_FS = 11;

// Descriptor regions (256 bytes each)
localparam R_DEV = 0, R_CFG = 1, R_REP0 = 2, R_REP1 = 3, R_STR0 = 4, R_STR1 = 5, R_STR2 = 6, R_STR3 = 7;

// Faults
localparam F_NONE = 0, F_NAK = 1, F_STALL = 2, F_SILENT = 3, F_CRC = 4, F_STUFF = 5, F_PID = 6,
           F_TOGGLE = 7, F_OVERLONG = 8, F_BABBLE = 9, F_HOLD_J = 10, F_HOLD_K = 11,
           F_DETACH = 12, F_LATE = 13;
localparam T_ANY = -1, T_SETUP = 0, T_IN = 1, T_OUT = 2;          // fault token match
localparam ST_SETUP = 0, ST_DATA = 1, ST_STATUS = 2;               // fault stage match
localparam NFR = 16;                                               // fault rules

// Decoder modes
localparam RX_IDLE = 0, RX_PKT = 1, RX_EOP = 2, RX_SE0 = 3, RX_RST = 4, RX_RESUME = 5, RX_WAIT = 6;

// Last bus event (for inter-packet and timeout checks)
localparam LE_NONE = 0, LE_HTOK_IN = 1, LE_HTOK_OUT = 2, LE_HTOK_SETUP = 3, LE_HDATA = 4,
           LE_HHS = 5, LE_HBAD = 6, LE_KA = 7, LE_RESET = 8, LE_DEV_BUSY = 9, LE_DEV_DATA = 10,
           LE_DEV_HS = 11, LE_HTOK_OTHER = 12;

// Device transaction state
localparam XS_IDLE = 0, XS_SETUP_DATA = 1, XS_OUT_DATA = 2, XS_IN_HS = 3;

// Control transfer stage
localparam CS_NONE = 0, CS_DATA_IN = 1, CS_DATA_OUT = 2, CS_STATUS_IN = 3, CS_DONE = 4;

// Pending control-request effect (applied at status completion)
localparam PA_NONE = 0, PA_ADDR = 1, PA_CONFIG = 2, PA_SETIF = 3, PA_IDLE = 4, PA_PROTO = 5,
           PA_SETREP = 6, PA_CLRHALT = 7, PA_SETHALT = 8;

// Transmit kinds
localparam TK_HS = 0, TK_DATA = 1;

localparam RFD = 64;                        // report FIFO depth per endpoint

//=============================================================================
// 2)  STATE
//=============================================================================

// Bus drivers and pull-up
reg        drv_en;
reg        drv_dp;
reg        drv_dm;
reg        pu_on;
reg        pu_fs;

`ifndef USB_LS_DEV_EXT_BUS
assign dp = drv_en ? drv_dp : 1'bz;
assign dm = drv_en ? drv_dm : 1'bz;
assign (pull1, highz0) dm = pu_on & ~pu_fs;
assign (pull1, highz0) dp = pu_on &  pu_fs;
`endif

// Configuration and bookkeeping
integer    verbose;
integer    seed;
integer    rate_ppm;
integer    dly_min;                         // response delay, 1/100 bit
integer    dly_max;
real       addr_rcy_ns;
reg        repeat_last;
reg [8*200-1:0] mb;                         // message buffer

// Checkers
reg        chk_en  [0:NCHK-1];
integer    chk_cnt [0:NCHK-1];
integer    err_total;

// Statistics
real       st_jit_next;                     // max consecutive-transition jitter
real       st_jit_pair;                     // max paired-transition jitter
real       st_rate_max;                     // max |ppm| of a host packet
real       st_rate_sum;                     // span-weighted ppm sum
real       st_rate_span;
integer    st_host_pkts;
real       st_ka_max;                       // max gap between host transmissions (armed)
integer    st_backoffs;
integer    st_resets;
real       st_rst_len [0:7];                // last reset lengths
integer    st_coll;
integer    st_susp;
integer    st_xfer_start;
real       st_xfer_start_t;                 // time of the last SETUP accepted
integer    st_xfer_done;
integer    st_faults;
integer    st_ipd_n;
real       st_ipd_min;
real       st_ipd_max;

// Line monitor
reg  [2:0] ls_state;                        // settled line state
reg  [2:0] ls_prev;                         // state before the last change
real       ls_t;                            // time of the last change
reg        ls_dev;                          // the last change was caused by the device
real       dev_evt_t;                       // time of the last device line action
real       last_se0_len;                    // length of the last host SE0

// Decoder
integer    rx_mode;
reg        rxb [0:1023];                    // unstuffed bits of the host packet
integer    rx_n;
integer    rx_ones;
reg        rx_stuff_err;
integer    rx_stuff_pos;
integer    rx_cell;                         // bit cells since SOP
real       rx_et [0:255];                   // edge times
integer    rx_ec [0:255];                   // cell index at each edge
integer    rx_ne;
reg        rx_ovf;
real       rx_sop_t;
real       rx_se0_t;
integer    rx_prev_ev;                      // last_ev when the packet started
real       rx_prev_t;
reg  [7:0] rxd [0:63];                      // packet bytes after the PID
real       hs_idle;                         // J before a host SE0 start (deferred checks)
integer    hs_prev_ev;
real       hs_prev_t;

// Host / bus history
integer    last_ev;
// Event toggles: each flips on its event, for a bench that waits with an
// edge-triggered event control (a level event control on an integer misses
// repeated values, and Verilator schedules it by what its body reads)
reg        ev_tgl;                          // last_ev assigned
reg        setup_tgl;                       // a SETUP accepted
reg        ack_tgl;                         // an interrupt data packet acknowledged
real       last_ev_t;
real       dev_eop_end_t;
real       attach_t;
real       detach_t;
reg        det_flag;

// Keep-alive and suspend
reg        ka_armed;
real       ka_last;
reg        ka_pend;
real       ka_pend_gap;
reg        susp_q;

// Reset
reg        rst_active;
real       rst_t0;

// Device protocol state
integer    st_dev;                          // DS_*
reg  [6:0] dev_addr;
real       addr_ready_t;
reg        addr_chg_pend;                   // host-side SET_ADDRESS recovery window
real       addr_chg_t;
reg  [6:0] addr_old;
integer    cur_cfg;
integer    cur_alt [0:7];
integer    hid_idle [0:7];
integer    hid_proto [0:7];
integer    ep_tgl  [0:3];
reg        ep_halt [0:3];

// Transaction
integer    xs;
integer    xs_ep;
integer    xs_len;
reg        xs_corrupt;
reg        xs_badtgl;
reg        xs_fifo;                         // the data came from the FIFO head

// Control transfer
reg        ctl_active;
integer    ctl_stage;
reg        ctl_stall;
integer    ctl_tgl;
integer    ctl_len;
integer    ctl_ptr;
reg        zlp_need;
reg        data_done;
integer    ctl_progress;
real       ctl_progress_t;                  // time of the last control-transfer progress
reg        out_ack_lost;                    // last OUT/SETUP handshake did not reach the host
reg        ctl_trouble;                     // the device STALLed or faulted this control transfer
reg        ctl_in_dir;                      // the transfer had an IN data stage
integer    ctl_out_cnt;
reg  [7:0] cs_rt, cs_rq;
reg [15:0] cs_wv, cs_wi, cs_wl;
reg [63:0] cs_raw;
integer    pend;
integer    pend_v;
integer    pend_i;
reg  [7:0] cbuf [0:511];
reg  [7:0] obuf [0:63];

// SET_REPORT record
reg  [7:0] srep [0:63];
integer    srep_len;
integer    srep_cnt;
reg [15:0] srep_wv;
integer    srep_if;

// Descriptors
reg  [7:0] dmem [0:2047];
integer    rlen [0:7];
integer    prof;
reg        prof_fs;
integer    nif, nep;
integer    if_num [0:7], if_alt [0:7], if_cls [0:7], if_sub [0:7], if_pro [0:7], if_hid [0:7];
integer    ep_num [0:7], ep_ifx [0:7], ep_mps [0:7], ep_attr [0:7];
reg        ep_in  [0:7];
integer    cfg_value;

// Report FIFOs (endpoints 1..3)
reg [63:0] rf_dat [0:4*RFD-1];
integer    rf_len [0:4*RFD-1];
integer    rf_rd  [0:3];
integer    rf_wr  [0:3];
integer    rf_cnt [0:3];
reg [63:0] rl_dat [0:3];
integer    rl_len [0:3];
reg        rl_ok  [0:3];
reg [63:0] idle_dat [0:3];                  // profile idle report (GET_REPORT, repeat mode)
integer    idle_len [0:3];
integer    int_sent_cnt;                    // interrupt data packets transmitted (bench probe)
integer    int_sent_ep;
integer    int_sent_len;
reg [63:0] int_sent_data;
integer    int_ack_cnt;                     // interrupt data packets acknowledged

// Fault rules
integer    fr_kind [0:NFR-1], fr_tok [0:NFR-1], fr_ep [0:NFR-1], fr_req [0:NFR-1];
integer    fr_dtype [0:NFR-1], fr_stage [0:NFR-1], fr_skip [0:NFR-1], fr_cnt [0:NFR-1];
integer    fr_arg [0:NFR-1], fr_occ [0:NFR-1], fr_hits [0:NFR-1];
integer    fz_kind, fz_arg, fz_idx;

// Transmitter
event      tx_go;
reg        tx_busy;
integer    tx_kind;
reg  [3:0] tx_pid;
integer    tx_nb;
reg  [7:0] txb [0:31];
reg        tx_crc_err, tx_stuff_err, tx_pid_err;
reg        tx_babble;                       // keep toggling for tx_hold_ns, then EOP
reg        tx_hold;                         // sync, then hold J or K for tx_hold_ns, no EOP
reg        tx_hold_k;
reg        fx_silent, fx_replaced, fx_corrupt, fx_badtgl;
integer    tx_detach_bit;
real       tx_hold_ns;
real       tx_t_ref;
real       tx_dly;
reg        resume_active;
reg        rawb [0:511];
reg        sbit [0:639];

assign attached   = pu_on;
assign suspended  = susp_q;
assign address    = dev_addr;
assign configured = (cur_cfg != 0);
assign dev_state  = st_dev[2:0];
assign err_count  = err_total;

//=============================================================================
// 3)  UTILITIES
//=============================================================================

function [8*9-1:0] chk_name;
   input integer id;
   case (id)
     C_RATE:      chk_name = "RATE";
     C_JITTER:    chk_name = "JITTER";
     C_EOP:       chk_name = "EOP";
     C_EOPREL:    chk_name = "EOP_REL";
     C_IPD:       chk_name = "IPD";
     C_TIMEOUT:   chk_name = "TIMEOUT";
     C_IDLE:      chk_name = "BUS_IDLE";
     C_CRC:       chk_name = "CRC";
     C_STUFF:     chk_name = "STUFF";
     C_PID:       chk_name = "PID";
     C_ADDR:      chk_name = "ADDR";
     C_RESET:     chk_name = "RESET";
     C_DEBOUNCE:  chk_name = "DEBOUNCE";
     C_KEEPALIVE: chk_name = "KEEPALIVE";
     C_TOGGLE:    chk_name = "TOGGLE";
     C_DETACHED:  chk_name = "DETACHED";
     C_STATUS:    chk_name = "STATUS";
     C_COLL:      chk_name = "COLLISION";
     C_PROTO:     chk_name = "PROTOCOL";
     C_FSDRV:     chk_name = "FS_DRIVE";
     default:     chk_name = "?";
   endcase
endfunction

function [8*5-1:0] pid_name;
   input [3:0] p;
   case (p)
     P_OUT:   pid_name = "OUT";
     P_IN:    pid_name = "IN";
     P_SOF:   pid_name = "SOF";
     P_SETUP: pid_name = "SETUP";
     P_DATA0: pid_name = "DATA0";
     P_DATA1: pid_name = "DATA1";
     P_DATA2: pid_name = "DATA2";
     P_MDATA: pid_name = "MDATA";
     P_ACK:   pid_name = "ACK";
     P_NAK:   pid_name = "NAK";
     P_STALL: pid_name = "STALL";
     P_NYET:  pid_name = "NYET";
     P_PRE:   pid_name = "PRE";
     default: pid_name = "?";
   endcase
endfunction

function [8*14-1:0] req_name;
   input [7:0] rt;
   input [7:0] rq;
   begin
      req_name = "VENDOR/OTHER";
      if (rt[6:5] == 2'd0)
        case (rq)
          8'd0:    req_name = "GET_STATUS";
          8'd1:    req_name = "CLEAR_FEATURE";
          8'd3:    req_name = "SET_FEATURE";
          8'd5:    req_name = "SET_ADDRESS";
          8'd6:    req_name = "GET_DESCRIPTOR";
          8'd8:    req_name = "GET_CONFIG";
          8'd9:    req_name = "SET_CONFIG";
          8'd10:   req_name = "GET_INTERFACE";
          8'd11:   req_name = "SET_INTERFACE";
          default: req_name = "STD_UNKNOWN";
        endcase
      else if (rt[6:5] == 2'd1)
        case (rq)
          8'h01:   req_name = "GET_REPORT";
          8'h02:   req_name = "GET_IDLE";
          8'h03:   req_name = "GET_PROTOCOL";
          8'h09:   req_name = "SET_REPORT";
          8'h0A:   req_name = "SET_IDLE";
          8'h0B:   req_name = "SET_PROTOCOL";
          default: req_name = "CLASS_UNKNOWN";
        endcase
   end
endfunction

function [2:0] ls_now;
   input dpv;
   input dmv;
   begin
      if (((dpv !== 1'b0) && (dpv !== 1'b1)) || ((dmv !== 1'b0) && (dmv !== 1'b1))) ls_now = L_X;
      else if (!dpv && !dmv) ls_now = L_SE0;
      else if ( dpv &&  dmv) ls_now = L_SE1;
      else if (!dpv &&  dmv) ls_now = L_J;
      else                   ls_now = L_K;
   end
endfunction

function [8*3-1:0] ls_name;
   input [2:0] s;
   case (s)
     L_SE0:   ls_name = "SE0";
     L_J:     ls_name = "J";
     L_K:     ls_name = "K";
     L_SE1:   ls_name = "SE1";
     default: ls_name = "X";
   endcase
endfunction

function integer rnd;                       // round a non-negative real
   input real x;
   rnd = $rtoi(x + 0.5);
endfunction

function real fabs;
   input real x;
   fabs = (x < 0.0) ? -x : x;
endfunction

// Record a checker hit (message already in mb)
task cerr;
   input integer id;
   begin
      if (chk_en[id])
        begin
           chk_cnt[id] = chk_cnt[id] + 1;
           err_total   = err_total + 1;
           $display("[%0t] %0s CHECK %0s: %0s", $time, NAME, chk_name(id), mb);
        end
   end
endtask

// Log message in mb at verbosity lvl
task vlog;
   input integer lvl;
   begin
      if (verbose >= lvl) $display("[%0t] %0s: %0s", $time, NAME, mb);
   end
endtask

task wait_until;
   input real t;
   begin
      if (t > $realtime) #(t - $realtime);
   end
endtask

//=============================================================================
// 4)  DESCRIPTORS AND PROFILES
//=============================================================================

task desc_clear;
   integer i;
   begin
      for (i = 0; i < 2048; i = i + 1) dmem[i] = 8'h00;
      for (i = 0; i < 8; i = i + 1) rlen[i] = 0;
   end
endtask

task dput;                                  // append one byte to a region
   input integer r;
   input integer b;
   begin
      if (rlen[r] < 256)
        begin
           dmem[r*256 + rlen[r]] = b[7:0];
           rlen[r] = rlen[r] + 1;
        end
   end
endtask

task dputv;                                 // append n bytes, first byte in the top byte of v
   input integer    r;
   input integer    n;
   input [1023:0]   v;
   integer          k;
   begin
      for (k = 0; k < n; k = k + 1) dput(r, v[8*(n-1-k) +: 8]);
   end
endtask

task desc_set;                              // poke one byte (extends the region if needed)
   input integer r;
   input integer idx;
   input integer val;
   begin
      dmem[r*256 + idx] = val[7:0];
      if (idx >= rlen[r]) rlen[r] = idx + 1;
      if (r == R_CFG) parse_cfg;
   end
endtask

task desc_len;
   input integer r;
   input integer n;
   begin
      rlen[r] = n;
      if (r == R_CFG) parse_cfg;
   end
endtask

task mk_dev;
   input integer cls;
   input integer vid;
   input integer pid;
   begin
      dput(R_DEV, 18); dput(R_DEV, 1); dput(R_DEV, 8'h10); dput(R_DEV, 8'h01);  // bcdUSB 1.10
      dput(R_DEV, cls); dput(R_DEV, 0); dput(R_DEV, 0); dput(R_DEV, 8);        // class, sub, proto, MPS0
      dput(R_DEV, vid & 255); dput(R_DEV, vid >> 8); dput(R_DEV, pid & 255); dput(R_DEV, pid >> 8);
      dput(R_DEV, 8'h00); dput(R_DEV, 8'h01);                                  // bcdDevice 1.00
      dput(R_DEV, 1); dput(R_DEV, 2); dput(R_DEV, 0); dput(R_DEV, 1);          // strings, 1 configuration
   end
endtask

task mk_cfg;                                // configuration header; wTotalLength set by cfg_done
   input integer nifs;
   begin
      dput(R_CFG, 9); dput(R_CFG, 2); dput(R_CFG, 0); dput(R_CFG, 0);
      dput(R_CFG, nifs); dput(R_CFG, 1); dput(R_CFG, 0); dput(R_CFG, 8'hA0); dput(R_CFG, 50);
   end
endtask

task mk_if;
   input integer num;
   input integer alt;
   input integer neps;
   input integer cls;
   input integer sub;
   input integer pro;
   begin
      dput(R_CFG, 9); dput(R_CFG, 4); dput(R_CFG, num); dput(R_CFG, alt); dput(R_CFG, neps);
      dput(R_CFG, cls); dput(R_CFG, sub); dput(R_CFG, pro); dput(R_CFG, 0);
   end
endtask

task mk_hid;
   input integer replen;
   begin
      dput(R_CFG, 9); dput(R_CFG, 8'h21); dput(R_CFG, 8'h11); dput(R_CFG, 8'h01); dput(R_CFG, 0);
      dput(R_CFG, 1); dput(R_CFG, 8'h22); dput(R_CFG, replen & 255); dput(R_CFG, replen >> 8);
   end
endtask

task mk_ep;
   input integer addr;
   input integer mps;
   input integer interval;
   begin
      dput(R_CFG, 7); dput(R_CFG, 5); dput(R_CFG, addr); dput(R_CFG, 3);
      dput(R_CFG, mps & 255); dput(R_CFG, mps >> 8); dput(R_CFG, interval);
   end
endtask

task cfg_done;
   begin
      dmem[R_CFG*256 + 2] = rlen[R_CFG] & 255;
      dmem[R_CFG*256 + 3] = rlen[R_CFG] >> 8;
      parse_cfg;
   end
endtask

task mk_str;                                // ASCII text -> UTF-16LE string descriptor
   input integer          r;
   input integer          n;
   input [8*32-1:0]       s;                // n characters, right-aligned
   integer                k;
   begin
      dput(r, 2 + 2*n); dput(r, 3);
      for (k = n - 1; k >= 0; k = k - 1) begin dput(r, s[8*k +: 8]); dput(r, 0); end
   end
endtask

task rep_kbd;     input integer r; dputv(r, 63, 504'h05010906A101050719E029E71500250175019508810295017508810195057501050819012905910295017503910195067508150025650507190029658100C0); endtask
task rep_mouse;   input integer r; dputv(r, 52, 416'h05010902A1010901A1000509190129031500250195037501810295017505810105010930093109381581257F750895038106C0C0); endtask
task rep_pad;     input integer r; dputv(r, 101, 808'h05010904A101A10275089505150026FF00350046FF00093009310932093209358102750495012507463B0165140939814265007501950C2501450105091901290C81020600FF750195082501450109018102C0A1027508950746FF0026FF0009029102C0C0); endtask
task rep_cons;    input integer r; dputv(r, 23, 184'h050C0901A101150026FF0319002AFF03751095018100C0); endtask

// Walk the configuration descriptor into the interface / endpoint tables
task parse_cfg;
   integer off, bl, ty, total, cur, base, a;
   begin : pc
      nif = 0; nep = 0; cur = -1;
      base = R_CFG * 256;
      total = rlen[R_CFG];
      cfg_value = (total > 5) ? dmem[base + 5] : 0;
      off = 0;
      while ((off + 1) < total)
        begin
           bl = dmem[base + off];
           ty = dmem[base + off + 1];
           if (bl == 0) disable pc;
           if ((ty == 4) && (nif < 8) && ((off + 8) < total))
             begin
                if_num[nif] = dmem[base + off + 2];
                if_alt[nif] = dmem[base + off + 3];
                if_cls[nif] = dmem[base + off + 5];
                if_sub[nif] = dmem[base + off + 6];
                if_pro[nif] = dmem[base + off + 7];
                if_hid[nif] = -1;
                cur = nif;
                nif = nif + 1;
             end
           else if ((ty == 8'h21) && (cur >= 0))
             begin
                if (if_hid[cur] < 0) if_hid[cur] = off;
             end
           else if ((ty == 5) && (cur >= 0) && (nep < 8) && ((off + 6) < total))
             begin
                a           = dmem[base + off + 2];
                ep_num[nep] = a & 15;
                ep_in[nep]  = (a >= 128);
                ep_attr[nep]= dmem[base + off + 3];
                ep_mps[nep] = dmem[base + off + 4] + 256 * dmem[base + off + 5];
                ep_ifx[nep] = cur;
                nep = nep + 1;
             end
           off = off + bl;
        end
   end
endtask

task load_profile;
   input integer p;
   integer k;
   begin
      desc_clear;
      for (k = 0; k < 4; k = k + 1) begin idle_dat[k] = 64'h0; idle_len[k] = 8; end
      prof    = p;
      prof_fs = (p == P_FS);
      dput(R_STR0, 4); dput(R_STR0, 3); dput(R_STR0, 8'h09); dput(R_STR0, 8'h04);   // LANGID 0x0409
      mk_str(R_STR1, 6, "aRVern");
      mk_str(R_STR2, 13, "LS test model");
      case (p)
        P_MOUSE:
          begin
             mk_dev(0, 16'h1209, 16'h0002);
             mk_cfg(1); mk_if(0, 0, 1, 3, 1, 2); mk_hid(52); mk_ep(8'h81, 4, 10); cfg_done;
             rep_mouse(R_REP0);
          end
        P_GAMEPAD:
          begin
             // DragonRise-style SNES pad: X, Y, 00, 80, 80, {Y B A X, hat F}, {.. Start Select .. R L}, 00
             mk_dev(0, 16'h0079, 16'h0011);
             mk_cfg(1); mk_if(0, 0, 1, 3, 0, 0); mk_hid(101); mk_ep(8'h81, 8, 10); cfg_done;
             rep_pad(R_REP0);
             idle_len[1] = 8;
             idle_dat[1] = 64'h0000_0F80_8000_7F7F;
          end
        P_COMPOSITE:
          begin
             mk_dev(0, 16'h1209, 16'h0003);
             mk_cfg(2);
             mk_if(0, 0, 1, 3, 1, 1); mk_hid(63); mk_ep(8'h81, 8, 10);
             mk_if(1, 0, 1, 3, 0, 0); mk_hid(23); mk_ep(8'h82, 4, 10);
             cfg_done;
             rep_kbd(R_REP0); rep_cons(R_REP1);
          end
        P_HUB:
          begin
             mk_dev(9, 16'h1209, 16'h0004);
             mk_cfg(1); mk_if(0, 0, 1, 9, 0, 0); mk_ep(8'h81, 1, 255); cfg_done;
          end
        P_VENDOR:
          begin
             mk_dev(8'hFF, 16'h1209, 16'h0005);
             mk_cfg(1); mk_if(0, 0, 1, 8'hFF, 0, 0); mk_ep(8'h81, 8, 10); cfg_done;
          end
        P_ALT_FIRST:
          begin
             mk_dev(0, 16'h1209, 16'h0006);
             mk_cfg(1);
             mk_if(0, 1, 1, 3, 0, 0); mk_hid(63); mk_ep(8'h82, 8, 10);
             mk_if(0, 0, 1, 3, 1, 1); mk_hid(63); mk_ep(8'h81, 8, 10);
             cfg_done;
             rep_kbd(R_REP0);
          end
        P_TOTAL8:
          begin
             mk_dev(0, 16'h1209, 16'h0007);
             mk_cfg(1); mk_if(0, 0, 1, 3, 1, 1); mk_hid(63); mk_ep(8'h81, 8, 10);
             dput(R_CFG, 6); dput(R_CFG, 8'h24); dput(R_CFG, 0); dput(R_CFG, 0); dput(R_CFG, 0); dput(R_CFG, 0);
             cfg_done;                      // 40 bytes: five full packets, then a ZLP
             rep_kbd(R_REP0);
          end
        P_MPS0, P_MPS_BIG, P_BINT0:
          begin
             mk_dev(0, 16'h1209, 16'h0008 + p - P_MPS0);
             mk_cfg(1); mk_if(0, 0, 1, 3, 1, 1); mk_hid(63);
             mk_ep(8'h81, (p == P_MPS0) ? 0 : (p == P_MPS_BIG) ? 16 : 8, (p == P_BINT0) ? 0 : 10);
             cfg_done;
             rep_kbd(R_REP0);
          end
        default:                            // P_KBD, P_FS
          begin
             mk_dev(0, 16'h1209, 16'h0001);
             mk_cfg(1); mk_if(0, 0, 1, 3, 1, 1); mk_hid(63); mk_ep(8'h81, 8, 10); cfg_done;
             rep_kbd(R_REP0);
          end
      endcase
   end
endtask

// Interface table index of interface number n, alternate setting a (-1: none)
function integer find_if;
   input integer n;
   input integer a;
   integer k;
   begin
      find_if = -1;
      for (k = nif - 1; k >= 0; k = k - 1)
        if ((if_num[k] == n) && (if_alt[k] == a)) find_if = k;
   end
endfunction

// Endpoint table index of IN endpoint e in the current configuration (-1: none)
function integer ep_lookup;
   input integer e;
   integer k, x;
   begin
      ep_lookup = -1;
      if (cur_cfg != 0)
        for (k = nep - 1; k >= 0; k = k - 1)
          begin
             x = ep_ifx[k];
             if ((ep_num[k] == e) && ep_in[k] && ((ep_attr[k] & 3) == 3) &&
                 (if_num[x] < 8) && (if_alt[x] == cur_alt[if_num[x]]))
               ep_lookup = k;
          end
   end
endfunction

//=============================================================================
// 5)  BENCH TASKS
//=============================================================================

function [8*8-1:0] fault_name;
   input integer k;
   case (k)
     F_NAK:      fault_name = "NAK";
     F_STALL:    fault_name = "STALL";
     F_SILENT:   fault_name = "SILENT";
     F_CRC:      fault_name = "CRC";
     F_STUFF:    fault_name = "STUFF";
     F_PID:      fault_name = "PID";
     F_TOGGLE:   fault_name = "TOGGLE";
     F_OVERLONG: fault_name = "OVERLONG";
     F_BABBLE:   fault_name = "BABBLE";
     F_HOLD_J:   fault_name = "HOLD_J";
     F_HOLD_K:   fault_name = "HOLD_K";
     F_DETACH:   fault_name = "DETACH";
     F_LATE:     fault_name = "LATE";
     default:    fault_name = "NONE";
   endcase
endfunction

// Device protocol state back to "address 0, not configured, pipes idle"
task dev_proto_clear;
   integer k, x;
   begin
      dev_addr      = 7'd0;
      addr_ready_t  = 0.0;
      addr_chg_pend = 1'b0;
      cur_cfg       = 0;
      for (k = 0; k < 8; k = k + 1)
        begin
           cur_alt[k]   = 0;
           hid_proto[k] = 1;                // report protocol (HID 7.2.6)
           x            = find_if(k, 0);
           hid_idle[k]  = ((x >= 0) && (if_sub[x] == 1) && (if_pro[x] == 1)) ? 125 : 0;
        end
      for (k = 0; k < 4; k = k + 1)
        begin
           ep_tgl[k]  = 0;
           ep_halt[k] = 1'b0;
        end
      ctl_active   = 1'b0;
      ctl_stage    = CS_NONE;
      ctl_stall    = 1'b0;
      out_ack_lost = 1'b0;
      ctl_trouble  = 1'b0;
      xs           = XS_IDLE;
      susp_q       = 1'b0;
   end
endtask

task attach;
   input integer p;
   begin : att
      if (pu_on)
        begin
           $sformat(mb, "attach ignored: already attached"); vlog(1);
           disable att;
        end
      if (p >= 0) load_profile(p);
      dev_proto_clear;
      st_dev     = DS_ATTACHED;
      rst_active = 1'b0;
      ka_armed   = 1'b0;
      ka_pend    = 1'b0;
      rx_mode    = RX_IDLE;
      det_flag   = 1'b0;
      last_ev    = LE_NONE; ev_tgl = ~ev_tgl;
      pu_fs      = prof_fs;
      attach_t   = $realtime;
      dev_evt_t  = $realtime;
      pu_on      = 1'b1;
      $sformat(mb, "attach, profile %0d%0s", prof, prof_fs ? " (full-speed pull-up on D+, silent)" : "");
      vlog(1);
   end
endtask

task detach;
   begin : det
      if (!pu_on) disable det;
      dev_evt_t     = $realtime;
      detach_t      = $realtime;
      drv_en        = 1'b0;
      resume_active = 1'b0;
      pu_on         = 1'b0;
      dev_proto_clear;
      st_dev        = DS_DETACHED;
      rst_active    = 1'b0;
      ka_armed      = 1'b0;
      ka_pend       = 1'b0;
      rx_mode       = RX_IDLE;
      $sformat(mb, "detach"); vlog(1);
   end
endtask

task push_report_ep;
   input integer    ep;
   input integer    len;
   input [63:0]     data;
   integer          k;
   begin : pr
      if ((ep < 1) || (ep > 3) || (len < 0) || (len > 8))
        begin
           $display("[%0t] %0s: push_report_ep(%0d, %0d) out of range, ignored", $time, NAME, ep, len);
           disable pr;
        end
      if (rf_cnt[ep] >= RFD)
        begin
           $display("[%0t] %0s: report FIFO of EP%0d full, report dropped", $time, NAME, ep);
           disable pr;
        end
      k         = ep * RFD + rf_wr[ep];
      rf_dat[k] = data;
      rf_len[k] = len;
      rf_wr[ep] = (rf_wr[ep] + 1) % RFD;
      rf_cnt[ep]= rf_cnt[ep] + 1;
      $sformat(mb, "report queued on EP%0d: %0d bytes %h (%0d queued)", ep, len, data, rf_cnt[ep]); vlog(2);
   end
endtask

task push_report;
   input integer    len;
   input [63:0]     data;
   push_report_ep(1, len, data);
endtask

task flush_reports;
   integer k;
   begin
      for (k = 0; k < 4; k = k + 1)
        begin
           rf_rd[k] = 0; rf_wr[k] = 0; rf_cnt[k] = 0; rl_ok[k] = 1'b0;
        end
   end
endtask

task set_repeat_last;
   input integer en;
   repeat_last = (en != 0);
endtask

task set_rate_ppm;
   input integer ppm;
   begin
      if ((ppm > 15000) || (ppm < -15000))
        $display("[%0t] %0s: rate offset %0d ppm is outside the device tolerance (+-15000)", $time, NAME, ppm);
      rate_ppm = ppm;
   end
endtask

task set_resp_delay;                        // 1/100 bit times
   input integer dmin;
   input integer dmax;
   begin
      dly_min = (dmin < dmax) ? dmin : dmax;
      dly_max = (dmin < dmax) ? dmax : dmin;
      if ((dly_min < 200) || (dly_max > 650))
        $display("[%0t] %0s: response delay %0d..%0d/100 bit outside 2..6.5 bit times", $time, NAME, dly_min, dly_max);
   end
endtask

task set_addr_recovery;                     // not clamped: > 2 ms is a fault case
   input integer ns;
   begin
      if (ns > 2000000)
        $display("[%0t] %0s: SET_ADDRESS recovery %0d ns exceeds the 2 ms a device may take", $time, NAME, ns);
      addr_rcy_ns = ns;
   end
endtask

task set_seed;
   input integer s;
   seed = s;
endtask

task set_verbosity;
   input integer v;
   verbose = v;
endtask

// kind F_*; tok T_*; ep -1 any; req bRequest (-1 any, EP0 only); dtype wValue[15:8]
// (-1 any, EP0 only); stage ST_* (-1 any, EP0 only); the rule fires on matching
// occurrences skip+1 .. skip+count (count -1: forever); arg: F_OVERLONG bytes,
// F_BABBLE us, F_HOLD_* frames (ms), F_DETACH bit index, F_LATE 1/100 bit
task inject_fault;
   input integer kind;
   input integer tok;
   input integer ep;
   input integer req;
   input integer dtype;
   input integer stage;
   input integer skip;
   input integer count;
   input integer arg;
   integer i, slot;
   begin : inj
      slot = -1;
      for (i = NFR - 1; i >= 0; i = i - 1)
        if (fr_kind[i] == F_NONE) slot = i;
      if (slot < 0)
        begin
           $display("[%0t] %0s: inject_fault: no free rule (max %0d)", $time, NAME, NFR);
           disable inj;
        end
      fr_kind[slot]  = kind;  fr_tok[slot]   = tok;   fr_ep[slot]  = ep;
      fr_req[slot]   = req;   fr_dtype[slot] = dtype; fr_stage[slot] = stage;
      fr_skip[slot]  = skip;  fr_cnt[slot]   = count; fr_arg[slot] = arg;
      fr_occ[slot]   = 0;     fr_hits[slot]  = 0;
      $sformat(mb, "fault rule %0d: %0s tok %0d ep %0d req %0d dtype %0d stage %0d skip %0d count %0d arg %0d",
               slot, fault_name(kind), tok, ep, req, dtype, stage, skip, count, arg);
      vlog(1);
   end
endtask

task clear_faults;
   integer i;
   for (i = 0; i < NFR; i = i + 1) fr_kind[i] = F_NONE;
endtask

task chk_enable;
   input integer id;
   input integer en;
   chk_en[id] = (en != 0);
endtask

task chk_clear;
   integer i;
   begin
      for (i = 0; i < NCHK; i = i + 1) chk_cnt[i] = 0;
      err_total    = 0;
      st_jit_next  = 0.0; st_jit_pair = 0.0; st_rate_max = 0.0; st_rate_sum = 0.0; st_rate_span = 0.0;
      st_host_pkts = 0;   st_ka_max   = 0.0; st_backoffs = 0;   st_resets   = 0;   st_coll      = 0;
      st_susp      = 0;   st_xfer_start = 0; st_xfer_done = 0;  st_faults   = 0;
      st_xfer_start_t = 0.0; ctl_progress_t = 0.0;
      st_ipd_n     = 0;   st_ipd_min  = 1.0e9; st_ipd_max = 0.0;
      for (i = 0; i < 8; i = i + 1) st_rst_len[i] = 0.0;
   end
endtask

// Device resume signalling: K on an idle bus for ms milliseconds (USB 2.0
// 7.1.7.7: 1..15 ms), then release. Blocks the caller.
task drive_resume;
   input integer ms;
   begin : dr
      if (!pu_on || pu_fs) disable dr;
      while (tx_busy || (ls_state != L_J)) #(BIT_NS);
      tx_busy       = 1'b1;
      resume_active = 1'b1;
      $sformat(mb, "device resume K for %0d ms", ms); vlog(1);
      drive_ls(L_K);
      #(ms * 1.0e6);
      if (pu_on)
        begin
           dev_evt_t = $realtime;
           drv_en    = 1'b0;
        end
      resume_active = 1'b0;
      tx_busy       = 1'b0;
   end
endtask

task drive_ls;
   input [2:0] s;
   begin
      dev_evt_t = $realtime;
      drv_dp    = (s == L_K);
      drv_dm    = (s == L_J);
      drv_en    = 1'b1;
   end
endtask

//=============================================================================
// 6)  LINE MONITOR AND HOST PACKET DECODER
//=============================================================================

initial
  begin : monitor
     reg  [2:0] nst;
     real       tc;
     #1;
     ls_state = ls_now(dp, dm);
     ls_prev  = ls_state;
     ls_t     = $realtime;
     ls_dev   = 1'b1;
     forever
       begin
          if (ls_now(dp, dm) == ls_state) @(dp or dm);
          tc = $realtime;
          #(LS_SETTLE);
          nst = ls_now(dp, dm);
          if (nst != ls_state) on_line_change(tc, nst);
       end
  end

task on_line_change;
   input real    t;
   input [2:0]   nst;
   reg   [2:0]   ps;
   real          dur;
   reg           devc;
   begin : olc
      ps       = ls_state;
      dur      = t - ls_t;
      devc     = drv_en || (fabs(t - dev_evt_t) < 1.0);
      ls_prev  = ps;
      ls_state = nst;
      ls_t     = t;
      ls_dev   = devc;
      if (verbose >= 3)
        $display("[%0t] %0s: line %0s -> %0s after %0.1f ns (%0s)", $time, NAME, ls_name(ps), ls_name(nst),
                 dur, devc ? "device" : "host");
      if (susp_q && pu_on)
        begin
           susp_q = 1'b0;
           $sformat(mb, "resumed by bus activity"); vlog(1);
        end
      if (devc || !pu_on || pu_fs)
        begin
           if ((rx_mode != RX_RST) && (rx_mode != RX_WAIT)) rx_mode = RX_IDLE;
           if (!pu_on) rx_mode = RX_IDLE;
           disable olc;
        end
      case (rx_mode)
        RX_IDLE:   idle_change(t, ps, nst, dur);
        RX_PKT:    pkt_change(t, ps, nst, dur);
        RX_EOP,
        RX_SE0:    se0_change(t, ps, nst, dur);
        RX_RST:    rst_change(t, ps, nst, dur);
        RX_RESUME:
          if (nst == L_SE0)
            begin
               rx_mode    = RX_SE0;
               rx_se0_t   = t;
               hs_idle    = 1.0e9;
               hs_prev_ev = LE_NONE;
               if (ka_armed) ka_last = t;   // the resume K was bus activity
            end
          else
            begin
               $sformat(mb, "host resume K ended by %0s, not by an EOP", ls_name(nst)); cerr(C_EOP);
               rx_mode = RX_WAIT;
            end
        RX_WAIT:
          if (nst == L_SE0)
            begin
               rx_mode    = RX_SE0;
               rx_se0_t   = t;
               hs_idle    = 1.0e9;
               hs_prev_ev = LE_NONE;
               ka_note_se0(t);
            end
        default:   rx_mode = RX_IDLE;
      endcase
   end
endtask

// Host change while the bus is idle
task idle_change;
   input real    t;
   input [2:0]   ps;
   input [2:0]   nst;
   input real    dur;
   begin
      if ((ps == L_J) && (nst == L_K))
        begin
           host_start_pkt(t, dur);
           rx_begin(t);
           ka_note_se0(t);
        end
      else if ((nst == L_SE0) && ((ps == L_J) || (ps == L_K)))
        begin
           // keep-alive, bus reset, or the EOP closing a resume K
           hs_idle    = (ps == L_J) ? dur : 1.0e9;
           hs_prev_ev = last_ev;
           hs_prev_t  = last_ev_t;
           rx_mode    = RX_SE0;
           rx_se0_t   = t;
           ka_note_se0(t);
        end
      else
        begin
           $sformat(mb, "host line change %0s -> %0s outside a packet", ls_name(ps), ls_name(nst));
           cerr(C_PROTO);
           rx_mode = RX_WAIT;
        end
   end
endtask

task rx_begin;
   input real t;
   begin
      rx_mode      = RX_PKT;
      rx_n         = 0;
      rx_ones      = 0;
      rx_stuff_err = 1'b0;
      rx_stuff_pos = 0;
      rx_cell      = 0;
      rx_ne        = 0;
      rx_sop_t     = t;
      rx_prev_ev   = last_ev;
      rx_prev_t    = last_ev_t;
      add_edge(t);
   end
endtask

task add_edge;
   input real t;
   begin
      if (rx_ne < 256)
        begin
           rx_et[rx_ne] = t;
           rx_ec[rx_ne] = rx_cell;
           rx_ne        = rx_ne + 1;
        end
   end
endtask

// Unstuff one decoded bit
task rx_emit;
   input b;
   begin
      if (rx_ones == 6)
        begin
           if (b == 1'b0)
             rx_ones = 0;                   // stuffed bit, dropped
           else
             begin
                if (!rx_stuff_err)
                  begin
                     rx_stuff_err = 1'b1;
                     rx_stuff_pos = rx_n;
                  end
                rx_ones = 7;
                if (rx_n < 1024) rxb[rx_n] = b;
                rx_n = rx_n + 1;
             end
        end
      else
        begin
           if (rx_n < 1024) rxb[rx_n] = b;
           rx_n    = rx_n + 1;
           rx_ones = b ? rx_ones + 1 : 0;
        end
   end
endtask

// A line state of dur ns ended: 0 for its opening transition, 1 for each further cell
task rx_cells;
   input real dur;
   integer    n, k;
   begin
      n = rnd(dur / BIT_NS);
      if (n < 1)  n = 1;
      if (n > 64) n = 64;
      rx_emit(1'b0);
      for (k = 1; k < n; k = k + 1) rx_emit(1'b1);
      rx_cell = rx_cell + n;
   end
endtask

task pkt_change;
   input real    t;
   input [2:0]   ps;
   input [2:0]   nst;
   input real    dur;
   begin
      if (((nst == L_J) || (nst == L_K)) && ((ps == L_J) || (ps == L_K)))
        begin
           rx_cells(dur);
           add_edge(t);
        end
      else if ((nst == L_SE0) && ((ps == L_J) || (ps == L_K)))
        begin
           rx_cells(dur);
           add_edge(t);                     // SE0 start: rate fit only
           rx_se0_t = t;
           rx_mode  = RX_EOP;
        end
      else
        begin
           $sformat(mb, "host packet broken by %0s after %0d bits", ls_name(nst), rx_n); cerr(C_PID);
           ka_close(t);
           host_bad(t);
           rx_mode = RX_WAIT;
        end
   end
endtask

// End of an SE0 (packet EOP, keep-alive, or the EOP closing a resume)
task se0_change;
   input real    t;
   input [2:0]   ps;
   input [2:0]   nst;
   input real    dur;
   integer       m;
   begin
      last_se0_len = dur;
      if (nst == L_J)
        begin
           if ((dur < 1250.0) || (dur > 1500.0))
             begin
                $sformat(mb, "host EOP SE0 of %0.1f ns (TLEOPT 1250-1500 ns)", dur); cerr(C_EOP);
             end
           ka_close(t);
           m = rx_mode;
           rx_mode = RX_IDLE;
           if (m == RX_SE0)
             begin
                if (hs_idle < (2.0 * BIT_NS - TOL_NS))
                  begin
                     $sformat(mb, "keep-alive started after %0.2f bit times of J (min 2)", hs_idle / BIT_NS);
                     cerr(C_IDLE);
                  end
                timeout_check(rx_se0_t, hs_prev_ev, hs_prev_t, "keep-alive");
                last_ev   = LE_KA; ev_tgl = ~ev_tgl;
                last_ev_t = t;
                $sformat(mb, "host keep-alive (SE0 %0.1f ns)", dur); vlog(2);
             end
           else
             rx_finish(t);
        end
      else
        begin
           $sformat(mb, "host SE0 followed by %0s, not J", ls_name(nst)); cerr(C_EOP);
           ka_close(t);
           host_bad(t);
           rx_mode = RX_WAIT;
        end
   end
endtask

// End of a bus reset
task rst_change;
   input real    t;
   input [2:0]   ps;
   input [2:0]   nst;
   input real    dur;
   real          len;
   begin
      len          = t - rst_t0;
      last_se0_len = len;
      st_rst_len[(st_resets - 1) % 8] = len;
      if (len < RST_MIN_NS)
        begin
           $sformat(mb, "bus reset of %0.3f ms (min %0.3f ms)", len / 1.0e6, RST_MIN_NS / 1.0e6); cerr(C_RESET);
        end
      $sformat(mb, "bus reset end after %0.3f ms", len / 1.0e6); vlog(1);
      rst_active = 1'b0;
      ka_armed   = 1'b1;
      ka_last    = t;
      ka_pend    = 1'b0;
      last_ev    = LE_RESET; ev_tgl = ~ev_tgl;
      last_ev_t  = t;
      rx_mode    = (nst == L_J) ? RX_IDLE : RX_WAIT;
   end
endtask

// Bus reset recognised (2.5 us of host SE0)
task reset_seen;
   begin
      rst_active = 1'b1;
      rst_t0     = ls_t;
      st_resets  = st_resets + 1;
      if (ka_pend)
        begin
           ka_pend = 1'b0;
           if (ka_pend_gap > KA_GAP_MAX_NS)
             begin
                st_backoffs = st_backoffs + 1;
                $sformat(mb, "host back-off: %0.3f ms without activity before this reset", ka_pend_gap / 1.0e6);
                vlog(1);
             end
        end
      ka_armed = 1'b0;
      rx_mode  = RX_RST;
      $sformat(mb, "bus reset seen (%0d)", st_resets); vlog(1);
      dev_bus_reset;
   end
endtask

// Host activity point: the start of a packet (SOP) or of a keep-alive SE0
task ka_note_se0;
   input real t;
   begin
      if (ka_armed)
        begin
           ka_pend_gap = t - ka_last;
           ka_pend     = 1'b1;
           ka_last     = t;
        end
   end
endtask

task ka_close;
   input real t;
   begin
      if (ka_pend)
        begin
           ka_pend = 1'b0;
           if (ka_pend_gap > st_ka_max) st_ka_max = ka_pend_gap;
           if (ka_pend_gap > KA_GAP_MAX_NS)
             begin
                $sformat(mb, "no host activity for %0.3f ms (keep-alive, max %0.3f ms)",
                         ka_pend_gap / 1.0e6, KA_GAP_MAX_NS / 1.0e6);
                cerr(C_KEEPALIVE);
             end
        end
   end
endtask

//=============================================================================
// 7)  HOST PACKET CHECKS
//=============================================================================

// Start of a host packet (SOP): bus idle and response timeout
task host_start_pkt;
   input real t;
   input real jdur;
   begin
      if (jdur < (2.0 * BIT_NS - TOL_NS))
        begin
           $sformat(mb, "host packet started after %0.2f bit times of J (min 2)", jdur / BIT_NS); cerr(C_IDLE);
        end
      timeout_check(t, last_ev, last_ev_t, "packet");
   end
endtask

// A host transmission starting at t after an unanswered IN token or data packet
task timeout_check;
   input real          t;
   input integer       pev;
   input real          pt;
   input [8*10-1:0]    what;
   begin
      if (((pev == LE_HTOK_IN) || (pev == LE_HDATA)) && ((t - pt) < (18.0 * BIT_NS - TOL_NS)))
        begin
           $sformat(mb, "host %0s %0.2f bit times after an unanswered %0s (response timeout >= 18)",
                    what, (t - pt) / BIT_NS, (pev == LE_HTOK_IN) ? "IN token" : "data packet");
           cerr(C_TIMEOUT);
        end
   end
endtask

task ipd_check;
   input real          d;
   input [8*28-1:0]    what;
   begin
      st_ipd_n = st_ipd_n + 1;
      if (d < st_ipd_min) st_ipd_min = d;
      if (d > st_ipd_max) st_ipd_max = d;
      if ((d < (2.0 * BIT_NS - TOL_NS)) || (d > (7.5 * BIT_NS + TOL_NS)))
        begin
           $sformat(mb, "host %0s after %0.2f bit times (2 to 7.5)", what, d / BIT_NS); cerr(C_IPD);
        end
      else if (verbose >= 3)
        $display("[%0t] %0s: host %0s after %0.2f bit times", $time, NAME, what, d / BIT_NS);
   end
endtask

// Bit rate (least-squares fit of edge time against cell index, SOP to SE0
// start) and edge jitter (differential transitions, SE0 start excluded)
task rate_jitter_check;
   integer k, n;
   real    sx, sy, sxx, sxy, x, y, den, slope, span, ppm, lim, d, jn, jp;
   begin
      n = rx_ne;
      if (n >= 3)
        begin
           sx = 0.0; sy = 0.0; sxx = 0.0; sxy = 0.0;
           for (k = 0; k < n; k = k + 1)
             begin
                x   = rx_ec[k];
                y   = rx_et[k] - rx_et[0];
                sx  = sx + x;  sy = sy + y;
                sxx = sxx + x * x;  sxy = sxy + x * y;
             end
           den = n * sxx - sx * sx;
           if (den > 0.0)
             begin
                slope = (n * sxy - sx * sy) / den;
                span  = rx_ec[n-1] * BIT_NS;
                ppm   = (BIT_NS - slope) / slope * 1.0e6;     // positive: host faster than 1.5 Mb/s
                lim   = RATE_TOL_PPM + 3.0 * RATE_GRID_NS / span * 1.0e6;
                if (fabs(ppm) > st_rate_max) st_rate_max = fabs(ppm);
                st_rate_sum  = st_rate_sum + ppm * span;
                st_rate_span = st_rate_span + span;
                if (fabs(ppm) > lim)
                  begin
                     $sformat(mb, "host bit rate %0.0f ppm over a %0d-bit packet (limit %0.0f ppm)", ppm, rx_ec[n-1], lim);
                     cerr(C_RATE);
                  end
             end
        end
      jn = 0.0; jp = 0.0;
      for (k = 1; k < n - 1; k = k + 1)
        begin
           d = fabs((rx_et[k] - rx_et[k-1]) - (rx_ec[k] - rx_ec[k-1]) * BIT_NS);
           if (d > jn) jn = d;
           if (k >= 2)
             begin
                d = fabs((rx_et[k] - rx_et[k-2]) - (rx_ec[k] - rx_ec[k-2]) * BIT_NS);
                if (d > jp) jp = d;
             end
        end
      if (jn > st_jit_next) st_jit_next = jn;
      if (jp > st_jit_pair) st_jit_pair = jp;
      if (jn > JIT_NEXT_NS)
        begin
           $sformat(mb, "host consecutive-transition jitter %0.1f ns (max %0d)", jn, JIT_NEXT_NS); cerr(C_JITTER);
        end
      if (jp > JIT_PAIR_NS)
        begin
           $sformat(mb, "host paired-transition jitter %0.1f ns (max %0d)", jp, JIT_PAIR_NS); cerr(C_JITTER);
        end
      if (verbose >= 3)
        $display("[%0t] %0s: host packet %0d cells, jitter next %0.1f / paired %0.1f ns", $time, NAME,
                 (n > 0) ? rx_ec[n-1] : 0, jn, jp);
   end
endtask

// A host packet failed its checks: the device ignores it
task host_bad;
   input real t;
   begin
      last_ev   = LE_HBAD; ev_tgl = ~ev_tgl;
      last_ev_t = t;
      if (xs == XS_IN_HS)
        begin
           $sformat(mb, "no valid handshake for the data on EP%0d: kept for retransmission", xs_ep); vlog(2);
        end
      xs = XS_IDLE;
   end
endtask

// Host packet complete (EOP SE0 -> J at t): framing, PID, CRC, dispatch
task rx_finish;
   input real    t;
   integer       nbytes, k, i, plen;
   reg   [3:0]   pid, pck;
   reg   [4:0]   c5, r5;
   reg  [15:0]   c16, r16;
   reg           fb, ok;
   reg   [6:0]   addr;
   reg   [3:0]   ep;
   begin : rf
      st_host_pkts = st_host_pkts + 1;
      rate_jitter_check;
      ok = 1'b1;
      if (rx_stuff_err)
        begin
           $sformat(mb, "bit-stuffing violation in a host packet (bit %0d)", rx_stuff_pos); cerr(C_STUFF);
           ok = 1'b0;
        end
      if ((rx_n < 16) || (rx_n > 1024) || (((rx_n - 8) % 8) != 0))
        begin
           $sformat(mb, "host packet of %0d bits after unstuffing: not sync + whole bytes", rx_n); cerr(C_PID);
           ok = 1'b0;
        end
      else if ({rxb[7], rxb[6], rxb[5], rxb[4], rxb[3], rxb[2], rxb[1], rxb[0]} != 8'b1000_0000)
        begin
           $sformat(mb, "host packet with a bad sync pattern"); cerr(C_PID);
           ok = 1'b0;
        end
      if (!ok)
        begin
           host_bad(t);
           disable rf;
        end
      pid = {rxb[11], rxb[10], rxb[9],  rxb[8]};
      pck = {rxb[15], rxb[14], rxb[13], rxb[12]};
      if (pck != ~pid)
        begin
           $sformat(mb, "host PID %b with check bits %b", pid, pck); cerr(C_PID);
           host_bad(t);
           disable rf;
        end
      nbytes = (rx_n - 16) / 8;
      for (k = 0; (k < nbytes) && (k < 64); k = k + 1)
        for (i = 0; i < 8; i = i + 1)
          rxd[k][i] = rxb[16 + 8*k + i];
      case (pid)
        P_OUT, P_IN, P_SETUP, P_SOF:
          begin
             if (nbytes != 2)
               begin
                  $sformat(mb, "host %0s token with %0d bytes", pid_name(pid), nbytes); cerr(C_PID);
                  host_bad(t);
                  disable rf;
               end
             c5 = 5'h1F;
             for (i = 0; i < 11; i = i + 1)
               begin
                  fb = rxb[16 + i] ^ c5[4];
                  c5 = {c5[3:0], 1'b0} ^ (fb ? 5'b00101 : 5'b00000);
               end
             for (i = 0; i < 5; i = i + 1) r5[4-i] = rxb[27 + i];
             if (r5 != ~c5)
               begin
                  $sformat(mb, "host %0s token CRC5 %b, expected %b", pid_name(pid), r5, ~c5); cerr(C_CRC);
                  host_bad(t);
                  disable rf;
               end
             addr = rxd[0][6:0];
             ep   = {rxd[1][2:0], rxd[0][7]};
             host_token(pid, addr, ep, t);
          end
        P_DATA0, P_DATA1:
          begin
             if (nbytes < 2)
               begin
                  $sformat(mb, "host %0s packet with %0d bytes (no CRC16)", pid_name(pid), nbytes); cerr(C_PID);
                  host_bad(t);
                  disable rf;
               end
             plen = nbytes - 2;
             c16  = 16'hFFFF;
             for (i = 0; i < 8 * plen; i = i + 1)
               begin
                  fb  = rxb[16 + i] ^ c16[15];
                  c16 = {c16[14:0], 1'b0} ^ (fb ? 16'h8005 : 16'h0000);
               end
             for (i = 0; i < 16; i = i + 1) r16[15-i] = rxb[16 + 8*plen + i];
             if (r16 != ~c16)
               begin
                  $sformat(mb, "host %0s CRC16 %h, expected %h", pid_name(pid), r16, ~c16); cerr(C_CRC);
                  host_bad(t);
                  disable rf;
               end
             host_data(pid, plen, t);
          end
        P_ACK, P_NAK, P_STALL, P_NYET:
          begin
             if (nbytes != 0)
               begin
                  $sformat(mb, "host %0s handshake with %0d extra bytes", pid_name(pid), nbytes); cerr(C_PID);
                  host_bad(t);
                  disable rf;
               end
             host_hs(pid, t);
          end
        default:
          begin
             $sformat(mb, "host PID %0s is not used at low speed", pid_name(pid)); cerr(C_PROTO);
             host_bad(t);
          end
      endcase
   end
endtask

task host_token;
   input [3:0]   pid;
   input [6:0]   addr;
   input [3:0]   ep;
   input real    t;
   begin : ht
      $sformat(mb, "host %0s addr %0d ep %0d", pid_name(pid), addr, ep); vlog(2);
      if (pid == P_SOF)
        begin
           $sformat(mb, "SOF token sent to a low-speed device"); cerr(C_PROTO);
           last_ev   = LE_HTOK_OTHER; ev_tgl = ~ev_tgl;
           last_ev_t = t;
           xs        = XS_IDLE;
           disable ht;
        end
      // Host side: the address of every token
      if (addr_chg_pend && (rx_sop_t < (addr_chg_t + SETADDR_RCY_NS)))
        begin
           $sformat(mb, "%0s token to address %0d %0.3f ms after the SET_ADDRESS status stage (recovery %0.1f ms)",
                    pid_name(pid), addr, (rx_sop_t - addr_chg_t) / 1.0e6, SETADDR_RCY_NS / 1.0e6);
           cerr(C_ADDR);
        end
      else
        begin
           addr_chg_pend = 1'b0;
           if (addr != dev_addr)
             begin
                $sformat(mb, "%0s token to address %0d, device address %0d", pid_name(pid), addr, dev_addr); cerr(C_ADDR);
             end
        end
      last_ev   = (pid == P_IN) ? LE_HTOK_IN : (pid == P_OUT) ? LE_HTOK_OUT : LE_HTOK_SETUP; ev_tgl = ~ev_tgl;
      last_ev_t = t;
      // Device side
      if (xs == XS_IN_HS)
        begin
           $sformat(mb, "no handshake for the data on EP%0d: kept for retransmission", xs_ep); vlog(2);
        end
      xs = XS_IDLE;
      if ((addr != dev_addr) || ($realtime < addr_ready_t)) disable ht;
      xs_ep = ep;
      case (pid)
        P_SETUP: if (ep == 0) xs = XS_SETUP_DATA;
        P_OUT:   if (ep == 0) xs = XS_OUT_DATA;
        default: dev_in(ep, t);
      endcase
   end
endtask

task host_data;
   input [3:0]   pid;
   input integer plen;
   input real    t;
   integer       k;
   begin
      if (verbose >= 2)
        begin
           $display("[%0t] %0s: host %0s, %0d bytes", $time, NAME, pid_name(pid), plen);
           for (k = 0; (k < plen) && (k < 64); k = k + 1) $write(" %h", rxd[k]);
           if (plen > 0) $write("\n");
        end
      if ((rx_prev_ev == LE_HTOK_OUT) || (rx_prev_ev == LE_HTOK_SETUP))
        ipd_check(rx_sop_t - rx_prev_t, "data packet after its token");
      else
        begin
           $sformat(mb, "host %0s packet not preceded by an OUT or SETUP token", pid_name(pid)); cerr(C_PROTO);
        end
      last_ev   = LE_HDATA; ev_tgl = ~ev_tgl;
      last_ev_t = t;
      if (plen > 8)
        begin
           $sformat(mb, "host data packet of %0d bytes (max 8 at low speed)", plen); cerr(C_PROTO);
        end
      if (xs == XS_SETUP_DATA)    dev_setup_data(pid, plen, t);
      else if (xs == XS_OUT_DATA) dev_out_data(pid, plen, t);
      xs = XS_IDLE;
   end
endtask

task host_hs;
   input [3:0]   pid;
   input real    t;
   begin : hh
      $sformat(mb, "host %0s", pid_name(pid)); vlog(2);
      if (rx_prev_ev == LE_DEV_DATA) ipd_check(rx_sop_t - rx_prev_t, "handshake after device data");
      last_ev   = LE_HHS; ev_tgl = ~ev_tgl;
      last_ev_t = t;
      if (pid != P_ACK)
        begin
           $sformat(mb, "host sent %0s (a host answers device data with ACK or nothing)", pid_name(pid)); cerr(C_PROTO);
           xs = XS_IDLE;
           disable hh;
        end
      if (rx_prev_ev != LE_DEV_DATA)
        begin
           $sformat(mb, "host ACK not after a device data packet"); cerr(C_PROTO);
        end
      if (xs != XS_IN_HS) disable hh;
      xs = XS_IDLE;
      if ((rx_sop_t - dev_eop_end_t) > (DEV_TO_BITS * BIT_NS))
        begin
           $sformat(mb, "ACK %0.2f bit times after the data: device timed out, packet kept",
                    (rx_sop_t - dev_eop_end_t) / BIT_NS);
           vlog(1);
           disable hh;
        end
      if (xs_corrupt)
        begin
           $sformat(mb, "host ACKed a corrupted, overlong or babbling data packet on EP%0d", xs_ep); cerr(C_PROTO);
           disable hh;
        end
      dev_ack;
   end
endtask

//=============================================================================
// 8)  DEVICE PROTOCOL
//=============================================================================

// Fault rules: the first rule whose occurrence window covers this match fires
task fault_match;
   input integer tok;
   input integer ep;
   input integer req;
   input integer dtype;
   input integer stage;
   integer       i;
   reg           m;
   begin
      fz_kind = F_NONE;
      fz_arg  = 0;
      fz_idx  = -1;
      for (i = 0; i < NFR; i = i + 1)
        if (fr_kind[i] != F_NONE)
          begin
             m = ((fr_tok[i]   < 0) || (fr_tok[i] == tok)) &&
                 ((fr_ep[i]    < 0) || (fr_ep[i]  == ep))  &&
                 ((fr_req[i]   < 0) || ((ep == 0) && (fr_req[i]   == req)))   &&
                 ((fr_dtype[i] < 0) || ((ep == 0) && (fr_dtype[i] == dtype))) &&
                 ((fr_stage[i] < 0) || ((ep == 0) && (fr_stage[i] == stage)));
             if (m)
               begin
                  fr_occ[i] = fr_occ[i] + 1;
                  if ((fz_idx < 0) && (fr_occ[i] > fr_skip[i]) &&
                      ((fr_cnt[i] < 0) || (fr_occ[i] <= (fr_skip[i] + fr_cnt[i]))))
                    begin
                       fz_idx     = i;
                       fz_kind    = fr_kind[i];
                       fz_arg     = fr_arg[i];
                       fr_hits[i] = fr_hits[i] + 1;
                    end
               end
          end
   end
endtask

task pick_delay;
   begin
      tx_dly = (dly_min + ({$random(seed)} % (dly_max - dly_min + 1))) / 100.0;
   end
endtask

// Default response: a handshake; callers fill a data packet when needed
task tx_reset_desc;
   begin
      tx_kind       = TK_HS;
      tx_pid        = P_ACK;
      tx_nb         = 0;
      tx_crc_err    = 1'b0;
      tx_stuff_err  = 1'b0;
      tx_pid_err    = 1'b0;
      tx_babble     = 1'b0;
      tx_hold       = 1'b0;
      tx_hold_k     = 1'b0;
      tx_hold_ns    = 0.0;
      tx_detach_bit = -1;
      fz_kind       = F_NONE;
      fz_idx        = -1;
      pick_delay;
   end
endtask

// Apply the matched fault to the prepared response
task apply_fault;
   integer i, n;
   begin
      fx_silent = 1'b0; fx_replaced = 1'b0; fx_corrupt = 1'b0; fx_badtgl = 1'b0;
      case (fz_kind)
        F_NAK:      begin tx_kind = TK_HS; tx_pid = P_NAK;   tx_nb = 0; fx_replaced = 1'b1; end
        F_STALL:    begin tx_kind = TK_HS; tx_pid = P_STALL; tx_nb = 0; fx_replaced = 1'b1; end
        F_SILENT:   fx_silent = 1'b1;
        F_CRC:      begin if (tx_kind == TK_DATA) tx_crc_err = 1'b1; else tx_pid_err = 1'b1; fx_corrupt = 1'b1; end
        F_STUFF:    begin tx_stuff_err = 1'b1; fx_corrupt = 1'b1; end
        F_PID:      begin tx_pid_err = 1'b1; fx_corrupt = 1'b1; end
        F_TOGGLE:   if (tx_kind == TK_DATA) begin tx_pid = tx_pid ^ 4'b1000; fx_badtgl = 1'b1; end
        F_OVERLONG: if (tx_kind == TK_DATA)
                      begin
                         n = (fz_arg > 8) ? fz_arg : 9;
                         if (n > 32) n = 32;
                         for (i = tx_nb; i < n; i = i + 1) txb[i] = 8'hA5 ^ i[7:0];
                         tx_nb      = n;
                         fx_corrupt = 1'b1;
                      end
        F_BABBLE:   begin tx_babble = 1'b1; tx_hold_ns = ((fz_arg > 0) ? fz_arg : 1500) * 1000.0; fx_corrupt = 1'b1; end
        F_HOLD_J,
        F_HOLD_K:   begin
                       tx_hold     = 1'b1;
                       tx_hold_k   = (fz_kind == F_HOLD_K);
                       tx_hold_ns  = ((fz_arg > 0) ? fz_arg : 1) * 1.0e6;
                       fx_replaced = 1'b1;
                    end
        F_DETACH:   begin tx_detach_bit = (fz_arg > 0) ? fz_arg : 12; fx_corrupt = 1'b1; end
        F_LATE:     tx_dly = fz_arg / 100.0;
        default:    ;
      endcase
      if ((fz_kind != F_NONE) && ctl_active) ctl_trouble = 1'b1;
      if (fz_kind != F_NONE)
        begin
           st_faults = st_faults + 1;
           $sformat(mb, "fault rule %0d applied: %0s", fz_idx, fault_name(fz_kind)); vlog(1);
        end
   end
endtask

// Start the transmitter, the response delay counted from the host EOP end t
task launch;
   input real t;
   begin
      tx_t_ref = t;
      if (tx_busy)
        begin
           $sformat(mb, "response dropped: transmitter busy"); vlog(1);
        end
      else
        begin
           if (verbose >= 2)
             $display("[%0t] %0s: device %0s%0s, %0d bytes, after %0.2f bit times", $time, NAME, pid_name(tx_pid),
                      tx_hold ? " (hold)" : tx_babble ? " (babble)" : "", tx_nb, tx_dly);
           if (ctl_active && (tx_kind == TK_HS) && (tx_pid == P_STALL)) ctl_trouble = 1'b1;
           tx_busy = 1'b1;
           -> tx_go;
        end
   end
endtask

// IN token for this device
task dev_in;
   input integer ep;
   input real    t;
   integer       k, n, ix, i, stage;
   reg   [63:0]  d;
   reg           is_data;
   begin : di
      tx_reset_desc;
      xs_ep      = ep;
      xs_corrupt = 1'b0;
      xs_badtgl  = 1'b0;
      xs_fifo    = 1'b0;
      xs_len     = 0;
      is_data    = 1'b0;
      if (ep == 0)
        begin
           stage = (ctl_stage == CS_STATUS_IN) ? ST_STATUS : ST_DATA;
           fault_match(T_IN, 0, cs_rq, cs_wv[15:8], stage);
           if (!ctl_active || ctl_stall || (ctl_stage == CS_NONE) || (ctl_stage == CS_DATA_OUT) ||
               (ctl_stage == CS_DONE) || ((ctl_stage == CS_DATA_IN) && data_done))
             tx_pid = P_STALL;
           else if (ctl_stage == CS_DATA_IN)
             begin
                n = ctl_len - ctl_ptr;
                if (n > 8) n = 8;
                for (i = 0; i < n; i = i + 1) txb[i] = cbuf[ctl_ptr + i];
                tx_kind = TK_DATA;
                tx_pid  = ctl_tgl ? P_DATA1 : P_DATA0;
                tx_nb   = n;
                is_data = 1'b1;
             end
           else
             begin                          // status stage of a no-data or OUT transfer
                tx_kind = TK_DATA;
                tx_pid  = P_DATA1;
                tx_nb   = 0;
                is_data = 1'b1;
             end
        end
      else
        begin
           ix = (ep <= 3) ? ep_lookup(ep) : -1;
           if (ix < 0)
             begin
                $sformat(mb, "IN to EP%0d: no such endpoint in this configuration, ignored", ep); vlog(2);
                disable di;
             end
           fault_match(T_IN, ep, -1, -1, -1);
           if (ep_halt[ep])
             tx_pid = P_STALL;
           else if (rf_cnt[ep] > 0)
             begin
                k       = ep * RFD + rf_rd[ep];
                n       = rf_len[k];
                d       = rf_dat[k];
                xs_fifo = 1'b1;
                is_data = 1'b1;
             end
           else if (repeat_last)
             begin
                n       = rl_ok[ep] ? rl_len[ep] : idle_len[ep];
                d       = rl_ok[ep] ? rl_dat[ep] : idle_dat[ep];
                is_data = 1'b1;
             end
           else
             tx_pid = P_NAK;
           if (is_data)
             begin
                for (i = 0; i < n; i = i + 1) txb[i] = d[8*i +: 8];
                tx_kind = TK_DATA;
                tx_pid  = ep_tgl[ep] ? P_DATA1 : P_DATA0;
                tx_nb   = n;
             end
        end
      apply_fault;
      if (fx_silent)
        begin
           $sformat(mb, "IN EP%0d: device silent", ep); vlog(2);
           disable di;
        end
      if (is_data && !fx_replaced)
        begin
           xs         = XS_IN_HS;
           xs_len     = tx_nb;
           xs_corrupt = fx_corrupt;
           xs_badtgl  = fx_badtgl;
           if ((ep != 0) && !fx_corrupt)
             begin
                int_sent_cnt  = int_sent_cnt + 1;
                int_sent_ep   = ep;
                int_sent_len  = tx_nb;
                int_sent_data = 64'h0;
                for (i = 0; (i < tx_nb) && (i < 8); i = i + 1) int_sent_data[8*i +: 8] = txb[i];
             end
        end
      launch(t);
   end
endtask

// Host ACK of the device's data packet
task dev_ack;
   integer k;
   begin
      if (xs_ep == 0)
        begin
           if (xs_badtgl)
             begin
                $sformat(mb, "EP0 packet with the wrong toggle acknowledged: not counted"); vlog(1);
             end
           else if (ctl_stage == CS_DATA_IN)
             begin
                ctl_ptr      = ctl_ptr + xs_len;
                ctl_tgl      = 1 - ctl_tgl;
                begin ctl_progress = ctl_progress + 1; ctl_progress_t = $realtime; end
                if ((xs_len < 8) || ((ctl_ptr >= ctl_len) && !zlp_need)) data_done = 1'b1;
             end
           else if (ctl_stage == CS_STATUS_IN)
             ctl_complete;
        end
      else if (xs_badtgl)
        begin
           $sformat(mb, "EP%0d packet with the wrong toggle acknowledged: report kept, toggle kept", xs_ep); vlog(1);
        end
      else
        begin
           ep_tgl[xs_ep] = 1 - ep_tgl[xs_ep];
           int_ack_cnt   = int_ack_cnt + 1;
           ack_tgl       = ~ack_tgl;
           if (xs_fifo && (rf_cnt[xs_ep] > 0))
             begin
                k              = xs_ep * RFD + rf_rd[xs_ep];
                rl_dat[xs_ep]  = rf_dat[k];
                rl_len[xs_ep]  = rf_len[k];
                rl_ok[xs_ep]   = 1'b1;
                rf_rd[xs_ep]   = (rf_rd[xs_ep] + 1) % RFD;
                rf_cnt[xs_ep]  = rf_cnt[xs_ep] - 1;
             end
           $sformat(mb, "report delivered on EP%0d: %0d bytes %h", xs_ep, xs_len, int_sent_data); vlog(1);
        end
   end
endtask

// DATA after a SETUP token for this device
task dev_setup_data;
   input [3:0]   pid;
   input integer plen;
   input real    t;
   begin : sd
      if (pid != P_DATA0)
        begin
           $sformat(mb, "SETUP data packet is %0s (must be DATA0)", pid_name(pid)); cerr(C_TOGGLE);
        end
      if (plen != 8)
        begin
           $sformat(mb, "SETUP data packet of %0d bytes (must be 8): ignored", plen); cerr(C_PROTO);
           disable sd;
        end
      tx_reset_desc;
      fault_match(T_SETUP, 0, rxd[1], rxd[3], ST_SETUP);
      apply_fault;
      if (!fx_silent && !fx_replaced) setup_accept;
      if (!fx_silent) launch(t);
   end
endtask

// DATA after an OUT token to EP0: OUT data stage or status stage
task dev_out_data;
   input [3:0]   pid;
   input integer plen;
   input real    t;
   integer       k, tg, stage;
   begin : od
      tg = (pid == P_DATA1) ? 1 : 0;
      tx_reset_desc;
      stage = (ctl_stage == CS_DATA_OUT) ? ST_DATA : ST_STATUS;
      fault_match(T_OUT, 0, cs_rq, cs_wv[15:8], stage);
      if (ctl_active && (ctl_stage == CS_STATUS_IN) && !ctl_in_dir && out_ack_lost && (tg != ctl_tgl))
        begin
           // the last OUT data packet retransmitted because our ACK was lost (8.6.3)
           apply_fault;
           if (!fx_silent && !fx_replaced)
             begin
                $sformat(mb, "OUT DATA%0d retransmitted after a lost ACK: ACKed and discarded", tg); vlog(1);
                out_ack_lost = fx_corrupt;
             end
        end
      else if (!ctl_active || (ctl_stage == CS_NONE) || (ctl_stage == CS_STATUS_IN))
        begin
           tx_pid = P_STALL;
           apply_fault;
        end
      else if (ctl_stage == CS_DONE)
        begin
           // a status OUT retransmitted because our ACK was lost
           if (!(ctl_in_dir && out_ack_lost)) tx_pid = P_STALL;
           apply_fault;
           if (!fx_silent && !fx_replaced && (tx_pid == P_ACK)) out_ack_lost = fx_corrupt;
        end
      else if (ctl_stage == CS_DATA_IN)
        begin
           // status stage of an IN transfer (or the host ending the data stage early)
           if (!tg)
             begin
                $sformat(mb, "status OUT data is DATA0 (must be DATA1)"); cerr(C_TOGGLE);
             end
           if (plen != 0)
             begin
                $sformat(mb, "status OUT data packet of %0d bytes (must be zero-length)", plen); cerr(C_PROTO);
             end
           if (ctl_stall) tx_pid = P_STALL;
           apply_fault;
           if (!fx_silent && !fx_replaced && !ctl_stall)
             begin
                begin ctl_progress = ctl_progress + 1; ctl_progress_t = $realtime; end
                out_ack_lost = fx_corrupt;
                ctl_complete;
             end
        end
      else
        begin                               // CS_DATA_OUT
           if (ctl_stall) tx_pid = P_STALL;
           apply_fault;
           if (!fx_silent && !fx_replaced && !ctl_stall)
             begin
                if (tg != ctl_tgl)
                  begin
                     if (out_ack_lost)
                       begin
                          $sformat(mb, "OUT DATA%0d retransmitted after a lost ACK: ACKed and discarded", tg); vlog(1);
                       end
                     else
                       begin
                          $sformat(mb, "OUT data stage packet is DATA%0d, expected DATA%0d", tg, ctl_tgl); cerr(C_TOGGLE);
                       end
                  end
                else
                  begin
                     if ((plen > 8) || ((ctl_out_cnt + plen) > cs_wl))
                       begin
                          $sformat(mb, "OUT data packet of %0d bytes with %0d of %0d already received",
                                   plen, ctl_out_cnt, cs_wl);
                          cerr(C_PROTO);
                       end
                     for (k = 0; (k < plen) && (k < 8) && ((ctl_out_cnt + k) < 64); k = k + 1)
                       obuf[ctl_out_cnt + k] = rxd[k];
                     ctl_out_cnt  = ctl_out_cnt + plen;
                     ctl_tgl      = 1 - ctl_tgl;
                     begin ctl_progress = ctl_progress + 1; ctl_progress_t = $realtime; end
                     if (ctl_out_cnt >= cs_wl) ctl_stage = CS_STATUS_IN;
                  end
                out_ack_lost = fx_corrupt;
             end
        end
      if (!fx_silent) launch(t);
   end
endtask

// A SETUP was accepted: start a control transfer
task setup_accept;
   reg [63:0] raw;
   begin
      raw = {rxd[7], rxd[6], rxd[5], rxd[4], rxd[3], rxd[2], rxd[1], rxd[0]};
      if (ctl_active && (ctl_stage != CS_DONE) && !ctl_trouble && ((ctl_progress > 0) || (raw != cs_raw)))
        begin
           $sformat(mb, "control transfer %0s abandoned by a new SETUP before its status stage",
                    req_name(cs_rt, cs_rq));
           cerr(C_STATUS);
        end
      ctl_trouble = 1'b0;
      cs_raw = raw;
      cs_rt  = rxd[0];
      cs_rq  = rxd[1];
      cs_wv  = {rxd[3], rxd[2]};
      cs_wi  = {rxd[5], rxd[4]};
      cs_wl  = {rxd[7], rxd[6]};
      ctl_active   = 1'b1;
      ctl_tgl      = 1;
      ctl_ptr      = 0;
      zlp_need     = 1'b0;
      data_done    = 1'b0;
      ctl_progress = 0;
      out_ack_lost = 1'b0;
      ctl_out_cnt  = 0;
      setup_decode;
      ctl_in_dir   = cs_rt[7] && (cs_wl != 0);
      if (cs_wl == 0)
        ctl_stage = CS_STATUS_IN;
      else if (cs_rt[7])
        begin
           ctl_stage = CS_DATA_IN;
           if (ctl_len > cs_wl) ctl_len = cs_wl;
           zlp_need  = (ctl_len < cs_wl) && ((ctl_len % 8) == 0);
        end
      else
        ctl_stage = CS_DATA_OUT;
      st_xfer_start = st_xfer_start + 1;
      setup_tgl     = ~setup_tgl;
      st_xfer_start_t = $realtime;
      $sformat(mb, "SETUP %0s rt %h rq %h wValue %h wIndex %h wLength %0d%0s", req_name(cs_rt, cs_rq),
               cs_rt, cs_rq, cs_wv, cs_wi, cs_wl, ctl_stall ? " -> STALL" : "");
      vlog(1);
   end
endtask

// Copy a descriptor region into the control buffer
task ctl_from_region;
   input integer r;
   integer i;
   begin
      if (rlen[r] == 0) ctl_stall = 1'b1;
      for (i = 0; i < rlen[r]; i = i + 1) cbuf[i] = dmem[r*256 + i];
      ctl_len = rlen[r];
   end
endtask

// Decode the request: data to return, STALL, or the effect to apply at completion
task setup_decode;
   integer i, e, x, dt, di, off;
   begin
      pend      = PA_NONE;
      pend_v    = 0;
      pend_i    = cs_wi[7:0];
      ctl_stall = 1'b0;
      ctl_len   = 0;
      dt        = cs_wv[15:8];
      di        = cs_wv[7:0];
      e         = cs_wi[3:0];
      if (cs_rt[6:5] == 2'd0)
        case (cs_rq)
          8'd0:                             // GET_STATUS
            if (cs_rt[7] && (cs_rt[4:0] <= 2))
              begin
                 cbuf[0] = 8'h00; cbuf[1] = 8'h00;
                 if ((cs_rt[4:0] == 2) && (e >= 1) && (e <= 3)) cbuf[0] = {7'd0, ep_halt[e]};
                 ctl_len = 2;
              end
            else ctl_stall = 1'b1;
          8'd1, 8'd3:                       // CLEAR_FEATURE, SET_FEATURE
            if (!cs_rt[7] && (cs_wl == 0) && (cs_rt[4:0] == 2) && (cs_wv == 16'd0) &&
                ((e == 0) || ((e <= 3) && (ep_lookup(e) >= 0))))
              begin
                 if (e != 0)
                   begin
                      pend   = (cs_rq == 8'd1) ? PA_CLRHALT : PA_SETHALT;
                      pend_v = e;
                   end
              end
            else if (!cs_rt[7] && (cs_wl == 0) && (cs_rt[4:0] == 0) && (cs_wv == 16'd1))
              ;                             // DEVICE_REMOTE_WAKEUP: accepted, no effect
            else ctl_stall = 1'b1;
          8'd5:                             // SET_ADDRESS
            if ((cs_rt == 8'h00) && (cs_wl == 0) && (cs_wv < 16'd128) && (st_dev != DS_CONFIGURED))
              begin
                 pend   = PA_ADDR;
                 pend_v = cs_wv[6:0];
              end
            else ctl_stall = 1'b1;
          8'd6:                             // GET_DESCRIPTOR
            if (cs_rt == 8'h80)
              begin
                 if ((dt == 1) && (di == 0))      ctl_from_region(R_DEV);
                 else if ((dt == 2) && (di == 0)) ctl_from_region(R_CFG);
                 else if ((dt == 3) && (di < 4))  ctl_from_region(R_STR0 + di);
                 else ctl_stall = 1'b1;
              end
            else if (cs_rt == 8'h81)
              begin
                 x = find_if(cs_wi[7:0], 0);
                 if ((dt == 8'h21) && (x >= 0) && (if_hid[x] >= 0))
                   begin
                      off = R_CFG * 256 + if_hid[x];
                      for (i = 0; i < 9; i = i + 1) cbuf[i] = dmem[off + i];
                      ctl_len = 9;
                   end
                 else if ((dt == 8'h22) && (cs_wi[7:0] < 2)) ctl_from_region(R_REP0 + cs_wi[7:0]);
                 else ctl_stall = 1'b1;
              end
            else ctl_stall = 1'b1;
          8'd8:                             // GET_CONFIGURATION
            if (cs_rt == 8'h80)
              begin
                 cbuf[0] = cur_cfg;
                 ctl_len = 1;
              end
            else ctl_stall = 1'b1;
          8'd9:                             // SET_CONFIGURATION
            if ((cs_rt == 8'h00) && (cs_wl == 0) && (st_dev >= DS_ADDRESS) &&
                ((cs_wv[7:0] == 0) || (cs_wv[7:0] == cfg_value)) && (cs_wv[15:8] == 0))
              begin
                 pend   = PA_CONFIG;
                 pend_v = cs_wv[7:0];
              end
            else ctl_stall = 1'b1;
          8'd10:                            // GET_INTERFACE
            if ((cs_rt == 8'h81) && (cur_cfg != 0) && (cs_wi < 8) && (find_if(cs_wi[7:0], 0) >= 0))
              begin
                 cbuf[0] = cur_alt[cs_wi[2:0]];
                 ctl_len = 1;
              end
            else ctl_stall = 1'b1;
          8'd11:                            // SET_INTERFACE
            if ((cs_rt == 8'h01) && (cs_wl == 0) && (cur_cfg != 0) && (cs_wi < 8) &&
                (find_if(cs_wi[7:0], cs_wv[7:0]) >= 0))
              begin
                 pend   = PA_SETIF;
                 pend_v = cs_wv[7:0];
              end
            else ctl_stall = 1'b1;
          default: ctl_stall = 1'b1;
        endcase
      else if ((cs_rt[6:5] == 2'd1) && (cs_rt[4:0] == 5'd1))
        begin
           x = find_if(cs_wi[7:0], (cs_wi < 8) ? cur_alt[cs_wi[2:0]] : 0);
           if ((x < 0) || (if_cls[x] != 3))
             ctl_stall = 1'b1;
           else
             case (cs_rq)
               8'h01:                       // GET_REPORT
                 if (cs_rt == 8'hA1) get_report(x);
                 else ctl_stall = 1'b1;
               8'h02:                       // GET_IDLE
                 if (cs_rt == 8'hA1) begin cbuf[0] = hid_idle[cs_wi[2:0]]; ctl_len = 1; end
                 else ctl_stall = 1'b1;
               8'h03:                       // GET_PROTOCOL (boot interfaces)
                 if ((cs_rt == 8'hA1) && (if_sub[x] == 1)) begin cbuf[0] = hid_proto[cs_wi[2:0]]; ctl_len = 1; end
                 else ctl_stall = 1'b1;
               8'h09:                       // SET_REPORT
                 if (cs_rt == 8'h21) pend = PA_SETREP;
                 else ctl_stall = 1'b1;
               8'h0A:                       // SET_IDLE
                 if ((cs_rt == 8'h21) && (cs_wl == 0)) begin pend = PA_IDLE; pend_v = cs_wv[15:8]; end
                 else ctl_stall = 1'b1;
               8'h0B:                       // SET_PROTOCOL (boot interfaces, 0 boot / 1 report)
                 if ((cs_rt == 8'h21) && (cs_wl == 0) && (if_sub[x] == 1) && (cs_wv <= 16'd1))
                   begin
                      pend   = PA_PROTO;
                      pend_v = cs_wv[0];
                   end
                 else ctl_stall = 1'b1;
               default: ctl_stall = 1'b1;
             endcase
        end
      else
        ctl_stall = 1'b1;
   end
endtask

// GET_REPORT: the next report of the interface's IN endpoint, else the last, else the idle one
task get_report;
   input integer x;
   integer k, i, e, n, ix;
   reg [63:0] d;
   begin
      e = -1;
      for (k = nep - 1; k >= 0; k = k - 1)
        if ((ep_ifx[k] == x) && ep_in[k] && (ep_num[k] >= 1) && (ep_num[k] <= 3)) e = ep_num[k];
      ix = -1;
      for (k = nep - 1; k >= 0; k = k - 1)
        if ((ep_ifx[k] == x) && ep_in[k]) ix = k;
      n = (ix >= 0) ? ep_mps[ix] : 8;
      if ((n < 1) || (n > 8)) n = 8;
      d = 64'h0;
      if (e > 0)
        begin
           if (rf_cnt[e] > 0)
             begin
                d = rf_dat[e * RFD + rf_rd[e]];
                n = rf_len[e * RFD + rf_rd[e]];
             end
           else if (rl_ok[e])
             begin
                d = rl_dat[e];
                n = rl_len[e];
             end
           else
             begin
                d = idle_dat[e];
                if (idle_len[e] < n) n = idle_len[e];
             end
        end
      for (i = 0; i < n; i = i + 1) cbuf[i] = d[8*i +: 8];
      ctl_len = n;
   end
endtask

// Status stage complete: apply the request's effect
task ctl_complete;
   integer k, x;
   begin
      ctl_stage    = CS_DONE;
      st_xfer_done = st_xfer_done + 1;
      case (pend)
        PA_ADDR:
          begin
             addr_old      = dev_addr;
             dev_addr      = pend_v[6:0];
             addr_ready_t  = $realtime + addr_rcy_ns;
             addr_chg_pend = (pend_v[6:0] != addr_old);
             addr_chg_t    = $realtime;
             st_dev        = (pend_v != 0) ? DS_ADDRESS : DS_DEFAULT;
          end
        PA_CONFIG:
          begin
             cur_cfg = pend_v;
             st_dev  = (pend_v != 0) ? DS_CONFIGURED : DS_ADDRESS;
             for (k = 0; k < 8; k = k + 1) cur_alt[k] = 0;
             for (k = 0; k < 4; k = k + 1) begin ep_tgl[k] = 0; ep_halt[k] = 1'b0; end
          end
        PA_SETIF:
          begin
             cur_alt[pend_i[2:0]] = pend_v;
             for (k = 0; k < nep; k = k + 1)
               if ((if_num[ep_ifx[k]] == pend_i) && (ep_num[k] <= 3)) ep_tgl[ep_num[k]] = 0;
          end
        PA_IDLE:    hid_idle[pend_i[2:0]]  = pend_v;
        PA_PROTO:   hid_proto[pend_i[2:0]] = pend_v;
        PA_SETREP:
          begin
             srep_len = (ctl_out_cnt < 64) ? ctl_out_cnt : 64;
             for (k = 0; k < srep_len; k = k + 1) srep[k] = obuf[k];
             srep_wv  = cs_wv;
             srep_if  = pend_i;
             srep_cnt = srep_cnt + 1;
          end
        PA_CLRHALT: begin ep_halt[pend_v] = 1'b0; ep_tgl[pend_v] = 0; end
        PA_SETHALT: ep_halt[pend_v] = 1'b1;
        default:    ;
      endcase
      $sformat(mb, "control transfer %0s complete%0s", req_name(cs_rt, cs_rq),
               (pend == PA_ADDR) ? " (new address in effect)" : "");
      vlog(1);
      pend = PA_NONE;
   end
endtask

task dev_bus_reset;
   begin
      if (ctl_active && (ctl_stage != CS_DONE) && !ctl_trouble)
        begin
           $sformat(mb, "bus reset abandons control transfer %0s before its status stage", req_name(cs_rt, cs_rq));
           cerr(C_STATUS);
        end
      dev_proto_clear;
      st_dev = DS_DEFAULT;
   end
endtask

//=============================================================================
// 9)  TRANSMITTER
//=============================================================================

initial
  begin : txproc
     #1;
     forever
       begin
          @(tx_go);
          tx_send;
       end
  end

task tx_abort;
   begin
      if (pu_on)
        begin
           dev_evt_t = $realtime;
           drv_en    = 1'b0;
        end
      tx_busy = 1'b0;
   end
endtask

// Build sync / PID / payload / CRC16, stuff, NRZI-drive at absolute times,
// then EOP (SE0 2 bits, J 1 bit) and release
task tx_send;
   integer     i, k, nraw, ns, ones;
   real        tb, t0, tend, tbab;
   reg         cur_k, fb;
   reg  [7:0]  pb;
   reg [15:0]  c16;
   begin : ts
      tb = BIT_NS / (1.0 + rate_ppm * 1.0e-6);
      t0 = tx_t_ref + tx_dly * tb;
      if (t0 < $realtime) t0 = $realtime;
      nraw = 0;
      for (i = 0; i < 7; i = i + 1) begin rawb[nraw] = 1'b0; nraw = nraw + 1; end
      rawb[nraw] = 1'b1; nraw = nraw + 1;
      if (!tx_hold)
        begin
           pb = {~tx_pid, tx_pid};
           if (tx_pid_err) pb[4] = ~pb[4];
           for (i = 0; i < 8; i = i + 1) begin rawb[nraw] = pb[i]; nraw = nraw + 1; end
           if (tx_kind == TK_DATA)
             begin
                c16 = 16'hFFFF;
                for (k = 0; k < tx_nb; k = k + 1)
                  for (i = 0; i < 8; i = i + 1)
                    begin
                       rawb[nraw] = txb[k][i];
                       nraw       = nraw + 1;
                       fb         = txb[k][i] ^ c16[15];
                       c16        = {c16[14:0], 1'b0} ^ (fb ? 16'h8005 : 16'h0000);
                    end
                c16 = ~c16;
                if (tx_crc_err) c16[0] = ~c16[0];
                for (i = 15; i >= 0; i = i - 1) begin rawb[nraw] = c16[i]; nraw = nraw + 1; end
             end
        end
      // Bit stuffing (a stuffing fault puts seven raw ones after the PID)
      ns = 0; ones = 0;
      for (i = 0; i < nraw; i = i + 1)
        begin
           sbit[ns] = rawb[i]; ns = ns + 1;
           if (rawb[i])
             begin
                ones = ones + 1;
                if (ones == 6) begin sbit[ns] = 1'b0; ns = ns + 1; ones = 0; end
             end
           else
             ones = 0;
           if (tx_stuff_err && (i == 15))
             begin
                for (k = 0; k < 7; k = k + 1) begin sbit[ns] = 1'b1; ns = ns + 1; end
                ones = 0;
             end
        end
      // Drive
      wait_until(t0);
      if (!pu_on) begin tx_abort; disable ts; end
      cur_k = 1'b0;
      for (i = 0; i < ns; i = i + 1)
        begin
           wait_until(t0 + i * tb);
           if (!pu_on) begin tx_abort; disable ts; end
           if (sbit[i] == 1'b0) cur_k = ~cur_k;
           drive_ls(cur_k ? L_K : L_J);
           if (i == 0)
             begin
                last_ev   = LE_DEV_BUSY; ev_tgl = ~ev_tgl;
                last_ev_t = $realtime;
             end
           if (tx_detach_bit == i)
             begin
                $sformat(mb, "detach in the middle of a packet (bit %0d)", i); vlog(1);
                detach;
                tx_busy = 1'b0;
                disable ts;
             end
        end
      tend = t0 + ns * tb;
      if (tx_hold)
        begin
           // loss of activity: the line stays driven, no EOP
           wait_until(tend);
           if (!pu_on) begin tx_abort; disable ts; end
           drive_ls(tx_hold_k ? L_K : L_J);
           wait_until(tend + tx_hold_ns);
           last_ev   = LE_NONE; ev_tgl = ~ev_tgl;
           last_ev_t = $realtime;
           tx_abort;
           disable ts;
        end
      if (tx_babble)
        begin
           tbab = tend + tx_hold_ns;
           i    = ns;
           while ((t0 + i * tb) < tbab)
             begin
                wait_until(t0 + i * tb);
                if (!pu_on) begin tx_abort; disable ts; end
                if ($random(seed) & 1) cur_k = ~cur_k;
                drive_ls(cur_k ? L_K : L_J);
                i = i + 1;
             end
           tend = t0 + i * tb;
        end
      wait_until(tend);
      if (!pu_on) begin tx_abort; disable ts; end
      drive_ls(L_SE0);
      wait_until(tend + 2.0 * tb);
      if (!pu_on) begin tx_abort; disable ts; end
      drive_ls(L_J);
      dev_eop_end_t = $realtime;
      last_ev       = (tx_kind == TK_DATA) ? LE_DEV_DATA : LE_DEV_HS; ev_tgl = ~ev_tgl;
      last_ev_t     = dev_eop_end_t;
      wait_until(tend + 3.0 * tb);
      tx_abort;
   end
endtask

//=============================================================================
// 10) WATCHERS: TIMERS, HOST OUTPUT ENABLE, COLLISIONS
//=============================================================================

// 1 us tick: suspend, bus reset, stalled host packet, detached drive
initial
  begin : tick
     real now;
     #1;
     forever
       begin
          #1000;
          now = $realtime;
          if (pu_on && !pu_fs && !susp_q && !drv_en && (ls_state == L_J) && ((now - ls_t) > 3.0e6))
            begin
               susp_q = 1'b1;
               st_susp = st_susp + 1;
               $sformat(mb, "suspended: bus idle for 3 ms"); vlog(1);
            end
          if (pu_on && !pu_fs && !rst_active && !ls_dev && (ls_state == L_SE0) && ((now - ls_t) >= 2500.0))
            reset_seen;
          if (pu_on && !pu_fs && (rx_mode == RX_PKT) && ((now - ls_t) > 20.0 * BIT_NS))
            begin
               if ((rx_ne == 1) && (ls_state == L_K))
                 begin
                    rx_mode = RX_RESUME;
                    $sformat(mb, "host resume signalling (K)"); vlog(1);
                 end
               else
                 begin
                    $sformat(mb, "host packet stalled: no transition for 20 bit times after %0d bits", rx_n);
                    cerr(C_STUFF);
                    host_bad(now);
                    rx_mode = RX_WAIT;
                 end
            end
          if ((rx_mode == RX_WAIT) && (ls_state == L_J) && ((now - ls_t) > 8.0 * BIT_NS))
            rx_mode = RX_IDLE;
          if (!pu_on && (host_oe === 1'b1) && !det_flag && ((now - detach_t) > DETACH_GRACE_NS))
            begin
               det_flag = 1'b1;
               $sformat(mb, "host drives the bus %0.1f us after the detach", (now - detach_t) / 1000.0);
               cerr(C_DETACHED);
            end
       end
  end

always @(posedge host_oe)
  if (host_oe === 1'b1)
    begin
       if (pu_on && pu_fs)
         begin
            $sformat(mb, "host drives the bus of a full-speed device"); cerr(C_FSDRV);
         end
       else if (pu_on && (($realtime - attach_t) < DEBOUNCE_NS))
         begin
            $sformat(mb, "host drives %0.3f ms after the attach (debounce %0.1f ms)",
                     ($realtime - attach_t) / 1.0e6, DEBOUNCE_NS / 1.0e6);
            cerr(C_DEBOUNCE);
         end
       if (!pu_on && !det_flag && (($realtime - detach_t) > DETACH_GRACE_NS))
         begin
            det_flag = 1'b1;
            $sformat(mb, "host drives a detached port"); cerr(C_DETACHED);
         end
    end

always @(negedge host_oe)
  begin
     det_flag = 1'b0;
     if (pu_on && !pu_fs && !rst_active && !ls_dev && (ls_state == L_J) && (ls_prev == L_SE0) &&
         (last_se0_len < 2500.0) && (($realtime - ls_t) > (BIT_NS + TOL_NS)))
       begin
          $sformat(mb, "host drives J for %0.2f bit times after its EOP SE0 before releasing (1 bit)",
                   ($realtime - ls_t) / BIT_NS);
          cerr(C_EOPREL);
       end
  end

initial
  begin : coll
     reg cnow, cact;
     cact = 1'b0;
     #1;
     forever
       begin
          @(dp or dm or drv_en or host_oe);
          #(LS_SETTLE);
          cnow = (drv_en && (host_oe === 1'b1) && !resume_active) ||
                 ((drv_en || (host_oe === 1'b1)) && (ls_now(dp, dm) == L_X));
          if (cnow && !cact)
            begin
               st_coll = st_coll + 1;
               $sformat(mb, "bus collision: device %0s, host %0s, lines %0s", drv_en ? "driving" : "released",
                        (host_oe === 1'b1) ? "driving" : "released", ls_name(ls_now(dp, dm)));
               cerr(C_COLL);
            end
          cact = cnow;
       end
  end

//=============================================================================
// 11) SUMMARY AND INITIALISATION
//=============================================================================

task dump_summary;
   integer i;
   real    gap;
   begin
      $display("");
      $display("[%0t] %0s: ---------------- device model summary ----------------", $time, NAME);
      $display("  state %0d, address %0d, configuration %0d, attached %0d, suspended %0d",
               st_dev, dev_addr, cur_cfg, pu_on, susp_q);
      $display("  control transfers started %0d, completed %0d; interrupt packets sent %0d, acknowledged %0d",
               st_xfer_start, st_xfer_done, int_sent_cnt, int_ack_cnt);
      $display("  SET_REPORT received %0d; faults applied %0d; suspends %0d; collisions %0d",
               srep_cnt, st_faults, st_susp, st_coll);
      $display("  host packets %0d; bit rate: max |err| %0.0f ppm, mean %0.0f ppm; jitter max %0.1f ns next, %0.1f ns paired",
               st_host_pkts, st_rate_max, (st_rate_span > 0.0) ? st_rate_sum / st_rate_span : 0.0,
               st_jit_next, st_jit_pair);
      if (st_ipd_n > 0)
        $display("  host inter-packet delays: %0d, %0.2f to %0.2f bit times", st_ipd_n,
                 st_ipd_min / BIT_NS, st_ipd_max / BIT_NS);
      gap = (ka_armed && (($realtime - ka_last) > st_ka_max)) ? ($realtime - ka_last) : st_ka_max;
      $display("  keep-alive: max gap %0.3f ms%0s; back-offs %0d", gap / 1.0e6,
               (gap > st_ka_max) ? " (still open)" : "", st_backoffs);
      $write("  bus resets %0d, lengths (ms):", st_resets);
      for (i = 0; (i < st_resets) && (i < 8); i = i + 1) $write(" %0.3f", st_rst_len[i] / 1.0e6);
      $write("\n");
      for (i = 0; i < NFR; i = i + 1)
        if ((fr_kind[i] != F_NONE) || (fr_hits[i] != 0))
          $display("  fault rule %0d %0s: %0d matches, %0d applied", i, fault_name(fr_kind[i]), fr_occ[i], fr_hits[i]);
      $display("  checker     enabled  count");
      for (i = 0; i < NCHK; i = i + 1)
        $display("  %0s:\t%0d\t%0d", chk_name(i), chk_en[i], chk_cnt[i]);
      $display("  total (enabled checkers): %0d", err_total);
      $display("[%0t] %0s: ----------------------------------------------------", $time, NAME);
   end
endtask

initial
  begin : init
     integer i;
     verbose       = VERBOSE;
     seed          = SEED;
     rate_ppm      = 0;
     dly_min       = 200;
     dly_max       = 650;
     addr_rcy_ns   = 0.0;
     repeat_last   = 1'b0;
     drv_en        = 1'b0;
     drv_dp        = 1'b0;
     drv_dm        = 1'b0;
     pu_on         = 1'b0;
     pu_fs         = 1'b0;
     for (i = 0; i < NCHK; i = i + 1) chk_en[i] = 1'b1;
     chk_clear;
     dev_evt_t     = 0.0;
     attach_t      = 0.0;
     detach_t      = 0.0;
     det_flag      = 1'b0;
     last_ev       = LE_NONE; ev_tgl = ~ev_tgl;
     last_ev_t     = 0.0;
     dev_eop_end_t = 0.0;
     last_se0_len  = 0.0;
     ka_armed      = 1'b0;
     ka_pend       = 1'b0;
     ka_last       = 0.0;
     rst_active    = 1'b0;
     rx_mode       = RX_IDLE;
     rx_n          = 0;
     rx_ne         = 0;
     tx_busy       = 1'b0;
     resume_active = 1'b0;
     tx_babble     = 1'b0;
     tx_hold       = 1'b0;
     srep_len      = 0;
     srep_cnt      = 0;
     int_sent_cnt  = 0;
     int_sent_ep   = 0;
     int_sent_len  = 0;
     int_sent_data = 64'h0;
     int_ack_cnt   = 0;
     ev_tgl        = 1'b0;
     setup_tgl     = 1'b0;
     ack_tgl       = 1'b0;
     cs_raw        = 64'h0;
     cs_rt         = 8'h0;
     cs_rq         = 8'h0;
     cs_wv         = 16'h0;
     cs_wi         = 16'h0;
     cs_wl         = 16'h0;
     pend          = PA_NONE;
     ctl_in_dir    = 1'b0;
     ctl_out_cnt   = 0;
     flush_reports;
     clear_faults;
     for (i = 0; i < NFR; i = i + 1) begin fr_occ[i] = 0; fr_hits[i] = 0; end
     load_profile(PROFILE);
     dev_proto_clear;
     st_dev        = DS_DETACHED;
     if (AUTO_ATTACH != 0) attach(-1);
  end

endmodule

`default_nettype wire
