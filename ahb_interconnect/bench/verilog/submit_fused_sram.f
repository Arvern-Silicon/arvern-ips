//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    submit_fused_sram
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : submit_fused_sram.f
// Module Description : Simulation submit file: fused SRAM controller testbench + RTL.
//----------------------------------------------------------------------------

+incdir+.
tb_ahb_fused_sram_ctrl.v
sram.v

//=============================================================================
// Shared common library (arv_ipdff, arv_synchronizer, ...)
//=============================================================================
-f ../../../arv_common/rtl/verilog/filelist.f

//=============================================================================
// DUT
//=============================================================================

+incdir+../../rtl/verilog/
../../rtl/verilog/ahb_fused_sram_ctrl.v
