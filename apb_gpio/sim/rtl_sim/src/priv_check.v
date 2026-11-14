//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    priv_check
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : priv_check.v
// Module Description : The MDELEG gates. For every WR_PRIV x RD_PRIV pair of
//                      User / Supervisor / Machine and both RESP values, a
//                      U-mode (with and without the S sideband), S-mode and
//                      M-mode requester writes and reads OUTPUT, OUT_TGL (a
//                      byte), OE_SET, INFO (a half-word), IRQ_PEND (W1C) and
//                      an unmapped word: an access is admitted when the
//                      requester's level is at least the gate's, at any
//                      offset; a refused one changes nothing, reads 0 and
//                      gets PSLVERR with RESP=1 only. PPROT[2:1] are random
//                      and ignored. The reference model checks every output
//                      and response throughout.
//
// Doc "Access protection": levels U=0, S=1, M=3 ({pprot[0], psmode} = 0x /
// 11 / 10), compared with ">="; RESP selects PSLVERR or a silent drop.
//----------------------------------------------------------------------------

integer    ww;
integer    rr;
integer    ee;
integer    mm;
reg  [1:0] wp;
reg  [1:0] rp;
reg  [1:0] mode;
reg [31:0] cur_out;
reg [31:0] val;
reg        w_ok;
reg        r_ok;

function [1:0] lvl_of;
   input integer n;
   begin
      lvl_of = (n == 0) ? 2'b00 : (n == 1) ? 2'b01 : 2'b11;
   end
endfunction

function [1:0] mode_of;
   input integer n;
   begin
      case (n)
        0:       mode_of = USER;
        1:       mode_of = USER_S;
        2:       mode_of = SUPERVISOR;
        default: mode_of = MACHINE;
      endcase
   end
endfunction

initial
   begin
      wait_reset_done(5);
      inputs_on(32'hFFFFFFFF);
      wr(R_IRQ_EN,   32'hFFFFFFFF);
      cur_out = 32'h0;
      cycles(2);
      model_check_en = 1'b1;

      for (ee = 0; ee < 2; ee = ee + 1)
        for (ww = 0; ww < 3; ww = ww + 1)
          for (rr = 0; rr < 3; rr = rr + 1)
            begin
               wp = lvl_of(ww);
               rp = lvl_of(rr);
               $display("---- MDELEG: WR_PRIV=%b RD_PRIV=%b RESP=%0d", wp, rp, ee);
               wr(R_MDELEG, {23'h0, ee[0], 4'h0, rp, wp});
               rd(R_MDELEG, {23'h0, ee[0], 4'h0, rp, wp});
               for (mm = 0; mm < 4; mm = mm + 1)
                 begin
                    mode = mode_of(mm);
                    tb_pprot_other = $urandom;
                    w_ok = (priv_of(mode) >= wp);
                    r_ok = (priv_of(mode) >= rp);

                    val = $urandom & GPIO_MASK;
                    apb_write(1, mode, R_OUTPUT, val, SZ_W, exp_resp_of(1'b1, mode, R_OUTPUT));
                    if (w_ok) cur_out = val;
                    chk32(gpio_o32, cur_out, "gpio_o after an OUTPUT write");
                    apb_read(1, mode, R_OUTPUT, r_ok ? cur_out : 32'h0, SZ_W, 1'b1, exp_resp_of(1'b0, mode, R_OUTPUT));

                    apb_write(1, mode, R_OUT_TGL + 1, 32'hFF, SZ_B, exp_resp_of(1'b1, mode, R_OUT_TGL));
                    if (w_ok) cur_out = cur_out ^ (32'h0000FF00 & GPIO_MASK);
                    chk32(gpio_o32, cur_out, "gpio_o after an OUT_TGL byte write");

                    apb_write(1, mode, R_OE_SET, pbit(mm), SZ_W, exp_resp_of(1'b1, mode, R_OE_SET));
                    apb_read(1, mode, R_INFO + 2, r_ok ? INFO_VALUE : 32'h0, SZ_H, 1'b1, exp_resp_of(1'b0, mode, R_INFO));
                    apb_write(1, mode, R_IRQ_PEND, 32'hFFFFFFFF, SZ_W, exp_resp_of(1'b1, mode, R_IRQ_PEND));
                    apb_write(1, mode, R_FIRST_UNMAP, 32'hFFFFFFFF, SZ_W, exp_resp_of(1'b1, mode, R_FIRST_UNMAP));
                    apb_read(1, mode, R_FIRST_UNMAP, 32'h0, SZ_W, 1'b1, exp_resp_of(1'b0, mode, R_FIRST_UNMAP));
                 end
               tb_pprot_other = 2'b00;
               // Re-latch an edge so the next W1C has something to clear
               wr(R_IRQ_RISE, 32'hFFFFFFFF);
               pins_set(32'h0);
               cycles(L_IN + 3);
               pins_set(32'hFFFFFFFF);
               cycles(L_IN + 3);
               wr(R_IRQ_RISE, 32'h0);
               wr(R_OE, 32'h0);
            end

      wr(R_MDELEG, MDELEG_RST_WORD);
      cycles(5);
      model_check_en = 1'b0;
      $display("model mismatches: %0d", m_errors);
      cycles(20);
      stimulus_done = 1;
   end
