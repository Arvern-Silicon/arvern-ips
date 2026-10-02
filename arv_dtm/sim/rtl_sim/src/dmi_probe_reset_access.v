//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dmi_probe_reset_access
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dmi_probe_reset_access
// Module Description : TRST asserted during a DMI write's APB transfer truncates
//                      it cleanly: the Debug Module sees the whole write or none.
//
//   The Debug Module stays out of reset (dbgresetn high) and keeps sampling the
//   bus while trst_n clears the DTM. trst_n is pulsed at 1 ns steps across the
//   SETUP and ACCESS cycles of a write with no wait states. Per offset: every
//   other subordinate location is untouched, the target holds either its old
//   or its new value (never a mix), and after re-initialising the TAP a fresh
//   read-back round-trips. The APB monitor exempts the truncation itself.
//----------------------------------------------------------------------------

integer off;
integer a;
integer bad;
reg     armed;

initial armed = 1'b0;

always @(posedge dmi_psel) if (armed) begin
   armed = 1'b0;
   #(off);
   trst_n = 1'b0;
   #(20);
   trst_n = 1'b1;
end

initial
   begin : test
      reg [31:0] d0;
      reg  [1:0] s0;
      reg [31:0] rd;
      reg  [1:0] st;

      @(posedge dbgresetn);
      @(posedge trst_n);
      repeat (4) @(posedge tck);
      slave_latency = 0;

      for (off = 0; off < 30; off = off + 1) begin
         for (a = 0; a < 128; a = a + 1) slave_mem[a] = 32'h1000_0000 + a;
         tap_reset;
         shift_ir(IR_DMI);
         armed = 1'b1;
         dmi_scan(7'h3C, 32'hC0FF_EE3C, OP_WRITE, d0, s0);
         repeat (40) @(posedge free_clk);

         bad = 0;
         for (a = 0; a < 128; a = a + 1)
            if ((a != 'h3C) && (slave_mem[a] !== 32'h1000_0000 + a)) bad = bad + 1;
         check_eq("others_intact", bad, 0);
         if ((slave_mem[7'h3C] !== 32'h1000_003C) && (slave_mem[7'h3C] !== 32'hC0FF_EE3C)) begin
            $display("ERROR: offset %0d: torn write 0x%0h  %0t ns", off, slave_mem[7'h3C], $time);
            error = error + 1;
         end

         repeat (4) @(posedge tck);
         tap_reset;
         shift_ir(IR_DMI);
         dmi_read(7'h11, DTM_IDLE_N, rd, st);
         check_eq("after_op",   st, OP_SUCCESS);
         check_eq("after_data", rd, 32'h1000_0011);
      end

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
