//----------------------------------------------------------------------------
// File Name          : uart_meas_wrap
// Module Description : A pre-lock low run longer than any acceptable 0x80 must be
//                      rejected however long it lasts -- the measurement counter must
//                      not wrap into a plausible divisor.
//
//   arv_dtm_uart.md: a measured bit period above AB_DIV_CEIL is rejected. A line held
//   low for 2^32 clocks cannot be simulated, so the measurement counter is preloaded
//   near its top while RX is low (the state such a line reaches), then RX is released
//   about one 0x80 frame later. Without a bound the counter has wrapped to a small
//   value by then and locks it; with the bound the measurement was abandoned long
//   before. A normal sync must then lock and the link work.
//----------------------------------------------------------------------------

initial
   begin : test
      integer k;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|  Measurement counter must not wrap into a lock |");
      $display(" ===============================================");

      uart_rx = 1'b0;
      while (dut.g_uart.u_dtm.ab_meas !== 1'b1) @(posedge free_clk);
      @(negedge free_clk);
      dut.g_uart.u_dtm.u_ab_cnt.q_o = 32'hFFFF_FFF0;          // a line low for ~2^32 clocks
      for (k = 0; k < 16 + 8 * HOST_CLKS_PER_BIT; k = k + 1) @(posedge free_clk);
      uart_rx = 1'b1;
      for (k = 0; k < 40 * HOST_CLKS_PER_BIT; k = k + 1) @(posedge free_clk);

      check_eq("no_lock_wrap", {31'd0, dut.g_uart.u_dtm.ab_done}, 32'd0);

      uart_autobaud_sync;
      check_eq("locked_after", {31'd0, dut.g_uart.u_dtm.ab_done}, 32'd1);
      begin : recheck
         reg [31:0] rd; reg [1:0] st;
         dmi_uart(7'h10, OP_WRITE, 32'hFEED_BEEF, st, rd);
         dmi_uart(7'h10, OP_READ,  32'h0,          st, rd);
         check_eq("rdata_after", rd, 32'hFEED_BEEF);
      end

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
