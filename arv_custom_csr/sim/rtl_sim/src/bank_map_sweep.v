//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    bank_map_sweep
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bank_map_sweep.v
// Module Description : Every offset of every bank, at any configuration: a write
//                      with a value unique to (bank, offset), then a read of every
//                      offset. RO inputs carry values unique to (group, index). The
//                      bench's reference model checks each cycle: the register an
//                      address lands on (index -> bank/offset mapping), RAZ/WI above
//                      NR_*, writes to RO banks ignored, hclk_en_o, the RW ports.
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
integer ii;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(5) @(posedge free_clk);

      for (ii = 0; ii < 64; ii = ii + 1) begin
         usr_ro_pad[32*ii+:32] = {16'hA0A0, 8'h04, ii[7:0]};
         sup_ro_pad[32*ii+:32] = {16'hA0A0, 8'h07, ii[7:0]};
         mac_ro_pad[32*ii+:32] = {16'hA0A0, 8'h0A, ii[7:0]};
      end

      for (bb = 0; bb < 11; bb = bb + 1)
         for (oo = 0; oo < 64; oo = oo + 1)
            csr_read_write(bank_base(bb) + oo, {8'h5A, bb[7:0], 8'hC3, oo[7:0]}, 32'h0, 0);

      for (bb = 0; bb < 11; bb = bb + 1)
         for (oo = 0; oo < 64; oo = oo + 1)
            csr_read(bank_base(bb) + oo, 32'h0, 0);

      if (mon_wr_cnt != (NR_USR_RW + NR_SUP_RW + NR_MAC_RW)) begin
         $display("ERROR: %0d RW registers written, expected %0d", mon_wr_cnt, NR_USR_RW + NR_SUP_RW + NR_MAC_RW);
         error = error + 1;
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
