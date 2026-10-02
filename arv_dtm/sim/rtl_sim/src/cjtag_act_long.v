//----------------------------------------------------------------------------
// File Name          : cjtag_act_long
// Module Description : The STANDARD (long) connect sequence must activate the link,
//                      not just the short form.
//
//   A stock J-Link uses the standard sequence BY DEFAULT (SEGGER: "By default, J-Link
//   will use the standard connect sequence"); short form needs SetcJTAGInitMode = 1.
//   Supporting both means the IP works out of the box.
//
//   Long form = OAC | EC(SHORT=0) | 24-bit Global Register State | Check Packet, with
//   all register fields zero except SCNFMT (bits 23:19) = 9 = OScan1 (Cl. 23.4.1.4.5).
//   The GRL is fixed length and the CP Preamble follows immediately (Rule 11.7.9.2 b 2).
//
//   Discriminator: a short-form-only decoder cannot pass this -- it would treat the
//   first Global Register bits as a Check Packet and never activate.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] id;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|   Standard (long) connect sequence           |");
      $display(" ===============================================");

      // Drive the sequence in two halves so the MIDPOINT can be checked. Checking only
      // the end state is NOT discriminating: a short-form-only decoder reads the GRL's
      // leading zeros as preamble + CP_END + postamble, goes Online early, and a later
      // tap_reset hides the misalignment -- it reaches online=1 either way.
      cjtag_escape_sel;
      cjtag_send_actcode_long_part1;            // OAC + EC(SHORT=0) + 12 GRL bits

      // Still mid-Global-Register-Load: MUST NOT be online yet. A short-form-only
      // decoder is already online here.
      check_eq("offline_mid_grl", dut.g_cjtag.u_dtm.online, 1'b0);

      cjtag_send_actcode_long_part2;            // remaining 12 GRL bits + Check Packet
      check_eq("online_long_form", dut.g_cjtag.u_dtm.online, 1'b1);

      tap_reset;
      idcode_read(id);
      check_eq("idcode_long_form", id, DUT_IDCODE);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
