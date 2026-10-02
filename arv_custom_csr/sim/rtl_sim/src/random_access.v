//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    random_access
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : random_access.v
// Module Description : Random traffic at any configuration: back-to-back and idle
//                      cycles, any bank and offset, reads, writes and write-enable
//                      without a selection, with the RO inputs changing under the
//                      reads. Every cycle is checked by the bench's reference model;
//                      every register is read back at the end.
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

integer nn;
integer bb;
integer oo;
integer ii;
integer rr;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(5) @(posedge free_clk);

      for (nn = 0; nn < 4000; nn = nn + 1) begin
         #1;
         rr = $urandom(tmp_seed) % 16;
         tmp_seed = tmp_seed + 1;
         bb = $urandom % 11;
         oo = $urandom % 64;
         if (rr < 2) begin                       // idle, write enable with nothing selected
            ccsr_bank    = 11'h000;
            ccsr_reg_sel = 64'h0;
            ccsr_wen     = $urandom % 2;
            ccsr_wdata   = $urandom;
         end else begin
            ccsr_bank    = 11'h001 << bb;
            ccsr_reg_sel = 64'h1 << oo;
            ccsr_wen     = (rr < 10);
            ccsr_wdata   = $urandom;
         end
         if (rr == 15) begin                     // RO inputs change
            ii = $urandom % 64;
            usr_ro_pad[32*ii+:32] = $urandom;
            sup_ro_pad[32*ii+:32] = $urandom;
            mac_ro_pad[32*ii+:32] = $urandom;
         end
         @(posedge free_clk);
      end
      #1;
      ccsr_bank = 11'h000; ccsr_reg_sel = 64'h0; ccsr_wen = 1'b0; ccsr_wdata = 32'h0;

      for (bb = 0; bb < 11; bb = bb + 1)
         for (oo = 0; oo < 64; oo = oo + 1)
            csr_read(bank_base(bb) + oo, 32'h0, 0);

      if (mon_wr_cnt == 0 && (NR_USR_RW + NR_SUP_RW + NR_MAC_RW) != 0) begin
         $display("ERROR: no RW register was written");
         error = error + 1;
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
