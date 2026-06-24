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
// Module Description : RTL source file list for ahb_aclint.
//----------------------------------------------------------------------------

//=============================================================================
// Shared building blocks (arv_common)
//=============================================================================
-f ../../../arv_common/rtl/verilog/filelist.f

//=============================================================================
// Module specific modules
//=============================================================================
aclint_gray2bin.v
aclint_mtimer_count_lf.v
aclint_mtimer_gray_sync.v
aclint_mtimer_write_cdc.v
aclint_mtimer.v
aclint_mswi.v
aclint_sswi.v
ahb_aclint.v
