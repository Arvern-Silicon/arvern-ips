//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_abort_inflight
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_abort_inflight
// Module Description : A resync must DROP an outstanding DMI transaction, not
//                      leave it in flight for the next request to collide with.
//
//   The break re-arm (host reconnect) resyncs arv_dtm_cmd from ANY state --
//   including S_WAIT, where a DMI op is still outstanding. If that transaction is
//   not dropped, the next request launches on top of it: the DMI bus runs the OLD
//   address and the DTM returns the OLD data as this request's result, with
//   status = SUCCESS. Silent wrong data, undetectable by the host.
//
//   Checked two ways:
//     1. INVARIANT (continuous): launch must never coincide with inflight.
//     2. The break must leave inflight CLEAR -- i.e. the abort actually reached the
//        DMI master (arv_dtm_cmd drives hardreset_o from abort_i) rather than merely
//        resyncing the interpreter's own FSM.
//   Then the link must still carry a correct transaction.
//
//   NOTE the data value returned by the aborted read is deliberately NOT checked:
//   dmi_slave_model latches its response at ACCESS and does not re-sample when the
//   master abandons mid-transfer (that is what its slave_abort input is for), so a
//   value check there would test the model, not the DUT. slave_abort models the DM
//   recovering after the DTM dropped the transfer.
//----------------------------------------------------------------------------

// INVARIANT: arv_dtm_cmd must never launch on top of an outstanding transaction.
always @(posedge free_clk)
   if (dbgresetn && dut.g_uart.u_dtm.launch && dut.g_uart.u_dtm.inflight) begin
      $display("ERROR: launch while inflight (stale op would answer this request)  %0t ns", $time);
      error = error + 1;
   end

// INVARIANT: launch and hardreset are mutually exclusive. Both together toggles
// req_level AND hardreset_level: the master latches inflight from the launch while
// the hclk side refuses the request, so no ack returns and inflight wedges forever.
always @(posedge free_clk)
   if (dbgresetn && dut.g_uart.u_dtm.launch && dut.g_uart.u_dtm.hardreset) begin
      $display("ERROR: launch coincident with hardreset (would wedge inflight)  %0t ns", $time);
      error = error + 1;
   end

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      uart_autobaud_sync();                     // open the link: measure baud + eat echo

      slave_latency = 3;

      // Two DISTINCT sentinels so a leaked transaction is unambiguous.
      dmi_uart(7'h10, OP_WRITE, 32'hDEAD_BEEF, st, rd);
      dmi_uart(7'h11, OP_WRITE, 32'hCAFE_F00D, st, rd);

      $display(" ===============================================");
      $display("|   Break aborts an in-flight DMI op            |");
      $display(" ===============================================");

      // Stall the slave, then hand-send a READ of 0x10. dmi_uart() would block on
      // the response, so the request is sent byte-by-byte: it launches and stays
      // in flight (arv_dtm_cmd parks in S_WAIT).
      slave_hold = 1'b1;
      uart_send_byte(8'h55);                    // SYNC
      uart_send_byte({1'b0, 7'h10});            // DMI address
      uart_send_byte(8'h00);                    // data [31:24]
      uart_send_byte(8'h00);                    // data [23:16]
      uart_send_byte(8'h00);                    // data [15:8]
      uart_send_byte(8'h00);                    // data [7:0]
      uart_send_byte(8'h01);                    // op = READ  -> launches, stalls

      repeat (40) @(posedge free_clk);          // let the launch settle
      check_eq("inflight_set", dut.g_uart.u_dtm.inflight, 1'b1);   // the op really is stuck

      // Host gives up and reconnects. The break must resync the interpreter AND
      // drop the outstanding transaction.
      uart_break;

      // THE CHECK: the abort reached the DMI master, not just the interpreter.
      check_eq("inflight_cleared", dut.g_uart.u_dtm.inflight, 1'b0);

      // Model the DM recovering now that the DTM has dropped the transfer.
      slave_abort = 1'b1;
      repeat (2) @(posedge free_clk);
      slave_abort = 1'b0;
      slave_hold  = 1'b0;
      repeat (4) @(posedge free_clk);

      uart_autobaud_sync();

      $display(" ===============================================");
      $display("|   Link still carries a correct transaction    |");
      $display(" ===============================================");

      dmi_uart(7'h11, OP_READ, 32'h0, st, rd);
      check_eq("post_abort_st", st, OP_SUCCESS);
      check_eq("post_abort_rd", rd, 32'hCAFE_F00D);

      dmi_uart(7'h10, OP_READ, 32'h0, st, rd);
      check_eq("still_alive", rd, 32'hDEAD_BEEF);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
