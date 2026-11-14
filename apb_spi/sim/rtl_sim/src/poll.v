//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    poll
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : poll.v
// Module Description : POLL entries: an R1 wait (mask 80h, value 80h), a
//                      start-token wait (FFh / FFh) and a busy wait (FFh /
//                      00h), each followed by a receive entry that must get
//                      the byte after the terminating frame intact; a
//                      condition met on the first and on the last allowed
//                      frame (no POLL_TO), a timeout (POLL_TO, the last
//                      frame pushed), more discarded frames than the FIFO
//                      holds; HALF 1 with RX_DLY 0, 1 and 15 (a device round
//                      trip of 295 ns), both clock phases, dual and quad;
//                      the SCK idle time between two poll frames is
//                      max(HALF, RX_DLY + 3) cycles.
//
// Doc "Polling".
//----------------------------------------------------------------------------

integer    ph, c, rxd, i, lanes, cur, g0;
real       gap;

task one;                                     // poll for (m, v), n frames allowed, the device sending k misses first
   input [7:0] m;
   input [7:0] v;
   input integer n;
   input integer k;
   input [7:0] miss;
   input [7:0] hit;
   input integer lanes;
   integer j;
   begin
      for (j = 0; j < k; j = j + 1) rq_push(miss);
      rq_push(hit);
      rq_push(32'hA5);
      ent(xa(KPOLL, 8, lanes, 1'b0, 1'b1, 1'b0, 0), {m, v, n[15:0] - 16'd1});
      ent(xa(KRX, 8, lanes, 1'b0, 1'b0, 1'b0, 0), 0);
   end
endtask

initial
   begin
      wait_reset_done(5);
      if (!POLL_USE) tb_skip("needs POLL");
      cs_set(8'h00, 1, 1, 1);
      for (ph = 0; ph < 2; ph = ph + 1)
        for (c = 0; c < 3; c = c + 1)
          begin
             rxd = (c == 0) ? 0 : (c == 1) ? 1 : 15;
             dev_rt = (c == 2) ? 295.0 : 0.0;
             spi_setup(C_IDLE_HIGH | (ph ? C_CPHA : 0), 1, rxd);
             wr(R_IRQ_PEND, 32'h7C);
             cur = x_rd;
             g0 = n_poll_gap;
             one(8'h80, 8'h80, 16, 3, 8'hFF, 8'h01, 1);    // R1 after three FFh
             one(8'hFF, 8'hFF, 64, 5, 8'hFF, 8'hFE, 1);    // start token
             one(8'hFF, 8'h00, 64, 4, 8'h00, 8'hFF, 1);    // busy end
             one(8'hFF, 8'hFF, 8, 0, 8'hFF, 8'hFE, 1);     // first frame
             one(8'hFF, 8'hFF, 4, 3, 8'hFF, 8'hFE, 1);     // last allowed frame
             wait_idle(100000);
             rx_drain;
             for (i = 0; i < 5; i = i + 1)
               chk32(rx_got[cur + 2 * i + 1], 32'hA5, "the byte after the terminating frame");
             chk32(rx_got[cur], 32'h01, "R1"); chk32(rx_got[cur + 2], 32'hFE, "token"); chk32(rx_got[cur + 4], 32'hFF, "busy end");
             irq_chk(32'h0, I_POLL_TO);
             // timeout: four frames, never met, the last pushed
             cur = x_rd;
             for (i = 0; i < 4; i = i + 1) rq_push(32'hFF);
             ent(xa(KPOLL, 8, 1, 1'b0, 1'b0, 1'b0, 0), {8'hFF, 8'hFF, 16'd3});
             wait_idle(100000);
             rx_drain;
             chk(x_rd == cur + 1, "timeout pushes the last frame only");
             irq_chk(I_POLL_TO, I_POLL_TO);
             // the SCK idle time between poll frames
             chk(n_poll_gap > g0, "poll frames resumed after the pause");
             gap = ((rxd + 3) > 1 ? (rxd + 3) : 1) * PCLK_P;
             if ((t_poll_gap < gap - 0.01) || (t_poll_gap > gap + 0.01)) begin
                $display("ERROR: poll pause %0.1f ns, expected %0.1f ns (CPHA %0d RX_DLY %0d) %t ns", t_poll_gap, gap, ph, rxd, $time);
                error = error + 1;
             end
          end
      dev_rt = 0.0;
      // more discarded frames than the FIFO holds, the FIFO empty
      spi_setup(C_IDLE_HIGH, 1, 1);
      cur = x_rd;
      one(8'hFF, 8'hFF, 4 * RX_DEPTH + 20, 3 * RX_DEPTH + 5, 8'hFF, 8'hFE, 1);
      wait_idle(200000);
      rx_drain;
      chk32(rx_got[cur], 32'hFE, "token after more frames than the FIFO holds");
      // the widest frame count: 65536 frames allowed, met on the third
      cur = x_rd;
      one(8'hFF, 8'hFF, 65536, 2, 8'hFF, 8'h5A, 1);
      one(8'hFF, 8'hFF, 4, 1, 8'hFF, 8'hFE, 1);
      wait_idle(200000);
      rx_drain;
      chk32(rx_got[cur], 32'h5A, "a 65536-frame poll ends on its condition");
      // dual and quad
      for (lanes = 2; lanes <= LANES_MAX; lanes = lanes * 2)
        begin
           cur = x_rd;
           one(8'h0F, 8'h0F, 16, 2, 8'hFF, 8'h3C, lanes);
           wait_idle(100000);
           rx_drain;
           chk32(rx_got[cur], 32'h3C, "multi-lane poll");
        end
      stimulus_done = 1;
   end
