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
// Module Description : The MDELEG gate: every register read and written in
//                      Machine, Supervisor, User and User-with-S-sideband
//                      modes under MDELEG_RST and a set of MDELEG values
//                      (WR_PRIV / RD_PRIV in User, Supervisor, Machine and
//                      the reserved code stored as Machine; RESP 0 silent
//                      drop, 1 PSLVERR), MDELEG byte-lane writes, MDELEG
//                      itself Machine-only. A refused write changes nothing
//                      (read back in Machine mode), a refused read returns 0,
//                      a refused CTRL write with EN=1 leaves the port OFF, a
//                      refused CMD.XFER_START sets nothing; in RUN a refused
//                      CMD.RESTART does not restart the port, a refused CTRL
//                      write does not stop it and a refused DIAG0 write does
//                      not clear the counters, the admitted ones do.
//
// Doc "Access protection" (apb_periph_example "MDELEG register layout",
// "Privilege model", "Access outcomes"), "Register map", "States".
//----------------------------------------------------------------------------

integer    md_c;
integer    md_m;
integer    md_r;
reg  [1:0] md_mode;
reg [31:0] md_addr;
reg [31:0] md_v;
reg [31:0] md_w;
reg [31:0] md_d;
reg        md_adm;
reg        md_resp;
integer    md_nrst;

function [1:0] md_mode_of;
   input integer m;
   case (m)
     0:       md_mode_of = MACHINE;
     1:       md_mode_of = SUPERVISOR;
     2:       md_mode_of = USER;
     default: md_mode_of = USER_S;
   endcase
endfunction

localparam MD_NREG = 20;
function [31:0] md_reg;
   input integer i;
   case (i)
     0:       md_reg = R_INFO;
     1:       md_reg = R_CTRL;
     2:       md_reg = R_CMD;
     3:       md_reg = R_STATUS;
     4:       md_reg = R_IRQ_EN;
     5:       md_reg = R_IRQ_PEND;
     6:       md_reg = R_DEV_ID;
     7:       md_reg = R_DEV_IF;
     8:       md_reg = R_DEV_EP;
     9:       md_reg = R_REPORT_INFO;
     10:      md_reg = R_XFER;
     11:      md_reg = R_SETUP0;
     12:      md_reg = R_SETUP1;
     13:      md_reg = R_DIAG0;
     14:      md_reg = R_DIAG1;
     15:      md_reg = R_REPORT0;
     16:      md_reg = R_XDATA0;
     17:      md_reg = R_MDELEG;
     18:      md_reg = 32'h3C;                // unlisted
     default: md_reg = WIN_SIZE - 4;         // top word of the window, unlisted
   endcase
endfunction

// MDELEG configurations written by Machine mode ({RESP, 4'b0, RD_PRIV, WR_PRIV})
localparam MD_NCFG = 9;
function [31:0] md_cfg;
   input integer i;
   case (i)
     1:       md_cfg = 32'h000;              // open, silent drop
     2:       md_cfg = 32'h105;              // Supervisor / Supervisor, PSLVERR
     3:       md_cfg = 32'h10F;              // Machine only, PSLVERR
     4:       md_cfg = 32'h00A;              // reserved codes: stored as Machine, silent
     5:       md_cfg = 32'h101;              // write Supervisor, read User, PSLVERR
     6:       md_cfg = 32'h004;              // write User, read Supervisor, silent
     7:       md_cfg = 32'h10C;              // write User, read Machine, PSLVERR
     default: md_cfg = 32'h003;              // write Machine, read User, silent
   endcase
endfunction

function [31:0] md_mirror_word;
   input dummy;
   md_mirror_word = {23'h0, m_resp, 4'h0, m_rd_priv, m_wr_priv};
endfunction

// A moment with the bus idle for 100 us: no host packet or keep-alive and no
// device response is cut by what the test does next
task md_quiet;
   begin
      while (!((usb_oe === 1'b0) && (dev.drv_en === 1'b0) && ($realtime - tb_act_t >= 100.0e3)))
        #(10.0e3);
   end
endtask

// STATE pending in IRQ_PEND, by an OFF -> DETACHED -> OFF round trip
task md_set_state_pend;
   reg [31:0] c;
   begin
      rdv(R_CTRL, c);
      wr(R_CTRL, c | C_EN);
      wait_state(S_DETACHED, 1.0);
      wr(R_CTRL, c & ~C_EN);
      wait_state(S_OFF, 1.0);
   end
endtask

// Read of addr in mode: the Machine-mode value when admitted, else 0
task md_read;
   input  [1:0] mode;
   input [31:0] addr;
   reg   [31:0] v;
   reg          adm;
   begin
      rdv(addr, v);
      if (addr == R_MDELEG) chk32(v, md_mirror_word(1'b0), "MDELEG value");
      adm = admitted(1'b0, mode, addr);
      apb_read(1, mode, addr, adm ? v : 32'h0, SZ_W, 1'b1, exp_resp_of(1'b0, mode, addr));
   end
endtask

// Write of addr in mode, then the Machine-mode read-back
task md_write;
   input  [1:0] mode;
   input [31:0] addr;
   reg   [31:0] v_bef;
   reg   [31:0] v_aft;
   reg   [31:0] d;
   reg   [31:0] x0;
   reg   [31:0] p0;
   reg          adm;
   reg          resp;
   begin
      if ((addr == R_IRQ_PEND) || (addr == R_CMD))
        begin
           if (addr == R_IRQ_PEND) md_set_state_pend;
           else                    wr(R_IRQ_PEND, I_XFER_DONE);
        end
      if ((addr == R_MDELEG) && (mode == MACHINE))
        ;                                    // Machine writes of MDELEG are the configurations
      else
        begin
           rdv(addr, v_bef);
           rdv(R_XFER, x0);
           rdv(R_IRQ_PEND, p0);
           adm  = admitted(1'b1, mode, addr);
           resp = exp_resp_of(1'b1, mode, addr);
           d    = $urandom;
           case (addr)
             R_CTRL:     d = adm ? (d & ~C_EN) : (d | C_EN);
             R_IRQ_PEND: d = I_STATE;
             R_CMD:      d = K_XFER_START;
             R_MDELEG:   d = 32'h0000_0000;  // would open every gate if it were stored
             default:    ;
           endcase
           apb_write(1, mode, addr, d, SZ_W, resp);
           case (addr)
             R_CTRL:     v_aft = adm ? (d & 32'h0000_FF07) : v_bef;
             R_IRQ_EN:   v_aft = adm ? (d & 32'h0000_007F) : v_bef;
             R_IRQ_PEND: v_aft = adm ? (v_bef & ~I_STATE) : v_bef;
             R_XFER:     v_aft = (adm && (CTRL_EN != 0)) ? ((v_bef & ~32'h7F) | (d & 32'h7F)) : v_bef;
             R_SETUP0, R_SETUP1, R_XDATA0:
                         v_aft = (adm && (CTRL_EN != 0)) ? d : v_bef;
             default:    v_aft = v_bef;     // RO, CMD, DIAG (0 here), unlisted, MDELEG
           endcase
           rd(addr, v_aft);
           chk(tb_state === S_OFF, "the port stays OFF");
           if (addr == R_CMD)
             begin
                // XFER_START outside RUN: REFUSED and XFER_DONE at once when admitted
                if (adm && (CTRL_EN != 0))
                  begin
                     rd(R_XFER, (x0 & 32'h7F) | {20'h0, X_REFUSED, 9'h0});
                     rd(R_IRQ_PEND, p0 | I_XFER_DONE);
                  end
                else
                  begin
                     rd(R_XFER, x0);
                     rd(R_IRQ_PEND, p0);
                  end
             end
        end
   end
endtask

initial
   begin
      wait_reset_done(5);
      rd(R_MDELEG, MDELEG_RST_WORD);

      // The matrix under MDELEG_RST, then under each configuration
      for (md_c = 0; md_c < MD_NCFG; md_c = md_c + 1)
        begin
           if (md_c != 0) wr(R_MDELEG, md_cfg(md_c) | 32'hFFFF_FE00);   // reserved bits ignored
           rd(R_MDELEG, md_mirror_word(1'b0));
           for (md_m = 0; md_m < 4; md_m = md_m + 1)
             for (md_r = 0; md_r < MD_NREG; md_r = md_r + 1)
               begin
                  md_read(md_mode_of(md_m), md_reg(md_r));
                  md_write(md_mode_of(md_m), md_reg(md_r));
               end

           // Open configuration: an admitted CTRL write from User mode (S sideband
           // set) starts the port
           if (md_c == 1)
             begin
                rdv(R_CTRL, md_v);
                apb_write(1, USER_S, R_CTRL, md_v | C_EN, SZ_W, OK);
                wait_state(S_DETACHED, 1.0);
                apb_write(1, USER, R_CTRL, md_v & ~C_EN, SZ_W, OK);
                wait_state(S_OFF, 1.0);
             end

           // Byte lanes of MDELEG: lane 0 the two privilege fields, lane 1 RESP,
           // lanes 2-3 nothing; [7:4] reserved
           if (md_c == 2)
             begin
                apb_write(1, MACHINE, R_MDELEG + 1, 32'h00, SZ_B, OK);
                rd(R_MDELEG, 32'h005);
                apb_write(1, MACHINE, R_MDELEG, 32'hF6, SZ_B, OK);          // RD 01, WR 10 -> 11
                rd(R_MDELEG, 32'h007);
                apb_write(1, MACHINE, R_MDELEG + 2, 32'hFFFF, SZ_H, OK);
                rd(R_MDELEG, 32'h007);
                apb_write(1, MACHINE, R_MDELEG + 3, 32'hFF, SZ_B, OK);
                rd(R_MDELEG, 32'h007);
                apb_write(1, MACHINE, R_MDELEG, 32'h0100, SZ_H, OK);
                rd(R_MDELEG, 32'h100);
                apb_write(1, MACHINE, R_MDELEG, 32'h0B, SZ_B, OK);          // RD 10 -> 11, WR 11
                rd(R_MDELEG, 32'h10F);
                for (md_m = 1; md_m < 4; md_m = md_m + 1)
                  begin
                     md_read(md_mode_of(md_m), R_CTRL);
                     md_write(md_mode_of(md_m), R_IRQ_EN);
                  end
             end
        end

      // In RUN: refused commands start nothing, admitted ones act.
      // Write gate Supervisor, read gate User, PSLVERR.
      wr(R_MDELEG, 32'h101);
      wr(R_IRQ_PEND, I_ALL);
      wr(R_CTRL, C_EN | C_BOOT | C_IDLE0 | (32'hFF << 8));   // slow polling: a quiet bus
      dev.attach(dev.P_KBD);
      wait_state(S_RUN, 600.0);
      md_nrst = st_count(S_RESET);
      chk(md_nrst == 2, "two bus resets in the enumeration");

      md_quiet;
      apb_write(1, USER, R_CMD, K_RESTART, SZ_W, ERROR);
      md_quiet;
      apb_write(1, USER_S, R_CTRL, 32'h0, SZ_W, ERROR);
      rd(R_CTRL, C_EN | C_BOOT | C_IDLE0 | (32'hFF << 8));
      if (DIAG_EN != 0)
        begin
           apb_write(1, USER_S, R_DIAG0, 32'h0, SZ_W, ERROR);
           rd(R_DIAG1, 32'h2);
           apb_read(1, USER, R_DIAG1, 32'h2, SZ_W, 1'b1, OK);
        end
      wait_ms(3.0);
      chk(tb_state === S_RUN, "refused RESTART / CTRL writes leave the port in RUN");
      chk(st_count(S_RESET) == md_nrst, "no bus reset after the refused RESTART");

      // RESP = 0: the same refusals, dropped silently
      wr(R_MDELEG, 32'h001);
      md_quiet;
      apb_write(1, USER, R_CMD, K_RESTART, SZ_W, OK);
      apb_write(1, SUPERVISOR, R_MDELEG, 32'h000, SZ_W, OK);
      rd(R_MDELEG, 32'h001);
      apb_read(1, USER_S, R_STATUS, 32'h0, SZ_W, 1'b0, OK);
      chk(acc_rdata[3:0] == S_RUN, "User read of STATUS admitted: RUN");
      wait_ms(3.0);
      chk(tb_state === S_RUN, "silently refused RESTART leaves the port in RUN");
      chk(st_count(S_RESET) == md_nrst, "no bus reset after the silent RESTART");

      // Admitted from Supervisor mode
      if (DIAG_EN != 0)
        begin
           apb_write(1, SUPERVISOR, R_DIAG0, 32'h0, SZ_W, OK);
           rd(R_DIAG1, 32'h0);
        end
      md_quiet;
      apb_write(1, SUPERVISOR, R_CMD, K_RESTART, SZ_W, OK);
      wait_state(S_RESET, 2.0);
      wait_state(S_RUN, 400.0);
      status_chk(S_RUN, E_NONE, 4'd0);

      stimulus_done = 1;
   end
