//----------------------------------------------------------------------------
// File Name          : cjtag_escape_boundary
// Module Description : The reset escape must fire at EIGHT TMSC changes, not fewer.
//
//   1149.7 distinguishes escapes by how many times TMSC changes while TCKC is held
//   high: a 7-edge sequence is a SELECTION escape, 8+ changes is a RESET escape. A
//   detector that fired on any change while TCKC was high would tear the link down
//   on every selection -- and no other test notices, because the OScan1 traffic in
//   this bench never moves TMSC during the TCKC-high phase at all.
//
//   Discriminator: activate, then drive exactly 7 changes and require the link to
//   still be ONLINE; then drive 8 and require it OFFLINE. Lowering the threshold
//   fails the first check, raising it fails the second.
//----------------------------------------------------------------------------

initial
   begin : test
      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|   7 changes must NOT reset the link          |");
      $display(" ===============================================");

      cjtag_activate;                    // selection escape + framed code
      check_eq("online_after_act",  dut.g_cjtag.u_dtm.online, 1'b1);

      cjtag_escape_n(2);                 // CUSTOM: no-op, link untouched
      check_eq("online_after_2",    dut.g_cjtag.u_dtm.online, 1'b1);

      cjtag_escape_n(4);                 // DESELECT ALL: node goes Offline
      check_eq("offline_after_4",   dut.g_cjtag.u_dtm.online, 1'b0);

      cjtag_activate;
      check_eq("online_again",      dut.g_cjtag.u_dtm.online, 1'b1);

      $display(" ===============================================");
      $display("|   8 changes MUST reset the link              |");
      $display(" ===============================================");

      cjtag_escape_n(8);
      check_eq("offline_after_8",   dut.g_cjtag.u_dtm.online, 1'b0);

      // Odd counts round DOWN: 5 must behave as 4 (deselect), not as 6 (selection).
      cjtag_activate;
      cjtag_escape_n(5);
      check_eq("offline_after_5",   dut.g_cjtag.u_dtm.online, 1'b0);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
