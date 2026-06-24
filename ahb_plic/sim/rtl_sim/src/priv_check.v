//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Test:      priv_check
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// Description: PRIV_CHECK_EN=1 access policy. Requires SU_MODE_EN=1.
//
//   Policy (per the IP doc + integration_guide):
//     U-mode             : DENY everything.
//     M-mode             : ALLOW everything.
//     S-mode             : ALLOW priority / pending
//                          ALLOW enable[S-ctx] / target[S-ctx]
//                          DENY  enable[M-ctx] / target[M-ctx]
//
//   Verification approach: write a known M-pattern as M-mode (which must
//   succeed with hresp=OK), try to access from S/U (which must return
//   hresp=ERROR per AHB-Lite 2-cycle pattern and leave state untouched),
//   read back as M-mode and verify the M-pattern is intact. M-mode reads
//   that follow a denied access also confirm the denied write had no
//   side effect.
//----------------------------------------------------------------------------

`define PLIC_BASE        32'h00400000
`define PRIORITY_BASE    32'h00000000
`define PENDING_BASE     32'h00001000
`define ENABLE_BASE      32'h00002000
`define ENABLE_STRIDE    32'h00000080
`define TARGET_BASE      32'h00200000
`define TARGET_STRIDE    32'h00001000

integer ii;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      tb_ahb_plic.irq_src = {(NUM_SOURCES+1){1'b0}};

      $display(" ===============================================");
      $display("|  M-MODE: PROGRAM KNOWN PATTERN (BASELINE)     |");
      $display(" ===============================================");

      // Priority for source 1 = 5
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIORITY_BASE + 32'h0004, 32'd5, 2, OK);
      ahb_read (1, MACHINE, `PLIC_BASE + `PRIORITY_BASE + 32'h0004, 32'd5, 2, 1, OK);

      // Enable[ctx 0 = M-ctx] word 0 = 0x0000_0002 (src 1 enabled)
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE,
                32'h0000_0002, 2, OK);
      ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE,
                32'h0000_0002, 2, 1, OK);

      // Enable[ctx 1 = S-ctx] word 0 = 0x0000_0004 (src 2 enabled)
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h1*`ENABLE_STRIDE,
                32'h0000_0004, 2, OK);
      ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h1*`ENABLE_STRIDE,
                32'h0000_0004, 2, 1, OK);

      // Threshold[ctx 0 = M-ctx] = 0
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE,
                32'd0, 2, OK);
      ahb_read (1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE,
                32'd0, 2, 1, OK);

      // Threshold[ctx 1 = S-ctx] = 1
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h1*`TARGET_STRIDE,
                32'd1, 2, OK);
      ahb_read (1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h1*`TARGET_STRIDE,
                32'd1, 2, 1, OK);

      $display(" ===============================================");
      $display("|  S-MODE: PRIORITY + PENDING ALLOWED           |");
      $display(" ===============================================");

      // Priority read as S-mode: ALLOWED, must return the M-programmed value
      ahb_read (1, SUPERVISOR, `PLIC_BASE + `PRIORITY_BASE + 32'h0004,
                32'd5, 2, 1, OK);

      // Priority write as S-mode: ALLOWED (priority is global config). Drive
      // a different value and confirm the write took effect, then put back to 5
      // so subsequent phases stay deterministic.
      ahb_write(1, SUPERVISOR, `PLIC_BASE + `PRIORITY_BASE + 32'h0004,
                32'd6, 2, OK);
      ahb_read (1, MACHINE,    `PLIC_BASE + `PRIORITY_BASE + 32'h0004,
                32'd6, 2, 1, OK);
      ahb_write(1, MACHINE,    `PLIC_BASE + `PRIORITY_BASE + 32'h0004,
                32'd5, 2, OK);

      // Pending read as S-mode: ALLOWED. No source asserted so word 0 = 0.
      ahb_read (1, SUPERVISOR, `PLIC_BASE + `PENDING_BASE,
                32'h0000_0000, 2, 1, OK);

      $display(" ===============================================");
      $display("|  S-MODE: enable[M-ctx] / target[M-ctx] DENIED |");
      $display(" ===============================================");

      // enable[ctx 0 = M-ctx]: S-mode write -> ERROR response, no side effect
      ahb_write(1, SUPERVISOR, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE,
                32'hDEAD_DEAD, 2, ERROR);
      // S-mode read of enable[M-ctx] -> ERROR, data RAZ (don't check)
      ahb_read (1, SUPERVISOR, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE,
                32'h0000_0000, 2, 0, ERROR);
      // M-mode read confirms the M-pattern survived
      ahb_read (1, MACHINE,    `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE,
                32'h0000_0002, 2, 1, OK);

      // threshold[ctx 0 = M-ctx]: S-mode write -> ERROR
      ahb_write(1, SUPERVISOR, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE,
                32'd7, 2, ERROR);
      ahb_read (1, MACHINE,    `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE,
                32'd0, 2, 1, OK);                                                 // still 0

      $display(" ===============================================");
      $display("|  S-MODE: enable[S-ctx] / target[S-ctx] ALLOWED|");
      $display(" ===============================================");

      // enable[ctx 1 = S-ctx]: S-mode write allowed
      ahb_write(1, SUPERVISOR, `PLIC_BASE + `ENABLE_BASE + 32'h1*`ENABLE_STRIDE,
                32'h0000_0008, 2, OK);
      ahb_read (1, SUPERVISOR, `PLIC_BASE + `ENABLE_BASE + 32'h1*`ENABLE_STRIDE,
                32'h0000_0008, 2, 1, OK);

      // threshold[ctx 1 = S-ctx]: S-mode write allowed
      ahb_write(1, SUPERVISOR, `PLIC_BASE + `TARGET_BASE + 32'h1*`TARGET_STRIDE,
                32'd3, 2, OK);
      ahb_read (1, SUPERVISOR, `PLIC_BASE + `TARGET_BASE + 32'h1*`TARGET_STRIDE,
                32'd3, 2, 1, OK);

      $display(" ===============================================");
      $display("|  U-MODE: EVERYTHING DENIED                    |");
      $display(" ===============================================");

      // Priority read as U: denied -> ERROR (data don't check)
      ahb_read (1, USER, `PLIC_BASE + `PRIORITY_BASE + 32'h0004,
                32'h0000_0000, 2, 0, ERROR);
      // Priority write as U: denied -> ERROR
      ahb_write(1, USER, `PLIC_BASE + `PRIORITY_BASE + 32'h0004,
                32'd255, 2, ERROR);
      // M-mode read confirms it's still 5
      ahb_read (1, MACHINE, `PLIC_BASE + `PRIORITY_BASE + 32'h0004,
                32'd5, 2, 1, OK);

      // Pending read as U: denied -> ERROR (pending is normally
      // readable by S, but U is the universal deny rule)
      ahb_read (1, USER, `PLIC_BASE + `PENDING_BASE,
                32'h0000_0000, 2, 0, ERROR);

      // enable[ctx 0] write/read as U: denied -> ERROR. M-pattern survives.
      ahb_write(1, USER, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE,
                32'hCAFE_F00D, 2, ERROR);
      ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0*`ENABLE_STRIDE,
                32'h0000_0002, 2, 1, OK);

      // target[ctx 0] write as U: denied -> ERROR. M-pattern (threshold=0) survives.
      ahb_write(1, USER, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE,
                32'd7, 2, ERROR);
      ahb_read (1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0*`TARGET_STRIDE,
                32'd0, 2, 1, OK);

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
