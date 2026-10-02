//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    i2c_fast_bus_guards
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : i2c_fast_bus_guards
// Module Description : The two read-phase delimiter guards -- sda_guard and the
//                      bus_listen mask -- keep a frame intact when the bus runs
//                      faster than the declared floor.
//
//   Both guards exist to stop the target mistaking its OWN line movement for a START
//   or STOP. At the nominal 200 ns bus period neither ever engages: the master moves
//   SCL low before the target changes data, so no delimiter is ever manufactured.
//   Measured across the whole i2c suite, `stop_cond & read_phase` and
//   `sda_guard & start_cond` are both silent -- which is why removing either guard
//   changed nothing observable.
//
//   They become load-bearing once the bus period shrinks enough that the target's
//   data change lands while SCL is still high. That happens below the declared floor,
//   so this test deliberately runs there: 42 ns down to 36 ns (nominal is 200 ns).
//
//   A SWEEP rather than one pinned period, because the two guards engage over
//   different ranges -- sda_guard from ~42 ns, the STOP mask only from ~38 ns, and
//   below ~36 ns the link stops working altogether. A single period would sit in a
//   2 ns window and turn any small timing change into a mystery failure.
//
//   The `*_seen` checks are the precondition: if a future change moves the window out
//   of the swept range the guards stop engaging, and without them this test would keep
//   passing while proving nothing.
//----------------------------------------------------------------------------

reg guard_fired_seen;                 // sda_guard suppressed a self-inflicted START
reg stop_masked_seen;                 // bus_listen suppressed a self-inflicted STOP

initial begin
   guard_fired_seen = 1'b0;
   stop_masked_seen = 1'b0;
end

always @(posedge free_clk) begin
   if (dut.g_i2c.u_dtm.stop_cond && dut.g_i2c.u_dtm.read_phase)          stop_masked_seen <= 1'b1;
   if ((|dut.g_i2c.u_dtm.sda_guard) && dut.g_i2c.u_dtm.start_cond)       guard_fired_seen <= 1'b1;
end

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;
      integer    k;
      real       hp;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      slave_latency = 2;

      $display(" ===================================================");
      $display("|  I2C: delimiter guards on a below-floor bus       |");
      $display(" ===================================================");

      for (k = 0; k < 4; k = k + 1) begin
         hp       = 42.0 - (k * 2.0);         // 42, 40, 38, 36 ns
         T_HIGH   = hp;
         T_LOW    = hp;
         T_SU_STA = hp;
         T_SU     = hp / 4.0;

         // A read is what matters: the guards only act in the read phase.
         dmi_i2c(7'h20, OP_WRITE, 32'hC0DE_0000 + k, st, rd);
         dmi_i2c(7'h20, OP_READ,  32'h0,             st, rd);
         check_eq("fast_rd", rd, 32'hC0DE_0000 + k);
      end

      // Both guards must actually have engaged, or the checks above prove nothing.
      check_eq("guard_fired", guard_fired_seen, 1'b1);
      check_eq("stop_masked", stop_masked_seen, 1'b1);

      // Back to nominal: the link is unharmed by the excursion.
      T_HIGH = 200.0;  T_LOW = 200.0;  T_SU_STA = 200.0;  T_SU = 50.0;
      dmi_i2c(7'h21, OP_WRITE, 32'h1234_5678, st, rd);
      dmi_i2c(7'h21, OP_READ,  32'h0,         st, rd);
      check_eq("nominal_rd", rd, 32'h1234_5678);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
