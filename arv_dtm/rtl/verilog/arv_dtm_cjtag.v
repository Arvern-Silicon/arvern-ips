//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arv_dtm_cjtag
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arv_dtm_cjtag.v
// Module Description : Compact JTAG (IEEE 1149.7, cJTAG) Debug Transport Module
//                      for the aRVern core -- a 2-wire (TCKC/TMSC) link layer
//                      over the protocol-neutral arv_dtm_tap core. OScan1 only.
//
//   Protocol, integration requirements and reset architecture: doc/arv_dtm_cjtag.md.
//
//   Scan engine is clocked by TCKC (native, like a 1149.1 TAP). The escape detector
//   is the one oversampled part: clk_i MUST be running to attach, at >= 8x TCKC
//   (measured) -- the escape class must settle through the clk_i synchroniser
//   before the terminating TCKC fall. A probe uses one TCKC rate for escapes and
//   packets, so this also bounds the link's TCKC.
//
//   OScan1 packet = 3 TCKC cycles:
//       cnt=0 (nTDI): sample tdi = ~TMSC        cnt=1 (TMS): sample tms = TMSC
//       cnt=2 (TDO) : drive TMSC = TDO, and enable the TAP for this one TCKC edge.
//
//   Encoding (activation codes, escape edge counts, OScan1 phase order) is checked
//   against IEEE Std 1149.7-2022. Both activation forms are decoded: standard (long)
//   and short. Point-to-point only -- multi-drop / star is not supported.
//----------------------------------------------------------------------------
`default_nettype none

module  arv_dtm_cjtag #(
    parameter            [27:0] IDCODE_BASE = 28'h000_01F7,     // IDCODE[27:0] (bit0 MUST be 1); the version field
                                                                // [31:28] arrives on idcode_version_i, not here
                                                                // (mfg field = Arvern's JEDEC identity -- see arv_dtm.md)
    parameter             [2:0] IDLE_HINT = 3'd3,               // dtmcs.idle: Run-Test/Idle cycles hint to the debugger
    parameter                   ARST_EN   = 1'b1                // Reset style: 1=async active-low, 0=sync
) (

// Global (clk_i is hclk for the DMI side ONLY -- the front-end is TCKC-clocked)
    input  wire                 clk_i,
    input  wire                 dbgresetn_i,                    // active-low debug reset
    output wire                 dbg_wakeup_o,                   // Cold-attach wake request

// cJTAG 2-wire PHY (from the debug probe / DTS)
    input  wire                 tckc_i,                         // compact TAP clock  (probe-driven)
    input  wire                 tmsc_i,                         // compact bidir data (probe -> target phases)
    output wire                 tmsc_o,                         // compact bidir data (target -> probe phase = TDO)
    output wire                 tmsc_oe_o,                      // TMSC output enable (drive in TDO phase, TCKC low)

// IDCODE[31:28]: the version field
    input  wire           [3:0] idcode_version_i,               // Version specified as a port so it can easily be ECO-ed

// DFT
    input  wire                 scan_mode_i,                    // 1 = test mode: resets held inactive, TMSC not driven

// aRVern DMI bus
    output wire                 dmi_psel_o,
    output wire                 dmi_penable_o,
    output wire           [8:0] dmi_paddr_o,
    output wire                 dmi_pwrite_o,
    output wire          [31:0] dmi_pwdata_o,
    output wire           [2:0] dmi_pprot_o,
    input  wire                 dmi_pready_i,
    input  wire          [31:0] dmi_prdata_i,
    input  wire                 dmi_pslverr_i
);

//=============================================================================
// LOCAL PARAMETERS
//=============================================================================
// Online Activation Code, LSB-first (bit-reversed) as it arrives on TMSC. OAC=0xC:
// OAC[1:0]=00 selects TAP.7, OAC[3:2]=11 selects Star-2 topology (forcing OScan1).
// EC is decoded by field, not compared (see code_ok); the Check Packet is variable
// length and handled by the activation FSM.
localparam [3:0] ACT_OAC      = 4'b0011;


// TCKC RESET IS ALWAYS ASYNCHRONOUS: TCKC comes from the external probe and may not
// be running, so a synchronous reset could never initialise the front end. ARST_EN
// governs the clk_i side (escape detector + the TAP core's DMI master).
localparam       TCK_ARST     = 1'b1;

// Reset escape: ">= 8 edges = reset all technologies" per IEEE 1149.7, so the compare
// is deliberately open-ended. 6/7 edges = selection (arms activation), 4/5 = deselect
// (goes Offline), 2/3 = custom (ignored).
localparam [4:0] ESC_CHANGES  = 5'd8;

// Escape classes (Cl. 10.4.1.1 Tbl 10-9). ESC_NONE covers the 2/3-edge "custom" case,
// which is a no-op for this technology.
localparam [1:0] ESC_NONE = 2'd0, ESC_DESEL = 2'd1, ESC_SEL = 2'd2, ESC_RST = 2'd3;

// Activation-frame phases. The code is OAC(4) + EC(4); the Check Packet that follows is
// VARIABLE length -- Preamble(1) + Body(2+) + Postamble(1), Cl. 11.7.9.1.1 -- so it
// cannot be folded into a fixed bit count.
localparam [2:0] P_CODE    = 3'd0, P_GRL     = 3'd1, P_CP_PRE = 3'd2,
                 P_CP_BODY = 3'd3, P_CP_POST = 3'd4, P_CP_RSO = 3'd5;
localparam [1:0] CP_END    = 2'b00;                 // Tbl 11-13; NOP = 01/10
localparam [1:0] CP_RSO    = 2'b11;

//=============================================================================
// RESET CONDITIONING
//=============================================================================
// clk_i is synchronised; TCKC is DELIBERATELY async-released. Do not "fix" the TCKC
// side: it is stopped at POR, so a synchroniser defers release onto the probe's first
// edges, and those edges are activation/selection data. Full rule in
// doc/arv_dtm_cjtag.md.
//
// scan_mode_i ORs in on the OUTPUT: the synchroniser flops are themselves scanned.
// tck_rst_n is dbgresetn_i itself, an external reset the integrator fixes in test mode.
wire clk_rst_n_sync, clk_rst_n;
wire tck_rst_n = dbgresetn_i;

arv_synchronizer #(.W(1), .ARST_EN(ARST_EN)) u_clk_rst_sync (
    .clk_i(clk_i),  .rst_n_i(dbgresetn_i), .async_i(1'b1), .sync_o(clk_rst_n_sync));

arv_or #(.N(2)) u_clk_rst_or (.a_i({clk_rst_n_sync, scan_mode_i}),  .z_o(clk_rst_n));

//=============================================================================
// ESCAPE DETECTOR  (oversampled on clk_i)
//=============================================================================
// TMSC changes while TCKC is held HIGH -- no TCKC edges then, so it is oversampled on
// clk_i. ONE counter, not two: the XOR edge detector catches BOTH edges, so it counts
// CHANGES directly, which is what keeps a 7-change selection escape distinct from an
// 8-change reset escape.
wire tmsc_s, tckc_s, tmsc_s_d;

arv_synchronizer #(.W(1), .RST_VAL(1'b0), .ARST_EN(ARST_EN)) u_esc_tmsc_sync (
    .clk_i(clk_i), .rst_n_i(clk_rst_n), .async_i(tmsc_i), .sync_o(tmsc_s));
// TCKC is sampled here as data; in test mode it is isolated (a clock must not
// feed a scan flop's data input).
wire tckc_data;
arv_and #(.N(2)) u_tckc_data_and (.a_i({tckc_i, ~scan_mode_i}), .z_o(tckc_data));

arv_synchronizer #(.W(1), .RST_VAL(1'b0), .ARST_EN(ARST_EN)) u_esc_tckc_sync (
    .clk_i(clk_i), .rst_n_i(clk_rst_n), .async_i(tckc_data), .sync_o(tckc_s));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_esc_tmsc_d (
    .clk_i(clk_i), .rst_n_i(clk_rst_n), .en_i(1'b1), .d_i(tmsc_s), .q_o(tmsc_s_d));

wire       tmsc_change = tmsc_s ^ tmsc_s_d;
wire [4:0] esc_cnt;

// Changes count only while TCKC has been high for two samples: a TMSC change in the
// sample where TCKC rises is data skew, and after a release with TCKC and TMSC parked
// high the first TMSC sample (tmsc_s_d still at its reset value) is not a change.
wire tckc_s_d;
arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_tckc_s_d (
    .clk_i(clk_i), .rst_n_i(clk_rst_n), .en_i(1'b1), .d_i(tckc_s), .q_o(tckc_s_d));

arv_ipdff_sinit #(.WIDTH(5), .ARST_EN(ARST_EN)) u_esc_cnt (
    .clk_i(clk_i), .rst_n_i(clk_rst_n), .sinit_i(~tckc_s | ~tckc_s_d),
    .en_i(tmsc_change & (esc_cnt != 5'h1f)), .d_i(esc_cnt + 5'd1), .q_o(esc_cnt));

// Classification per Tbl 10-9. Odd counts round DOWN -- the standard reads an odd count
// "as the next lowest even number" to absorb a data edge landing just after TCKC rises
// -- which the >= compares do naturally.
wire [1:0] esc_class = (esc_cnt >= 5'd8) ? ESC_RST   :      // reset all technologies
                       (esc_cnt >= 5'd6) ? ESC_SEL   :      // selection sequence follows
                       (esc_cnt >= 5'd4) ? ESC_DESEL :      // deselect all
                                           ESC_NONE;

// The ACTION is taken when the escape ENDS (TCKC returns low): the count is not final
// before then. esc_cnt still holds its value for one cycle after tckc_s falls, because
// its sinit samples the pre-edge tckc_s -- that is the cycle esc_end fires.
wire esc_end = tckc_s_d & ~tckc_s & (esc_class != ESC_NONE);

wire esc_tog;
arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_esc_tog (
    .clk_i(clk_i), .rst_n_i(clk_rst_n),
    .en_i(esc_end), .d_i(~esc_tog), .q_o(esc_tog));

// DRIVE INHIBIT is separate and IMMEDIATE, per Cl. 10.4.1.3: detecting the reset escape
// "immediately initiates the TMSC signal's Dormant Drive Policy".
wire esc_hit = (esc_cnt >= ESC_CHANGES);

wire esc_tog_tckc;
arv_synchronizer #(.W(1), .ARST_EN(TCK_ARST)) u_esc_tog_sync (
    .clk_i(tckc_i), .rst_n_i(tck_rst_n), .async_i(esc_tog), .sync_o(esc_tog_tckc));

//=============================================================================
// SCAN ENGINE + ACTIVATION  (TCKC domain -- posedge tckc_i)
//=============================================================================
wire [1:0]  cnt;          // OScan1 phase: 0=nTDI, 1=TMS, 2=TDO
wire        online;
wire  [6:0] act_sreg;     // 7 most-recent framed bits (8th is the arriving TMSC)
wire        tdi_l, tms_l; // latched TDI/TMS presented to the TAP
wire        esc_tog_seen; // TCKC-domain copy of esc_tog (edge -> escape)

// Value INCLUDING the bit arriving this edge. Fields are stored first-sent-highest, so
// after the 8 code bits act_next[7:4] is OAC and act_next[3:0] is EC.
wire  [7:0] act_next  = {act_sreg[6:0], tmsc_i};

// EC decoded BY FIELD (Cl. 11.7.7.2 Tbl 11-2), not compared as a nibble:
//   act_next[0] = SHORT   (1 = short form; 0 = long form, adds a 24-bit register load)
//   act_next[1] = PROTECT (1 demands Voting Drive, Cl. 13.2.1.3 -- not implemented)
//   act_next[3:2] = STATE (00 = TLR/Run-Test-Idle, the only parking states this parks in)
// Rejecting PROTECT/STATE we do not support is conformant: Rule 11.9.5.2 b) makes a
// mismatch fail the selection test, leaving the node Offline.
wire        ec_short  = act_next[0];
wire        code_ok   = (act_next[7:4] == ACT_OAC) & (act_next[3:2] == 2'b00) & ~act_next[1];

// Long form loads 24 fixed bits (Tbl 11-4) before the Check Packet, ascending bit order,
// so SCNFMT (bits 23:19) is the LAST field on the wire, its own LSB first. Reversing the
// most-recent five bits recovers it. SCNFMT = 9 selects OScan1 (Cl. 23.4.1.4.5) -- the
// value a stock J-Link writes. Anything else is a format we do not implement.
wire  [4:0] grl_scnfmt = {act_next[0], act_next[1], act_next[2], act_next[3], act_next[4]};
wire        scnfmt_ok  = (grl_scnfmt == 5'd9);

// Edge on the synchronised toggle = a new escape. This path is used for the DRIVE
// inhibit only -- its 2-TCKC crossing latency is far too late to FRAME the activation.
wire escape_evt = (esc_tog_tckc ^ esc_tog_seen);

// FRAMING reference. Rule 11.7.6.2 c) makes OAC[0] the bit right after the escape, so
// the action must land on the very next TCKC rising edge. The escape's TERMINATING
// FALLING edge is the only edge available (there are none while TCKC is held high), and
// it sits exactly half a bit before that rising edge. esc_class is quasi-static by then
// -- it settled many clk_i cycles earlier, during the escape -- so this single-flop
// capture is not a race. It self-clears one bit later when esc_cnt clears, which makes
// it a natural one-bit-period pulse.
wire [1:0] esc_type_ng;
arv_ipdff #(.WIDTH(2), .ARST_EN(TCK_ARST), .CLK_NEGEDGE(1'b1)) u_esc_type_ng (
    .clk_i(tckc_i), .rst_n_i(tck_rst_n), .en_i(1'b1), .d_i(esc_class), .q_o(esc_type_ng));

wire esc_is_rst = (esc_type_ng == ESC_RST);
wire esc_is_sel = (esc_type_ng == ESC_SEL);
wire esc_is_des = (esc_type_ng == ESC_DESEL);


// Rule 11.7.6.2 c): "The data bit following the data bit coincident with a Selection
// Escape shall be used as the LSB of the Online Activation Code." So the sequence is
// FRAMED off a SELECTION escape -- not free-running, and not off a reset escape.
// act_cnt counts the 12 framed bits; act_armed says a frame is in progress.
wire        act_armed;
wire  [4:0] act_cnt;
wire  [2:0] act_phase;
reg         act_armed_nxt;
reg   [4:0] act_cnt_nxt;
reg   [2:0] act_phase_nxt;

reg  [1:0]  cnt_nxt;
reg         online_nxt;
reg   [6:0] act_sreg_nxt;
reg         tdi_l_nxt, tms_l_nxt;

always @(*) begin
    cnt_nxt       = cnt;
    online_nxt    = online;
    act_sreg_nxt  = act_sreg;
    tdi_l_nxt     = tdi_l;
    tms_l_nxt     = tms_l;
    act_armed_nxt = act_armed;
    act_cnt_nxt   = act_cnt;

    act_phase_nxt = act_phase;

    if (esc_is_rst | esc_is_des) begin
        // Reset (>=8) or deselect (4/5): go Offline and stop driving. Rule 14.5.2 b) --
        // "The TMSC signal shall not be driven provided ... The ADTAPC is Offline."
        // Any in-progress activation frame is abandoned.
        online_nxt    = 1'b0;
        act_sreg_nxt  = 7'd0;
        cnt_nxt       = 2'd0;
        act_armed_nxt = 1'b0;
        act_cnt_nxt   = 5'd0;
        act_phase_nxt = P_CODE;
    end else if (esc_is_sel) begin
        // Selection escape (6/7). The bit "coincident with" the escape is the one whose
        // TCKC-high phase was held for the escape itself; THIS edge -- the first rise
        // after the terminating fall -- already carries OAC[0], so arm AND consume it.
        online_nxt    = 1'b0;
        act_sreg_nxt  = {6'd0, tmsc_i};
        cnt_nxt       = 2'd0;
        act_armed_nxt = 1'b1;
        act_cnt_nxt   = 5'd1;
        act_phase_nxt = P_CODE;
    end else if (!online) begin
        // Offline: shift TMSC (LSB-first) ONLY inside an armed frame. Outside one,
        // arbitrary traffic must not be able to activate (the window is framed, not
        // free-running), so nothing is accumulated and nothing can match.
        cnt_nxt = 2'd0;
        if (act_armed) begin
            act_sreg_nxt = act_next[6:0];
            act_cnt_nxt  = act_cnt + 5'd1;
            case (act_phase)
                P_CODE :
                    if (act_cnt == 5'd7) begin
                        // 8 code bits complete. A bad OAC/EC ends the frame here -- the
                        // node simply stays Offline (Rule 11.9.5.2 b). SHORT picks the
                        // form: short goes straight to the CP, long loads 24 bits first.
                        if      (!code_ok) act_armed_nxt = 1'b0;
                        else if ( ec_short) act_phase_nxt = P_CP_PRE;
                        else begin act_phase_nxt = P_GRL; act_cnt_nxt = 5'd0; end
                    end
                P_GRL :
                    // Fixed 24 bits (Tbl 11-4). The CP Preamble follows immediately on
                    // the next bit -- no gap or delimiter (Rule 11.7.9.2 b) 2).
                    if (act_cnt == 5'd23) begin
                        if (scnfmt_ok) begin act_phase_nxt = P_CP_PRE; act_cnt_nxt = 5'd0; end
                        else           act_armed_nxt = 1'b0;   // format we do not implement
                    end
                P_CP_PRE :                              // one Preamble bit, value ignored
                    begin act_phase_nxt = P_CP_BODY; act_cnt_nxt = 5'd0; end
                P_CP_BODY :
                    // Rule 11.9.6.2 e): from the second body bit on, the last two body
                    // bits are the directive (a sliding window; the most recent bit is
                    // the MSB). CP_NOP extends the body by one bit, CP_END and CP_RSO
                    // end it after one more bit. act_cnt only marks "past the first
                    // bit" and saturates, so a long NOP run cannot wrap it.
                    begin
                        act_cnt_nxt = 5'd1;
                        if (act_cnt != 5'd0) begin
                            if      ({act_next[0], act_next[1]} == CP_END) act_phase_nxt = P_CP_POST;
                            else if ({act_next[0], act_next[1]} == CP_RSO) act_phase_nxt = P_CP_RSO;
                        end
                    end
                P_CP_RSO :
                    // Postamble after CP_RSO: a TAP.7 controller reset. The node stays
                    // Offline, which holds the TAP in reset and TMSC undriven.
                    begin
                        act_armed_nxt = 1'b0;
                        act_phase_nxt = P_CODE;
                    end
                default :                               // P_CP_POST: one Postamble bit
                    begin
                        act_armed_nxt = 1'b0;
                        act_phase_nxt = P_CODE;
                        online_nxt    = 1'b1;
                        cnt_nxt       = 2'd0;
                    end
            endcase
        end
    end else begin
        // Online: walk the 3-phase OScan1 packet.
        case (cnt)
            2'd0: begin tdi_l_nxt = ~tmsc_i; cnt_nxt = 2'd1; end   // nTDI
            2'd1: begin tms_l_nxt =  tmsc_i; cnt_nxt = 2'd2; end   // TMS
            default: cnt_nxt = 2'd0;                               // TDO (cnt==2)
        endcase
    end
end

arv_ipdff #(.WIDTH(2),  .ARST_EN(TCK_ARST)) u_cnt (
    .clk_i(tckc_i), .rst_n_i(tck_rst_n), .en_i(1'b1), .d_i(cnt_nxt),       .q_o(cnt));
arv_ipdff #(.WIDTH(1),  .ARST_EN(TCK_ARST)) u_online (
    .clk_i(tckc_i), .rst_n_i(tck_rst_n), .en_i(1'b1), .d_i(online_nxt),    .q_o(online));
arv_ipdff #(.WIDTH(7),  .ARST_EN(TCK_ARST)) u_act_sreg (
    .clk_i(tckc_i), .rst_n_i(tck_rst_n), .en_i(1'b1), .d_i(act_sreg_nxt),  .q_o(act_sreg));
arv_ipdff #(.WIDTH(1),  .ARST_EN(TCK_ARST)) u_act_armed (
    .clk_i(tckc_i), .rst_n_i(tck_rst_n), .en_i(1'b1), .d_i(act_armed_nxt), .q_o(act_armed));
arv_ipdff #(.WIDTH(5),  .ARST_EN(TCK_ARST)) u_act_cnt (
    .clk_i(tckc_i), .rst_n_i(tck_rst_n), .en_i(1'b1), .d_i(act_cnt_nxt),   .q_o(act_cnt));
arv_ipdff #(.WIDTH(3),  .ARST_EN(TCK_ARST)) u_act_phase (
    .clk_i(tckc_i), .rst_n_i(tck_rst_n), .en_i(1'b1), .d_i(act_phase_nxt), .q_o(act_phase));
arv_ipdff #(.WIDTH(1),  .ARST_EN(TCK_ARST)) u_tdi_l (
    .clk_i(tckc_i), .rst_n_i(tck_rst_n), .en_i(1'b1), .d_i(tdi_l_nxt),     .q_o(tdi_l));
arv_ipdff #(.WIDTH(1),  .ARST_EN(TCK_ARST)) u_tms_l (
    .clk_i(tckc_i), .rst_n_i(tck_rst_n), .en_i(1'b1), .d_i(tms_l_nxt),     .q_o(tms_l));
arv_ipdff #(.WIDTH(1),  .ARST_EN(TCK_ARST)) u_esc_tog_seen (
    .clk_i(tckc_i), .rst_n_i(tck_rst_n), .en_i(1'b1), .d_i(esc_tog_tckc),  .q_o(esc_tog_seen));

//=============================================================================
// TAP CLOCK ENABLE  -- the TAP runs on tckc_i and advances once per packet
//=============================================================================
// tdo_phase comes straight off the REGISTERED phase counter, not a transparent latch,
// so tmsc_oe below turns on cleanly at the TCKC falling edge instead of briefly
// holding the previous packet's value while the probe already drives.

wire tdo_phase = (cnt == 2'd2) & online;

//=============================================================================
// COLD-ATTACH WAKE
//=============================================================================
// Purely TCKC-domain, so it keeps toggling with clk_i stopped -- the escape detector
// cannot see a probe until the oscillator runs, and this is what asks for it.
// A toggle, NOT a level: nothing in this domain could clear a sticky level, since
// clearing it would need the very clock being started. Rationale: doc/arv_dtm_cjtag.md.
wire wake_tog;
arv_ipdff #(.WIDTH(1), .ARST_EN(TCK_ARST)) u_wake_tog (
    .clk_i(tckc_i), .rst_n_i(tck_rst_n), .en_i(1'b1), .d_i(~wake_tog), .q_o(wake_tog));
assign dbg_wakeup_o = wake_tog;

//=============================================================================
// TAP CORE  (driven by the reconstructed virtual 4-wire interface)
//=============================================================================
// TAP reset = POR AND online: held in TLR while offline, released in a known state.
// dbgresetn_i is POR-only so the TAP is initialised even before any activation, and
// arv_dtm_tap synchronises this into tck for a clean release. Combined via arv_and so
// the reset-tree gate stays one identifiable cell for PD.
// `online` is a scanned flop, so this reset is generated here and masked here.
wire tap_rst_n_raw, tap_rst_n;
arv_and #(.N(2)) u_tap_rst_and (.a_i({dbgresetn_i, online}),         .z_o(tap_rst_n_raw));
arv_or  #(.N(2)) u_tap_rst_or  (.a_i({tap_rst_n_raw, scan_mode_i}),  .z_o(tap_rst_n));

wire tap_tdo;
wire tap_tdo_oe;   // core shift-active; NOT used to gate TMSC framing (see below)

arv_dtm_tap #(
    .IDCODE_BASE   ( IDCODE_BASE ),
    .IDLE_HINT     ( IDLE_HINT   ),
    .ARST_EN       ( ARST_EN     )
) u_tap (
    .idcode_version_i ( idcode_version_i ),
    .tck_i            ( tckc_i           ),   // free-running probe clock
    .tck_en_i         ( tdo_phase        ),   // one enabled edge per OScan1 packet
    .tap_rst_n_i      ( tap_rst_n        ),
    .scan_mode_i      ( scan_mode_i      ),
    .tms_i            ( tms_l            ),
    .tdi_i            ( tdi_l            ),
    .tdo_o            ( tap_tdo          ),
    .tdo_oe_o         ( tap_tdo_oe       ),

    .hclk_i           ( clk_i            ),
    .dbgresetn_i      ( dbgresetn_i      ),
    .dmi_psel_o       ( dmi_psel_o       ),
    .dmi_penable_o    ( dmi_penable_o    ),
    .dmi_paddr_o      ( dmi_paddr_o      ),
    .dmi_pwrite_o     ( dmi_pwrite_o     ),
    .dmi_pwdata_o     ( dmi_pwdata_o     ),
    .dmi_pprot_o      ( dmi_pprot_o      ),
    .dmi_pready_i     ( dmi_pready_i     ),
    .dmi_prdata_i     ( dmi_prdata_i     ),
    .dmi_pslverr_i    ( dmi_pslverr_i    )
);

//=============================================================================
// TMSC OUTPUT: target drives TDO during the TDO phase while TCKC is LOW only
// (bus-keeper holds it for the probe on the rising edge -> contention-free).
//=============================================================================
assign tmsc_o       = tap_tdo;
// ~scan_mode_i: never drive the shared bidirectional pad in test mode.
// Go quiet the moment an escape is DETECTED, not when it finishes crossing into the
// TCKC domain: until the crossing lands the scan FSM still believes it is online, and
// would drive TDO into a DTS that has already moved on. esc_pending is compared across
// domains on purpose -- it can only ever RELEASE the bus early, never create a drive,
// so it needs no synchroniser to be safe.
wire   esc_pending  = esc_tog ^ esc_tog_tckc;

// Inhibits, earliest first: esc_hit from the 8th edge (Cl. 10.4.1.3 "immediately"),
// esc_type_ng from the terminating TCKC fall of any escape until `online` clears on the
// next rise, esc_pending from escape end until the toggle crosses, escape_evt for the
// edge it lands on. escape_evt is redundant with the negedge framing capture and is
// kept as defence: it costs one AND term.

wire oe_window      = tdo_phase & ~tckc_i;

assign tmsc_oe_o    = oe_window & ~scan_mode_i & (esc_type_ng == ESC_NONE)
                                & ~esc_hit & ~esc_pending & ~escape_evt;

// tap_tdo_oe intentionally unused (framing is unconditional); sink it for lint.
wire   cjtag_unused = 1'b0 | tap_tdo_oe;

endmodule // arv_dtm_cjtag

`default_nettype wire
