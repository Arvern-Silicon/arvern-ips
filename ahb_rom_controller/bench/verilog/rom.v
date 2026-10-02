//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    rom
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : rom.v
// Module Description : Scalable ROM model for testbench use.
//----------------------------------------------------------------------------

module rom (

// OUTPUTs
    rom_dout_o,                     // ROM data output

// INPUTs
    rom_addr_i,                     // ROM address
    rom_cen_i,                      // ROM chip enable (low active)
    rom_clk_i                       // ROM clock
);

// PARAMETERs
//============
parameter MEM_ADDRW   =  6;          // Width of the address bus
parameter MEM_SIZE    =  256;        // Memory size in bytes

// OUTPUTs
//============
output         [31:0] rom_dout_o;    // ROM data output

// INPUTs
//============
input [MEM_ADDRW-1:0] rom_addr_i;    // ROM address
input                 rom_cen_i;     // ROM chip enable (low active)
input                 rom_clk_i;     // ROM clock


// ROM MODEL
//============

reg            [31:0] mem [0:(MEM_SIZE/4)-1];
reg   [MEM_ADDRW-1:0] rom_addr_reg;
reg                   rom_rd_q;      // the last edge sampled a read command

initial
  begin
    rom_addr_reg = {MEM_ADDRW{1'b0}};
    rom_rd_q     = 1'b0;
  end

always @(posedge rom_clk_i)
  begin
    rom_rd_q <= ~rom_cen_i;
    if (~rom_cen_i)
      rom_addr_reg <= rom_addr_i;
  end

// Data is defined only in the cycle after a read command; any other cycle
// returns a poison word, so a controller that forwards rom_dout_o outside its
// read data phase is caught.
assign rom_dout_o = rom_rd_q ? mem[rom_addr_reg] : 32'hBAD0_BAD0;


endmodule // rom
