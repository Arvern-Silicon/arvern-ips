//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    cjtag_escape_5edge
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : cjtag_escape_5edge
// Module Description : Five TMSC changes is a DESELECT escape, not a SELECTION one,
//                      so the bits that follow must NOT be treated as an activation.
//
//   Tbl 10-9: >=8 = reset, 6/7 = selection, 4/5 = deselect. `cjtag_escape_boundary`
//   covers the 6/7 side; this covers the edge just below it. Without it, lowering the
//   selection threshold to 5 is invisible -- and a threshold that fires one edge early
//   turns a deselect (which must take the node OFF the bus) into an activation.
//
//   The escape here is written inline rather than using cjtag_escape_n, because that
//   task appends idle TCKC cycles afterwards. Framing depends on the code starting on
//   the FIRST rising edge after the escape's terminating fall (Rule 11.7.6.2 c), so the
//   stimulus has to be as tight as cjtag_escape_sel is.
//----------------------------------------------------------------------------

// cjtag_escape_sel with a caller-chosen change count, terminating fall included.
task cjtag_escape_n_tight;
    input integer nchanges;
    integer k;
    begin
        // Settle the line LOW while TCKC is still low. Without this the opening
        // 1->0 transition lands after TCKC has been observed high (2-FF sync) and is
        // counted as an escape change -- measured: 5 intended toggles read as 6, which
        // is a SELECTION and would make this test fail against correct RTL.
        host_tmsc_oe = 1'b1;  host_tmsc = 1'b0;
        repeat (CJHALF * 3) @(posedge free_clk);
        tckc = 1'b1;
        repeat (CJHALF) @(posedge free_clk);
        for (k = 0; k < nchanges; k = k + 1) begin
            host_tmsc = ~host_tmsc;
            repeat (CJHALF) @(posedge free_clk);
        end
        tckc = 1'b0;  repeat (CJHALF) @(posedge free_clk);   // terminating fall
    end
endtask

initial
   begin : test
      reg [31:0] id;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|  cJTAG: 5-edge escape is DESELECT, not SELECT |");
      $display(" ===============================================");

      // -- 5 changes then a perfectly valid code: must NOT activate --------------
      cjtag_escape_n_tight(5);
      cjtag_send_actcode;
      check_eq("offline_after_5edge", dut.g_cjtag.u_dtm.online, 1'b0);

      // -- 6 changes, same code: activates ---------------------------------------
      // One extra edge is the only difference, so the threshold itself is what is
      // under test, not the code or the framing.
      cjtag_escape_n_tight(6);
      cjtag_send_actcode;
      check_eq("online_after_6edge", dut.g_cjtag.u_dtm.online, 1'b1);

      tap_reset;
      idcode_read(id);
      check_eq("idcode_after_6edge", id, DUT_IDCODE);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
