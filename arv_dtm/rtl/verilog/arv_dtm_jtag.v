//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arv_dtm_jtag
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arv_dtm_jtag.v
// Module Description : Standard 4-wire JTAG (IEEE 1149.1) Debug Transport Module
//                      for the aRVern core, per the RISC-V Debug Specification
//                      1.0 JTAG DTM chapter. This is a thin LINK LAYER: it maps
//                      the physical TAP pins (TCK/TRST_n/TMS/TDI/TDO) 1:1 onto
//                      the protocol-neutral arv_dtm_tap core, which owns the TAP
//                      controller, the dtmcs/dmi registers, and the TCK<->hclk
//                      DMI clock-domain crossing.
//
//   The pins ARE the virtual interface for standard JTAG (tck=TCK, tap reset =
//   TRST_n, tms/tdi/tdo direct), so this wrapper is pure wiring. The 2-wire
//   cJTAG variant (arv_dtm_cjtag) is the non-trivial sibling: it
//   reconstructs the same virtual signals from an IEEE 1149.7 OScan1 stream.
//----------------------------------------------------------------------------
`default_nettype none

module  arv_dtm_jtag #(
    parameter            [27:0] IDCODE_BASE = 28'h000_01F7,     // IDCODE[27:0] (bit0 MUST be 1); the version field
                                                                // [31:28] arrives on idcode_version_i, not here
                                                                // (mfg field = Arvern's JEDEC identity -- see arv_dtm.md)
    parameter             [2:0] IDLE_HINT = 3'd3,               // dtmcs.idle: Run-Test/Idle cycles hint to the debugger
    parameter                   ARST_EN   = 1'b1                // Reset style: 1=async active-low, 0=sync
) (

// JTAG TAP pins (TCK domain)
    input  wire                 tck_i,                          // JTAG test clock
    input  wire                 trst_n_i,                       // active-low TAP reset. ALWAYS async into
                                                                // the TCK domain (TCK may not be running)
                                                                // and into hclk -- see the reset note in
                                                                // arv_dtm_tap.v
    input  wire                 tms_i,                          // test mode select (sampled on rising TCK)
    input  wire                 tdi_i,                          // test data in     (sampled on rising TCK)
    output wire                 tdo_o,                          // test data out    (updated on falling TCK)
    output wire                 tdo_oe_o,                       // TDO output enable (high only while shifting)

// Cold-attach wake request (see below).
    output wire                 dbg_wakeup_o,

// DFT
    input  wire                 scan_mode_i,                    // 1 = test mode (shift and capture): hold resets inactive

// IDCODE[31:28]: the version field
    input  wire           [3:0] idcode_version_i,               // Version specified as a port so it can easily be ECO-ed

// aRVern DMI bus
    input  wire                 hclk_i,                         // MUST be the ungated oscillator
    input  wire                 dbgresetn_i,                    // active-low reset (hclk domain)

    output wire                 dmi_psel_o,
    output wire                 dmi_penable_o,
    output wire           [8:0] dmi_paddr_o,                    // [DMI_ABITS+1:0]
    output wire                 dmi_pwrite_o,
    output wire          [31:0] dmi_pwdata_o,
    output wire           [2:0] dmi_pprot_o,
    input  wire                 dmi_pready_i,
    input  wire          [31:0] dmi_prdata_i,
    input  wire                 dmi_pslverr_i
);

//=============================================================================
// TAP CORE
//=============================================================================

// TAP reset = TRST_n AND the debug-domain power-on reset.
wire tap_rst_n;
arv_and #(.N(2)) u_tap_rst_and (.a_i({trst_n_i, dbgresetn_i}), .z_o(tap_rst_n));

//=============================================================================
// COLD-ATTACH WAKE
//=============================================================================
// The DMI side runs on clk_i, so with the oscillator stopped a probe can shift the TAP
// but no transaction can complete -- debug-from-sleep would be impossible. This output is
// generated purely in the probe-clock domain and therefore works with clk_i off: it
// TOGGLES on every rising probe-clock edge, so any probe activity produces transitions
// the SoC's always-on controller can detect and turn into a clock-enable request.
//
// A toggle rather than a level: nothing in this domain could ever CLEAR a sticky level
// (that would need clk_i, the very thing being started), and a level plus a clear port
// would push the clear back across the same dead boundary.
//
// Timing is naturally generous. A DTS opens with a selection escape, which holds the
// probe clock HIGH across >= 6 TMSC changes before the first activation bit -- so the
// wake fires on the escape's leading edge and the oscillator has that entire window to
// come up before anything must be decoded.
// TCK_ARST is not declared here; the TAP owns that localparam. Use async reset.
wire wake_tog;
arv_ipdff #(.WIDTH(1), .ARST_EN(1'b1)) u_wake_tog (
    .clk_i(tck_i), .rst_n_i(tap_rst_n), .en_i(1'b1), .d_i(~wake_tog), .q_o(wake_tog));
assign dbg_wakeup_o = wake_tog;

arv_dtm_tap #(
    .IDCODE_BASE ( IDCODE_BASE ),
    .IDLE_HINT   ( IDLE_HINT   ),
    .ARST_EN     ( ARST_EN     )
) u_tap (
    .idcode_version_i ( idcode_version_i ),
    .tck_i            ( tck_i            ),
    .tck_en_i         ( 1'b1             ),
    .tap_rst_n_i      ( tap_rst_n        ),
    .scan_mode_i      ( scan_mode_i      ),
    .tms_i            ( tms_i            ),
    .tdi_i            ( tdi_i            ),
    .tdo_o            ( tdo_o            ),
    .tdo_oe_o         ( tdo_oe_o         ),

    // DMI bus
    .hclk_i           ( hclk_i           ),
    .dbgresetn_i      ( dbgresetn_i      ),
    .dmi_psel_o       ( dmi_psel_o       ),
    .dmi_penable_o    ( dmi_penable_o    ),
    .dmi_paddr_o      ( dmi_paddr_o      ),
    .dmi_pwrite_o     ( dmi_pwrite_o     ),
    .dmi_pwdata_o     ( dmi_pwdata_o     ),
    .dmi_pprot_o      ( dmi_pprot_o      ),
    .dmi_pready_i     ( dmi_pready_i     ),
    .dmi_prdata_i     ( dmi_prdata_i     ),
    .dmi_pslverr_i    ( dmi_pslverr_i    )
);

endmodule // arv_dtm_jtag

`default_nettype wire
