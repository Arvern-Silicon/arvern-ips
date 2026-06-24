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
// Module Description : Simulation submit file (testbench + ROM model + RTL).
//----------------------------------------------------------------------------

//=============================================================================
// Testbench related
//=============================================================================

+incdir+.
tb_ahb_rom_controller.v
rom.v

//=============================================================================
// ROM Controller IP
//=============================================================================

+incdir+../../rtl/verilog/
-f ../../rtl/verilog/filelist.f

