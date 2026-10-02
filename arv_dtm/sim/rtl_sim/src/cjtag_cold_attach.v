//----------------------------------------------------------------------------
// File Name          : cjtag_cold_attach
// Module Description : dbg_wakeup_o must signal probe activity with clk_i STOPPED.
//
//   The escape detector is oversampled on clk_i, so with the oscillator gated off a
//   probe is invisible and debug-from-sleep is impossible. dbg_wakeup_o exists to break
//   that circularity: it is generated purely in the TCKC domain, so it still moves when
//   clk_i is dead, and the SoC's always-on controller uses it to start the oscillator.
//
//   A toggle rather than a level, because nothing in the TCKC domain could clear a
//   sticky level -- clearing it would need the very clock being started.
//
//   Discriminator: stop clk_i entirely, clock TCKC, and require dbg_wakeup_o to change.
//   Any implementation that derives the wake from clk_i is frozen here and fails.
//   Then restart clk_i and confirm a normal attach still completes.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] id;
      reg        w0, seen;
      integer    k;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|  Probe activity with the oscillator STOPPED  |");
      $display(" ===============================================");

      // Kill the always-on clock. Nothing in the clk_i domain can advance from here.
      clk_gate = 1'b0;
      #1000;
      w0 = dbg_wakeup;

      // Clock TCKC as a probe would when connecting. No clk_i edges occur at all.
      // COUNT TRANSITIONS -- comparing endpoints is wrong, because an even number of
      // toggles returns the output to its starting value.
      seen = 1'b0;
      for (k = 0; k < 8; k = k + 1) begin
         tckc = 1'b1;  #500;
         tckc = 1'b0;  #500;
         if (dbg_wakeup !== w0) seen = 1'b1;
         w0 = dbg_wakeup;
      end

      // The wake output must have moved despite clk_i being dead.
      check_eq("wake_moved_clk_stopped", {31'd0, seen}, 32'd1);

      // Restart the oscillator; a normal attach must still work end to end.
      clk_gate = 1'b1;
      repeat (200) @(posedge free_clk);

      cjtag_activate;
      check_eq("online_after_wake", dut.g_cjtag.u_dtm.online, 1'b1);
      tap_reset;
      idcode_read(id);
      check_eq("idcode_after_wake", id, DUT_IDCODE);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
