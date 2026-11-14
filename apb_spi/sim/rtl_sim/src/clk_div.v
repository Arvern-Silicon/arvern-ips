//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    clk_div
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : clk_div.v
// Module Description : Serial-clock divider: transfers at HALF = 1 to 8, 42,
//                      250 and 4096 (the monitor checks every half-period,
//                      the setup, hold and inactive times in ns), the
//                      divider changed between transactions and taking
//                      effect at the next one.
//
// Doc "Clocks and serial clock", "Divider changes".
//----------------------------------------------------------------------------

integer    i, h;
integer    halves [0:11];

initial
   begin
      wait_reset_done(5);
      halves[0] = 1; halves[1] = 2; halves[2] = 3; halves[3] = 4; halves[4] = 5; halves[5] = 6;
      halves[6] = 7; halves[7] = 8; halves[8] = 42; halves[9] = 250; halves[10] = 4096; halves[11] = 2;
      ctrl_wr(C_EN | C_IDLE_HIGH);
      cs_set(8'h00, 1, 1, 1);
      for (i = 0; i < 12; i = i + 1)
        begin
           h = halves[i];
           clk_set(h, 0);
           if (h < 4096)
             begin
                ent_tx(8, $urandom, 1'b1);
                if (RX_EN != 0) begin rq_push($urandom); ent_rx(8, 1, 1'b1); end
                ent_tx(16, $urandom, 1'b0);
             end
           else
             ent_tx(2, 32'h2, 1'b0);
           wait_idle(200000);
           rx_drain;
           chk(t_H == h, "the transaction ran at the divider written");
        end
      stimulus_done = 1;
   end
