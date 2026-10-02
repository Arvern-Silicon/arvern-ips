//----------------------------------------------------------------------------
// File Name          : cjtag_por_act
// Module Description : The link must activate on the FIRST attempt straight out of
//                      POR, with no escape or idle cycles to warm the TCKC domain.
//
//   Activation is FRAMED off a SELECTION escape (Rule 11.7.6.2 c), so the escape is
//   part of the sequence, not a warm-up. The property under test is that no TCKC edges
//   are needed BEFORE it: the TCKC domain is released asynchronously precisely so the
//   probe's very first edges can carry the escape and then the code.
//----------------------------------------------------------------------------

initial
   begin : test
      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      cjtag_escape_sel;                         // selection escape frames the code
      cjtag_send_actcode;                       // no idle cycles in between
      check_eq("online_from_por", dut.g_cjtag.u_dtm.online, 1'b1);
      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
