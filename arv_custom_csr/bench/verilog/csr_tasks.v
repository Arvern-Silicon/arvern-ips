//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    csr_tasks
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : csr_tasks.v
// Module Description : Generic tasks performing CSR read/write transfers.
//----------------------------------------------------------------------------

//============================================================================
// Address -> bank one-hot decode
//============================================================================

function [10:0] csr_addr_to_bank;
   input [11:0] addr;
   begin
      csr_addr_to_bank = (addr[11:8]==4'h8)  ? ((addr[7:6]==0) ? 11'h001 :       // Bank  0 - User-Mode      : Read-Write --> 0x800-0x83F
                                                (addr[7:6]==1) ? 11'h002 :       // Bank  1 - User-Mode      : Read-Write --> 0x840-0x87F
                                                (addr[7:6]==2) ? 11'h004 :       // Bank  2 - User-Mode      : Read-Write --> 0x880-0x8BF
                                                                 11'h008 ) :     // Bank  3 - User-Mode      : Read-Write --> 0x8C0-0x8FF
                         (addr[11:6]==6'h33) ?                   11'h010   :     // Bank  4 - User-Mode      : Read-Only  --> 0xCC0-0xCFF
                         (addr[11:6]==6'h17) ?                   11'h020   :     // Bank  5 - Supervisor-Mode: Read-Write --> 0x5C0-0x5FF
                         (addr[11:6]==6'h27) ?                   11'h040   :     // Bank  6 - Supervisor-Mode: Read-Write --> 0x9C0-0x9FF
                         (addr[11:6]==6'h37) ?                   11'h080   :     // Bank  7 - Supervisor-Mode: Read-Only  --> 0xDC0-0xDFF
                         (addr[11:6]==6'h1F) ?                   11'h100   :     // Bank  8 - Machine-Mode   : Read-Write --> 0x7C0-0x7FF
                         (addr[11:6]==6'h2F) ?                   11'h200   :     // Bank  9 - Machine-Mode   : Read-Write --> 0xBC0-0xBFF
                         (addr[11:6]==6'h3F) ?                   11'h400   :     // Bank 10 - Machine-Mode   : Read-Only  --> 0xFC0-0xFFF
                                                                 11'h000   ;
   end
endfunction


//============================================================================
// Simple Read-Write access
//============================================================================

task csr_read_write;
   input  [11:0] addr;           // CSR register address
   input  [31:0] wdata;          // Write Data
   input  [31:0] expected_rdata; // Read Data
   input         check;          // Enable/disable read value check

   begin
      #1;
      ccsr_bank     = csr_addr_to_bank(addr);
      ccsr_reg_sel  = (64'h0000000000000001 << addr[5:0]);
      ccsr_wdata    = wdata;
      ccsr_wen      =  1'b1;

      @(posedge free_clk);
      if (check)
         begin
            if (ccsr_rdata !== expected_rdata)
               begin
                  $display("ERROR: CCSR read check -- address: 0x%h -- read: 0x%h / expected: 0x%h -- %t ns", addr, ccsr_rdata, expected_rdata, $time);
                  error = error+1;
               end
            else
               begin
                  $display("PASS:  CCSR read check -- address: 0x%h -- value: 0x%h -- %t ns", addr, ccsr_rdata, $time);
               end
         end

      #1;
      ccsr_bank     = 11'h000;
      ccsr_reg_sel  = 64'h0000000000000000;
      ccsr_wdata    = 32'h00000000;
      ccsr_wen      =  1'b0;

   end
endtask

//============================================================================
// Simple Read access
//============================================================================

task csr_read;
   input  [11:0] addr;           // CSR register address
   input  [31:0] expected_rdata; // Read Data
   input         check;          // Enable/disable read value check

   begin
      #1;
      ccsr_bank     = csr_addr_to_bank(addr);
      ccsr_reg_sel  = (64'h0000000000000001 << addr[5:0]);
      ccsr_wen      =  1'b0;

      @(posedge free_clk);
      if (check)
         begin
            if (ccsr_rdata !== expected_rdata)
               begin
                  $display("ERROR: CCSR read check -- address: 0x%h -- read: 0x%h / expected: 0x%h -- %t ns", addr, ccsr_rdata, expected_rdata, $time);
                  error = error+1;
               end
            else
               begin
                  $display("PASS:  CCSR read check -- address: 0x%h -- value: 0x%h -- %t ns", addr, ccsr_rdata, $time);
               end
         end

      #1;
      ccsr_bank     = 11'h000;
      ccsr_reg_sel  = 64'h0000000000000000;
      ccsr_wdata    = 32'h00000000;
      ccsr_wen      =  1'b0;

   end
endtask

//============================================================================
// Drive a valid bank/reg_sel with non-zero wdata but wen=0.
// Used to verify that wen=0 does NOT cause a write (the sentinel wdata
// must NOT end up in the register).
//============================================================================

task csr_no_write_attempt;
   input  [11:0] addr;           // CSR register address
   input  [31:0] wdata;          // Sentinel write data (must be ignored by the DUT)

   begin
      #1;
      ccsr_bank     = csr_addr_to_bank(addr);
      ccsr_reg_sel  = (64'h0000000000000001 << addr[5:0]);
      ccsr_wdata    = wdata;
      ccsr_wen      =  1'b0;

      @(posedge free_clk);

      #1;
      ccsr_bank     = 11'h000;
      ccsr_reg_sel  = 64'h0000000000000000;
      ccsr_wdata    = 32'h00000000;
      ccsr_wen      =  1'b0;
   end
endtask
