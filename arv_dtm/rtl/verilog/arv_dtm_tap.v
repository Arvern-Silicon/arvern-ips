//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arv_dtm_tap
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arv_dtm_tap.v
// Module Description : Protocol-neutral RISC-V Debug Spec 1.0 TAP core. This is
//                      the reusable heart of the DTM: everything a JTAG-style
//                      Test Access Port needs, driven by a VIRTUAL 4-wire
//                      interface (tck / tap_rst_n / tms / tdi / tdo / tdo_oe)
//                      rather than by physical pins.
//
//   It contains:
//     + the 16-state JTAG TAP controller,
//     + the IR (instruction register) and its decode (IDCODE/DTMCS/DMI/BYPASS),
//     + the IDCODE / dtmcs / dmi / BYPASS data registers,
//     + the DMI sticky busy/error tracking (spec section "DMI register"), and
//     + an instance of the transport-agnostic arv_dtm_dmi_master, which owns the
//       single TCK <-> hclk clock-domain crossing and drives the arvern DMI bus.
//
//   Link layers wrap this core:
//     + arv_dtm_jtag   -- maps physical TCK/TRST_n/TMS/TDI/TDO pins 1:1 onto the
//                         virtual interface (the standard 4-wire IEEE 1149.1 TAP).
//     + arv_dtm_cjtag  -- reconstructs the virtual tck/tms/tdi and
//                         synthesizes tap_rst_n from an IEEE 1149.7 OScan1 2-wire
//                         (TCKC/TMSC) stream, then reads tdo back per scan bit.
//   Because the core is clocked entirely by the virtual tck and reset by the
//   virtual tap_rst_n, a link layer only has to supply clean edges: it needs no
//   knowledge of the DTMCS/DMI register semantics below.
//
//   Edge discipline (mandated by IEEE 1149.1, exercised by the bench):
//     + tms and tdi are sampled on the RISING edge of tck.
//     + tdo is updated on the FALLING edge of tck (so a host samples a stable
//       value on the next rising edge). tdo is only driven during Shift-DR /
//       Shift-IR (tdo_oe_o gates the consumer). A 2-wire link that issues a full
//       high->low tck pulse per scan bit reads the same post-shift tdo the pin
//       TAP presents on its falling edge.
//
//   DMI busy / sticky-error semantics (spec): a DMI op launches at Update-DR
//   (IR=dmi, op != nop). Reading the dmi register while the previous op is
//   still in flight -- or launching a new op then -- reports BUSY (3) and
//   latches a sticky condition that stalls further ops until cleared; the
//   dtmcs.idle hint is what lets the debugger avoid it. A completed op that
//   returned op=failed latches sticky the same way. dtmcs.dmireset clears the
//   sticky condition without disturbing any outstanding transaction;
//   dtmcs.dmihardreset also drops the outstanding transaction (DMI-master FSM
//   back to idle). The PRIMARY vs SECONDARY busy triggers are commented at the
//   launch / sticky-error logic below.
//----------------------------------------------------------------------------
`default_nettype none

module  arv_dtm_tap #(
    parameter            [27:0] IDCODE_BASE  = 28'h000_01F7,    // IDCODE[27:0]: part-number [27:12], manufacturer
                                                                // [11:1], and the mandatory 1 at [0]. OVERRIDE at
                                                                // integration. The VERSION field [31:28] is NOT here --
                                                                // it arrives on idcode_version_i so an ECO can bump it
                                                                // without re-synthesis. Manufacturer [11:1] defaults
                                                                // to Arvern Silicon's JEDEC JEP106 identity (IEEE
                                                                // 1149.1-2001 12.2.1); part-number [27:12] defaults to
                                                                // 0x0000 (unassigned): integrators set their own; see
                                                                // arv_dtm.md.
    parameter             [2:0] IDLE_HINT    = 3'd3,            // dtmcs.idle: Run-Test/Idle cycles hint to the debugger
    parameter                   ARST_EN      = 1'b1             // Reset style: 1=async active-low, 0=sync
) (

// Virtual TAP interface (tck domain) -- driven by a link-layer wrapper
    input  wire                 tck_i,                          // (virtual) TAP clock
    input  wire                 tck_en_i,                       // 1 = this tck edge is a TAP clock
    input  wire                 tap_rst_n_i,                    // (virtual) active-low TAP reset (async if ARST_EN)
    input  wire                 tms_i,                          // test mode select (sampled on rising tck)
    input  wire                 tdi_i,                          // test data in     (sampled on rising tck)
    output wire                 tdo_o,                          // test data out    (updated on falling tck)
    output wire                 tdo_oe_o,                       // TDO output enable (high only while shifting)

// IDCODE[31:28]: the version field
    input  wire           [3:0] idcode_version_i,               // Version specified as a port so it can easily be ECO-ed

// DFT
    input  wire                 scan_mode_i,                    // 1 = test mode (shift and capture): hold resets inactive

// aRVern DMI bus
    input  wire                 hclk_i,                         // MUST be the ungated oscillator
    input  wire                 dbgresetn_i,                    // the Debug Module's reset (hclk domain)

    output wire                 dmi_psel_o,
    output wire                 dmi_penable_o,
    output wire           [8:0] dmi_paddr_o,                    // [DMI_ABITS+1:0]
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
// DMI address width. Fixed at the arvern core's value; not a knob (no use case
// for another width). Sets the dmi DR width DW and the APB paddr port [8:0].
localparam                      DMI_ABITS = 7;
localparam                      DW = DMI_ABITS + 34;  // dmi DR width: addr + 32 data + 2 op

// IR opcodes (5-bit IR per the DTM chapter). BYPASS (0x1f) and every other
// unassigned opcode select the bypass register via the default decode below.
localparam                [4:0] IR_IDCODE   = 5'h01,
                                IR_DTMCS    = 5'h10,
                                IR_DMI      = 5'h11;

// DMI op encodings (request side). NOP (0) is the absence of read/write and is
// implied by ~dmi_op_active; it needs no named constant in the RTL.
localparam                [1:0] OP_READ     = 2'd1,
                                OP_WRITE    = 2'd2;
// DMI status encodings (response / sticky side)
localparam                [1:0] OP_FAILED_S = 2'd2,
                                OP_BUSY     = 2'd3;

// Both reset synchronisers are forced ASYNCHRONOUS, independently of ARST_EN.
//   TCK  side: TCK may not be running at all, so a synchronous reset could never
//              initialise the front end.
//   hclk side: the SOURCE is tap_rst_n_i, which the link layer builds from trst_n_i --
//              a raw probe pin with no minimum width (IEEE 1149.1 specs TRST* async).
//              With a synchronous reset here, a trst_n_i pulse shorter than one hclk
//              period asserts the TCK domain and is NEVER OBSERVED on the hclk side:
//              the toggle handshake's two halves then reset asymmetrically and the
//              surviving edge launches an unrequested APB read of DMI 0x00.
// Making it async is structural; the alternative -- demanding a minimum pulse width on
// an externally driven pin -- is a contract that cannot be enforced.
localparam                      TCK_ARST    = 1'b1;
localparam                      HCLK_ARST   = 1'b1;

// dtmcs.errinfo encodings (Sec 6.1.4)
localparam [2:0] ERRINFO_DEVICE  = 3'd3,   // DMI subordinate reported an error (PSLVERR)
                 ERRINFO_UNKNOWN = 3'd4;   // no error / no further detail; reset value

// Reset conditioning for BOTH domains. tap_rst_n_i already asserts on either
// underlying reset (the link layer ANDs them), so one synchroniser per domain is
// enough -- and because the same source feeds both, "either reset asserts both
// domains" holds by construction, which is what arv_dtm_dmi_master's toggle
// handshake depends on.
//
// scan_mode masks the OUTPUTS (the nets that reach flop reset pins): the
// synchroniser flops are scannable, so in test mode their outputs are scan data and
// would otherwise reset flops mid-chain (shift) or mid-capture.
wire tap_rst_n;
wire tap_rst_n_sync;                // tck  domain (this TAP + the master's TCK side)
wire hclk_rst_n, hclk_rst_n_sync;   // hclk domain (the master's DMI-bus side)
wire hclk_rst_n_align;

arv_synchronizer #(.W(1), .RST_VAL(1'b0), .ARST_EN(TCK_ARST)) u_tap_rst_sync (
                      .clk_i(tck_i),  .rst_n_i(tap_rst_n_i), .async_i(1'b1), .sync_o(tap_rst_n_sync));
arv_synchronizer #(.W(1), .RST_VAL(1'b0), .ARST_EN(HCLK_ARST)) u_hclk_rst_sync (
                      .clk_i(hclk_i), .rst_n_i(tap_rst_n_i), .async_i(1'b1), .sync_o(hclk_rst_n_sync));

// A TAP-only reset (TRST, cJTAG offline) must reach the DMI bus side on an hclk edge:
// the Debug Module keeps running on dbgresetn_i and samples PSEL/PADDR/PWDATA, so an
// asynchronous clear mid-ACCESS could present it a torn transfer. The synchroniser
// above still catches a pulse of any width; this flop only aligns its assertion.
// Its own reset is dbgresetn_i, which resets the Debug Module in the same cycle, and
// it stays asynchronous like the synchroniser so dbgresetn_i never reaches a D pin.
arv_ipdff #(.WIDTH(1), .RST_VAL(1'b0), .ARST_EN(HCLK_ARST)) u_hclk_rst_align (
                      .clk_i(hclk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(hclk_rst_n_sync), .q_o(hclk_rst_n_align));

arv_or #(.N(2)) u_tap_rst_or  (.a_i({tap_rst_n_sync,  scan_mode_i}),  .z_o(tap_rst_n));
arv_or #(.N(2)) u_hclk_rst_or (.a_i({hclk_rst_n_align, scan_mode_i}), .z_o(hclk_rst_n));

// TAP controller states
localparam                [3:0] S_TLR       = 4'h0,   // Test-Logic-Reset
                                S_RTI       = 4'h1,   // Run-Test/Idle
                                S_SEL_DR    = 4'h2,
                                S_CAP_DR    = 4'h3,
                                S_SHF_DR    = 4'h4,
                                S_EX1_DR    = 4'h5,
                                S_PAU_DR    = 4'h6,
                                S_EX2_DR    = 4'h7,
                                S_UPD_DR    = 4'h8,
                                S_SEL_IR    = 4'h9,
                                S_CAP_IR    = 4'ha,
                                S_SHF_IR    = 4'hb,
                                S_EX1_IR    = 4'hc,
                                S_PAU_IR    = 4'hd,
                                S_EX2_IR    = 4'he,
                                S_UPD_IR    = 4'hf;

//=============================================================================
// TAP STATE REGISTER + NEXT-STATE
//=============================================================================
wire [3:0] state;
reg  [3:0] next_state;

always @(*) begin
    case (state)
        S_TLR              : next_state = tms_i ? S_TLR    : S_RTI;
        S_RTI              : next_state = tms_i ? S_SEL_DR : S_RTI;
        S_SEL_DR           : next_state = tms_i ? S_SEL_IR : S_CAP_DR;
        S_CAP_DR           : next_state = tms_i ? S_EX1_DR : S_SHF_DR;
        S_SHF_DR           : next_state = tms_i ? S_EX1_DR : S_SHF_DR;
        S_EX1_DR           : next_state = tms_i ? S_UPD_DR : S_PAU_DR;
        S_PAU_DR           : next_state = tms_i ? S_EX2_DR : S_PAU_DR;
        S_EX2_DR           : next_state = tms_i ? S_UPD_DR : S_SHF_DR;
        S_UPD_DR           : next_state = tms_i ? S_SEL_DR : S_RTI;
        S_SEL_IR           : next_state = tms_i ? S_TLR    : S_CAP_IR;
        S_CAP_IR           : next_state = tms_i ? S_EX1_IR : S_SHF_IR;
        S_SHF_IR           : next_state = tms_i ? S_EX1_IR : S_SHF_IR;
        S_EX1_IR           : next_state = tms_i ? S_UPD_IR : S_PAU_IR;
        S_PAU_IR           : next_state = tms_i ? S_EX2_IR : S_PAU_IR;
        S_EX2_IR           : next_state = tms_i ? S_UPD_IR : S_SHF_IR;
      /*S_UPD_IR*/ default : next_state = tms_i ? S_SEL_DR : S_RTI;
    endcase
end

// state-decode strobes
wire cap_dr = (state == S_CAP_DR);
wire shf_dr = (state == S_SHF_DR);
wire upd_dr = (state == S_UPD_DR);
wire cap_ir = (state == S_CAP_IR);
wire shf_ir = (state == S_SHF_IR);
wire upd_ir = (state == S_UPD_IR);
wire tlr    = (state == S_TLR);


//=============================================================================
// IR + DECODE
//=============================================================================
wire  [4:0] ir;          // committed instruction
wire  [4:0] ir_sr;       // IR shift register

wire        ir_is_idcode = (ir == IR_IDCODE);
wire        ir_is_dtmcs  = (ir == IR_DTMCS);
wire        ir_is_dmi    = (ir == IR_DMI);


//=============================================================================
// DMI MASTER (CDC + bus FSM) -- all TCK-side status comes back from here
//=============================================================================
wire        dm_inflight;
wire [31:0] dm_rdata;
wire  [1:0] dm_cstatus;

// Sticky DMI error state (spec): 0 = none, 2 = failed, 3 = busy. BOTH the
// failed(2) and busy(3) conditions are sticky -- once set, the reported status
// holds and further DMI ops are dropped until dtmcs.dmireset clears it.
wire  [1:0] sticky_err;
wire        fail_pend;

// completion edge: dm_inflight is a clean TCK-domain level from the master
// (set on launch, cleared on ack). Its falling edge marks a finished op, with
// dm_cstatus simultaneously updated to that op's status.
wire        dm_inflight_d;
wire        complete_edge   = dm_inflight_d & ~dm_inflight;

// An abort (dmihardreset) also drops dm_inflight
wire        abort_pending;
wire        complete_failed = complete_edge & (dm_cstatus == OP_FAILED_S) & ~abort_pending;

// combined status reported to the debugger (dmi op field + dtmcs.dmistat). The
// idle path reports success(0): a genuine failure is held by sticky_err (which
// dmireset clears), and on its retiring edge by complete_failed
wire  [1:0] combined_status = dm_inflight      ? OP_BUSY     :
                             (sticky_err != 0) ? sticky_err  :
                             complete_failed   ? OP_FAILED_S :
                                                 2'd0        ;


//=============================================================================
// DATA REGISTERS (capture / shift)
//=============================================================================
wire   [31:0] dr_idcode;
wire   [31:0] dr_dtmcs;
wire [DW-1:0] dr_dmi;
wire          dr_bypass;
wire    [2:0] errinfo;

// dtmcs capture value
wire   [31:0] dtmcs_capture = { 11'b0,                  // [31:21] reserved
                                 errinfo,               // [20:18] errinfo (Sec 6.1.4)
                                 2'b0,                  // [17:16] dmihardreset/dmireset (W1, read 0)
                                 1'b0,                  // [15]    reserved
                                 IDLE_HINT,             // [14:12] idle hint
                                 combined_status,       // [11:10] dmistat
                                 DMI_ABITS[5:0],        // [9:4]   abits
                                 4'd1 };                // [3:0]   version = 1

// dmi capture value: { address of the last launched op, data=rdata, op=status }.
// Sec 6.1.5: after a successful read, address is the address that was read from.
wire [DMI_ABITS-1:0] dmi_last_addr;
wire [DW-1:0] dmi_capture   = { dmi_last_addr, dm_rdata, combined_status };


//=============================================================================
// DMI REQUEST FIELDS (from the shifted-in dmi register at Update-DR)
//=============================================================================
wire [DMI_ABITS-1:0] dmi_req_addr  = dr_dmi[DW-1:34];
wire          [31:0] dmi_req_wdata = dr_dmi[33:2];
wire           [1:0] dmi_req_op    = dr_dmi[1:0];

wire                 dmi_op_active = (dmi_req_op == OP_READ) | (dmi_req_op == OP_WRITE);

// launch only when idle and no sticky error pending. ~complete_failed is defensive:
// an op completing at this Update-DR was in flight at the same scan's Capture-DR,
// which already latched busy, so (sticky_err == 2'd0) blocks the launch first.
// These two cross into arv_dtm_dmi_master's toggle handshake, which needs a pulse ONE
// tck cycle wide. upd_dr is a state decode, so it stays high for a whole TAP clock
// period -- three tck_i cycles on cJTAG, where tck_i is the free-running probe clock
// and only one edge per packet is enabled. Qualifying with tck_en_i makes the pulse
// one cycle again; on JTAG tck_en_i is constant 1 and this is a no-op.
wire                 dmi_launch    = tck_en_i & upd_dr & ir_is_dmi   & dmi_op_active & ~dm_inflight & (sticky_err == 2'd0) & ~complete_failed;
// dtmcs.dmihardreset -> abort outstanding transaction in the master
wire                 dmi_hardreset = tck_en_i & upd_dr & ir_is_dtmcs & dr_dtmcs[17];


//=============================================================================
// SEQUENTIAL: TAP state, IR, DRs, sticky-busy
//=============================================================================
reg     [4:0] ir_nxt;
reg     [4:0] ir_sr_nxt;
reg    [31:0] dr_idcode_nxt;
reg    [31:0] dr_dtmcs_nxt;
reg  [DW-1:0] dr_dmi_nxt;
reg           dr_bypass_nxt;
reg     [1:0] sticky_err_nxt;
reg     [2:0] errinfo_nxt;
reg           abort_pending_nxt;
reg           fail_pend_nxt;

always @(*) begin
    ir_nxt            = ir;
    ir_sr_nxt         = ir_sr;
    dr_idcode_nxt     = dr_idcode;
    dr_dtmcs_nxt      = dr_dtmcs;
    dr_dmi_nxt        = dr_dmi;
    dr_bypass_nxt     = dr_bypass;
    sticky_err_nxt    = sticky_err;
    errinfo_nxt       = errinfo;
    fail_pend_nxt     = fail_pend;

    // Arm on an abort of an in-flight op; disarm on the resulting completion
    // edge (which complete_failed then ignores). Only that one edge is masked.
    abort_pending_nxt = abort_pending;
    if      (dmi_hardreset & dm_inflight) abort_pending_nxt = 1'b1;
    else if (complete_edge)               abort_pending_nxt = 1'b0;

    // ---- Instruction register ----
    if (tlr)          ir_nxt    = IR_IDCODE;       // TLR forces IDCODE
    else if (upd_ir)  ir_nxt    = ir_sr;           // commit shifted IR

    if (cap_ir)       ir_sr_nxt = 5'b00001;        // IEEE 1149.1: LSBs load as ...01
    else if (shf_ir)  ir_sr_nxt = {tdi_i, ir_sr[4:1]};

    // ---- Data registers: capture ----
    if (cap_dr) begin
        dr_idcode_nxt = {idcode_version_i, IDCODE_BASE};   // version is ECO-strapped, not elaborated
        dr_dtmcs_nxt  = dtmcs_capture;
        dr_dmi_nxt    = dmi_capture;
        dr_bypass_nxt = 1'b0;
        // PRIMARY busy: debugger read the dmi register before the op finished.
        if (ir_is_dmi & dm_inflight)
            sticky_err_nxt = OP_BUSY;
    end
    // ---- Data registers: shift ----
    else if (shf_dr) begin
        if      (ir_is_idcode) dr_idcode_nxt = {tdi_i, dr_idcode[31:1]};
        else if (ir_is_dtmcs)  dr_dtmcs_nxt  = {tdi_i, dr_dtmcs[31:1]};
        else if (ir_is_dmi)    dr_dmi_nxt    = {tdi_i, dr_dmi[DW-1:1]};
        else                   dr_bypass_nxt = tdi_i;
    end

    // ---- Sticky-failed: a completed op returned op=failed ----
    // Latched here (not just reported) so subsequent ops are dropped until
    // dmireset, exactly like the busy condition.
    if (complete_failed & (sticky_err == 2'd0)) begin
        sticky_err_nxt = OP_FAILED_S;
        // The only failure this DTM can attribute: the completion carried PSLVERR, i.e.
        // the subordinate itself reported the error. Updated with op, per Sec 6.1.4.
        errinfo_nxt    = ERRINFO_DEVICE;
    end
    // A failure behind a busy sticky is held until dmireset clears the busy, so
    // the scan the debugger repeats after it (B.2.1) reports the failure.
    if (complete_failed & (sticky_err != 2'd0))
        fail_pend_nxt  = 1'b1;

    // ---- Update-DR side effects ----
    if (upd_dr) begin
        if (ir_is_dmi) begin
            // SECONDARY busy: requested an op while one is in flight.
            if (dmi_op_active & dm_inflight & (sticky_err == 2'd0))
                sticky_err_nxt = OP_BUSY;
        end
        if (ir_is_dtmcs) begin
            // dmireset (bit16) or dmihardreset (bit17) clears the sticky error;
            // dmireset then exposes a failure held behind it. Evaluated last so an
            // explicit reset wins over any concurrent set.
            if (dr_dtmcs[17]) begin
                sticky_err_nxt = 2'd0;
                errinfo_nxt    = ERRINFO_UNKNOWN;
                fail_pend_nxt  = 1'b0;
            end else if (dr_dtmcs[16]) begin
                sticky_err_nxt = fail_pend ? OP_FAILED_S    : 2'd0;
                errinfo_nxt    = fail_pend ? ERRINFO_DEVICE : ERRINFO_UNKNOWN;
                fail_pend_nxt  = 1'b0;
            end
        end
    end
end


//=============================================================================
// TAP / IR / DR / sticky registers (arv_ipdff, TCK domain, tap_rst_n async reset)
//=============================================================================

arv_ipdff #(.WIDTH(4),  .RST_VAL(S_TLR),     .ARST_EN(TCK_ARST)) u_state (
                                      .clk_i(tck_i), .rst_n_i(tap_rst_n), .en_i(tck_en_i), .d_i(next_state),    .q_o(state));

arv_ipdff #(.WIDTH(5),  .RST_VAL(IR_IDCODE), .ARST_EN(TCK_ARST)) u_ir (
                                      .clk_i(tck_i), .rst_n_i(tap_rst_n), .en_i(tck_en_i), .d_i(ir_nxt),        .q_o(ir));

arv_ipdff #(.WIDTH(5),  .RST_VAL(5'b00001),  .ARST_EN(TCK_ARST)) u_ir_sr (
                                      .clk_i(tck_i), .rst_n_i(tap_rst_n), .en_i(tck_en_i), .d_i(ir_sr_nxt),     .q_o(ir_sr));

arv_ipdff #(.WIDTH(32),                      .ARST_EN(TCK_ARST)) u_dr_idcode (
                                      .clk_i(tck_i), .rst_n_i(tap_rst_n), .en_i(tck_en_i), .d_i(dr_idcode_nxt), .q_o(dr_idcode));

arv_ipdff #(.WIDTH(32),                      .ARST_EN(TCK_ARST)) u_dr_dtmcs (
                                      .clk_i(tck_i), .rst_n_i(tap_rst_n), .en_i(tck_en_i), .d_i(dr_dtmcs_nxt),  .q_o(dr_dtmcs));

arv_ipdff #(.WIDTH(DW),                      .ARST_EN(TCK_ARST)) u_dr_dmi (
                                      .clk_i(tck_i), .rst_n_i(tap_rst_n), .en_i(tck_en_i), .d_i(dr_dmi_nxt),    .q_o(dr_dmi));

arv_ipdff #(.WIDTH(DMI_ABITS),               .ARST_EN(TCK_ARST)) u_dmi_last_addr (
                                      .clk_i(tck_i), .rst_n_i(tap_rst_n), .en_i(dmi_launch), .d_i(dmi_req_addr), .q_o(dmi_last_addr));

arv_ipdff #(.WIDTH(1),                       .ARST_EN(TCK_ARST)) u_dr_bypass (
                                      .clk_i(tck_i), .rst_n_i(tap_rst_n), .en_i(tck_en_i), .d_i(dr_bypass_nxt), .q_o(dr_bypass));

arv_ipdff #(.WIDTH(2),                       .ARST_EN(TCK_ARST)) u_sticky_err (
                                      .clk_i(tck_i), .rst_n_i(tap_rst_n), .en_i(tck_en_i), .d_i(sticky_err_nxt), .q_o(sticky_err));
arv_ipdff #(.WIDTH(3), .RST_VAL(ERRINFO_UNKNOWN), .ARST_EN(TCK_ARST)) u_errinfo (
                                      .clk_i(tck_i), .rst_n_i(tap_rst_n), .en_i(tck_en_i), .d_i(errinfo_nxt),    .q_o(errinfo));

arv_ipdff #(.WIDTH(1),                       .ARST_EN(TCK_ARST)) u_fail_pend (
                                      .clk_i(tck_i), .rst_n_i(tap_rst_n), .en_i(tck_en_i), .d_i(fail_pend_nxt),  .q_o(fail_pend));

// Track the in-flight level to detect op completion (for sticky-failed).
arv_ipdff #(.WIDTH(1),                       .ARST_EN(TCK_ARST)) u_dm_inflight_d (
                                      .clk_i(tck_i), .rst_n_i(tap_rst_n), .en_i(tck_en_i), .d_i(dm_inflight),   .q_o(dm_inflight_d));

// Masks the completion edge produced by a dmihardreset abort (not a real ack).
arv_ipdff #(.WIDTH(1),                       .ARST_EN(TCK_ARST)) u_abort_pending (
                                      .clk_i(tck_i), .rst_n_i(tap_rst_n), .en_i(tck_en_i), .d_i(abort_pending_nxt), .q_o(abort_pending));


//=============================================================================
// TDO: select active register LSB, retime on FALLING TCK
//=============================================================================

wire shift_tdo    = shf_ir       ? ir_sr[0]     :
                    ir_is_idcode ? dr_idcode[0] :
                    ir_is_dtmcs  ? dr_dtmcs[0]  :
                    ir_is_dmi    ? dr_dmi[0]    :
                                   dr_bypass    ;

wire shift_active = shf_dr | shf_ir;

wire tdo_neg;
wire tdo_oe_neg;

// TDO retimes on the FALLING edge of TCK (IEEE 1149.1) -> arv_ipdff CLK_NEGEDGE.
// Deliberately NOT gated by tck_en_i: both inputs derive from flops that only move
// on an enabled rising edge, so a free-running falling edge re-latches the same
// value. Gating them would need the enable that applied to the PREVIOUS rising
// edge, which is a needless extra flop.
arv_ipdff #(.WIDTH(1), .ARST_EN(TCK_ARST), .CLK_NEGEDGE(1'b1)) u_tdo_neg (
                                         .clk_i(tck_i), .rst_n_i(tap_rst_n), .en_i(1'b1), .d_i(shift_tdo),    .q_o(tdo_neg));

arv_ipdff #(.WIDTH(1), .ARST_EN(TCK_ARST), .CLK_NEGEDGE(1'b1)) u_tdo_oe_neg (
                                         .clk_i(tck_i), .rst_n_i(tap_rst_n), .en_i(1'b1), .d_i(shift_active), .q_o(tdo_oe_neg));

assign tdo_o    = tdo_neg;
assign tdo_oe_o = tdo_oe_neg;

//=============================================================================
// DMI MASTER INSTANCE
//=============================================================================

arv_dtm_dmi_master #(.TCK_ARST_EN ( TCK_ARST ),   // external probe clock: must be async
                     .CLK_ARST_EN ( ARST_EN  )) u_dmi_master (

    // TCK side
    .tck_i           ( tck_i              ),
    .tck_resetn_i    ( tap_rst_n          ),
    .launch_i        ( dmi_launch         ),
    .req_addr_i      ( dmi_req_addr       ),
    .req_op_i        ( dmi_req_op         ),
    .req_data_i      ( dmi_req_wdata      ),
    .hardreset_i     ( dmi_hardreset      ),
    .inflight_o      ( dm_inflight        ),
    .rdata_o         ( dm_rdata           ),
    .cstatus_o       ( dm_cstatus         ),

    // DMI bus side
    .hclk_i          ( hclk_i             ),
    .hclk_resetn_i   ( hclk_rst_n         ),
    .dmi_psel_o      ( dmi_psel_o         ),
    .dmi_penable_o   ( dmi_penable_o      ),
    .dmi_paddr_o     ( dmi_paddr_o        ),
    .dmi_pwrite_o    ( dmi_pwrite_o       ),
    .dmi_pwdata_o    ( dmi_pwdata_o       ),
    .dmi_pprot_o     ( dmi_pprot_o        ),
    .dmi_pready_i    ( dmi_pready_i       ),
    .dmi_prdata_i    ( dmi_prdata_i       ),
    .dmi_pslverr_i   ( dmi_pslverr_i      )
);

//=============================================================================
// PARAMETER / IDCODE SANITY
//=============================================================================
// pragma translate_off
generate
    if (IDCODE_BASE[0] != 1'b1) begin : CHECK_IDCODE
        initial $fatal(1, "arv_dtm_tap: IDCODE_BASE LSB must be 1 per IEEE 1149.1 (got 0x%07x).", IDCODE_BASE);
    end
endgenerate
// pragma translate_on

endmodule // arv_dtm_tap

`default_nettype wire
