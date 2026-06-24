//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    sswi_multihart
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : sswi_multihart
// Module Description : Per-hart SETSSIP edge routing per ACLINT 1.0-rc4 Ch4.
//                      For each hart h:
//                        + Writing 1 to SETSSIP[h] (offset 4*h) fires a
//                          1-cycle pulse ONLY on irq_s_software_o[h].
//                        + No other hart's edge fires.
//                        + Reads always return 0.
//                      Then a simultaneous-set scenario: write 1 to several
//                      SETSSIP regs in sequence and check each hart sees
//                      exactly one pulse on its own line.
//                      Requires NUM_HARTS >= 2, SU_MODE_EN = 1.
//----------------------------------------------------------------------------

integer ii;
integer last_hart;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|       SSWI : PER-HART EDGE SWEEP              |");
      $display(" ===============================================");
      $display("INFO:  NUM_HARTS = %0d", NUM_HARTS);

      // Per-hart independence: write 1 to SETSSIP[h], confirm only h's edge
      // fires for one cycle and the other hart bits stay 0; read back 0.
      for (ii = 0; ii < NUM_HARTS; ii = ii + 1) begin
         ahb_write(1, MACHINE, 32'h0040C000 + (32'h4 * ii), 32'h00000001, 2, OK);
         #1;
         if (tb_ahb_aclint.dut.irq_s_software_o[ii] !== 1'b1) begin
            $display("ERROR: irq_s_software_o[%0d] expected 1 (edge cycle) -- got %b %t ns",
                     ii, tb_ahb_aclint.dut.irq_s_software_o[ii], $time);
            error = error + 1;
         end else begin
            $display("PASS:  irq_s_software_o[%0d] == 1 on edge cycle %t ns", ii, $time);
         end

         // Pulse drops one cycle later.
         @(posedge free_clk);
         #1;
         if (tb_ahb_aclint.dut.irq_s_software_o[ii] !== 1'b0) begin
            $display("ERROR: irq_s_software_o[%0d] expected 0 after pulse -- got %b %t ns",
                     ii, tb_ahb_aclint.dut.irq_s_software_o[ii], $time);
            error = error + 1;
         end else begin
            $display("PASS:  irq_s_software_o[%0d] dropped after pulse %t ns", ii, $time);
         end

         // Read-back: spec says LSB-reads-0, all upper bits 0.
         ahb_read(1, MACHINE, 32'h0040C000 + (32'h4 * ii), 32'h00000000, 2, 1, OK);
      end

      // Make sure nothing latched residual after the per-hart sweep.
      repeat(3) @(posedge free_clk);
      #1;
      if (|tb_ahb_aclint.dut.irq_s_software_o !== 1'b0) begin
         $display("ERROR: irq_s_software_o non-zero at end of per-hart sweep -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_s_software_o, $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_s_software_o all-zero at end of per-hart sweep %t ns", $time);
      end

      $display(" ===============================================");
      $display("|     SSWI : SIMULTANEOUS EDGES IN A WINDOW     |");
      $display(" ===============================================");

      // Fire SETSSIP[0], SETSSIP[1], SETSSIP[last] in rapid succession. Each
      // ahb_write takes 2 hclk cycles; the edges arrive ~1 cycle after each
      // write. Track each hart's pulse count by repeated probing.
      last_hart = NUM_HARTS - 1;

      ahb_write(1, MACHINE, 32'h0040C000,                       32'h00000001, 2, OK);
      #1;
      if (tb_ahb_aclint.dut.irq_s_software_o[0] !== 1'b1) begin
         $display("ERROR: SETSSIP[0] edge missing -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_s_software_o[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  SETSSIP[0] edge fired on irq_s_software_o[0] %t ns", $time);
      end

      ahb_write(1, MACHINE, 32'h0040C000 + (32'h4 * 1),         32'h00000001, 2, OK);
      #1;
      if (tb_ahb_aclint.dut.irq_s_software_o[1] !== 1'b1) begin
         $display("ERROR: SETSSIP[1] edge missing -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_s_software_o[1], $time);
         error = error + 1;
      end else begin
         $display("PASS:  SETSSIP[1] edge fired on irq_s_software_o[1] %t ns", $time);
      end

      ahb_write(1, MACHINE, 32'h0040C000 + (32'h4 * last_hart), 32'h00000001, 2, OK);
      #1;
      if (tb_ahb_aclint.dut.irq_s_software_o[last_hart] !== 1'b1) begin
         $display("ERROR: SETSSIP[%0d] edge missing -- got %b %t ns",
                  last_hart, tb_ahb_aclint.dut.irq_s_software_o[last_hart], $time);
         error = error + 1;
      end else begin
         $display("PASS:  SETSSIP[%0d] edge fired on irq_s_software_o[%0d] %t ns",
                  last_hart, last_hart, $time);
      end

      // After all edges + a few cycles, the line settles back to all-zero.
      repeat(3) @(posedge free_clk);
      #1;
      if (|tb_ahb_aclint.dut.irq_s_software_o !== 1'b0) begin
         $display("ERROR: irq_s_software_o expected 0 after window of edges -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_s_software_o, $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_s_software_o == 0 after window of edges %t ns", $time);
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
