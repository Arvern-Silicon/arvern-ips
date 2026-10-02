//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arv_dtm
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arv_dtm.v
// Module Description : Synthesizable transport-selectable Debug Transport Module
//                      wrapper for the arv_dtm front-ends.
//
//   Picks ONE of the four DTM transports at ELABORATION time via the DTM_TYPE
//   parameter and instantiates only that front-end with a generate statement
//   (0 = JTAG, 1 = UART, 2 = I2C, 3 = cJTAG).
//   The unselected transports contribute NO logic. This wrapper is what the
//   bench instantiates, so the regression covers the module that actually ships.
//
//   All four transports present the same aRVern DMI (APB4 master) bus and the
//   same active-low dbgresetn_i; they differ only in their PHY pins and in the
//   clock-port spelling (JTAG: hclk_i, serial/cJTAG: clk_i). All bind to this
//   wrapper's clk_i -- the always-on oscillator that also clocks the DMI bus.
//   The PHY pins of the non-selected transports are driven to their idle state
//   (TDO released, UART TX high, I2C pull-downs off, TMSC released) so every
//   wrapper output is driven for any DTM_TYPE.
//
//   NOTE cJTAG (DTM_TYPE=3) is point-to-point only -- multi-drop / star is not
//   supported. See doc/arv_dtm_cjtag.md before selecting it for silicon.
//----------------------------------------------------------------------------

`default_nettype none

module arv_dtm #(
    parameter integer DTM_TYPE      = 0,             // Transport: 0=JTAG, 1=UART, 2=I2C, 3=cJTAG
    parameter [27:0]  IDCODE_BASE   = 28'h000_01F7,  // IDCODE[27:0] (bit0 MUST be 1); version [31:28] is on idcode_version_i
    parameter  [2:0]  IDLE_HINT     = 3'd3,          // JTAG dtmcs.idle Run-Test/Idle hint
    parameter  [6:0]  I2C_ADDR      = 7'h30,         // I2C 7-bit target address
    parameter         ARST_EN       = 1'b1,          // Reset style: 1=async active-low, 0=sync
    parameter [31:0]  AB_BREAK_CLKS = 32'd1048576,   // UART break re-arm: continuous-low clk_i cycles to force reconnect
                                                     //   (lowest baud = 16*f_clk/AB_BREAK_CLKS: 1Mi keeps 9600 up to ~629 MHz)
    parameter integer UART_RX_FIFO_DEPTH = 64,       // UART RX FIFO depth = the host's request-pipelining window (deeper = faster bulk transfers).
    parameter integer I2C_WD_BITS   = 16             // I2C read-side watchdog: 2^I2C_WD_BITS clk_i without an SCL edge releases the bus

) (
    // Always-on oscillator + reset (serial/cJTAG clk_i AND JTAG hclk_i bind here)
    input  wire                 clk_i,
    input  wire                 dbgresetn_i,
    output wire                 dbg_wakeup_o,

    // JTAG PHY
    input  wire                 tck_i,
    input  wire                 trst_n_i,
    input  wire                 tms_i,
    input  wire                 tdi_i,
    output wire                 tdo_o,
    output wire                 tdo_oe_o,

    // UART PHY
    input  wire                 uart_rx_i,
    output wire                 uart_tx_o,

    // I2C PHY (open-drain level in, active-high pull-down request out)
    input  wire                 scl_i,
    input  wire                 sda_i,
    output wire                 scl_pd_o,
    output wire                 sda_pd_o,

    // cJTAG PHY (2-wire; TMSC is bidirectional -- pad drives tmsc_o when tmsc_oe_o)
    input  wire                 tckc_i,
    input  wire                 tmsc_i,
    output wire                 tmsc_o,
    output wire                 tmsc_oe_o,

// IDCODE[31:28]: the version field
    input  wire           [3:0] idcode_version_i,               // Version specified as a port so it can easily be ECO-ed

    // DFT
    input  wire                 scan_mode_i,      // 1 = test mode: internal resets held inactive, cJTAG TMSC released

    // aRVern DMI bus -- APB4 master (the selected DTM drives this)
    output wire                 dmi_psel_o,
    output wire                 dmi_penable_o,
    output wire           [8:0] dmi_paddr_o,
    output wire                 dmi_pwrite_o,
    output wire          [31:0] dmi_pwdata_o,
    output wire           [2:0] dmi_pprot_o,
    input  wire                 dmi_pready_i,
    input  wire          [31:0] dmi_prdata_i,
    input  wire                 dmi_pslverr_i
);

    // Transport encoding: 0 = JTAG (the else/default branch), 1 = UART, 2 = I2C, 3 = cJTAG.
    localparam integer SEL_UART = 1, SEL_I2C = 2, SEL_CJTAG = 3;

    // Elaboration-time guard, VISIBLE TO SYNTHESIS. The instantiation below names a
    // module that does not exist, so an out-of-range DTM_TYPE is an elaboration error
    // in every tool -- the module name is the message. Do not wrap this in
    // translate_off: a sim-only guard lets a bad DTM_TYPE silently synthesise the
    // default (JTAG) branch and ship the wrong transport.
    generate
    if ((DTM_TYPE < 0) || (DTM_TYPE > 3)) begin : g_bad_dtm_type
        ERROR_arv_dtm_DTM_TYPE_must_be_0_JTAG_1_UART_2_I2C_or_3_CJTAG u_bad ();
        // pragma translate_off
        initial begin
            $display("arv_dtm: DTM_TYPE (%0d) must be 0=JTAG, 1=UART, 2=I2C, 3=cJTAG.", DTM_TYPE);
            $finish;
        end
        // pragma translate_on
    end
    endgenerate

    generate
    if (DTM_TYPE == SEL_UART) begin : g_uart

        // UART transport selected. Idle the JTAG and I2C PHY outputs.
        arv_dtm_uart #(.ARST_EN       ( ARST_EN       ),
                       .AB_BREAK_CLKS ( AB_BREAK_CLKS ),
                       .RX_FIFO_DEPTH ( UART_RX_FIFO_DEPTH )) u_dtm (
            .clk_i         ( clk_i         ),
            .dbgresetn_i   ( dbgresetn_i   ),
            .uart_rx_i     ( uart_rx_i     ),
            .uart_tx_o     ( uart_tx_o     ),
            .dmi_psel_o    ( dmi_psel_o    ),
            .dmi_penable_o ( dmi_penable_o ),
            .dmi_paddr_o   ( dmi_paddr_o   ),
            .dmi_pwrite_o  ( dmi_pwrite_o  ),
            .dmi_pwdata_o  ( dmi_pwdata_o  ),
            .dmi_pprot_o   ( dmi_pprot_o   ),
            .dmi_pready_i  ( dmi_pready_i  ),
            .dmi_prdata_i  ( dmi_prdata_i  ),
            .dmi_pslverr_i ( dmi_pslverr_i )
        );

        assign tdo_o        = 1'b0;
        assign tdo_oe_o     = 1'b0;
        assign scl_pd_o     = 1'b0;
        assign sda_pd_o     = 1'b0;
        assign dbg_wakeup_o = 1'b0;
        assign tmsc_o       = 1'b0;
        assign tmsc_oe_o    = 1'b0;   // TMSC released

        wire   jtag_unused  = 1'b0 | tck_i | trst_n_i | tms_i | tdi_i;
        wire   i2c_unused   = 1'b0 | scl_i | sda_i;
        wire   idver_unused = 1'b0 | (|idcode_version_i);   // no TAP in this transport
        wire   cjtag_unused = 1'b0 | tckc_i | tmsc_i;
        wire   scan_unused  = 1'b0 | scan_mode_i;

    end
    else if (DTM_TYPE == SEL_I2C) begin : g_i2c

        // I2C transport selected. Idle the JTAG and UART PHY outputs.
        arv_dtm_i2c #(.ARST_EN       ( ARST_EN       ),
                      .WD_BITS       ( I2C_WD_BITS   )) u_dtm (
            .clk_i         ( clk_i         ),
            .dbgresetn_i   ( dbgresetn_i   ),
            .scl_i         ( scl_i         ),
            .sda_i         ( sda_i         ),
            .scl_pd_o      ( scl_pd_o      ),
            .sda_pd_o      ( sda_pd_o      ),
            .i2c_addr_i    ( I2C_ADDR      ),
            .dmi_psel_o    ( dmi_psel_o    ),
            .dmi_penable_o ( dmi_penable_o ),
            .dmi_paddr_o   ( dmi_paddr_o   ),
            .dmi_pwrite_o  ( dmi_pwrite_o  ),
            .dmi_pwdata_o  ( dmi_pwdata_o  ),
            .dmi_pprot_o   ( dmi_pprot_o   ),
            .dmi_pready_i  ( dmi_pready_i  ),
            .dmi_prdata_i  ( dmi_prdata_i  ),
            .dmi_pslverr_i ( dmi_pslverr_i )
        );

        assign tdo_o        = 1'b0;
        assign tdo_oe_o     = 1'b0;
        assign uart_tx_o    = 1'b1;   // UART idles high
        assign dbg_wakeup_o = 1'b0;
        assign tmsc_o       = 1'b0;
        assign tmsc_oe_o    = 1'b0;   // TMSC released

        wire   jtag_unused  = 1'b0 | tck_i | trst_n_i | tms_i | tdi_i;
        wire   uart_unused  = 1'b0 | uart_rx_i;
        wire   idver_unused = 1'b0 | (|idcode_version_i);   // no TAP in this transport
        wire   cjtag_unused = 1'b0 | tckc_i | tmsc_i;
        wire   scan_unused  = 1'b0 | scan_mode_i;

    end
    else if (DTM_TYPE == SEL_CJTAG) begin : g_cjtag

        // cJTAG transport selected. Idle the JTAG, UART and I2C PHY outputs.
        arv_dtm_cjtag #(.IDCODE_BASE ( IDCODE_BASE ),
                        .IDLE_HINT   ( IDLE_HINT   ),
                        .ARST_EN     ( ARST_EN     )) u_dtm (
            .idcode_version_i ( idcode_version_i ),
            .clk_i            ( clk_i            ),
            .dbgresetn_i      ( dbgresetn_i      ),
            .tckc_i           ( tckc_i           ),
            .tmsc_i           ( tmsc_i           ),
            .tmsc_o           ( tmsc_o           ),
            .tmsc_oe_o        ( tmsc_oe_o        ),
            .scan_mode_i      ( scan_mode_i      ),
            .dbg_wakeup_o     ( dbg_wakeup_o     ),
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

        assign tdo_o     = 1'b0;
        assign tdo_oe_o  = 1'b0;
        assign uart_tx_o = 1'b1;   // UART idles high
        assign scl_pd_o  = 1'b0;
        assign sda_pd_o  = 1'b0;

        wire jtag_unused = 1'b0 | tck_i | trst_n_i | tms_i | tdi_i;
        wire uart_unused = 1'b0 | uart_rx_i;
        wire i2c_unused  = 1'b0 | scl_i | sda_i;

    end
    else begin : g_jtag

        // JTAG transport selected (default). Idle the UART and I2C PHY outputs.
        arv_dtm_jtag #(.IDCODE_BASE ( IDCODE_BASE ),
                       .IDLE_HINT   ( IDLE_HINT   ),
                       .ARST_EN     ( ARST_EN     )) u_dtm (
            .idcode_version_i ( idcode_version_i ),
            .tck_i            ( tck_i            ),
            .trst_n_i         ( trst_n_i         ),
            .tms_i            ( tms_i            ),
            .tdi_i            ( tdi_i            ),
            .tdo_o            ( tdo_o            ),
            .tdo_oe_o         ( tdo_oe_o         ),
            .hclk_i           ( clk_i            ),
            .dbgresetn_i      ( dbgresetn_i      ),
            .scan_mode_i      ( scan_mode_i      ),
            .dbg_wakeup_o     ( dbg_wakeup_o     ),
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

        assign uart_tx_o   = 1'b1;   // UART idles high
        assign scl_pd_o    = 1'b0;
        assign sda_pd_o    = 1'b0;
        assign tmsc_o      = 1'b0;
        assign tmsc_oe_o   = 1'b0;   // TMSC released

        wire   i2c_unused  = 1'b0 | scl_i | sda_i;
        wire   uart_unused = 1'b0 | uart_rx_i;
        wire   cjtag_unused= 1'b0 | tckc_i | tmsc_i;

    end
    endgenerate

endmodule

`default_nettype wire
