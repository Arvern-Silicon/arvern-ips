//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mdeleg_reset
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mdeleg_reset.v
// Module Description : MDELEG resets to MDELEG_RST (the bench's
//                      GPIO_TB_MDELEG_RST; the default build is Machine only
//                      with PSLVERR, the "open" build User / User and silent).
//                      The gates in force out of reset are the reset value's:
//                      U-mode and S-mode writes and reads of OUTPUT are
//                      admitted or refused, with the response its RESP
//                      gives. A mid-test reset, taken with MDELEG holding
//                      another value, restores the reset value.
//
// Doc "Parameters": MDELEG_RST; doc "Access protection".
//----------------------------------------------------------------------------

reg [31:0] md_other;
reg [31:0] val;

task probe_gates;
   begin
      val = $urandom & GPIO_MASK;
      apb_write(1, USER,       R_OUTPUT, val, SZ_W, exp_resp_of(1'b1, USER, R_OUTPUT));
      apb_read (1, USER,       R_OUTPUT, 32'h0, SZ_W, 1'b0, exp_resp_of(1'b0, USER, R_OUTPUT));
      apb_write(1, SUPERVISOR, R_OUTPUT, ~val, SZ_W, exp_resp_of(1'b1, SUPERVISOR, R_OUTPUT));
      apb_read (1, SUPERVISOR, R_OUTPUT, 32'h0, SZ_W, 1'b0, exp_resp_of(1'b0, SUPERVISOR, R_OUTPUT));
      apb_read (1, USER_S,     R_INFO,   32'h0, SZ_W, 1'b0, exp_resp_of(1'b0, USER_S, R_INFO));
   end
endtask

initial
   begin
      wait_reset_done(5);
      model_check_en = 1'b1;

      $display(" ===============================================");
      $display("|   RESET VALUE AND THE GATES IT SETS           |");
      $display(" ===============================================");
      $display("MDELEG_RST = 9'h%03h", MDELEG_RST);
      rd(R_MDELEG, MDELEG_RST_WORD);
      probe_gates;

      $display(" ===============================================");
      $display("|   MID-TEST RESET RESTORES IT                  |");
      $display(" ===============================================");
      md_other = (MDELEG_RST_WORD != 32'h00000105) ? 32'h00000105 : 32'h00000000;
      wr(R_MDELEG, md_other);
      rd(R_MDELEG, md_other);
      probe_gates;
      tb_reset_pulse(4);
      cycles(3);
      rd(R_MDELEG, MDELEG_RST_WORD);
      probe_gates;

      cycles(5);
      model_check_en = 1'b0;
      cycles(20);
      stimulus_done = 1;
   end
