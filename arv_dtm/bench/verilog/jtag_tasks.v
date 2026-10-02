//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    jtag_tasks
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : jtag_tasks.v
// Module Description : JTAG host-side bus-functional tasks for driving the
//                      arv_dtm_jtag TAP.  Black-box: drives only TCK/TMS/TDI and
//                      samples only TDO -- no DUT-internal access.
//
//   IEEE 1149.1 edge discipline (must match a real debugger / OpenOCD):
//     + the HOST changes TMS/TDI on the FALLING edge of TCK,
//     + the DUT samples TMS/TDI on the RISING edge,
//     + the DUT updates TDO on the FALLING edge,
//     + the HOST samples TDO on the RISING edge.
//   tck_cycle() below implements exactly that relationship, so a DUT that
//   (incorrectly) drove TDO on the rising edge would be caught.
//----------------------------------------------------------------------------

//=============================================================================
// One TCK cycle: set TMS/TDI on negedge, sample TDO on the next posedge.
//=============================================================================
task tck_cycle;
    input tms_val;
    input tdi_val;
    begin
        @(negedge tck);
        tms = tms_val;
        tdi = tdi_val;
        @(posedge tck);
        tdo_sampled = tdo;          // host samples TDO on the rising edge
    end
endtask

//=============================================================================
// Move the TAP to Test-Logic-Reset, then to Run-Test/Idle.
//=============================================================================
task tap_reset;
    integer k;
    begin
        for (k = 0; k < 5; k = k + 1) tck_cycle(1'b1, 1'b0);  // exactly 5 TMS=1 -> TLR
        tck_cycle(1'b0, 1'b0);                                // -> Run-Test/Idle
    end
endtask

//=============================================================================
// Insert n Run-Test/Idle cycles (TMS=0) -- the dtmcs.idle CDC settling hint.
//=============================================================================
task idle_cycles;
    input integer n;
    integer k;
    begin
        for (k = 0; k < n; k = k + 1) tck_cycle(1'b0, 1'b0);
    end
endtask

//=============================================================================
// Shift the IR (5 bits, LSB first). Assumes Run-Test/Idle, returns to it.
//=============================================================================
task shift_ir;
    input  [4:0] ir_val;
    integer i;
    begin
        tck_cycle(1'b1, 1'b0);      // RTI   -> Select-DR
        tck_cycle(1'b1, 1'b0);      //       -> Select-IR
        tck_cycle(1'b0, 1'b0);      //       -> Capture-IR
        tck_cycle(1'b0, 1'b0);      //       -> Shift-IR
        for (i = 0; i < 5; i = i + 1)
            tck_cycle((i == 4) ? 1'b1 : 1'b0, ir_val[i]);   // last bit -> Exit1-IR
        tck_cycle(1'b1, 1'b0);      // Exit1 -> Update-IR
        tck_cycle(1'b0, 1'b0);      //       -> Run-Test/Idle
    end
endtask

//=============================================================================
// Shift a DR of arbitrary width (LSB first). Assumes Run-Test/Idle, returns to
// it. Captures the shifted-out value into tdo_dr. The DR-update side effects
// (e.g. a DMI launch) fire as the TAP passes through Update-DR.
//=============================================================================
task shift_dr;
    input  [63:0] tdi_dr;
    input  integer nbits;
    output [63:0] tdo_dr;
    integer i;
    begin
        tdo_dr = 64'b0;
        tck_cycle(1'b1, 1'b0);      // RTI   -> Select-DR
        tck_cycle(1'b0, 1'b0);      //       -> Capture-DR
        tck_cycle(1'b0, 1'b0);      //       -> Shift-DR (DR now holds capture value)
        for (i = 0; i < nbits; i = i + 1) begin
            tck_cycle((i == nbits-1) ? 1'b1 : 1'b0, tdi_dr[i]);  // last bit -> Exit1-DR
            tdo_dr[i] = tdo_sampled;
        end
        tck_cycle(1'b1, 1'b0);      // Exit1 -> Update-DR
        tck_cycle(1'b0, 1'b0);      //       -> Run-Test/Idle (launch fires here)
    end
endtask

//=============================================================================
// Read IDCODE (IR=IDCODE, 32-bit DR).
//=============================================================================
task idcode_read;
    output [31:0] val;
    reg [63:0] cap;
    begin
        shift_ir(IR_IDCODE);
        shift_dr(64'b0, 32, cap);
        val = cap[31:0];
    end
endtask

//=============================================================================
// Read / write dtmcs (IR=DTMCS, 32-bit DR).
//=============================================================================
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

//=============================================================================
// Raw DMI DR scan (IR must already be DMI). Assembles the
// {address, data, op} field and returns the captured {address, data, op}.
//   dmi DR layout: [ABITS+33:34]=address, [33:2]=data, [1:0]=op
//=============================================================================
task dmi_scan;
    input  [ABITS-1:0] addr;
    input  [31:0]      data;
    input  [1:0]       op;
    output [31:0]      cap_data;
    output [1:0]       cap_op;
    reg [63:0] tdi_dr;
    reg [63:0] cap;
    begin
        tdi_dr            = 64'b0;
        tdi_dr[1:0]       = op;
        tdi_dr[33:2]      = data;
        tdi_dr[ABITS+33:34] = addr;
        shift_dr(tdi_dr, DMI_DR_W, cap);
        cap_op   = cap[1:0];
        cap_data = cap[33:2];
    end
endtask

//=============================================================================
// Full DMI read: launch a read, settle, then collect the result with a nop
// scan. Returns data + status. Caller is responsible for IR=DMI.
//=============================================================================
task dmi_read;
    input  [ABITS-1:0] addr;
    input  integer     idle_n;
    output [31:0]      data;
    output [1:0]       status;
    reg [31:0] d0;
    reg [1:0]  s0;
    begin
        dmi_scan(addr, 32'b0, OP_READ, d0, s0);   // launch read
        idle_cycles(idle_n);                      // settle the CDC
        dmi_scan({ABITS{1'b0}}, 32'b0, OP_NOP, data, status); // collect result
    end
endtask

//=============================================================================
// Full DMI write: launch a write, settle. Caller is responsible for IR=DMI.
//=============================================================================
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

//=============================================================================
// Simple pass/fail checker (mirrors the aclint bench style).
//=============================================================================
task check_eq;
    input [127:0] name;     // short label (packed ASCII)
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
