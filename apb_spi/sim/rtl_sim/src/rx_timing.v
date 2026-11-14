//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    rx_timing
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : rx_timing.v
// Module Description : Receive sampling point: for both clock phases, HALF
//                      1 to 3, device round trips of 0, 13 and 27 ns and
//                      every RX_DLY up to 2·HALF + 2, the words received are
//                      correct exactly when the document's two-sided budget
//                      holds and wrong when it fails by a margin:
//                        rt + t_co < (HALF + RX_DLY)·T   (setup)
//                        RX_DLY·T  < HALF·T + rt + t_ho  (hold)
//                      with the device's t_co = 6 ns and t_ho = 1 ns; a
//                      capture landing after the select release is still
//                      delivered.
//
// Doc "Receive timing".
//----------------------------------------------------------------------------

integer    ph, h, ri, rxd, k, bad;
real       rt, su, ho;
reg [31:0] pat [0:3];
reg        ok, fail;

initial
   begin
      wait_reset_done(5);
      if (RX_EN == 0) tb_skip("needs the receive path");
      pat[0] = 32'h35; pat[1] = 32'hCB; pat[2] = 32'h69; pat[3] = 32'h97;
      cs_set(8'h00, 1, 1, 1);
      rx_auto = 0;
      for (ph = 0; ph < 2; ph = ph + 1)
        for (h = 1; h <= 3; h = h + 1)
          for (ri = 0; ri < 3; ri = ri + 1)
            for (rxd = 0; rxd <= 2 * h + 2 && rxd < 16; rxd = rxd + 1)
              begin
                 rt  = (ri == 0) ? 0.0 : (ri == 1) ? 13.0 : 27.0;
                 su  = (h + rxd) * PCLK_P - (rt + dev_tco);     // setup margin
                 ho  = h * PCLK_P + rt + dev_tho - rxd * PCLK_P; // hold margin
                 ok   = (su > 0.5) && (ho > 0.5);
                 fail = (su < -0.5) || (ho < -0.5);
                 if (ok || fail)
                   begin
                      dev_rt = rt;
                      clk_set(h, rxd);
                      ctrl_wr(C_EN | C_IDLE_HIGH | (ph ? C_CPHA : 0));
                      for (k = 0; k < 4; k = k + 1) rq_push(pat[k]);
                      ent_rx(8, 4, 1'b0);
                      wait_idle(100000);
                      rx_drain;
                      bad = 0;
                      for (k = 0; k < 4; k = k + 1)
                        if (rx_got[x_rd - 4 + k] !== pat[k]) bad = bad + 1;
                      if (ok && bad != 0) begin
                         $display("ERROR: rx_timing: CPHA %0d HALF %0d rt %0.0f RX_DLY %0d inside the budget, %0d bad words %t ns",
                                  ph, h, rt, rxd, bad, $time);
                         error = error + 1;
                      end
                      if (fail && bad == 0) begin
                         $display("ERROR: rx_timing: CPHA %0d HALF %0d rt %0.0f RX_DLY %0d outside the budget, all words right %t ns",
                                  ph, h, rt, rxd, $time);
                         error = error + 1;
                      end
                      if (ok && rxd == 0) cv_rxdly0 = 1;
                      if (ok && rxd >= 2 * h) cv_rxdly_late = 1;
                   end
              end
      // the receive delay line at every RX_DLY (a round trip that keeps it in the
      // budget at HALF 1), with every frame shape it carries: single, dual and
      // quad receive frames, loopback, the 3-wire receive lane
      rx_auto = 1;
      for (rxd = 0; rxd < 16; rxd = rxd + 1)
        begin
           dev_rt = (rxd == 0) ? 0.0 : 20.0 * rxd - 6.0;
           clk_set(1, rxd);
           ctrl_wr(C_EN | C_IDLE_HIGH);
           for (k = 0; k < 8; k = k + 1) rq_push($urandom);
           ent(xa(KRX, 8, 1, 1'b0, 1'b1, 1'b0, 0), 1);
           if (LANES_MAX >= 2) ent(xa(KRX, 8, 2, 1'b0, 1'b1, 1'b0, 0), 1);
           if (LANES_MAX == 4) ent(xa(KRX, 8, 4, 1'b0, 1'b1, 1'b0, 0), 1);
           ent(xa(KRX, 8, 1, 1'b0, 1'b0, 1'b0, 0), 0);
           wait_idle(100000);
           rx_drain;
           ctrl_wr(C_EN | C_IDLE_HIGH | C_LOOPBACK);
           ent_txc(8, $urandom, 1'b1);
           ent_txc(8, $urandom, 1'b0);
           wait_idle(100000);
           rx_drain;
           ctrl_wr(C_EN | C_IDLE_REL | C_RX_IO0);
           ent_tx(8, $urandom, 1'b1);
           rq_push($urandom); rq_push($urandom);
           ent_rx(8, 2, 1'b0);
           wait_idle(100000);
           rx_drain;
        end
      // RX_DLY 15 at HALF 16 is inside the budget
      dev_rt = 0.0;
      clk_set(16, 15);
      ctrl_wr(C_EN | C_IDLE_HIGH);
      rx_auto = 1;
      for (k = 0; k < 4; k = k + 1) rq_push(pat[k]);
      ent_rx(8, 4, 1'b0);
      wait_idle(100000);
      rx_drain;
      cv_rxdly15 = 1;
      stimulus_done = 1;
   end
