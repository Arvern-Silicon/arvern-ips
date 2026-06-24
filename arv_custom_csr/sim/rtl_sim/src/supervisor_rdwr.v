//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    supervisor_rdwr
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : supervisor_rdwr.v
// Module Description : Supervisor-Mode CCSR Read-Write test stimulus.
//                      Exercises Bank 5 (0x5C0-0x5C3) and includes a
//                      bank-isolation check that confirms writes to Sup
//                      Bank 5 do not corrupt User Bank 0 or Mac Bank 8.
//----------------------------------------------------------------------------

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      $display(" ===============================================");
      $display("|        SUPERVISOR-MODE CCSR READ-WRITES       |");
      $display(" ===============================================");

      // Reset value of Sup RW Bank 5 (regs 0..3 at 0x5C0..0x5C3) -> expect 0
      repeat(10) @(posedge free_clk);
      csr_read_write(12'h5C0, 32'h11111111, 32'h00000000, 1);
      csr_read_write(12'h5C1, 32'h22222222, 32'h00000000, 1);
      csr_read_write(12'h5C2, 32'h33333333, 32'h00000000, 1);
      csr_read_write(12'h5C3, 32'h44444444, 32'h00000000, 1);

      // Read back via the CSR interface
      repeat(5) @(posedge free_clk);
      csr_read(12'h5C0, 32'h11111111, 1);
      csr_read(12'h5C1, 32'h22222222, 1);
      csr_read(12'h5C2, 32'h33333333, 1);
      csr_read(12'h5C3, 32'h44444444, 1);

      // The captured output ports must show the same values as the CSR reads
      check_value(ccsr_sup_rw0, 32'h11111111);
      check_value(ccsr_sup_rw1, 32'h22222222);
      check_value(ccsr_sup_rw2, 32'h33333333);
      check_value(ccsr_sup_rw3, 32'h44444444);

      // Bank isolation: User Bank 0 and Mac Bank 8 must still hold the reset
      // value because nothing has written to them. This catches cross-talk
      // between the bank decoders.
      repeat(5) @(posedge free_clk);
      csr_read(12'h800, 32'h00000000, 1);
      csr_read(12'h801, 32'h00000000, 1);
      csr_read(12'h802, 32'h00000000, 1);
      csr_read(12'h803, 32'h00000000, 1);
      csr_read(12'h7C0, 32'h00000000, 1);
      csr_read(12'h7C1, 32'h00000000, 1);
      csr_read(12'h7C2, 32'h00000000, 1);
      csr_read(12'h7C3, 32'h00000000, 1);

      // Captured outputs of the untouched banks must also be 0
      check_value(ccsr_usr_rw0, 32'h00000000);
      check_value(ccsr_usr_rw1, 32'h00000000);
      check_value(ccsr_usr_rw2, 32'h00000000);
      check_value(ccsr_usr_rw3, 32'h00000000);
      check_value(ccsr_mac_rw0, 32'h00000000);
      check_value(ccsr_mac_rw1, 32'h00000000);
      check_value(ccsr_mac_rw2, 32'h00000000);
      check_value(ccsr_mac_rw3, 32'h00000000);

      // Overwrite Sup Bank 5 with new values and confirm both the read
      // and the captured output ports update.
      repeat(5) @(posedge free_clk);
      csr_read_write(12'h5C0, 32'hDEADBEEF, 32'h11111111, 1);
      csr_read_write(12'h5C1, 32'hBADC0FFE, 32'h22222222, 1);
      csr_read_write(12'h5C2, 32'hA5A5A5A5, 32'h33333333, 1);
      csr_read_write(12'h5C3, 32'h5A5A5A5A, 32'h44444444, 1);

      check_value(ccsr_sup_rw0, 32'hDEADBEEF);
      check_value(ccsr_sup_rw1, 32'hBADC0FFE);
      check_value(ccsr_sup_rw2, 32'hA5A5A5A5);
      check_value(ccsr_sup_rw3, 32'h5A5A5A5A);

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
