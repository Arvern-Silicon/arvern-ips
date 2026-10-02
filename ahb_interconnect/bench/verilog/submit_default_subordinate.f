//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    submit_default_subordinate
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : submit_default_subordinate.f
// Module Description : Simulation submit file: ahb_default_subordinate unit testbench.
//----------------------------------------------------------------------------

+incdir+.
tb_ahb_default_subordinate.v

//=============================================================================
// Shared common library (arv_ipdff, ...)
//=============================================================================
-f ../../../arv_primitives/rtl/verilog/filelist.f

//=============================================================================
// DUT
//=============================================================================
+incdir+../../rtl/verilog/
../../rtl/verilog/ahb_default_subordinate.v
