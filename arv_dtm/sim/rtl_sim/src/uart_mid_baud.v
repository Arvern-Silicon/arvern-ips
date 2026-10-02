//----------------------------------------------------------------------------
// File Name          : uart_mid_baud
// Module Description : Auto-baud locks across the middle of the legal range (SLOW
//                      build, AB_BREAK_CLKS=65536, ceiling 4096 clk/bit).
//
//   The default build caps the measurable bit period at 43 clocks and
//   uart_slow_baud locks only at 4096, so no other test locks a divisor in between
//   -- where real links run (arv_dtm_uart.md baud table: 434 clk/bit at 50 MHz /
//   115200, 868 at 100 MHz) -- nor an odd one. Legs at 17, 434, 868, 2047 and 3071 clk/bit,
//   each ended by a break (a low longer than AB_BREAK_CLKS) that forces the re-lock
//   of the next leg. Each leg checks the locked divisor and round-trips data words
//   heavy in 0x00/0xFF bytes. It opens with a 40000-clock low before any lock, longer
//   than any acceptable 0x80 at this ceiling: abandoned, nothing locks.
//----------------------------------------------------------------------------

task mid_leg;
   input integer clks;
   reg [31:0] rd;
   reg [1:0]  st;
   integer    div;
   begin
      $display("----- leg: %0d clk/bit -----", clks);
      host_bit_ns = clks * (FREE_HALF * 2.0);
      uart_autobaud_sync;
      check_eq("locked", {31'd0, dut.g_uart.u_dtm.ab_done}, 32'd1);
      div = dut.g_uart.u_dtm.ab_div;
      if ((div < clks - 1) || (div > clks + 1)) begin
         $display("ERROR: divisor %0d for %0d clk/bit  %0t ns", div, clks, $time);
         error = error + 1;
      end else
         $display("PASS:  divisor %0d for %0d clk/bit  %0t ns", div, clks, $time);
      dmi_uart(7'h10, OP_WRITE, 32'hFF00_FF00, st, rd);
      dmi_uart(7'h10, OP_READ,  32'h0,         st, rd);
      check_eq("rd_ff00", rd, 32'hFF00_FF00);
      dmi_uart(7'h2B, OP_WRITE, 32'h00FF_00FF, st, rd);
      dmi_uart(7'h2B, OP_READ,  32'h0,         st, rd);
      check_eq("rd_00ff", rd, 32'h00FF_00FF);
      check_eq("st_00ff", st, OP_SUCCESS);
   end
endtask

task long_break;                              // > AB_BREAK_CLKS (65536) of continuous low
   integer k;
   begin
      uart_rx = 1'b0;
      for (k = 0; k < 70000; k = k + 1) @(posedge free_clk);
      uart_rx = 1'b1;
      for (k = 0; k < 64; k = k + 1) @(posedge free_clk);
      check_eq("unlocked", {31'd0, dut.g_uart.u_dtm.ab_done}, 32'd0);
      while (rx_wr !== rx_rd) rx_rd = (rx_rd + 1) & 255;
   end
endtask

initial
   begin : test
      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      slave_latency = 0;

      // Pre-lock low longer than any acceptable 0x80 at this ceiling (8 x 4096):
      // abandoned, no lock, the first leg then locks normally.
      begin : prelock
         integer k;
         uart_rx = 1'b0;
         for (k = 0; k < 40000; k = k + 1) @(posedge free_clk);
         uart_rx = 1'b1;
         for (k = 0; k < 64; k = k + 1) @(posedge free_clk);
         check_eq("no_lock_prelock", {31'd0, dut.g_uart.u_dtm.ab_done}, 32'd0);
      end

      mid_leg(17);
      long_break;
      mid_leg(434);
      long_break;
      mid_leg(868);
      long_break;
      mid_leg(2047);
      long_break;
      mid_leg(3071);

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
