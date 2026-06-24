//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    submit
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : submit.f
// Module Description : Simulation submit file: generic interconnect testbench + RTL.
//----------------------------------------------------------------------------

+incdir+.
tb_ahb_interconnect.v
ahb_arbiter.v
ahb_decoder.v
rom.v
sram.v
ahb_waitstate_inserter.v
ahb_protocol_checker.v


//=============================================================================
// Other IPs used in the testbench
//=============================================================================

+incdir+../../../ahb_rom_controller/rtl/verilog/
-f ../../../ahb_rom_controller/rtl/verilog/filelist.f

+incdir+../../../ahb_sram_controller/rtl/verilog/
-f ../../../ahb_sram_controller/rtl/verilog/filelist.f

+incdir+../../../ahb_periph_example/rtl/verilog/
-f ../../../ahb_periph_example/rtl/verilog/filelist.f


//=============================================================================
// AHB Interconnect IP
//=============================================================================

+incdir+../../rtl/verilog/
-f ../../rtl/verilog/filelist.f
