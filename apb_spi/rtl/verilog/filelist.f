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
// Module Description : RTL source file list for apb_spi.
//----------------------------------------------------------------------------

//=============================================================================
// Shared common library (arv_ipdff reset primitive, synchronizers, etc.)
//=============================================================================
-f ../../../arv_primitives/rtl/verilog/filelist.f

//=============================================================================
// Module specific modules
//=============================================================================
apb_spi_fifo.v
apb_spi_core.v
apb_spi.v
