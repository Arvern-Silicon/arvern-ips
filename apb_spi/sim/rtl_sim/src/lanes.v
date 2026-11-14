//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    lanes
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : lanes.v
// Module Description : Lanes and pads: single, dual and quad transmit,
//                      receive and dummy frames with IO23_REL both ways;
//                      IO0 driven low, high and released (TX_IDLE) during
//                      single-lane receive frames; the 3-wire mode (IO0
//                      released, RX_IO0) with a write then a read on the
//                      shared line, gap-free and after a pause; lanes a dual
//                      or quad frame released staying released until the
//                      select is released (a flash may go on driving them).
//
// Doc "Lanes and pads".
//----------------------------------------------------------------------------

integer    l, lanes, r, ti;

initial
   begin
      wait_reset_done(5);
      cs_set(8'h00, 1, 1, 1);
      clk_set(2, 0);
      for (r = 0; r < 2; r = r + 1)
        for (l = 0; l < 3; l = l + 1)
          begin
             lanes = (l == 0) ? 1 : (l == 1) ? 2 : 4;
             if (lanes <= LANES_MAX)
               begin
                  ctrl_wr(C_EN | C_IDLE_HIGH | (r ? C_IO23_REL : 0));
                  ent(xa(KTX, 16, lanes, 1'b0, 1'b1, 1'b0, 0), $urandom);
                  ent(xa(KDUMMY, 4, lanes, 1'b0, 1'b1, 1'b0, 0), 2);
                  if (RX_EN != 0) begin rq_push($urandom); ent(xa(KRX, 16, lanes, 1'b0, 1'b1, 1'b0, 0), 0); end
                  ent(xa(KTX, 8, lanes, 1'b0, 1'b0, 1'b0, 0), $urandom);
                  wait_idle(100000);
                  rx_drain;
               end
          end
      if (RX_EN != 0)
        begin
           // IO0 during single-lane receive frames: low, high, released
           for (ti = 0; ti < 3; ti = ti + 1)
             begin
                ctrl_wr(C_EN | (ti == 0 ? C_IDLE_LOW : ti == 1 ? C_IDLE_HIGH : C_IDLE_REL));
                rq_push($urandom);
                ent_rx(8, 2, 1'b0);
                wait_idle(100000);
                rx_drain;
             end
           // 3-wire: write then read on IO0, gap-free and after a pause
           ctrl_wr(C_EN | C_IDLE_REL | C_RX_IO0);
           ent_tx(8, 32'h81, 1'b1);
           rq_push(32'h5A); ent_rx(8, 1, 1'b1);
           wait_quiet(10000);
           repeat (50) @(posedge free_clk);
           ent_tx(16, 32'hBEEF, 1'b1);
           rq_push(32'hC3); ent_rx(8, 1, 1'b0);
           wait_idle(100000);
           rx_drain;
        end
      if (LANES_MAX == 4 && RX_EN != 0)
        begin
           // a quad read then an empty FIFO: the quad lanes stay released while the select is held
           ctrl_wr(C_EN | C_IDLE_HIGH);
           ent(xa(KTX, 8, 1, 1'b0, 1'b1, 1'b0, 0), 32'hEB);
           rq_push($urandom); ent(xa(KRX, 32, 4, 1'b0, 1'b1, 1'b0, 0), 0);
           wait_quiet(10000);
           repeat (20) @(posedge free_clk);
           chk(spi_io_oe === 4'b0000, "lanes released after a quad frame while the select is held");
           ent(xa(KTX, 8, 1, 1'b0, 1'b0, 1'b0, 0), 32'h00);
           wait_idle(100000);
           rx_drain;
           chk(spi_io_oe === 4'b1101, "idle levels back after the release");
        end
      if (LANES_MAX < 4)
        begin
           // IO2 / IO3 released: the pads move with nothing reading them in this build
           ctrl_wr(C_IDLE_HIGH | C_IO23_REL);
           dev_oe[3:2] = 2'b11; dev_v[3:2] = 2'b00;
           repeat (10) @(posedge free_clk);
           dev_oe[3:2] = 2'b00;
           repeat (10) @(posedge free_clk);
           ctrl_wr(C_EN | C_IDLE_HIGH);
        end
      stimulus_done = 1;
   end
