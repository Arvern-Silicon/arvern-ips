//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    priv_check_off
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : priv_check_off
// Module Description : PRIV_CHECK_EN=0 build (fabric-policed / legacy). The
//                      privilege checker and the two-cycle ERROR FSM are
//                      compiled out (ahb_aclint.v G_AHB_NO_ERR), so S-mode and
//                      U-mode accesses that ERROR under PRIV_CHECK_EN=1 must
//                      now all return OK and take effect. Previously this
//                      parameter value was lint-only -- never simulated. This
//                      build also proves the scoreboard / coverage monitor do
//                      not reach into the (now-absent) G_AHB_ERR_RSP internals.
//                      Requires the priv_off config (ACLINT_PRIV_CHECK_EN=0).
//----------------------------------------------------------------------------

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);

      if (PRIV_CHECK_EN != 0) begin
         tb_skip_finish("priv_check_off requires ACLINT_PRIV_CHECK_EN=0 (priv_off config)");
      end

      repeat(4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|     PRIV_CHECK_EN=0 : all modes allowed       |");
      $display(" ===============================================");

      // U-mode and S-mode accesses to the Machine-only windows: no error now.
      ahb_read (1, USER,       32'h00400000, 32'h00000000, 2, 1, OK);  // MSIP[0]
      ahb_read (1, SUPERVISOR, 32'h00404000, 32'h00000000, 2, 0, OK);  // MTIMECMP_LO[0]

      // Functional: a U-mode write must actually take effect (checker off).
      ahb_write(1, USER, 32'h00400000, 32'h00000001, 2, OK);           // MSIP[0] = 1
      ahb_read (1, USER, 32'h00400000, 32'h00000001, 2, 1, OK);
      $display("PASS:  U-mode MSIP[0] write committed with PRIV_CHECK_EN=0 %t ns", $time);

      // S-mode write/clear, then U-mode read-back -- all OK, no ERROR FSM.
      ahb_write(1, SUPERVISOR, 32'h00400000, 32'h00000000, 2, OK);
      ahb_read (1, USER,       32'h00400000, 32'h00000000, 2, 1, OK);

      // hresp must stay low throughout (no two-cycle error path exists).
      if (hresp !== 1'b0) begin
         $display("ERROR: hresp asserted with PRIV_CHECK_EN=0 -- error FSM should be absent %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  hresp stayed low for all privileged accesses %t ns", $time);
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
