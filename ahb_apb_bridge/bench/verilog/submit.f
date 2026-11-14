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
// Module Description : Simulation submit file (testbench + RTL sources).
//----------------------------------------------------------------------------

//=============================================================================
// Testbench related
//=============================================================================

+incdir+.
apb_completer_model.v
tb_ahb_apb_bridge.v

//=============================================================================
// AHB to APB bridge IP
//=============================================================================

+incdir+../../rtl/verilog/
-f ../../rtl/verilog/filelist.f
