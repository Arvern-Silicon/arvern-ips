//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    sram
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : sram.v
// Module Description : Scalable SRAM model for testbench use.
//----------------------------------------------------------------------------

module sram (

// OUTPUTs
    sram_dout_o,                     // SRAM data output

// INPUTs
    sram_addr_i,                     // SRAM address
    sram_cen_i,                      // SRAM chip enable (low active)
    sram_clk_i,                      // SRAM clock
    sram_din_i,                      // SRAM data input
    sram_wen_i                       // SRAM write enable (low active)
);

// PARAMETERs
//============
parameter MEM_ADDRW   =  6;          // Width of the address bus
parameter MEM_SIZE    =  256;        // Memory size in bytes

// OUTPUTs
//============
output         [31:0] sram_dout_o;   // SRAM data output

// INPUTs
//============
input [MEM_ADDRW-1:0] sram_addr_i;   // SRAM address
input                 sram_cen_i;    // SRAM chip enable (low active)
input                 sram_clk_i;    // SRAM clock
input          [31:0] sram_din_i;    // SRAM data input
input           [3:0] sram_wen_i;    // SRAM write enable (low active)


// SRAM MODEL
//============

reg            [31:0] mem [0:(MEM_SIZE/4)-1];
reg   [MEM_ADDRW-1:0] sram_addr_reg;

wire           [31:0] mem_val = mem[sram_addr_i];
   
initial
  begin
    sram_addr_reg = {MEM_ADDRW{1'b0}};
  end

always @(posedge sram_clk_i)
  if (~sram_cen_i & sram_addr_i<(MEM_SIZE/4))
    begin
      if      (sram_wen_i==4'b0000) mem[sram_addr_i] <= {sram_din_i[31:24], sram_din_i[23:16], sram_din_i[15:8], sram_din_i[7:0]};

      else if (sram_wen_i==4'b1100) mem[sram_addr_i] <= {mem_val[31:24],    mem_val[23:16],    sram_din_i[15:8], sram_din_i[7:0]};
      else if (sram_wen_i==4'b0011) mem[sram_addr_i] <= {sram_din_i[31:24], sram_din_i[23:16], mem_val[15:8],    mem_val[7:0]   };

      else if (sram_wen_i==4'b1110) mem[sram_addr_i] <= {mem_val[31:24],    mem_val[23:16],    mem_val[15:8],    sram_din_i[7:0]};
      else if (sram_wen_i==4'b1101) mem[sram_addr_i] <= {mem_val[31:24],    mem_val[23:16],    sram_din_i[15:8], mem_val[7:0]   };
      else if (sram_wen_i==4'b1011) mem[sram_addr_i] <= {mem_val[31:24],    sram_din_i[23:16], mem_val[15:8],    mem_val[7:0]   };
      else if (sram_wen_i==4'b0111) mem[sram_addr_i] <= {sram_din_i[31:24], mem_val[23:16],    mem_val[15:8],    mem_val[7:0]   };

      sram_addr_reg <= sram_addr_i;
    end

assign sram_dout_o = mem[sram_addr_reg];


endmodule // sram
