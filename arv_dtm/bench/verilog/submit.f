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
//   One unified bench (tb_arv_dtm.v) instantiates the SHIPPING wrapper
//   rtl/verilog/arv_dtm.v and selects the transport at elaboration via its
//   DTM_TYPE parameter, derived from a +define+ (DTM_JTAG / DTM_UART / DTM_I2C /
//   DTM_CJTAG) set by runsim -dtm. Only the selected front-end is elaborated, and
//   the regression therefore covers arv_dtm.v itself rather than a bench copy.
//=============================================================================

+incdir+.
tb_arv_dtm.v

//=============================================================================
// arv_dtm DTM IP (all transports)
//=============================================================================

+incdir+../../rtl/verilog/
-f ../../rtl/verilog/filelist.f
