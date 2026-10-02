//----------------------------------------------------------------------------
// File Name          : cjtag_reset_assert
// Module Description : Asserting dbgresetn_i mid-traffic must tear the cJTAG link
//                      down, and the link must come back afterwards.
//
//   The TCKC-domain flops are released ASYNCHRONOUSLY by design (see the reset
//   section of arv_dtm_cjtag.v: synchronising deassertion into a stopped probe clock
//   would swallow the first activation/selection bits). That decision is about the
//   RELEASE path only -- it must not weaken the ASSERT path, which is the half that
//   actually has to work: a system reset while the probe is mid-packet has to drop
//   `online` and clear `act_sreg` regardless of where TCKC happens to be.
//
//   No other cJTAG test asserts dbgresetn at all -- dmi_reset_cross is JTAG-only
//   (it pulses trst_n, which cJTAG does not have).
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] id;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|  Link up, then reset asserted mid-traffic     |");
      $display(" ===============================================");

      cjtag_activate;
      check_eq("online_before", dut.g_cjtag.u_dtm.online, 1'b1);

      tap_reset;
      idcode_read(id);
      check_eq("idcode_before", id, DUT_IDCODE);

      // Assert while TCKC is parked HIGH -- the awkward phase for an async release,
      // and the one a synchroniser would have covered.
      tckc = 1'b1;
      repeat (2) @(posedge free_clk);
      dbgresetn = 1'b0;
      repeat (8) @(posedge free_clk);
      check_eq("online_in_reset",   dut.g_cjtag.u_dtm.online,   1'b0);
      check_eq("act_sreg_in_reset", dut.g_cjtag.u_dtm.act_sreg, 12'h000);
      dbgresetn = 1'b1;
      repeat (8) @(posedge free_clk);
      tckc = 1'b0;
      repeat (4) @(posedge free_clk);

      check_eq("online_after_reset", dut.g_cjtag.u_dtm.online, 1'b0);

      $display(" ===============================================");
      $display("|  ...and the link comes back                   |");
      $display(" ===============================================");

      cjtag_active_done = 1'b0;
      cjtag_activate;
      check_eq("online_recovered", dut.g_cjtag.u_dtm.online, 1'b1);

      tap_reset;
      idcode_read(id);
      check_eq("idcode_recovered", id, DUT_IDCODE);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
