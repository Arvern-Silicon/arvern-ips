//----------------------------------------------------------------------------
// File Name          : cjtag_first_packet
// Module Description : The FIRST OScan1 packet after activation must clock the TAP.
//
//   Rule 11.7.9.2 f): the bit following the Check Packet postamble is the first bit
//   of the first Scan Packet. That packet carries a real TMS and must advance the TAP
//   like any other -- nothing may be spent "warming up" the recovered TAP clock.
//
//   Every other cJTAG test reaches its start state via tap_reset, which issues SIX
//   TMS=1 packets before the first TMS=0. Five are already enough to force TLR, so a
//   swallowed first packet leaves the TAP in exactly the same place and the loss is
//   invisible. This test makes the first packet load-bearing instead: straight out of
//   activation the TAP is in Test-Logic-Reset, and ONE TMS=0 packet is the only thing
//   moving it to Run-Test/Idle. shift_ir() then assumes Run-Test/Idle, so if that
//   packet is lost the whole IDCODE navigation is off by one state and the read fails.
//
//   The failure it pins: a TAP reset released by `online` and re-synchronised on a
//   gated, per-packet clock has no edge to release on until the link is already
//   running, so it consumes the probe's first TAP clock. The TAP's synchroniser
//   therefore runs on the free-running TCKC, and the TAP advances on tck_en (one
//   enabled edge per OScan1 packet), so the reset has released before the first packet.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] id;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      cjtag_activate;                           // online; TAP left in Test-Logic-Reset
      check_eq("online", dut.g_cjtag.u_dtm.online, 1'b1);

      // The load-bearing packet: TLR -> Run-Test/Idle. Deliberately NOT tap_reset.
      cjtag_bit(1'b0, 1'b0);

      // shift_ir/shift_dr both start from Run-Test/Idle. If the packet above was
      // dropped the TAP is still in TLR and this navigation lands elsewhere.
      idcode_read(id);
      check_eq("idcode_after_first_packet", id, DUT_IDCODE);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
