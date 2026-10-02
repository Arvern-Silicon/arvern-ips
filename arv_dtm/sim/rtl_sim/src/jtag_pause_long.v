//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    jtag_pause_long
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : jtag_pause_long
// Module Description : A DMI access or an IR load whose shift is parked in
//                      Pause-DR / Pause-IR for several TCKs executes exactly as
//                      shifted, both when the shift resumes (Exit2 -> Shift) and
//                      when it updates straight from the pause (Exit2 -> Update).
//
//   IEEE 1149.1 makes Pause-DR/IR and the Exit2 -> Update-DR/IR arc mandatory, and a
//   debugger may take either exit. doc/arv_dtm_jtag.md: "A DMI op is launched at
//   Update-DR when IR=dmi and op != nop. The result is collected on a later scan:
//   the Capture-DR value carries the address of the last launched op, its data (read
//   data) and its op status". `jtag_pause_resume` covers IDCODE read-out across a
//   pause; this test covers the side effects: the launched op and the IR update.
//
//   TDI is driven 1 on every Pause/Exit2 cycle, so a spurious shift there corrupts
//   the value. Per DMI scan: the 41 bits shifted out across the pause equal the
//   documented capture of the previous (completed) read, exactly one PSEL appears,
//   the target address holds the written word and no other subordinate location
//   changed; a normal read-back returns it. Per IR scan: the register that follows
//   is the one selected (dtmcs against a reference read, the dmi capture, IDCODE).
//   Every TAP clock is driven through tck_cycle; the bench's TAP model checks TDO
//   enable in every state visited.
//----------------------------------------------------------------------------

reg [31:0] pl_snap [0:127];
reg        pl_watch;
integer    pl_rise;
integer    pl_a;
integer    pl_bad;

initial begin
   pl_watch = 1'b0;
   pl_rise  = 0;
end

always @(posedge dmi_psel) if (pl_watch) pl_rise = pl_rise + 1;

// DR scan through Pause-DR after `nfirst` bits, parked `npause` extra cycles.
// nfirst < nbits: Exit2-DR -> Shift-DR, finish, Exit1 -> Update.
// nfirst = nbits: Exit2-DR -> Update-DR directly.
task pl_shift_dr;
   input  [63:0]  tdi_dr;
   input  integer nbits;
   input  integer nfirst;
   input  integer npause;
   output [63:0]  tdo_dr;
   integer i;
   begin
      tdo_dr = 64'b0;
      tck_cycle(1'b1, 1'b0);                     // RTI      -> Select-DR
      tck_cycle(1'b0, 1'b0);                     //          -> Capture-DR
      tck_cycle(1'b0, 1'b0);                     //          -> Shift-DR
      for (i = 0; i < nfirst; i = i + 1) begin
         tck_cycle((i == nfirst-1) ? 1'b1 : 1'b0, tdi_dr[i]);   // last -> Exit1-DR
         tdo_dr[i] = tdo_sampled;
      end
      tck_cycle(1'b0, 1'b1);                     // Exit1    -> Pause-DR
      for (i = 0; i < npause; i = i + 1)
         tck_cycle(1'b0, 1'b1);                  // parked
      tck_cycle(1'b1, 1'b1);                     // Pause    -> Exit2-DR
      if (nfirst < nbits) begin
         tck_cycle(1'b0, 1'b1);                  // Exit2    -> Shift-DR
         for (i = nfirst; i < nbits; i = i + 1) begin
            tck_cycle((i == nbits-1) ? 1'b1 : 1'b0, tdi_dr[i]); // last -> Exit1-DR
            tdo_dr[i] = tdo_sampled;
         end
         tck_cycle(1'b1, 1'b0);                  // Exit1    -> Update-DR
      end else
         tck_cycle(1'b1, 1'b1);                  // Exit2    -> Update-DR
      tck_cycle(1'b0, 1'b0);                     //          -> Run-Test/Idle
   end
endtask

// IR scan through Pause-IR after `nfirst` bits (same two exits as above).
task pl_shift_ir;
   input  [4:0]   ir_val;
   input  integer nfirst;
   input  integer npause;
   integer i;
   begin
      tck_cycle(1'b1, 1'b0);                     // RTI      -> Select-DR
      tck_cycle(1'b1, 1'b0);                     //          -> Select-IR
      tck_cycle(1'b0, 1'b0);                     //          -> Capture-IR
      tck_cycle(1'b0, 1'b0);                     //          -> Shift-IR
      for (i = 0; i < nfirst; i = i + 1)
         tck_cycle((i == nfirst-1) ? 1'b1 : 1'b0, ir_val[i]);   // last -> Exit1-IR
      tck_cycle(1'b0, 1'b1);                     // Exit1    -> Pause-IR
      for (i = 0; i < npause; i = i + 1)
         tck_cycle(1'b0, 1'b1);                  // parked
      tck_cycle(1'b1, 1'b1);                     // Pause    -> Exit2-IR
      if (nfirst < 5) begin
         tck_cycle(1'b0, 1'b1);                  // Exit2    -> Shift-IR
         for (i = nfirst; i < 5; i = i + 1)
            tck_cycle((i == 4) ? 1'b1 : 1'b0, ir_val[i]);       // last -> Exit1-IR
         tck_cycle(1'b1, 1'b0);                  // Exit1    -> Update-IR
      end else
         tck_cycle(1'b1, 1'b1);                  // Exit2    -> Update-IR
      tck_cycle(1'b0, 1'b0);                     //          -> Run-Test/Idle
   end
endtask

function [63:0] pl_dmi_word;
   input [6:0]  addr;
   input [31:0] data;
   input [1:0]  op;
   begin
      pl_dmi_word = {23'b0, addr, data, op};
   end
endfunction

task pl_snapshot;
   begin
      for (pl_a = 0; pl_a < 128; pl_a = pl_a + 1) pl_snap[pl_a] = slave_mem[pl_a];
      pl_rise  = 0;
      pl_watch = 1'b1;
   end
endtask

// Exactly one transfer; only `addr` changed, to `val` (a read: nothing changed).
task pl_check_bus;
   input [6:0]  addr;
   input [31:0] val;
   begin
      repeat (10) @(posedge free_clk);
      pl_watch = 1'b0;
      check_eq("one_psel", pl_rise, 1);
      pl_bad = 0;
      for (pl_a = 0; pl_a < 128; pl_a = pl_a + 1)
         if ((pl_a != addr) && (slave_mem[pl_a] !== pl_snap[pl_a])) pl_bad = pl_bad + 1;
      check_eq("others_intact", pl_bad, 0);
      check_eq("target_word", slave_mem[addr], val);
   end
endtask

// One paused DMI write whose shift-out must be the capture of the last read.
task pl_paused_write;
   input [6:0]    addr;
   input [31:0]   val;
   input integer  nfirst;
   input integer  npause;
   input [63:0]   exp_cap;
   reg   [63:0]   cap;
   reg   [31:0]   rd;
   reg    [1:0]   st;
   begin
      $display("INFO:  paused write 0x%0h -> [0x%0h], split %0d, pause %0d",
               val, addr, nfirst, npause);
      pl_snapshot;
      pl_shift_dr(pl_dmi_word(addr, val, OP_WRITE), DMI_DR_W, nfirst, npause, cap);
      idle_cycles(DTM_IDLE_N);
      check_eq("capture_out", cap[DMI_DR_W-1:0], exp_cap);
      pl_check_bus(addr, val);
      dmi_read(addr, DTM_IDLE_N, rd, st);        // leaves {addr, val, 0} as the capture
      check_eq("readback_op",   st, OP_SUCCESS);
      check_eq("readback_data", rd, val);
   end
endtask

initial
   begin : test
      reg [63:0] cap;
      reg [31:0] dref;
      reg [31:0] rd;
      reg  [1:0] st;
      reg [31:0] id;

      dtm_init;                                   // TLR -> RTI, IR = DMI
      slave_latency = 1;
      for (pl_a = 0; pl_a < 128; pl_a = pl_a + 1) slave_mem[pl_a] = 32'h1000_0000 + pl_a;
      dtmcs_read(dref);                           // reference, clean state

      $display(" ===============================================");
      $display("|  Pause-DR -> Exit2 -> Shift: DMI write        |");
      $display(" ===============================================");
      shift_ir(IR_DMI);
      dmi_read(7'h12, DTM_IDLE_N, rd, st);
      check_eq("seed_read", rd, 32'h1000_0012);
      pl_paused_write(7'h3A, 32'hC0DE_0A3A,  1, 3, pl_dmi_word(7'h12, 32'h1000_0012, OP_SUCCESS));
      pl_paused_write(7'h3B, 32'hC0DE_0B3B, 17, 5, pl_dmi_word(7'h3A, 32'hC0DE_0A3A, OP_SUCCESS));
      pl_paused_write(7'h3C, 32'hC0DE_0C3C, 40, 8, pl_dmi_word(7'h3B, 32'hC0DE_0B3B, OP_SUCCESS));

      $display(" ===============================================");
      $display("|  Pause-DR -> Exit2 -> Update: DMI write/read  |");
      $display(" ===============================================");
      pl_paused_write(7'h3D, 32'hC0DE_0D3D, DMI_DR_W, 3, pl_dmi_word(7'h3C, 32'hC0DE_0C3C, OP_SUCCESS));
      pl_paused_write(7'h3E, 32'hC0DE_0E3E, DMI_DR_W, 6, pl_dmi_word(7'h3D, 32'hC0DE_0D3D, OP_SUCCESS));

      // A read launched from the pause: collected by a plain nop scan.
      pl_snapshot;
      pl_shift_dr(pl_dmi_word(7'h21, 32'b0, OP_READ), DMI_DR_W, DMI_DR_W, 4, cap);
      idle_cycles(DTM_IDLE_N);
      check_eq("capture_rd", cap[DMI_DR_W-1:0], pl_dmi_word(7'h3E, 32'hC0DE_0E3E, OP_SUCCESS));
      pl_check_bus(7'h21, 32'h1000_0021);
      shift_dr(64'b0, DMI_DR_W, cap);             // nop
      check_eq("paused_read", cap[DMI_DR_W-1:0], pl_dmi_word(7'h21, 32'h1000_0021, OP_SUCCESS));

      $display(" ===============================================");
      $display("|  Pause-IR -> Exit2 -> Update                  |");
      $display(" ===============================================");
      // IR is DMI here; the update must select dtmcs.
      pl_shift_ir(IR_DTMCS, 5, 4);
      shift_dr(64'b0, 32, cap);
      check_eq("ir_upd_dtmcs", cap[31:0], dref);

      pl_shift_ir(IR_IDCODE, 5, 3);
      shift_dr(64'b0, 32, cap);
      check_eq("ir_upd_idcode", cap[31:0], DUT_IDCODE);

      $display(" ===============================================");
      $display("|  Pause-IR -> Exit2 -> Shift                   |");
      $display(" ===============================================");
      // IR is IDCODE here; resume into DMI -> the capture of the paused read.
      pl_shift_ir(IR_DMI, 2, 5);
      shift_dr(64'b0, DMI_DR_W, cap);
      check_eq("ir_shf_dmi", cap[DMI_DR_W-1:0], pl_dmi_word(7'h21, 32'h1000_0021, OP_SUCCESS));

      pl_shift_ir(IR_DTMCS, 4, 3);
      shift_dr(64'b0, 32, cap);
      check_eq("ir_shf_dtmcs", cap[31:0], dref);

      // Normal navigation still works.
      tap_reset;
      idcode_read(id);
      check_eq("idcode_after", id, DUT_IDCODE);

      repeat (8) @(posedge tck);
      stimulus_done = 1'b1;
   end
