//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    flash_sequence
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : flash_sequence.v
// Module Description : A quad SPI NOR flash (spi_flash.v) driven with entries:
//                      status reads (05h), a single-lane read (03h), a write
//                      enable (06h) and a Quad Page Program (32h: address on
//                      IO0, data on IO0-IO3) with its WIP poll, then Quad
//                      I/O Reads (EBh) with 1, 4 and 0 dummy clocks (the
//                      zero-latency turnaround), in modes 0 and 3, and the
//                      continuous read mode entered with mode bits Axh and
//                      left with 00h. Every word read must equal the array;
//                      HOLD# must read high in every single-lane phase.
//
// Doc "Integration examples" (quad flash), "Lanes and pads".
//----------------------------------------------------------------------------

integer    i, cur, a, md;
reg  [7:0] old [0:255];
reg [31:0] v;

task fl_read_quad;                            // EBh at a, n words, mode byte m, from continuous mode when cont
   input  [7:0] a;
   input integer n;
   input  [7:0] m;
   input        cont;
   integer      k;
   begin
      if (!cont) ent(xa(KTX, 8, 1, 1'b0, 1'b1, 1'b0, 0), 32'hEB);
      ent(xa(KTX, 24, 4, 1'b0, 1'b1, 1'b0, 0), {24'h0, a});
      ent(xa(KTX, 8, 4, 1'b0, 1'b1, 1'b0, 0), m);
      if (fl_dummy > 0) ent(xa(KDUMMY, 4, 4, 1'b0, 1'b1, 1'b0, 0), fl_dummy - 1);
      ent(xa(KRX, 32, 4, 1'b0, 1'b0, 1'b0, 0), n - 1);
   end
endtask

task fl_check_words;                          // n words read from a, starting at rx_got[c]
   input integer c;
   input  [7:0] a;
   input integer n;
   integer      k;
   reg    [7:0] b;
   begin
      for (k = 0; k < n; k = k + 1)
        begin
           b = a + 4 * k;
           chk32(rx_got[c + k], {fl_mem[b], fl_mem[b + 8'd1], fl_mem[b + 8'd2], fl_mem[b + 8'd3]}, "flash word");
        end
   end
endtask

initial
   begin
      wait_reset_done(5);
      if (RX_EN == 0 || !POLL_USE) tb_skip("needs the receive path and POLL");
      dev_mode = 2;
      ent_drain = 1'b1;
      fl_cs = CS_NR - 1;
      for (md = 0; md < 2; md = md + 1)
        begin
           spi_setup(C_IDLE_HIGH | (md ? (C_CPOL | C_CPHA) : 0), 1, 1);
           // status: idle
           cur = x_rd;
           ent(xa(KTX, 8, 1, 1'b0, 1'b1, 1'b0, fl_cs), 32'h05);
           ent(xa(KRX, 8, 1, 1'b0, 1'b0, 1'b0, fl_cs), 0);
           wait_idle(100000); rx_drain;
           chk32(rx_got[cur], 32'h00, "RDSR1 idle");
           // single-lane read
           cur = x_rd;
           ent(xa(KTX, 8, 1, 1'b0, 1'b1, 1'b0, fl_cs), 32'h03);
           ent(xa(KTX, 24, 1, 1'b0, 1'b1, 1'b0, fl_cs), 32'h10);
           ent(xa(KRX, 32, 1, 1'b0, 1'b0, 1'b0, fl_cs), 3);
           wait_idle(100000); rx_drain;
           fl_check_words(cur, 8'h10, 4);
           if (LANES_MAX == 4)
             begin
                // write enable, quad page program at 0x40, WIP poll
                for (i = 0; i < 256; i = i + 1) old[i] = fl_mem[i];
                ent(xa(KTX, 8, 1, 1'b0, 1'b0, 1'b0, fl_cs), 32'h06);
                ent(xa(KTX, 8, 1, 1'b0, 1'b1, 1'b0, fl_cs), 32'h32);
                ent(xa(KTX, 24, 1, 1'b0, 1'b1, 1'b0, fl_cs), 32'h40);
                for (i = 0; i < 4; i = i + 1)
                  ent(xa(KTX, 32, 4, 1'b0, (i != 3), 1'b0, fl_cs), 32'h0F0F_F0F0 ^ (i * 32'h1111_1111));
                cur = x_rd;
                ent(xa(KTX, 8, 1, 1'b0, 1'b1, 1'b0, fl_cs), 32'h05);
                ent(xa(KPOLL, 8, 1, 1'b0, 1'b0, 1'b0, fl_cs), {8'h01, 8'h01, 16'd63});
                wait_idle(100000); rx_drain;
                chk32(rx_got[cur], 32'h00, "WIP poll ends with WIP 0");
                for (i = 0; i < 16; i = i + 1)
                  begin
                     v = 32'h0F0F_F0F0 ^ ((i / 4) * 32'h1111_1111);
                     chk(fl_mem[8'h40 + i] === (old[8'h40 + i] & v[31 - 8 * (i % 4) -: 8]), "QPP programmed byte");
                  end
                // Quad I/O Read with 1, 4 and 0 dummy clocks
                for (i = 0; i < 3; i = i + 1)
                  begin
                     fl_dummy = (i == 0) ? 1 : (i == 1) ? 4 : 0;
                     cur = x_rd;
                     ent(xa(KTX, 8, 1, 1'b0, 1'b1, 1'b0, fl_cs), 32'hEB);
                     ent(xa(KTX, 24, 4, 1'b0, 1'b1, 1'b0, fl_cs), 32'h3C + i);
                     ent(xa(KTX, 8, 4, 1'b0, 1'b1, 1'b0, fl_cs), 32'h00);
                     if (fl_dummy > 0) ent(xa(KDUMMY, 4, 4, 1'b0, 1'b1, 1'b0, fl_cs), fl_dummy - 1);
                     ent(xa(KRX, 32, 4, 1'b0, 1'b0, 1'b0, fl_cs), 7);
                     wait_idle(100000); rx_drain;
                     fl_check_words(cur, 8'h3C + i, 8);
                  end
                // continuous read mode: Axh keeps it, 00h leaves it
                fl_dummy = 1;
                cur = x_rd;
                ent(xa(KTX, 8, 1, 1'b0, 1'b1, 1'b0, fl_cs), 32'hEB);
                ent(xa(KTX, 24, 4, 1'b0, 1'b1, 1'b0, fl_cs), 32'h80);
                ent(xa(KTX, 8, 4, 1'b0, 1'b1, 1'b0, fl_cs), 32'hA5);
                ent(xa(KDUMMY, 4, 4, 1'b0, 1'b1, 1'b0, fl_cs), 0);
                ent(xa(KRX, 32, 4, 1'b0, 1'b0, 1'b0, fl_cs), 1);
                wait_idle(100000); rx_drain;
                chk(fl_cont == 1'b1, "mode bits Axh: continuous read mode");
                fl_check_words(cur, 8'h80, 2);
                cur = x_rd;
                ent(xa(KTX, 24, 4, 1'b0, 1'b1, 1'b0, fl_cs), 32'hC0);
                ent(xa(KTX, 8, 4, 1'b0, 1'b1, 1'b0, fl_cs), 32'h00);
                ent(xa(KDUMMY, 4, 4, 1'b0, 1'b1, 1'b0, fl_cs), 0);
                ent(xa(KRX, 32, 4, 1'b0, 1'b0, 1'b0, fl_cs), 1);
                wait_idle(100000); rx_drain;
                chk(fl_cont == 1'b0, "mode bits 00h: continuous read mode left");
                fl_check_words(cur, 8'hC0, 2);
             end
        end
      stimulus_done = 1;
   end
