//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dmi_hardreset_fail_race
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dmi_hardreset_fail_race
// Module Description : dmihardreset racing a FAILING (PSLVERR) completion of the
//                      transfer it abandons: no sticky failure and no errinfo
//                      survives the hardreset, whatever edge PREADY lands on.
//
//   Debug 1.0 Sec 6.1.4 dmihardreset: "Writing 1 to this bit does a hard reset of the
//   DTM, causing the DTM to forget about any outstanding DMI transactions".
//   doc/arv_dtm_jtag.md dtmcs table: dmihardreset "resets the bus FSM, the in-flight
//   flag, the sticky error and errinfo"; errinfo "4 = unknown (reset / no error),
//   3 = device error -- the DM signalled PSLVERR".
//
//   Same sweep as dmi_hardreset_race, but the held read targets slave_fault_addr
//   with slave_fault_en = 1, so its completion carries PSLVERR. The hclk edge Nf on
//   which the abandon drops PSEL is calibrated once, then PREADY+PSLVERR is placed
//   on edge Nf + k, k = -4 .. +4 (k = -1: the failing completion is sampled on the
//   same edge the hardreset takes effect; k <= -2: it completes, and latches a
//   failure, before the hardreset reaches the bus side). Each pass re-checks the
//   PSEL fall edge against the calibration.
//
//   Per offset, after the hardreset: a nop poll reports op = 0, dtmcs reads
//   errinfo = 4 and dmistat = 0, no new PSEL appears until the next launch, and a
//   fresh read of a second (non-faulting) address seeded for this pass round-trips
//   with success. The subordinate is released and back to idle before anything new
//   is launched (the model does not drop a transfer when PSEL falls).
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
   reg [31:0] dt;
   begin
      slave_hold = 1'b0;
      repeat (20) @(posedge free_clk);
      slave_mem[HR_ADDR_F] = 32'h5EED_0000 + k + 16;

      shift_ir(IR_DMI);
      dmi_scan({ABITS{1'b0}}, 32'b0, OP_NOP, rd, st);
      check_eq("poll_op", st, OP_SUCCESS);

      dtmcs_read(dt);
      check_eq("errinfo", {29'd0, dt[20:18]}, 32'd4);
      check_eq("dmistat", {30'd0, dt[11:10]}, 32'd0);
      shift_ir(IR_DMI);

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
      slave_latency    = 1;
      slave_fault_en   = 1'b1;
      slave_fault_addr = HR_ADDR_H;

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
      $display("|  Link still works, faults still reported      |");
      $display(" ===============================================");
      shift_ir(IR_DMI);
      dmi_write(7'h36, 32'h0BAD_C0DE, DTM_IDLE_N);
      dmi_read (7'h36, DTM_IDLE_N, rd, st);
      check_eq("final_op",   st, OP_SUCCESS);
      check_eq("final_data", rd, 32'h0BAD_C0DE);
      dmi_read (HR_ADDR_H, DTM_IDLE_N, rd, st);
      check_eq("held_fails", st, OP_FAILED);    // the fault address still faults
      dtmcs_read(rd);
      check_eq("errinfo_dev", {29'd0, rd[20:18]}, 32'd3);
      dtmcs_write(32'h0001_0000);               // dmireset
      dtmcs_read(rd);
      check_eq("errinfo_clr", {29'd0, rd[20:18]}, 32'd4);
      check_eq("dmistat_clr", {30'd0, rd[11:10]}, 32'd0);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
