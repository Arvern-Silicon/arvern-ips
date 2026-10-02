//----------------------------------------------------------------------------
// File Name          : cjtag_escape_align
// Module Description : A reset escape must be clean at EVERY OScan1 packet alignment.
//
//   The escape's effect crosses into the TCKC domain, and the target must stop driving
//   TMSC before the DTS resumes. Whether that window is covered depends on which packet
//   phase the escape starts from: only cnt==2 during the crossing produces a drive, and
//   that needs cnt==0 when the TCKC-high hold begins -- the natural alignment, since a
//   DTS raises TCKC to sample TDO and simply keeps it high.
//
//   Every escape task in this bench enters with cnt==0 and then raises TCKC, which
//   yields cnt_0==1 -- one of three alignments, and the SAFE one. A drive into the
//   probe from the other alignments would go unseen by those tests.
//
//   Detector: the bench's TMSC contention checker -- any cycle where host and DUT
//   drive TMSC together is an error.
//
//   SCOPE: this does NOT discriminate the `~escape_evt` term in tmsc_oe_o. Removing
//   that term still passes, because the negedge framing capture makes the FSM clear
//   `online` on the FIRST rising edge after the escape. What this test guards is that
//   the escape stays clean at all three packet alignments.
//
//   The same sweep with a selection escape pins the drive inhibit between the
//   terminating TCKC fall (escape type known) and the next rise (`online` clears).
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] id;
      integer    ph;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      for (ph = 0; ph < 3; ph = ph + 1) begin
         $display(" ===============================================");
         $display("|   Escape starting at packet phase %0d          |", ph);
         $display(" ===============================================");

         cjtag_activate;
         check_eq("online_before_esc", dut.g_cjtag.u_dtm.online, 1'b1);

         tap_reset;
         idcode_read(id);                       // real traffic, ends on a packet boundary
         check_eq("idcode_before_esc", id, DUT_IDCODE);

         cjtag_phase_advance(ph);               // land on cnt == ph
         cjtag_escape;                          // reset escape from that alignment
         check_eq("offline_after_esc", dut.g_cjtag.u_dtm.online, 1'b0);
      end
      // Selection escape (6 edges) from each alignment: its type is known from the
      // terminating TCKC fall, while `online` clears only on the next rise, so the
      // drive must already be inhibited in between.
      for (ph = 0; ph < 3; ph = ph + 1) begin
         $display(" ===============================================");
         $display("|   Selection escape at packet phase %0d         |", ph);
         $display(" ===============================================");
         cjtag_activate;
         tap_reset;
         idcode_read(id);
         check_eq("idcode_before_sel", id, DUT_IDCODE);
         cjtag_phase_advance(ph);
         cjtag_escape_sel;                      // ends on the terminating fall
         cjtag_send_actcode;                    // the DTS drives OAC[0] at once
         check_eq("online_after_sel", dut.g_cjtag.u_dtm.online, 1'b1);
         tap_reset;
         idcode_read(id);
         check_eq("idcode_after_sel", id, DUT_IDCODE);
      end

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
