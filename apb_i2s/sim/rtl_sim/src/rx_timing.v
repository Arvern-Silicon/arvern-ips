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
// Module Description : Receive sampling point and round-trip budget with
//                      MDIV 2, RATIO 256 (BCLK half-period H = 8 cycles,
//                      400 ns): data that settles before the sampling point
//                      (RX_DLY cycles after the BCLK sampling edge) is
//                      received correctly and data that settles after it is
//                      not, at RX_DLY 0, 1, 3 and 6 (setup side); with a
//                      1 ns round trip RX_DLY 6 still samples before the next
//                      bit and RX_DLY 10 and 14 sample after it (hold side).
//                      Every round trip stays below a BCLK period.
//
// Doc "Receive timing": the pad value at the pclk edge RX_DLY cycles after
// the sampling edge is captured; correct when the round trip is below
// (H + RX_DLY) pclk periods and the sampling point is before the next
// change (launch + 2H + round trip).
//----------------------------------------------------------------------------

integer dl [0:5];
integer di, ok, rtv, exp_ok, f, i, n;

task try_rt;
   input integer rt;
   input integer expect_ok;
   integer       first;
   begin
      dev_rt = rt;
      i2s_setup(2, 3'd0, F_I2S, 1'b0);
      rx_fill(n);
      rx_read(n);
      first = -1;
      for (f = 0; (f < 4000) && (first < 0); f = f + 1)
        if (rx_exp_word(f, 1'b0, 2'd0) == got_rx[0]) first = f;
      ok = (first >= 0);
      for (i = 1; ok && (i < n); i = i + 1)
        if (got_rx[i] !== rx_exp_word(first + i, 1'b0, 2'd0)) ok = 0;
      if (ok != expect_ok)
        begin
           $display("ERROR: RX timing -- RX_DLY %0d round trip %0d ns: received %s, expected %s %t ns",
                    rx_dly, rt, ok ? "correctly" : "wrong", expect_ok ? "correct" : "wrong", $time);
           error = error + 1;
        end
      else
        $display("PASS:  RX timing -- RX_DLY %0d round trip %0d ns: %s", rx_dly, rt, ok ? "correct" : "wrong as expected");
      wr(R_CMD, 32'h2);
   end
endtask

initial
   begin
      wait_reset_done(5);
      if (RX_EN == 0) tb_skip("no receive path");
      n = (RX_DEPTH < 4) ? RX_DEPTH : 4;
      dl[0] = 0; dl[1] = 1; dl[2] = 3; dl[3] = 6; dl[4] = 10; dl[5] = 14;
      for (di = 0; di < 6; di = di + 1)
        begin
           rx_dly = dl[di];
           // setup side: the sampling point is (8 + RX_DLY) * 50 ns after the launch
           if (dl[di] <= 6)
             begin
                try_rt((8 + dl[di]) * 50 - 5, 1);
                try_rt((8 + dl[di]) * 50 + 5, 0);
             end
           // hold side: the next bit lands 16 * 50 ns + the round trip after the launch
           if (dl[di] >= 6)
             try_rt(1, ((8 + dl[di]) * 50) < (16 * 50 + 1));
        end
      rx_dly = 0;
      dev_rt = 10;
      stimulus_done = 1;
   end
