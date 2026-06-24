//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Test:      priv_check_off
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// Description: PRIV_CHECK_EN=0 bypass. The same accesses that the
//              priv_check test verifies are denied (U-mode write to priority,
//              S-mode write to enable[M-ctx], etc.) must SUCCEED here -- the
//              IP-level filter is intentionally off (the integrator is relying
//              on a fabric-level check, or there is no privilege control).
//----------------------------------------------------------------------------

`define PLIC_BASE        32'h00400000
`define PRIORITY_BASE    32'h00000000
`define ENABLE_BASE      32'h00002000
`define ENABLE_STRIDE    32'h00000080
`define TARGET_BASE      32'h00200000
`define TARGET_STRIDE    32'h00001000

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      tb_ahb_plic.irq_src = {(NUM_SOURCES+1){1'b0}};

      $display(" ===============================================");
      $display("|  PRIV_CHECK_EN=0 -- all modes allowed    |");
      $display(" ===============================================");

      // U-mode write to priority is ALLOWED when the filter is off.
      ahb_write(1, USER, `PLIC_BASE + `PRIORITY_BASE + 32'h0004, 32'd5, 2, OK);
      ahb_read (1, USER, `PLIC_BASE + `PRIORITY_BASE + 32'h0004, 32'd5, 2, 1, OK);

      // S-mode write to enable[M-ctx] is ALLOWED when the filter is off.
      ahb_write(1, SUPERVISOR, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE,
                32'h0000_0002, 2, OK);
      ahb_read (1, SUPERVISOR, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE,
                32'h0000_0002, 2, 1, OK);

      // S-mode write to threshold[M-ctx] is ALLOWED when the filter is off.
      ahb_write(1, SUPERVISOR, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE,
                32'd0, 2, OK);
      ahb_read (1, SUPERVISOR, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE,
                32'd0, 2, 1, OK);

      // U-mode write to enable[any ctx] is ALLOWED when the filter is off.
      ahb_write(1, USER, `PLIC_BASE + `ENABLE_BASE + 32'h1*`ENABLE_STRIDE,
                32'h0000_0008, 2, OK);
      ahb_read (1, USER, `PLIC_BASE + `ENABLE_BASE + 32'h1*`ENABLE_STRIDE,
                32'h0000_0008, 2, 1, OK);

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
