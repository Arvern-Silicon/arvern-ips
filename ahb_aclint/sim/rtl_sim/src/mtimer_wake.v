//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_wake
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_wake.v
// Module Description : Marquee test : program MTIMECMP[0] just ahead of
//                      the current MTIME, wait for irq_m_timer_o[0] to
//                      assert, then push MTIMECMP to the top of the range
//                      and verify the interrupt clears within a few CDC
//                      roundtrips.
//----------------------------------------------------------------------------

reg  [63:0] t_now;
reg  [63:0] target;
integer     poll_count;
reg         irq_seen;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(20) @(posedge free_clk);

      $display(" ===============================================");
      $display("|        MTIMER : WAKE-FROM-IDLE TIMER          |");
      $display(" ===============================================");

      // Park MTIMECMP at the top of the range so the comparator stays low
      // while we sample the current MTIME (reset value 0xFFFFFFFFFFFFFFFF
      // would already match if MTIME happened to wrap; trivially safe here).
      ahb_write(1, MACHINE, 32'h00404004, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, 32'h00404000, 32'hFFFFFFFF, 2, OK);

      // Let the MTIMECMP CDC settle.
      repeat(40) @(posedge free_clk);

      // Capture current MTIME via the canonical LO+HI pair. We probe the
      // hclk-domain mtime_shadow register directly: it is the same atomic
      // 64-bit snapshot the AHB returns, but stays stable across the AHB
      // task termination (unlike hrdata, which falls back to 0 once
      // dph_valid clears).
      ahb_read(1, MACHINE, 32'h00404008, 32'h00000000, 2, 0, OK);
      t_now = tb_ahb_aclint.mtime_shadow_ahb_sim;
      ahb_read(1, MACHINE, 32'h0040400C, 32'h00000000, 2, 0, OK);
      $display("INFO:  t_now = 0x%h_%h %t ns", t_now[63:32], t_now[31:0], $time);

      // Program MTIMECMP slightly ahead of MTIME. 80 LF ticks at 5 MHz LF
      // = 16 us = well within the simulation timeout.
      target = t_now + 64'd80;

      // Write LO first then HI to avoid a transient match while crossing
      // the 32-bit boundary.
      ahb_write(1, MACHINE, 32'h00404000, target[31:0],  2, OK);
      ahb_write(1, MACHINE, 32'h00404004, target[63:32], 2, OK);
      $display("INFO:  programmed MTIMECMP = 0x%h_%h %t ns",
               target[63:32], target[31:0], $time);

      // Wait for the MTIMECMP CDC to commit + MTIME to catch up.
      repeat(40) @(posedge free_clk);

      // Bounded poll for the interrupt to assert.
      irq_seen   = 1'b0;
      poll_count = 0;
      begin : POLL_RISE
         repeat (2000) begin
            @(posedge free_clk);
            poll_count = poll_count + 1;
            if (tb_ahb_aclint.dut.irq_m_timer_o == 1'b1) begin
               irq_seen = 1'b1;
               disable POLL_RISE;
            end
         end
      end

      if (irq_seen) begin
         $display("PASS:  irq_m_timer_o[0] asserted after %0d hclk cycles %t ns",
                  poll_count, $time);
      end else begin
         $display("ERROR: irq_m_timer_o[0] did not assert within 2000 hclk cycles %t ns",
                  $time);
         error = error + 1;
      end

      // Push MTIMECMP all the way up; expect the interrupt to drop back to 0
      // within a handful of CDC + synchroniser cycles.
      ahb_write(1, MACHINE, 32'h00404000, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, 32'h00404004, 32'hFFFFFFFF, 2, OK);

      // Wait for the LF side to absorb the new compare value + 2-FF sync.
      // Budget ~14 hclk + 4 LF ~= 850 ns ~= 17 hclk cycles; use 200 to be safe.
      irq_seen   = 1'b1;
      poll_count = 0;
      begin : POLL_FALL
         repeat (200) begin
            @(posedge free_clk);
            poll_count = poll_count + 1;
            if (tb_ahb_aclint.dut.irq_m_timer_o == 1'b0) begin
               irq_seen = 1'b0;
               disable POLL_FALL;
            end
         end
      end

      if (irq_seen == 1'b0) begin
         $display("PASS:  irq_m_timer_o[0] cleared after %0d hclk cycles %t ns",
                  poll_count, $time);
      end else begin
         $display("ERROR: irq_m_timer_o[0] did not clear within 200 hclk cycles %t ns",
                  $time);
         error = error + 1;
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
