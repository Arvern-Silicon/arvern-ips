//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mdeleg_access
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mdeleg_access.v
// Module Description : MDELEG itself. Machine mode only, whatever the gates:
//                      with the gates open to User mode, U-mode (with and
//                      without the S sideband) and S-mode writes are refused
//                      and reads return 0, with PSLVERR when RESP=1 and
//                      silently when RESP=0. Byte lanes: lane 0 holds the
//                      two gates, lane 1 RESP, lanes 2 and 3 nothing. The
//                      reserved code 2'b10 is stored as 2'b11 and the
//                      reserved bits read 0. Machine mode with any
//                      PPROT[2:1] is admitted.
//
// Doc "Access protection": MDELEG layout and its Machine-mode-only rule.
//----------------------------------------------------------------------------

integer    mm;
integer    ee;
reg  [1:0] mode;
reg [31:0] cur;

function [1:0] mode_of;
   input integer n;
   begin
      case (n)
        0:       mode_of = USER;
        1:       mode_of = USER_S;
        default: mode_of = SUPERVISOR;
      endcase
   end
endfunction

initial
   begin
      wait_reset_done(5);
      model_check_en = 1'b1;

      $display(" ===============================================");
      $display("|   LOWER MODES REFUSED, GATES OPEN             |");
      $display(" ===============================================");
      for (ee = 0; ee < 2; ee = ee + 1)
        begin
           cur = {23'h0, ee[0], 8'h00};                    // WR_PRIV = RD_PRIV = User
           wr(R_MDELEG, cur);
           for (mm = 0; mm < 3; mm = mm + 1)
             begin
                mode = mode_of(mm);
                apb_write(1, mode, R_MDELEG,     32'h0000010F, SZ_W, ee[0]);
                apb_write(1, mode, R_MDELEG,     32'h0000000F, SZ_B, ee[0]);
                apb_write(1, mode, R_MDELEG + 1, 32'h01,       SZ_B, ee[0]);
                apb_read (1, mode, R_MDELEG,     32'h0, SZ_W, 1'b1, ee[0]);
                apb_read (1, mode, R_MDELEG + 1, 32'h0, SZ_B, 1'b1, ee[0]);
                rd(R_MDELEG, cur);
                // the gates themselves still admit the lower mode elsewhere
                apb_read (1, mode, R_INFO, INFO_VALUE, SZ_W, 1'b1, OK);
             end
        end

      $display(" ===============================================");
      $display("|   BYTE LANES                                  |");
      $display(" ===============================================");
      wr(R_MDELEG, 32'h00000000);
      apb_write(1, MACHINE, R_MDELEG,     32'hFF, SZ_B, OK);      // lane 0: both gates (reserved bits [7:4] dropped)
      rd(R_MDELEG, 32'h0000000F);
      apb_write(1, MACHINE, R_MDELEG + 1, 32'hFF, SZ_B, OK);      // lane 1: RESP only
      rd(R_MDELEG, 32'h0000010F);
      apb_write(1, MACHINE, R_MDELEG + 2, 32'hFFFF, SZ_H, OK);    // lanes 2, 3: nothing
      apb_write(1, MACHINE, R_MDELEG + 3, 32'h00, SZ_B, OK);
      rd(R_MDELEG, 32'h0000010F);
      apb_write(1, MACHINE, R_MDELEG + 1, 32'h00, SZ_B, OK);
      rd(R_MDELEG, 32'h0000000F);
      apb_write(1, MACHINE, R_MDELEG,     32'h0105, SZ_H, OK);    // lanes 0 + 1
      rd(R_MDELEG, 32'h00000105);
      apb_write(1, MACHINE, R_MDELEG,     32'h00, SZ_B, OK);
      rd(R_MDELEG, 32'h00000100);
      apb_read(1, MACHINE, R_MDELEG + 1, 32'h00000100, SZ_B, 1'b1, OK);

      $display(" ===============================================");
      $display("|   RESERVED CODE AND BITS                      |");
      $display(" ===============================================");
      wr(R_MDELEG, 32'h0000000A);                                 // 2'b10 in both gates
      rd(R_MDELEG, 32'h0000000F);
      wr(R_MDELEG, 32'h00000006);                                 // RD 01, WR 10
      rd(R_MDELEG, 32'h00000007);
      wr(R_MDELEG, 32'hFFFFFEF0);                                 // every reserved bit, RESP 0, gates User
      rd(R_MDELEG, 32'h00000000);
      wr(R_MDELEG, 32'hFFFFFFFF);
      rd(R_MDELEG, 32'h0000010F);

      $display(" ===============================================");
      $display("|   MACHINE MODE WITH OTHER PPROT BITS          |");
      $display(" ===============================================");
      for (mm = 0; mm < 3; mm = mm + 1)
        begin
           tb_pprot_other = mm + 1;
           wr(R_MDELEG, {23'h0, mm[0], 4'h0, 2'b01, 2'b00});
           rd(R_MDELEG, {23'h0, mm[0], 4'h0, 2'b01, 2'b00});
        end
      tb_pprot_other = 2'b00;

      wr(R_MDELEG, MDELEG_RST_WORD);
      cycles(5);
      model_check_en = 1'b0;
      cycles(20);
      stimulus_done = 1;
   end
