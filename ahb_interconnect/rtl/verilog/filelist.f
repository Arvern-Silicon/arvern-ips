//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    filelist
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : filelist.f
// Module Description : RTL source file list for ahb_interconnect.
//----------------------------------------------------------------------------

//=============================================================================
// Shared common library (arv_ipdff, arv_synchronizer, ...)
//=============================================================================
-f ../../../arv_common/rtl/verilog/filelist.f

//=============================================================================
// Module specific modules
//=============================================================================
ahb_default_subordinate.v
ahb_subordinate_mux.v
ahb_manager_if.v
ahb_manager_mux.v
ahb_arbiter_2m.v
ahb_fused_rom_ctrl.v
ahb_fused_sram_ctrl.v
ahb_interconnect_generic.v
ahb_interconnect_hiperf.v
ahb_interconnect_fused.v
