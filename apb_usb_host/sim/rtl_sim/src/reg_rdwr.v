//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    reg_rdwr
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : reg_rdwr.v
// Module Description : Register read / write in Machine mode: every RW field
//                      (CTRL, IRQ_EN; XFER.LEN, SETUP0/1, XDATA[0..1] with
//                      CTRL_EN=1, read 0 and write-ignored with CTRL_EN=0)
//                      with word, halfword and byte strobes and random data;
//                      RO registers, CMD, unlisted words and the REPORT /
//                      XDATA words beyond [1] read their value and ignore
//                      writes over the whole window (sampled above 0x100);
//                      no write aliases into another register; CTRL.EN=1
//                      starts the port; a DIAG0 write clears DIAG0 and DIAG1;
//                      PENABLE without PSEL writes nothing.
//
// Doc "Register map", "States", "Parameters".
//----------------------------------------------------------------------------

integer    rr_i;
integer    rr_j;
integer    rr_k;
integer    rr_a;
reg [31:0] rr_exp [0:63];                    // expected word of each offset below 0x100
reg [31:0] rr_v;
reg [31:0] rr_d;
reg  [1:0] rr_sz;
reg [31:0] rr_addr;

// Offsets with RW fields, in a list for random picks
reg [31:0] rr_rw_list [0:6];
initial
  begin
     rr_rw_list[0] = R_CTRL;
     rr_rw_list[1] = R_IRQ_EN;
     rr_rw_list[2] = R_XFER;
     rr_rw_list[3] = R_SETUP0;
     rr_rw_list[4] = R_SETUP1;
     rr_rw_list[5] = R_XDATA0;
     rr_rw_list[6] = R_XDATA0 + 4;
  end

// Writable bits of a word (doc "Register map"); CTRL.EN is excluded from the
// random writes, which keep the port OFF, and tested on its own
function [31:0] rr_wmask;
   input [31:0] off;
   begin
      case (off)
        R_CTRL:                    rr_wmask = 32'h0000_FF07;
        R_IRQ_EN:                  rr_wmask = 32'h0000_007F;
        R_XFER:                    rr_wmask = (CTRL_EN != 0) ? 32'h0000_007F : 32'h0;
        R_SETUP0, R_SETUP1,
        R_XDATA0, R_XDATA0 + 4:    rr_wmask = (CTRL_EN != 0) ? 32'hFFFF_FFFF : 32'h0;
        default:                   rr_wmask = 32'h0;
      endcase
   end
endfunction

function [31:0] rr_exp_of;
   input [31:0] a;
   begin
      rr_exp_of = (a < 32'h100) ? rr_exp[a[7:2]] : 32'h0;
   end
endfunction

// Machine-mode write of size sz at byte address a; the model follows the
// strobed lanes and the writable bits
task rr_write;
   input [31:0] a;
   input  [1:0] sz;
   input [31:0] d;
   reg   [31:0] off;
   reg   [31:0] lm;
   reg   [31:0] pl;
   reg   [31:0] wm;
   reg   [31:0] dd;
   begin
      off = {a[31:2], 2'b00};
      dd  = d;
      if ((off == R_CTRL) && (a[1:0] == 2'b00)) dd[0] = 1'b0;
      apb_write(1, MACHINE, a, dd, sz, OK);
      if (off < 32'h100)
        begin
           lm = lane_mask(a, sz);
           pl = lane_place(a, sz, dd);
           wm = rr_wmask(off);
           rr_exp[off[7:2]] = (rr_exp[off[7:2]] & ~(lm & wm)) | (pl & lm & wm);
        end
   end
endtask

task rr_check;
   input [31:0] a;
   begin
      apb_read(1, MACHINE, a, rr_exp_of(a), SZ_W, 1'b1, OK);
   end
endtask

// Every listed register and the REPORT / XDATA windows against the model
task rr_check_all;
   integer n;
   begin
      for (n = 0; n < 64; n = n + 1)
        if ((n << 2) != R_MDELEG)
          rr_check(n << 2);
      rr_check(R_MDELEG);
   end
endtask

task rr_random_size;
   output [1:0] sz;
   begin
      case ($urandom % 3)
        0:       sz = SZ_B;
        1:       sz = SZ_H;
        default: sz = SZ_W;
      endcase
   end
endtask

// Byte address of a random lane / halfword of word off for size sz
function [31:0] rr_lane_addr;
   input [31:0] off;
   input  [1:0] sz;
   input [31:0] r;
   begin
      case (sz)
        SZ_B:    rr_lane_addr = off + (r % 4);
        SZ_H:    rr_lane_addr = off + 2 * (r % 2);
        default: rr_lane_addr = off;
      endcase
   end
endfunction

initial
   begin
      wait_reset_done(5);

      for (rr_i = 0; rr_i < 64; rr_i = rr_i + 1) rr_exp[rr_i] = 32'h0;
      rr_exp[R_INFO >> 2]   = INFO_VALUE;
      rr_exp[R_CTRL >> 2]   = CTRL_RST;
      rr_exp[R_MDELEG >> 2] = MDELEG_RST_WORD;

      // Reset values first
      rr_check_all;

      // Each RW word: a full word, both halfwords and the four bytes, four rounds
      for (rr_k = 0; rr_k < 4; rr_k = rr_k + 1)
        for (rr_i = 0; rr_i < 7; rr_i = rr_i + 1)
          begin
             rr_addr = rr_rw_list[rr_i];
             rr_write(rr_addr, SZ_W, $urandom);
             rr_check(rr_addr);
             for (rr_j = 0; rr_j < 2; rr_j = rr_j + 1)
               begin
                  rr_write(rr_addr + 2 * rr_j, SZ_H, $urandom);
                  rr_check(rr_addr);
               end
             for (rr_j = 0; rr_j < 4; rr_j = rr_j + 1)
               begin
                  rr_write(rr_addr + rr_j, SZ_B, $urandom);
                  rr_check(rr_addr);
               end
          end

      // All ones and all zeros through the strobes
      for (rr_i = 0; rr_i < 7; rr_i = rr_i + 1)
        begin
           rr_write(rr_rw_list[rr_i], SZ_W, 32'hFFFF_FFFF);
           rr_check(rr_rw_list[rr_i]);
           rr_write(rr_rw_list[rr_i] + 2, SZ_H, 32'h0);
           rr_check(rr_rw_list[rr_i]);
           rr_write(rr_rw_list[rr_i] + 1, SZ_B, 32'h0);
           rr_check(rr_rw_list[rr_i]);
        end

      // Random mix, then the whole map: a write to one word changes no other
      for (rr_k = 0; rr_k < 200; rr_k = rr_k + 1)
        begin
           rr_i = $urandom % 7;
           rr_random_size(rr_sz);
           rr_write(rr_lane_addr(rr_rw_list[rr_i], rr_sz, $urandom), rr_sz, $urandom);
           if (($urandom % 4) == 0) rr_check(rr_rw_list[$urandom % 7]);
        end
      rr_check_all;
      chk(tb_state === S_OFF, "random RW writes leave the port OFF");

      // RO registers ignore writes, at every size
      for (rr_k = 0; rr_k < 3; rr_k = rr_k + 1)
        for (rr_i = 0; rr_i < 22; rr_i = rr_i + 1)
          begin
             case (rr_i)
               0:       rr_addr = R_INFO;
               1:       rr_addr = R_STATUS;
               2:       rr_addr = R_DEV_ID;
               3:       rr_addr = R_DEV_IF;
               4:       rr_addr = R_DEV_EP;
               5:       rr_addr = R_REPORT_INFO;
               6:       rr_addr = R_DIAG1;
               default: rr_addr = R_REPORT0 + 4 * (rr_i - 7);   // REPORT[0..14]
             endcase
             rr_random_size(rr_sz);
             rr_write(rr_lane_addr(rr_addr, rr_sz, $urandom), rr_sz, $urandom);
             rr_check(rr_addr);
          end

      // CMD reads 0; RESTART is ignored in OFF and XFER_NEXT with no transfer
      rr_write(R_CMD, SZ_W, 32'hFFFF_FFF0);
      rr_check(R_CMD);
      rr_write(R_CMD, SZ_W, K_RESTART);
      rr_check(R_CMD);
      rr_write(R_CMD, SZ_W, K_XFER_NEXT);
      rr_check(R_CMD);
      rr_write(R_CMD + 1, SZ_B, 32'hFF);
      rr_check(R_CMD);
      chk(tb_state === S_OFF, "RESTART ignored in OFF");
      rr_check(R_XFER);
      rr_check(R_IRQ_PEND);

      // The whole window: unlisted words, REPORT / XDATA beyond [1], RO words.
      // RW words, CMD and MDELEG are left to the sections above; the long
      // windows are sampled above 0x100 as reset_values.v does.
      for (rr_a = 0; rr_a < WIN_SIZE; rr_a = rr_a + 4)
        begin
           if ((rr_wmask(rr_a) == 32'h0) && (rr_a != R_CMD) && (rr_a != R_MDELEG) &&
               (rr_a != R_CTRL) && (rr_a != R_IRQ_EN))
             begin
                rr_random_size(rr_sz);
                rr_write(rr_lane_addr(rr_a, rr_sz, $urandom), rr_sz, $urandom);
                rr_check(rr_a);
                rr_write(rr_a, SZ_W, $urandom);
                rr_check(rr_a);
             end
           if (rr_a >= 32'h100) rr_a = rr_a + 4 * ($urandom % 64);
        end

      // No write above landed in another register
      rr_check_all;
      chk(tb_state === S_OFF, "window walk leaves the port OFF");
      chk(irq === 1'b0, "irq_o low");

      // CTRL.EN = 1 starts the port (doc "States": OFF -> DETACHED)
      rr_v = rr_exp[R_CTRL >> 2];
      wr(R_CTRL, rr_v | C_EN);
      wait_state(S_DETACHED, 1.0);
      rd(R_CTRL, rr_v | C_EN);
      wr(R_CTRL, rr_v);
      wait_state(S_OFF, 1.0);
      rd(R_CTRL, rr_v);
      rdv(R_IRQ_PEND, rr_v);
      chk(rr_v[6] === 1'b1, "IRQ_PEND.STATE after OFF -> DETACHED -> OFF");
      wr(R_IRQ_PEND, I_ALL);
      rr_check(R_IRQ_PEND);

      // DIAG0 write clears DIAG0 and DIAG1: one bus reset counted by a hub,
      // which ends UNSUPPORTED after step 1 with the lines released
      if (DIAG_EN != 0)
        begin
           dev.attach(dev.P_HUB);
           wr(R_CTRL, C_EN | C_BOOT | C_IDLE0);
           wait_state(S_UNSUPPORTED, 400.0);
           rdv(R_DIAG1, rr_v);
           chk32(rr_v & 32'h0000_FFFF, 32'h1, "DIAG1 bus resets after one reset");
           rr_d = rr_v;
           wr(R_DIAG1, 32'h0);
           rd(R_DIAG1, rr_d);
           wr(R_DIAG0, $urandom);
           rd(R_DIAG0, 32'h0);
           rd(R_DIAG1, 32'h0);
           wr(R_CTRL, 32'h0);
           wait_state(S_OFF, 1.0);
           dev.detach;
           wr(R_IRQ_PEND, I_ALL);
        end
      else
        begin
           rd(R_DIAG0, 32'h0);
           rd(R_DIAG1, 32'h0);
        end

      // PENABLE without PSEL is no transfer (APB4): writes of every register
      // with PSEL low change nothing
      wr(R_IRQ_EN, 32'h55);
      rdv(R_CTRL, rr_d);
      for (rr_i = 0; rr_i < 8; rr_i = rr_i + 1)
        begin
           @(posedge free_clk);
           #1;
           psel    = 1'b0;
           penable = 1'b1;
           pwrite  = 1'b1;
           paddr   = (rr_i < 4) ? R_IRQ_EN[ADDRW-1:0] : R_CTRL[ADDRW-1:0];
           pwdata  = $urandom | 32'h1;
           pstrb   = 4'hF;
           pprot   = 3'b001;
           psmode  = 1'b0;
        end
      @(posedge free_clk);
      #1;
      apb_idle;
      rd(R_IRQ_EN, 32'h55);
      rd(R_CTRL, rr_d);
      wr(R_IRQ_EN, 32'h0);

      stimulus_done = 1;
   end
