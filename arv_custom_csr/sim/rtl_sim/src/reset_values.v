//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    reset_values
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : reset_values.v
// Module Description : Reset of the RW registers, in either reset style: every
//                      implemented RW register written non-zero, then reset asserted
//                      while a write is on the interface. The asynchronous build
//                      clears the ports before the next clock edge; both builds hold
//                      zero through reset, drop the in-flight write, and read zero
//                      afterwards (the bench's reference model checks every cycle).
//----------------------------------------------------------------------------

// Bank base addresses, in bank order (ccsr_bank_i bit 0..10).
function [11:0] bank_base;
   input integer b;
   begin
      case (b)
         0: bank_base = 12'h800;   1: bank_base = 12'h840;   2: bank_base = 12'h880;
         3: bank_base = 12'h8C0;   4: bank_base = 12'hCC0;   5: bank_base = 12'h5C0;
         6: bank_base = 12'h9C0;   7: bank_base = 12'hDC0;   8: bank_base = 12'h7C0;
         9: bank_base = 12'hBC0;   default: bank_base = 12'hFC0;
      endcase
   end
endfunction

integer bb;
integer oo;
integer nz;
integer ii;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(5) @(posedge free_clk);

      for (bb = 0; bb < 11; bb = bb + 1)
         for (oo = 0; oo < 64; oo = oo + 1)
            csr_read_write(bank_base(bb) + oo, 32'hFFFF0000 | (bb << 8) | oo, 32'h0, 0);

      // Reset while a write is presented.
      #1;
      ccsr_bank    = 11'h001;
      ccsr_reg_sel = 64'h1;
      ccsr_wdata   = 32'h12345678;
      ccsr_wen     = 1'b1;
      #10;
      hresetn = 1'b0;
      if (ASYNC_RST_EN) begin
         #1;
         nz = (|usr_rw_pad) | (|sup_rw_pad) | (|mac_rw_pad);
         if (nz) begin
            $display("ERROR: asynchronous reset did not clear the RW ports before the next edge %t ns", $time);
            error = error + 1;
         end
      end
      @(posedge free_clk); #1;
      ccsr_bank = 11'h000; ccsr_reg_sel = 64'h0; ccsr_wen = 1'b0; ccsr_wdata = 32'h0;
      repeat(3) @(posedge free_clk); #1;
      nz = (|usr_rw_pad) | (|sup_rw_pad) | (|mac_rw_pad);
      if (nz) begin
         $display("ERROR: RW ports not zero during reset %t ns", $time);
         error = error + 1;
      end
      hresetn = 1'b1;
      repeat(2) @(posedge free_clk);

      for (bb = 0; bb < 11; bb = bb + 1)
         for (oo = 0; oo < 64; oo = oo + 1)
            csr_read(bank_base(bb) + oo, 32'h0, 0);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
