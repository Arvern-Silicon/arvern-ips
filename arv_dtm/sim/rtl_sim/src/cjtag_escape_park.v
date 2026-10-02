//----------------------------------------------------------------------------
// File Name          : cjtag_escape_park
// Module Description : A reset escape must arm the link exactly ONCE, whatever
//                      level the DTS parks TMSC at afterwards.
//
//   The escape counters only clear on a TMSC edge while TCKC is low. If the DTS
//   parks TMSC, they stay >= threshold -- and a level-enabled handshake would then
//   re-fire on every TCKC cycle, wiping act_sreg so activation can never complete.
//   An 8-change escape is EVEN, so TMSC returns to its starting level: the parked
//   case is the likely one, not a corner case.
//
//   Discriminator: escape parked LOW, then activate, and require online on the
//   FIRST attempt (a retry would mask the bug).
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] id;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|   Escape parked LOW -> activate first time    |");
      $display(" ===============================================");

      cjtag_escape_park(1'b0);          // the level that used to strand the one-shot
      cjtag_send_actcode;
      check_eq("online_park_lo", dut.g_cjtag.u_dtm.online, 1'b1);

      tap_reset;
      idcode_read(id);
      check_eq("idcode_park_lo", id, DUT_IDCODE);

      $display(" ===============================================");
      $display("|   ...and parked HIGH                          |");
      $display(" ===============================================");

      cjtag_escape_park(1'b1);
      cjtag_send_actcode;
      check_eq("online_park_hi", dut.g_cjtag.u_dtm.online, 1'b1);

      tap_reset;
      idcode_read(id);
      check_eq("idcode_park_hi", id, DUT_IDCODE);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
