//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    cjtag_tasks
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : cjtag_tasks.v
// Module Description : cJTAG (IEEE 1149.7, OScan1) host-side BFM for driving the
//                      arv_dtm_cjtag 2-wire TAP. It models a debug probe (DTS):
//                      it drives TCKC and the probe half of the bidirectional
//                      TMSC, and reads TDO back in the third scan phase.
//
//   The whole point: the OScan1 packet carries exactly one TAP bit, so a single
//   primitive cjtag_bit(tms,tdi)->tdo reproduces the semantics of the JTAG
//   tck_cycle(). Every higher-level task below (tap_reset / shift_ir / shift_dr /
//   dmi_*) is therefore IDENTICAL to jtag_tasks.v -- if a stimulus passes over
//   both, the cJTAG link layer is proven transparent.
//
//   Packet (3 TCKC periods; probe drives TMSC in phases 1-2, target in phase 3):
//       phase 1: TMSC = nTDI   (probe)      phase 2: TMSC = TMS (probe)
//       phase 3: TMSC = TDO    (target)     -- probe releases, samples
//
//   Activation drives the SEGGER "short" online-activation (OAC=0x0C, EC=0x08,
//   CP=0x00) that arv_dtm_cjtag detects. NOTE: a real J-Link defaults to the
//   STANDARD sequence -- see arv_dtm_cjtag.v. This bench proves the datapath +
//   short-form activation are self-consistent; hardware interop needs a capture.
//----------------------------------------------------------------------------

// free_clk cycles per TCKC half-phase. TCKC period ~= 2*CJHALF clk_i. The module's
// bound is clk_i >= 8x TCKC (CJHALF = 4): the escape class must settle through the
// ~3-cycle synchroniser before the terminating TCKC fall. Default 16x; run_all also
// runs the cJTAG suite at the bound.
`ifndef CJHALF
  `define CJHALF 8
`endif
localparam integer CJHALF = `CJHALF;               // -D CJHALF=4 runs at the 8x minimum ratio

//=============================================================================
// One OScan1 scan bit: emit nTDI, TMS, then read TDO. Mirrors tck_cycle().
//=============================================================================
task cjtag_bit;
    input tms_val;
    input tdi_val;
    begin
        // -- phase 1: nTDI (probe drives) --
        host_tmsc_oe = 1'b1;  host_tmsc = ~tdi_val;
        repeat (CJHALF) @(posedge free_clk);
        tckc = 1'b1;  repeat (CJHALF) @(posedge free_clk);   // target samples nTDI on rising
        tckc = 1'b0;  repeat (CJHALF) @(posedge free_clk);   // -> S_TMS
        // -- phase 2: TMS (release TMSC at the falling edge, BEFORE the target
        //    enters S_TDO and starts driving -- clean bus turnaround) --
        host_tmsc = tms_val;
        repeat (CJHALF) @(posedge free_clk);
        tckc = 1'b1;  repeat (CJHALF) @(posedge free_clk);   // target samples TMS on rising
        tckc = 1'b0;  host_tmsc_oe = 1'b0;                   // lower + release together
        repeat (CJHALF) @(posedge free_clk);                 // target enters S_TDO, drives
        // -- phase 3: TDO (target drives; probe reads) --
        // SPEC-ACCURATE SAMPLING: IEEE 1149.7 / SEGGER both say the far side samples
        // on the RISING edge of TCKC, after the target has released and the KEEPER
        // holds the level -- NOT during the low phase while the target still drives.
        // Sampling early hides any dependence on the release/keeper handoff.
        tckc = 1'b1;
        tdo_sampled = tmsc;                                  // sample AT the rising edge
        repeat (CJHALF) @(posedge free_clk);                 // virtual TCK rises -> shift
        tckc = 1'b0;  repeat (CJHALF) @(posedge free_clk);   // virtual TCK falls -> S_NTDI
        host_tmsc_oe = 1'b1;  host_tmsc = 1'b1;              // re-acquire (target has deasserted)
    end
endtask

//=============================================================================
// Reset escape: >= 8 TMSC changes while TCKC held high (-> bridge offline).
//=============================================================================
task cjtag_escape;
    integer k;
    begin
        host_tmsc_oe = 1'b1;  host_tmsc = 1'b0;
        tckc = 1'b1;                                          // hold TCKC high
        repeat (CJHALF) @(posedge free_clk);
        for (k = 0; k < 10; k = k + 1) begin                 // >= 8 edges
            host_tmsc = ~host_tmsc;
            repeat (CJHALF) @(posedge free_clk);
        end
        tckc = 1'b0;  repeat (CJHALF) @(posedge free_clk);
        host_tmsc = 1'b1;  repeat (CJHALF) @(posedge free_clk);
        // Idle TCKC cycles so the escape reaches the TCKC domain BEFORE the first
        // real bit. The detector is oversampled on clk_i and crosses in via a 2FF
        // synchroniser, so it needs TCKC edges to land; until it does the scan FSM
        // still believes it is online and could drive TMSC into the host.
        // Keep DRIVING through the idle cycles -- a real DTS goes straight into
        // activation. The target must stay off the bus by itself (esc_pending).
        repeat (3) begin
            tckc = 1'b1;  repeat (CJHALF) @(posedge free_clk);
            tckc = 1'b0;  repeat (CJHALF) @(posedge free_clk);
        end
        host_tmsc_oe = 1'b1;  host_tmsc = 1'b1;
    end
endtask

//=============================================================================
// One offline activation bit (shifted on TCKC-rising; matched on TCKC-falling).
//=============================================================================
task cjtag_act_bit;
    input val;
    begin
        host_tmsc_oe = 1'b1;  host_tmsc = val;
        repeat (CJHALF) @(posedge free_clk);
        tckc = 1'b1;  repeat (CJHALF) @(posedge free_clk);
        tckc = 1'b0;  repeat (CJHALF) @(posedge free_clk);
    end
endtask

//=============================================================================
// Reset escape that PARKS TMSC at `park` and leaves it there (no trailing edge).
// The counters only clear on a TMSC edge while TCKC is low, so parking is the case
// that used to strand the escape one-shot and make activation fail.
//=============================================================================
// Escape with an EXACT number of TMSC changes, to probe the detection threshold:
// >= ESC_CHANGES (8) is a reset escape, fewer must leave the link untouched.
task cjtag_escape_n;
    input integer nchanges;
    integer k;
    begin
        host_tmsc_oe = 1'b1;  host_tmsc = 1'b0;
        tckc = 1'b1;                                          // hold TCKC high
        repeat (CJHALF) @(posedge free_clk);
        for (k = 0; k < nchanges; k = k + 1) begin
            host_tmsc = ~host_tmsc;
            repeat (CJHALF) @(posedge free_clk);
        end
        tckc = 1'b0;  repeat (CJHALF) @(posedge free_clk);
        // Released only because a SUB-threshold (selection) escape leaves the link
        // online with its packet phase misaligned from the DTS, and realignment is
        // not implemented (see doc/arv_dtm_cjtag.md). A reset escape needs no such
        // courtesy: the target self-mutes via esc_pending, which cjtag_escape_park
        // proves with the DTS driving right through.
        host_tmsc_oe = 1'b0;
        repeat (3) begin
            tckc = 1'b1;  repeat (CJHALF) @(posedge free_clk);
            tckc = 1'b0;  repeat (CJHALF) @(posedge free_clk);
        end
        host_tmsc_oe = 1'b1;  host_tmsc = 1'b1;
        repeat (CJHALF) @(posedge free_clk);
    end
endtask

// Selection escape whose TMSC is PARKED at a chosen level for the final change, then
// terminated. Used to prove the arming is independent of the parked level.
task cjtag_escape_park;
    input park;
    integer k;
    begin
        host_tmsc_oe = 1'b1;  host_tmsc = 1'b0;
        tckc = 1'b1;
        repeat (CJHALF) @(posedge free_clk);
        for (k = 0; k < 6; k = k + 1) begin           // 6 changes = selection escape
            host_tmsc = ~host_tmsc;
            repeat (CJHALF) @(posedge free_clk);
        end
        host_tmsc = park;                             // parked level, still TCKC high
        repeat (CJHALF) @(posedge free_clk);
        tckc = 1'b0;  repeat (CJHALF) @(posedge free_clk);   // terminating fall
    end
endtask

//=============================================================================
// Send the 12-bit short activation code (LSB-first per nibble: OAC=0x0C,
// EC=0x08, CP=0x00 -> bit stream 0x08C, seq[0] first). Assumes offline.
//=============================================================================
task cjtag_send_actcode;
    reg [11:0] seq;
    integer i;
    begin
        seq = 12'h08C;                                       // seq[0] sent first
        for (i = 0; i < 12; i = i + 1) cjtag_act_bit(seq[i]);
    end
endtask

//=============================================================================
// Short-form activation with an arbitrary Check Packet body: OAC + EC, the CP
// Preamble, `len` body bits (body[0] first), then the Postamble. Rule 11.9.6.2 e)
// makes the directive a sliding window: from the second body bit on, the last two
// body bits are the directive (CP_NOP = 01/10 extends by one bit, CP_END = 00 and
// CP_RSO = 11 end the body), so the caller passes the body up to and including
// the terminating directive and this task appends the single Postamble bit.
//=============================================================================
task cjtag_send_actcode_body;
    input [15:0] body;
    input integer len;
    reg [7:0] code;
    integer i;
    begin
        code = 8'h8C;                                    // OAC=0011, EC=0001 (LSB first)
        for (i = 0; i < 8; i = i + 1) cjtag_act_bit(code[i]);
        cjtag_act_bit(1'b0);                             // CP Preamble
        for (i = 0; i < len; i = i + 1) cjtag_act_bit(body[i]);
        cjtag_act_bit(1'b0);                             // CP Postamble
    end
endtask

// STANDARD (long) form activation, as a stock J-Link emits by default: OAC, then EC with
// SHORT=0, then the fixed 24-bit Global Register State, then the Check Packet. All
// register fields are zero except SCNFMT (bits 23:19) = 9 -> OScan1. Bits go out in
// ascending bit order, each field LSB first, so SCNFMT is last on the wire.
task cjtag_send_actcode_long;
    begin
        cjtag_send_actcode_long_part1;
        cjtag_send_actcode_long_part2;
    end
endtask

// Split so a test can probe mid-Global-Register-Load.
task cjtag_send_actcode_long_part1;              // OAC + EC(SHORT=0) + GRL bits 00..11
    reg [7:0] code;
    integer i;
    begin
        code = 8'h0C;                            // OAC=0011, EC=0000 (SHORT=0)
        for (i = 0; i < 8;  i = i + 1) cjtag_act_bit(code[i]);
        for (i = 0; i < 12; i = i + 1) cjtag_act_bit(1'b0);
    end
endtask

task cjtag_send_actcode_long_part2;              // GRL bits 12..23 + Check Packet
    integer i;
    begin
        for (i = 0; i < 7; i = i + 1) cjtag_act_bit(1'b0);   // bits 12..18
        cjtag_act_bit(1'b1);                     // SCNFMT bit19 = LSB of 9 (01001)
        cjtag_act_bit(1'b0);                     // bit20
        cjtag_act_bit(1'b0);                     // bit21
        cjtag_act_bit(1'b1);                     // bit22
        cjtag_act_bit(1'b0);                     // bit23 = MSB
        cjtag_act_bit(1'b0);                     // CP Preamble
        cjtag_act_bit(1'b0);  cjtag_act_bit(1'b0);   // CP_END
        cjtag_act_bit(1'b0);                     // CP Postamble
    end
endtask

// Bring the bridge online: escape, then the short activation code.
//=============================================================================
// Per Rule 11.7.6.2 c) the activation code is FRAMED off a SELECTION escape (6/7
// edges) -- NOT a reset escape -- and OAC[0] is the bit immediately following it. So
// there must be NO idle TCKC cycles between the escape and the code: with framing they
// would be consumed as activation bits.
task cjtag_activate;
    begin
        cjtag_escape_sel;
        cjtag_send_actcode;
    end
endtask

// Advance the packet phase counter by N TCKC pulses WITHOUT completing a packet, so a
// test can start an escape at a chosen cnt alignment. The host releases TMSC for the
// TDO phase exactly as cjtag_bit does, so no contention is introduced by the stimulus.
task cjtag_phase_advance;
    input integer n;
    integer k;
    begin
        for (k = 0; k < n; k = k + 1) begin
            host_tmsc_oe = 1'b1;  host_tmsc = 1'b1;
            repeat (CJHALF) @(posedge free_clk);
            tckc = 1'b1;  repeat (CJHALF) @(posedge free_clk);
            tckc = 1'b0;  host_tmsc_oe = 1'b0;      // release before any target drive
            repeat (CJHALF) @(posedge free_clk);
        end
    end
endtask

// Selection escape: 6 TMSC changes while TCKC is held high, terminated by the falling
// edge that frames the code. Nothing follows it -- the caller sends the 12 bits.
task cjtag_escape_sel;
    integer k;
    begin
        host_tmsc_oe = 1'b1;  host_tmsc = 1'b0;
        tckc = 1'b1;
        repeat (CJHALF) @(posedge free_clk);
        for (k = 0; k < 6; k = k + 1) begin
            host_tmsc = ~host_tmsc;
            repeat (CJHALF) @(posedge free_clk);
        end
        tckc = 1'b0;  repeat (CJHALF) @(posedge free_clk);    // terminating fall
    end
endtask

//=============================================================================
// ---- Everything below is IDENTICAL to jtag_tasks.v (cjtag_bit for tck_cycle) --
//=============================================================================

task tap_reset;
    integer k;
    begin
        // Bring the bridge online the first time any stimulus resets the TAP, so
        // JTAG-style tests (which never call dtm_init) transparently work over cJTAG.
        if (!cjtag_active_done) begin
            cjtag_activate;
            cjtag_active_done = 1'b1;
        end
        for (k = 0; k < 5; k = k + 1) cjtag_bit(1'b1, 1'b0);  // exactly 5 TMS=1 -> TLR
        cjtag_bit(1'b0, 1'b0);                                // -> Run-Test/Idle
    end
endtask

task idle_cycles;
    input integer n;
    integer k;
    begin
        for (k = 0; k < n; k = k + 1) cjtag_bit(1'b0, 1'b0);
    end
endtask

task shift_ir;
    input  [4:0] ir_val;
    integer i;
    begin
        cjtag_bit(1'b1, 1'b0);      // RTI   -> Select-DR
        cjtag_bit(1'b1, 1'b0);      //       -> Select-IR
        cjtag_bit(1'b0, 1'b0);      //       -> Capture-IR
        cjtag_bit(1'b0, 1'b0);      //       -> Shift-IR
        for (i = 0; i < 5; i = i + 1)
            cjtag_bit((i == 4) ? 1'b1 : 1'b0, ir_val[i]);    // last bit -> Exit1-IR
        cjtag_bit(1'b1, 1'b0);      // Exit1 -> Update-IR
        cjtag_bit(1'b0, 1'b0);      //       -> Run-Test/Idle
    end
endtask

task shift_dr;
    input  [63:0] tdi_dr;
    input  integer nbits;
    output [63:0] tdo_dr;
    integer i;
    begin
        tdo_dr = 64'b0;
        cjtag_bit(1'b1, 1'b0);      // RTI   -> Select-DR
        cjtag_bit(1'b0, 1'b0);      //       -> Capture-DR
        cjtag_bit(1'b0, 1'b0);      //       -> Shift-DR
        for (i = 0; i < nbits; i = i + 1) begin
            cjtag_bit((i == nbits-1) ? 1'b1 : 1'b0, tdi_dr[i]);  // last bit -> Exit1-DR
            tdo_dr[i] = tdo_sampled;
        end
        cjtag_bit(1'b1, 1'b0);      // Exit1 -> Update-DR
        cjtag_bit(1'b0, 1'b0);      //       -> Run-Test/Idle (launch fires here)
    end
endtask

task idcode_read;
    output [31:0] val;
    reg [63:0] cap;
    begin
        shift_ir(IR_IDCODE);
        shift_dr(64'b0, 32, cap);
        val = cap[31:0];
    end
endtask

task dtmcs_read;
    output [31:0] val;
    reg [63:0] cap;
    begin
        shift_ir(IR_DTMCS);
        shift_dr(64'b0, 32, cap);
        val = cap[31:0];
    end
endtask

task dtmcs_write;
    input [31:0] val;
    reg [63:0] cap;
    begin
        shift_ir(IR_DTMCS);
        shift_dr({32'b0, val}, 32, cap);
    end
endtask

task dmi_scan;
    input  [ABITS-1:0] addr;
    input  [31:0]      data;
    input  [1:0]       op;
    output [31:0]      cap_data;
    output [1:0]       cap_op;
    reg [63:0] tdi_dr;
    reg [63:0] cap;
    begin
        tdi_dr              = 64'b0;
        tdi_dr[1:0]         = op;
        tdi_dr[33:2]        = data;
        tdi_dr[ABITS+33:34] = addr;
        shift_dr(tdi_dr, DMI_DR_W, cap);
        cap_op   = cap[1:0];
        cap_data = cap[33:2];
    end
endtask

task dmi_read;
    input  [ABITS-1:0] addr;
    input  integer     idle_n;
    output [31:0]      data;
    output [1:0]       status;
    reg [31:0] d0;
    reg [1:0]  s0;
    begin
        dmi_scan(addr, 32'b0, OP_READ, d0, s0);
        idle_cycles(idle_n);
        dmi_scan({ABITS{1'b0}}, 32'b0, OP_NOP, data, status);
    end
endtask

task dmi_write;
    input [ABITS-1:0] addr;
    input [31:0]      data;
    input integer     idle_n;
    reg [31:0] d0;
    reg [1:0]  s0;
    begin
        dmi_scan(addr, data, OP_WRITE, d0, s0);
        idle_cycles(idle_n);
    end
endtask

task check_eq;
    input [127:0] name;
    input [63:0]  got;
    input [63:0]  exp;
    begin
        if (got !== exp) begin
            $display("ERROR: %0s expected 0x%0h got 0x%0h  %0t ns", name, exp, got, $time);
            error = error + 1;
        end else begin
            $display("PASS:  %0s == 0x%0h  %0t ns", name, got, $time);
        end
    end
endtask
