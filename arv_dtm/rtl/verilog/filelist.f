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
// Module Description : RTL source file list for arv_dtm (all transports).
//----------------------------------------------------------------------------

//=============================================================================
// Shared building blocks (arv_primitives)
//=============================================================================
-f ../../../arv_primitives/rtl/verilog/filelist.f

//=============================================================================
// Module specific modules
//=============================================================================

// Shared backend + DMI command interpreter
arv_dtm_dmi_master.v
arv_dtm_rxfifo.v
arv_dtm_cmd.v

// Protocol-neutral TAP core (shared by JTAG + cJTAG link layers)
arv_dtm_tap.v

// Transport front-ends (toplevels)
arv_dtm_jtag.v
arv_dtm_cjtag.v
arv_dtm_uart.v
arv_dtm_i2c.v

// Synthesizable transport-selectable wrapper (DTM_TYPE parameter + generate)
arv_dtm.v
