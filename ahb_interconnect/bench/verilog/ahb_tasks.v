//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_tasks
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_tasks.v
// Module Description : Generic AHB read/write tasks used by all testbenches.
//----------------------------------------------------------------------------

task automatic ahb_write;
   input  [31:0] master;   // Select master 0, 1 or 2
   input         blocking; // Block until end of data-phase if 1, else release at the end of address-phase
   input  [31:0] addr;     // Address
   input  [31:0] data;     // Data
   input   [1:0] size;     // Access size (0: 8-bit / 1: 16-bit / 2: 32-bit)

   begin
      case (master)
         2      : m2_ahb_write(blocking, addr, data, size);
         1      : m1_ahb_write(blocking, addr, data, size);
         default: m0_ahb_write(blocking, addr, data, size);
      endcase
   end
endtask


//============================================================================
// Simple Read access
//============================================================================

task automatic ahb_read;
   input  [31:0] master;         // Select master 0, 1 or 2
   input         blocking;       // Block until end of data-phase if 1, else release at the end of address-phase
   input  [31:0] addr;           // Address
   input  [31:0] expected_data;  // Data
   input   [1:0] size;           // Access size (0: 8-bit / 1: 16-bit / 2: 32-bit)
   input         check;          // Enable/disable read value check

   begin
      case (master)
         2      : m2_ahb_read(blocking, addr, expected_data, size, check);
         1      : m1_ahb_read(blocking, addr, expected_data, size, check);
         default: m0_ahb_read(blocking, addr, expected_data, size, check);
      endcase
   end
endtask
