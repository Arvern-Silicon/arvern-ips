//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mem_strobes
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mem_strobes.v
// Module Description : Memory-strobe generator helper for the testbench.
//----------------------------------------------------------------------------

wire [31:0] rom_0  = rom_inst0.mem[0];   // 0x00400000
wire [31:0] rom_1  = rom_inst0.mem[1];   // 0x00400004
wire [31:0] rom_2  = rom_inst0.mem[2];   // 0x00400008
wire [31:0] rom_3  = rom_inst0.mem[3];   // 0x0040000C
wire [31:0] rom_4  = rom_inst0.mem[4];   // 0x00400010
wire [31:0] rom_5  = rom_inst0.mem[5];   // 0x00400014
wire [31:0] rom_6  = rom_inst0.mem[6];   // 0x00400018
wire [31:0] rom_7  = rom_inst0.mem[7];   // 0x0040001C
wire [31:0] rom_8  = rom_inst0.mem[8];   // 0x00400020
wire [31:0] rom_9  = rom_inst0.mem[9];   // 0x00400024
wire [31:0] rom_A  = rom_inst0.mem[10];  // 0x00400028
wire [31:0] rom_B  = rom_inst0.mem[11];  // 0x0040002C
wire [31:0] rom_C  = rom_inst0.mem[12];  // 0x00400030
wire [31:0] rom_D  = rom_inst0.mem[13];  // 0x00400034
wire [31:0] rom_E  = rom_inst0.mem[14];  // 0x00400038
wire [31:0] rom_F  = rom_inst0.mem[15];  // 0x0040003C

wire [31:0] sram_0 = sram_inst0.mem[0];  // 0x00401000
wire [31:0] sram_1 = sram_inst0.mem[1];  // 0x00401004
wire [31:0] sram_2 = sram_inst0.mem[2];  // 0x00401008
wire [31:0] sram_3 = sram_inst0.mem[3];  // 0x0040100C
wire [31:0] sram_4 = sram_inst0.mem[4];  // 0x00401010
wire [31:0] sram_5 = sram_inst0.mem[5];  // 0x00401014
wire [31:0] sram_6 = sram_inst0.mem[6];  // 0x00401018
wire [31:0] sram_7 = sram_inst0.mem[7];  // 0x0040101C
wire [31:0] sram_8 = sram_inst0.mem[8];  // 0x00401020
wire [31:0] sram_9 = sram_inst0.mem[9];  // 0x00401024
wire [31:0] sram_A = sram_inst0.mem[10]; // 0x00401028
wire [31:0] sram_B = sram_inst0.mem[11]; // 0x0040102C
wire [31:0] sram_C = sram_inst0.mem[12]; // 0x00401030
wire [31:0] sram_D = sram_inst0.mem[13]; // 0x00401034
wire [31:0] sram_E = sram_inst0.mem[14]; // 0x00401038
wire [31:0] sram_F = sram_inst0.mem[15]; // 0x0040103C
