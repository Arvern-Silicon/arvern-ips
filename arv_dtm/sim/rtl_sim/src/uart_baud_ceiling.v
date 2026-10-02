//----------------------------------------------------------------------------
// File Name          : uart_baud_ceiling
// Module Description : An absurdly slow measured baud must be REJECTED, not locked.
//
//   ab_div_ok bounded only the low side, so a long line-low -- an unplugged pin, or an
//   adapter holding RX low through enumeration -- locked a huge divisor. Two
//   consequences: the sync echo takes 10 x ab_div clocks (minutes at a large lock), and
//   worse, one byte then outlasts the break window itself, so the RX FSM is still
//   mid-byte when a re-arm lands and the documented break -> 0x80 -> echo recovery
//   leaves the link dead.
//
//   AB_DIV_CEIL is derived from AB_BREAK_CLKS rather than being a new magic number: a
//   lock slower than the break can never be escaped by the break.
//
//   Discriminator: after an over-long low, ab_done must still be 0 (no lock), and a
//   normal 0x80 must then lock correctly. Without the ceiling the first low locks and
//   the subsequent traffic is decoded at the wrong rate.
//----------------------------------------------------------------------------

initial
   begin : test
      integer k;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|  Over-long RX low must not lock a divisor    |");
      $display(" ===============================================");

      // Hold RX low far longer than any legal 0x80 low run, then release.
      uart_rx = 1'b0;
      for (k = 0; k < 20000; k = k + 1) @(posedge free_clk);
      uart_rx = 1'b1;
      for (k = 0; k < 4000; k = k + 1) @(posedge free_clk);

      check_eq("no_lock_after_long_low", {31'd0, dut.g_uart.u_dtm.ab_done}, 32'd0);

      // A normal sync must still lock and the link must work.
      uart_autobaud_sync;
      check_eq("locked_after_sync", {31'd0, dut.g_uart.u_dtm.ab_done}, 32'd1);

      begin : recheck
         reg [31:0] rd; reg [1:0] st;
         dmi_uart(7'h10, OP_WRITE, 32'hFEED_BEEF, st, rd);
         dmi_uart(7'h10, OP_READ,  32'h0,          st, rd);
         check_eq("recovered_rdata", rd, 32'hFEED_BEEF);
      end

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
