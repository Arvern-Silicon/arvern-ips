//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    sswi_basic
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : sswi_basic.v
// Module Description : Exercise the ACLINT SSWI device (per-hart SETSSIP at
//                      offset 4*hart, single-hart variant) per ACLINT 1.0-rc4
//                      Chapter 4:
//                        + Writing 1 to LSB sends a 1-CYCLE EDGE on
//                          irq_s_software_o[hart].
//                        + Writes of 0 / reserved bits / sub-word reads have
//                          no effect.
//                        + Reads always return 0 (LSB-reads-0 + upper-bits-0).
//----------------------------------------------------------------------------

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|        SSWI : EDGE-TRIGGERED SETSSIP[0]       |");
      $display(" ===============================================");

      // Idle state: irq_s_software_o[0] must be 0.
      if (tb_ahb_aclint.dut.irq_s_software_o !== 1'b0) begin
         $display("ERROR: irq_s_software_o expected 0 at idle -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_s_software_o, $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_s_software_o == 0 at idle %t ns", $time);
      end

      // Write 1 to SETSSIP[0]. ahb_write (blocking=1) returns on the cycle
      // ssoftware_pulse_r latches the edge -- sample IMMEDIATELY (#1 only)
      // to catch the 1-cycle pulse before it drops.
      ahb_write(1, MACHINE, 32'h0040C000, 32'h00000001, 2, OK);
      #1;
      if (tb_ahb_aclint.dut.irq_s_software_o !== 1'b1) begin
         $display("ERROR: irq_s_software_o expected 1 (pulse cycle) -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_s_software_o, $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_s_software_o == 1 (edge pulse) %t ns", $time);
      end

      // Next cycle: pulse must drop back to 0.
      @(posedge free_clk);
      #1;
      if (tb_ahb_aclint.dut.irq_s_software_o !== 1'b0) begin
         $display("ERROR: irq_s_software_o expected 0 after 1-cycle pulse -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_s_software_o, $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_s_software_o == 0 after 1-cycle pulse %t ns", $time);
      end

      // Read back SETSSIP[0]: spec says LSB ALWAYS reads 0 (and upper bits 0).
      ahb_read(1, MACHINE, 32'h0040C000, 32'h00000000, 2, 1, OK);

      // Write 0 to SETSSIP[0]: no edge. irq_s_software_o stays 0 through all
      // subsequent cycles.
      ahb_write(1, MACHINE, 32'h0040C000, 32'h00000000, 2, OK);
      repeat(3) @(posedge free_clk);
      #1;
      if (tb_ahb_aclint.dut.irq_s_software_o !== 1'b0) begin
         $display("ERROR: irq_s_software_o expected 0 after writing 0 -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_s_software_o, $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_s_software_o == 0 after writing 0 (no edge) %t ns", $time);
      end

      // Reserved-bits write: 0xFFFF_FFFE has bit[0]=0, so NO edge expected.
      ahb_write(1, MACHINE, 32'h0040C000, 32'hFFFFFFFE, 2, OK);
      repeat(3) @(posedge free_clk);
      #1;
      if (tb_ahb_aclint.dut.irq_s_software_o !== 1'b0) begin
         $display("ERROR: irq_s_software_o expected 0 after reserved-bits write -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_s_software_o, $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_s_software_o == 0 (reserved-bits write of 0xFFFF_FFFE) %t ns", $time);
      end

      // Reserved-bits write of 0xFFFF_FFFF: bit[0]=1, so DOES fire an edge.
      ahb_write(1, MACHINE, 32'h0040C000, 32'hFFFFFFFF, 2, OK);
      #1;
      if (tb_ahb_aclint.dut.irq_s_software_o !== 1'b1) begin
         $display("ERROR: irq_s_software_o expected 1 after write 0xFFFF_FFFF (bit[0]=1) -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_s_software_o, $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_s_software_o == 1 (edge from 0xFFFF_FFFF write) %t ns", $time);
      end
      @(posedge free_clk);
      #1;
      if (tb_ahb_aclint.dut.irq_s_software_o !== 1'b0) begin
         $display("ERROR: irq_s_software_o expected 0 after 1-cycle pulse -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_s_software_o, $time);
         error = error + 1;
      end

      // Out-of-window write: 0xC004 -- NUM_HARTS=1 so this hart_index is OOR.
      // Write 1 must NOT fire an edge.
      ahb_write(1, MACHINE, 32'h0040C004, 32'h00000001, 2, OK);
      repeat(3) @(posedge free_clk);
      #1;
      if (tb_ahb_aclint.dut.irq_s_software_o !== 1'b0) begin
         $display("ERROR: irq_s_software_o expected 0 after OOR write -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_s_software_o, $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_s_software_o == 0 (OOR write silently dropped) %t ns", $time);
      end

      // Out-of-window READ: spec is silent, our impl RAZs. Also covers a
      // separate part of the read mux.
      ahb_read(1, MACHINE, 32'h0040C004, 32'h00000000, 2, 1, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
