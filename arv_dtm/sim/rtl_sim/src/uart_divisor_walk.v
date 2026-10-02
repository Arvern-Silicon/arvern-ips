//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_divisor_walk
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_divisor_walk
// Module Description : Consecutive auto-baud locks that move every bit of the
//                      measured divisor from bit 1 to bit 12 both up and down
//                      (SLOW build, AB_BREAK_CLKS = 65536, ceiling 4096 clk/bit).
//
//   doc/arv_dtm_uart.md, Auto-baud: "it times the low run, computes
//   baud_div = round(low_run / 8), rejects a divisor outside
//   [AB_DIV_FLOOR, AB_DIV_CEIL]"; Bounds: "a measured divisor is rejected above
//   AB_DIV_CEIL = AB_BREAK_CLKS / 16 clocks per bit". "Both RX sampling and TX baud
//   derive from the measured divisor, so the reply always tracks the host."
//
//   Legs at 17, 4094 (0xFFE), 4096 (0x1000, the only legal value with bit 12 set),
//   2730 (0xAAA) and 1365 (0x555) clk/bit, a break longer than AB_BREAK_CLKS between
//   legs. Each leg checks the lock and the divisor (within +/-1), and round-trips one
//   DMI word. The divisor seen at each lock is compared with the previous lock's, and
//   the test requires every bit 1..12 to have risen and fallen at least once.
//----------------------------------------------------------------------------

`ifndef SLOW_BAUD
initial
   begin : test
      $display("ERROR: uart_divisor_walk needs the SLOW_BAUD build (AB_BREAK_CLKS = 65536)");
      error = error + 1;
      stimulus_done = 1'b1;
   end
`else

reg [12:0] dw_rise;
reg [12:0] dw_fall;
reg [12:0] dw_prev;
reg        dw_have_prev;

task dw_leg;
   input integer clks;
   input [6:0]   addr;
   reg [31:0] rd;
   reg [31:0] wd;
   reg [1:0]  st;
   reg [12:0] cur;
   reg [31:0] cw;
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
      cur = div;
      if (dw_have_prev) begin
         dw_rise = dw_rise | (cur & ~dw_prev);
         dw_fall = dw_fall | (~cur & dw_prev);
      end
      dw_prev      = cur;
      dw_have_prev = 1'b1;

      cw = clks;
      wd = {cw[15:0], ~cw[15:0]};
      dmi_uart(addr, OP_WRITE, wd,    st, rd);
      check_eq("wr_st", st, OP_SUCCESS);
      dmi_uart(addr, OP_READ,  32'h0, st, rd);
      check_eq("rd_st",   st, OP_SUCCESS);
      check_eq("rd_data", rd, wd);
      check_eq("slave_word", slave_mem[addr], wd);
   end
endtask

task dw_break;                                // > AB_BREAK_CLKS (65536) of continuous low
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
      dw_rise      = 13'd0;
      dw_fall      = 13'd0;
      dw_prev      = 13'd0;
      dw_have_prev = 1'b0;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      slave_latency = 0;

      dw_leg(17,   7'h41);
      dw_break;
      dw_leg(4094, 7'h42);
      dw_break;
      dw_leg(4096, 7'h43);
      dw_break;
      dw_leg(2730, 7'h44);
      dw_break;
      dw_leg(1365, 7'h45);

      check_eq("div_bits_rose", dw_rise[12:1], 12'hFFF);
      check_eq("div_bits_fell", dw_fall[12:1], 12'hFFF);

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end

`endif
