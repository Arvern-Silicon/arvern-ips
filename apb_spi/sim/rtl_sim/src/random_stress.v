//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    random_stress
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : random_stress.v
// Module Description : Random batches of entries: each batch picks a clock
//                      mode, bit and byte order, divider, receive delay
//                      within the device budget and select timing, then
//                      pushes random entries (every kind, lane width the
//                      build has, frame length, CAPT, CS_HOLD, select and
//                      CS_NONE) with random gaps, so the engine runs
//                      gap-free, pauses with a held select, stalls on a
//                      full receive FIFO and switches selects. The monitor
//                      checks every frame on the wire; every received word
//                      is compared with the frame the device sent.
//
// Doc "Transfers", "Chip selects", "Lanes and pads", "Receive timing".
//----------------------------------------------------------------------------

integer    b, i, n, k, bits, lanes, half, rxd, kind, nb, sel, gap;
reg [31:0] d, pm, pv;
reg        hold, none, capt;

initial
   begin
      wait_reset_done(5);
      ent_drain = 1'b1;
      nb = 12;
      for (b = 0; b < nb; b = b + 1)
        begin
           wait_idle(400000);
           rx_drain;
           half = ($urandom % 4 == 0) ? 1 + $urandom % 6 : 1;
           // a device round trip and a receive delay inside the budget (doc "Receive timing")
           dev_rt = (RX_EN != 0) ? (($urandom % 3) * 13.0) : 0.0;
           rxd = 0;
           while (((half + rxd) * PCLK_P - (dev_rt + dev_tco) < 0.5) && rxd < 15) rxd = rxd + 1;
           k = rxd;
           while ((half * PCLK_P + dev_rt + dev_tho - (k + 1) * PCLK_P > 0.5) && k < 15) k = k + 1;
           rxd = rxd + $urandom % (k - rxd + 1);
           clk_set(half, rxd);
           cs_set($urandom, 1 + $urandom % 3, 1 + $urandom % 3, 1 + $urandom % 3);
           ctrl_wr(C_EN | ($urandom & (C_CPOL | C_CPHA | C_LSB | C_BSWAP)) |
                   ((RX_EN != 0 && $urandom % 6 == 0) ? (C_IDLE_REL | C_RX_IO0) : C_IDLE_HIGH) |
                   (($urandom % 4 == 0) ? C_IO23_REL : 0));
           n = 10 + $urandom % 30;
           for (i = 0; i < n; i = i + 1)
             begin
                lanes = 1;
                if (LANES_MAX >= 2 && $urandom % 3 == 0) lanes = 2;
                if (LANES_MAX == 4 && $urandom % 3 == 0) lanes = 4;
                if (apb_spi_inst0.ctrl[6]) lanes = 1;               // 3-wire: single lane
                bits = lanes * (1 + $urandom % (32 / lanes));
                kind = $urandom % 4;
                if (RX_EN == 0 && (kind == 1 || kind == 3)) kind = 0;
                if (!POLL_USE && kind == 3) kind = 1 - (RX_EN == 0);
                if (kind == 1 || kind == 3) if (RX_EN == 0) kind = 0;
                capt = (RX_EN != 0) && (lanes == 1) && ($urandom % 2) && !apb_spi_inst0.ctrl[6];
                hold = ($urandom % 4 != 0);
                none = ($urandom % 10 == 0);
                sel  = $urandom % CS_NR;
                d    = $urandom;
                if (kind != 0) d = $urandom % 3;                     // frame / clock count - 1
                if (kind == 3) begin pm = $urandom; d = {pm[7:0], pm[15:8] & pm[7:0], 14'd0, pm[17:16]}; end
                for (k = 0; k < 4; k = k + 1) rq_push($urandom);
                ent(xa(kind, bits, lanes, capt, hold, none, sel), d);
                gap = $urandom % 8;
                if (gap == 0) repeat ($urandom % 200) @(posedge free_clk);
                if (gap == 1 && (apb_spi_inst0.rx_level != 0) && (x_rd < x_wr)) rx_pop_chk(1);
             end
           // close a held select
           ent(xa(KDUMMY, 8, 1, 1'b0, 1'b0, 1'b0, 0), 0);
        end
      wait_idle(400000);
      rx_drain;
      chk(x_rd == x_wr, "every expected word read");
      $display("random_stress: %0d frames, %0d transactions, %0d words", n_frames, n_txn, x_wr);
      stimulus_done = 1;
   end
