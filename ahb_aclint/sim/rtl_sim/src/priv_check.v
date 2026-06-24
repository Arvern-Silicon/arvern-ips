//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    priv_check
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : priv_check.v
// Module Description : Verify the per-window privilege filter (PRIV_CHECK_EN=1).
//                      Policy (per ACLINT 1.0-rc4 Table 1):
//                        - MSWI   (Machine)    : M-mode only
//                        - MTIMER (Machine)    : M-mode only
//                        - SSWI   (Supervisor) : M-mode AND S-mode
//                        - U-mode               : always denied
//                      Checks:
//                        - M-mode access to MSWI / MTIMER / SSWI succeeds.
//                        - S-mode access to MSWI / MTIMER returns AHB ERROR.
//                        - S-mode access to SSWI succeeds (spec-compliant).
//                        - U-mode access to all three sub-windows returns
//                          AHB ERROR.
//                        - Unmapped addresses RAZ/WI even from S/U mode
//                          (the error FSM gates on the per-window decode, so
//                          an unmapped access never errors).
//                        - A denied S-mode write to MSIP[0] does NOT change
//                          the register: after the denied write, a final
//                          M-mode read of MSIP[0] still returns 0.
//                        - An allowed S-mode write of bit[0]=1 to SSWI
//                          SETSSIP[0] fires the 1-cycle edge on
//                          irq_s_software_o[0] (functional cross-check that
//                          the gating doesn't accidentally drop the access).
//                      Requires SU_MODE_EN=1 (default config).
//----------------------------------------------------------------------------

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|       PRIV_CHECK_EN=1 : M-mode allowed        |");
      $display(" ===============================================");

      // M-mode RW to one register in each of the three sub-windows; all OK.
      ahb_write(1, MACHINE, 32'h00400000, 32'h00000000, 2, OK);     // MSIP[0]   = 0
      ahb_read (1, MACHINE, 32'h00400000, 32'h00000000, 2, 1, OK);
      ahb_write(1, MACHINE, 32'h00404000, 32'hFFFFFFFF, 2, OK);     // MTIMECMP_LO[0]
      ahb_read (1, MACHINE, 32'h00404000, 32'hFFFFFFFF, 2, 1, OK);
      ahb_read (1, MACHINE, 32'h0040C000, 32'h00000000, 2, 1, OK);  // SSWI SETSSIP[0] reads RAZ


      $display(" ===============================================");
      $display("|  PRIV_CHECK_EN=1 : S-mode -> MSWI/MTIMER ERR  |");
      $display(" ===============================================");

      // S-mode to MSWI / MTIMER : ERROR (Machine-privilege windows).
      ahb_read (1, SUPERVISOR, 32'h00400000, 32'h00000000, 2, 1, ERROR);
      ahb_write(1, SUPERVISOR, 32'h00400000, 32'h12345678, 2, ERROR);
      ahb_read (1, SUPERVISOR, 32'h00404000, 32'h00000000, 2, 1, ERROR);
      ahb_write(1, SUPERVISOR, 32'h00404000, 32'h00000001, 2, ERROR);


      $display(" ===============================================");
      $display("|     PRIV_CHECK_EN=1 : S-mode -> SSWI  OK      |");
      $display(" ===============================================");

      // S-mode to SSWI : ALLOWED (Supervisor-privilege window per spec). Reads
      // of SETSSIP return 0 (LSB always reads 0 / reserved upper bits = 0);
      // writes are accepted (functional check of the write below).
      ahb_read (1, SUPERVISOR, 32'h0040C000, 32'h00000000, 2, 1, OK);
      ahb_write(1, SUPERVISOR, 32'h0040C000, 32'h00000000, 2, OK);  // write of 0 -> no edge


      $display(" ===============================================");
      $display("|       PRIV_CHECK_EN=1 : U-mode -> ERROR       |");
      $display(" ===============================================");

      // U-mode RW: ERROR on every sub-window (no ACLINT device is U-accessible).
      ahb_read (1, USER, 32'h00400000, 32'h00000000, 2, 1, ERROR);
      ahb_write(1, USER, 32'h00404000, 32'h00000001, 2, ERROR);
      ahb_read (1, USER, 32'h0040C000, 32'h00000000, 2, 1, ERROR);
      ahb_write(1, USER, 32'h0040C000, 32'h00000001, 2, ERROR);


      $display(" ===============================================");
      $display("|   PRIV_CHECK_EN=1 : S-mode SETSSIP edge fires |");
      $display(" ===============================================");

      // S-mode write of bit[0]=1 to SSWI SETSSIP[0] must reach the device
      // and produce a 1-cycle edge on irq_s_software_o[0]. Sample at #1
      // after the registered AHB write returns -- the edge is registered
      // into ssoftware_pulse_r on the same edge.
      ahb_write(1, SUPERVISOR, 32'h0040C000, 32'h00000001, 2, OK);
      #1;
      if (tb_ahb_aclint.dut.irq_s_software_o[0] !== 1'b1) begin
         $display("ERROR: irq_s_software_o[0] expected 1 after S-mode SETSSIP[0]=1 -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_s_software_o[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_s_software_o[0] == 1 on S-mode SETSSIP[0]=1 %t ns", $time);
      end
      @(posedge free_clk);
      #1;
      if (tb_ahb_aclint.dut.irq_s_software_o[0] !== 1'b0) begin
         $display("ERROR: irq_s_software_o[0] expected 0 after pulse drop -- got %b %t ns",
                  tb_ahb_aclint.dut.irq_s_software_o[0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  irq_s_software_o[0] dropped after 1-cycle pulse %t ns", $time);
      end


      $display(" ===============================================");
      $display("|       Unmapped addresses : RAZ/WI from any    |");
      $display(" ===============================================");

      // Unmapped addresses (between the four windows) must still RAZ/WI
      // even from a denied privilege mode -- the error FSM gates on the raw
      // sub-window decode, so an access that doesn't decode never errors.
      ahb_read (1, SUPERVISOR, 32'h00408000, 32'h00000000, 2, 1, OK);
      ahb_write(1, SUPERVISOR, 32'h00408000, 32'hFFFFFFFF, 2, OK);
      ahb_read (1, USER,       32'h0040E000, 32'h00000000, 2, 1, OK);
      ahb_write(1, USER,       32'h0040E000, 32'hFFFFFFFF, 2, OK);


      $display(" ===============================================");
      $display("|       Denied writes did NOT commit state      |");
      $display(" ===============================================");

      // The denied S-mode write tried to put 0x12345678 into MSIP[0]. The
      // legit M-mode read must still see 0 (we set it to 0 in phase 1 and
      // no allowed write has touched it since).
      ahb_read (1, MACHINE, 32'h00400000, 32'h00000000, 2, 1, OK);

      // Likewise MTIMECMP_LO[0] should still hold the legit M-mode write
      // value (0xFFFFFFFF) -- the denied S/U writes of 1 must not have
      // overwritten it.
      ahb_read (1, MACHINE, 32'h00404000, 32'hFFFFFFFF, 2, 1, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
