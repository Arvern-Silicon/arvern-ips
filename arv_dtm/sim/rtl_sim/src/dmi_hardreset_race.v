//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dmi_hardreset_race
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dmi_hardreset_race
// Module Description : dmihardreset racing the completion of the transfer it
//                      abandons: whatever edge PREADY lands on, nothing of the
//                      abandoned read survives the hardreset.
//
//   Debug 1.0 Sec 6.1.4 dmihardreset: "Writing 1 to this bit does a hard reset of the
//   DTM, causing the DTM to forget about any outstanding DMI transactions".
//   doc/arv_dtm_jtag.md dtmcs table: dmihardreset "resets the bus FSM, the in-flight
//   flag, the sticky error and errinfo; the last captured data/op and the shift
//   registers keep their values, so a nop scan after it returns stale data with
//   op = success". doc/arv_dtm.md: "the master drops psel/penable mid-ACCESS without
//   waiting for pready ... the orphan pready lands on an idle master".
//
//   A read is held by the subordinate (slave_hold) and dmihardreset is written. The
//   hclk edge Nf on which the abandon drops PSEL is calibrated once (the read is held
//   throughout), then the subordinate is released so its PREADY rises on edge
//   Nf + k, k = -4 .. +4. k = -1 is the true race: the completion is sampled on the
//   same edge the hardreset takes effect. Timing is made deterministic: over JTAG
//   every pass starts on a TCK rising edge at the same phase against clk (TCK:clk =
//   3.1 advances the phase 1 ns per TCK), over cJTAG TCKC is derived from clk. Each
//   pass re-checks the PSEL fall edge against the calibration, so a pass that slips
//   a cycle is an error rather than a silently shifted sweep.
//
//   Per offset: no new PSEL appears until the next launch, a nop poll reports
//   op = 0 (data unspecified, not checked), and a fresh read of a second address
//   seeded for this pass returns its value with success -- no stale data or status
//   from the abandoned read. The subordinate is released and allowed to return to
//   idle before anything new is launched: the model does not drop a transfer when
//   PSEL falls, and the hub page makes that ordering the integrator's obligation.
//----------------------------------------------------------------------------

localparam integer HR_MAXCYC = 20000;             // clk edges to wait for the PSEL fall
localparam [6:0]   HR_ADDR_H = 7'h24;             // held (abandoned) read
localparam [6:0]   HR_ADDR_F = 7'h35;             // fresh read after the hardreset

integer hr_nf_cal;      // calibrated abandon edge (clk rising edges after t0)
integer hr_nf;          // PSEL fall edge measured in the current pass (-1 = none)
integer hr_rel;         // slave_hold released after this edge (-1 = never)
integer hr_n;
integer hr_k;
integer hr_guard;
integer hr_psel_rise;
reg     hr_watch;

initial begin
   hr_watch     = 1'b0;
   hr_psel_rise = 0;
end

always @(posedge dmi_psel) if (hr_watch) hr_psel_rise = hr_psel_rise + 1;

// Launch the held read and bring the host to a reproducible t0.
task hr_launch_held;
   reg [31:0] d0;
   reg  [1:0] s0;
   begin
      slave_hold = 1'b1;
      shift_ir(IR_DMI);
      dmi_scan(HR_ADDR_H, 32'b0, OP_READ, d0, s0);
      idle_cycles(8);
      check_eq("apb_held", {dmi_psel, dmi_penable}, 2'b11);
`ifndef DTM_CJTAG
      hr_guard = 0;
      while ((($time - 5) % 10 != 3) && (hr_guard < 12)) begin
         idle_cycles(1);
         hr_guard = hr_guard + 1;
      end
      if (($time - 5) % 10 != 3) begin
         $display("ERROR: TCK phase alignment not reached  %0t ns", $time);
         error = error + 1;
      end
`endif
   end
endtask

// From t0: write dmihardreset while counting clk edges; release the subordinate
// after edge hr_rel (hr_rel < 0 keeps it held).
task hr_hardreset_timed;
   begin
      hr_nf = -1;
      fork
         dtmcs_write(32'h0002_0000);                // dmihardreset = bit17
         begin
            hr_n = 0;
            while ((hr_n < HR_MAXCYC) && ((hr_nf < 0) || (hr_n < hr_rel))) begin
               @(posedge free_clk);
               #1;
               hr_n = hr_n + 1;
               if ((hr_nf < 0) && (dmi_psel !== 1'b1)) hr_nf = hr_n;
               if (hr_n == hr_rel) slave_hold = 1'b0;
            end
         end
      join
      if (hr_nf < 0) begin
         $display("ERROR: PSEL never fell after dmihardreset  %0t ns", $time);
         error = error + 1;
      end
   end
endtask

// After the release: let the subordinate return to idle, then check the link.
task hr_check_after;
   input integer k;
   reg [31:0] rd;
   reg  [1:0] st;
   begin
      slave_hold = 1'b0;
      repeat (20) @(posedge free_clk);
      slave_mem[HR_ADDR_F] = 32'h5EED_0000 + k + 16;

      shift_ir(IR_DMI);
      dmi_scan({ABITS{1'b0}}, 32'b0, OP_NOP, rd, st);
      check_eq("poll_op", st, OP_SUCCESS);

      hr_watch = 1'b0;
      check_eq("no_phantom", hr_psel_rise, 0);

      dmi_read(HR_ADDR_F, DTM_IDLE_N, rd, st);
      check_eq("fresh_op",   st, OP_SUCCESS);
      check_eq("fresh_data", rd, (32'h5EED_0000 + k + 16) & 64'hFFFF_FFFF);
   end
endtask

initial
   begin : test
      reg [31:0] rd;
      reg  [1:0] st;

      dtm_init;
      slave_latency = 1;

      $display(" ===============================================");
      $display("|  Calibrate the abandon edge (read held)       |");
      $display(" ===============================================");
      slave_mem[HR_ADDR_H] = 32'hDEAD_0000;
      hr_launch_held;
      hr_psel_rise = 0;
      hr_watch     = 1'b1;
      hr_rel       = -1;
      hr_hardreset_timed;
      hr_nf_cal = hr_nf;
      $display("INFO:  abandon edge Nf = %0d clk after t0", hr_nf_cal);
      hr_check_after(-16);

      $display(" ===============================================");
      $display("|  Sweep PREADY from Nf-4 to Nf+4               |");
      $display(" ===============================================");
      for (hr_k = -4; hr_k <= 4; hr_k = hr_k + 1) begin
         $display("INFO:  offset k = %0d", hr_k);
         slave_mem[HR_ADDR_H] = 32'hDEAD_0000 + hr_k + 16;
         hr_launch_held;
         hr_psel_rise = 0;
         hr_watch     = 1'b1;
         hr_rel       = hr_nf_cal + hr_k - 1;       // PREADY rises on edge Nf + k
         hr_hardreset_timed;
         // k >= -1: PSEL falls on the abandon edge, exactly as calibrated.
         // k <= -2: the read completes first, so PSEL falls before it.
         if (hr_k >= -1)
            check_eq("abandon_edge", hr_nf, hr_nf_cal);
         else if (hr_nf >= hr_nf_cal) begin
            $display("ERROR: k=%0d: PSEL fell at %0d, expected completion before %0d  %0t ns",
                     hr_k, hr_nf, hr_nf_cal, $time);
            error = error + 1;
         end
         hr_check_after(hr_k);
      end

      $display(" ===============================================");
      $display("|  Held address untouched, link still works     |");
      $display(" ===============================================");
      shift_ir(IR_DMI);
      dmi_write(7'h36, 32'h0BAD_C0DE, DTM_IDLE_N);
      dmi_read (7'h36, DTM_IDLE_N, rd, st);
      check_eq("final_op",   st, OP_SUCCESS);
      check_eq("final_data", rd, 32'h0BAD_C0DE);
      dmi_read (HR_ADDR_H, DTM_IDLE_N, rd, st);
      check_eq("held_data",  rd, 32'hDEAD_0000 + 4 + 16);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
