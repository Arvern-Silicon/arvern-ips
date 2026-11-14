//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    frame_bits
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : frame_bits.v
// Module Description : Frame lengths: every length 1 to 32 in single lane
//                      (transmit with CAPT, receive), every even length in
//                      dual and every multiple of four in quad, in modes 0
//                      and 3, MSB and LSB first.
//
// Doc "Entry attributes", "Frame format and clock modes".
//----------------------------------------------------------------------------

integer    n, m, lanes, l;

initial
   begin
      wait_reset_done(5);
      cs_set(8'h00, 1, 1, 1);
      clk_set(1, 0);
      for (m = 0; m < 2; m = m + 1)
        begin
           ctrl_wr(C_EN | C_IDLE_HIGH | (m ? (C_CPOL | C_CPHA | C_LSB) : 0));
           for (l = 0; l < 3; l = l + 1)
             begin
                lanes = (l == 0) ? 1 : (l == 1) ? 2 : 4;
                if (lanes <= LANES_MAX)
                  for (n = lanes; n <= 32; n = n + lanes)
                    begin
                       ent(xa(KTX, n, lanes, (RX_EN != 0) && (lanes == 1), 1'b1, 1'b0, 0), $urandom);
                       if (RX_EN != 0) begin rq_push($urandom); rq_push($urandom); ent(xa(KRX, n, lanes, 1'b0, 1'b1, 1'b0, 0), 1); end
                    end
             end
           ent_tx(8, 32'hFF, 1'b0);
           wait_idle(200000);
           rx_drain;
        end
      stimulus_done = 1;
   end
