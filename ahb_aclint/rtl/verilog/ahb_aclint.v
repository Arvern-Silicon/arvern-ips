//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_aclint
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_aclint.v
// Module Description : RISC-V ACLINT-spec interrupt controller, AHB-Lite
//                      slave wrapper. Contains:
//                        + aclint_mswi    : per-hart Machine-Software IRQ
//                        + aclint_mtimer  : 64-bit MTIME + per-hart MTIMECMP
//                                           with LF-domain counter for
//                                           wake-from-WFI support
//                        + aclint_sswi    : per-hart Supervisor-Software IRQ
//                                           (present iff SU_MODE_EN=1)
//
// ADDRESS MAP (16-bit haddr_i, byte address):
//   0x0000 - 0x3FFF  MSWI
//   0x4000 - 0x7FFF  MTIMER
//   0x8000 - 0xBFFF  reserved (RAZ/WI)
//   0xC000 - 0xCFFF  SSWI       (only if SU_MODE_EN=1)
//   0xD000 - 0xFFFF  reserved (RAZ/WI)
//
//----------------------------------------------------------------------------
`default_nettype none

module  ahb_aclint #(
    parameter                   SU_MODE_EN      = 0,    // 1 => instantiate SSWI
    parameter                   NUM_HARTS       = 1,    // Number of harts (1..16)
    parameter                   PRIV_CHECK_EN   = 1,    // 1 => enforce M-only privilege checker via hprot_i[1] + hsmode_i; 0 => allow any access (legacy / fabric-policed)
    parameter                   ASYNC_RST_EN    = 1     // Reset architecture: 1 => asynchronous active-low reset (default), 0 => synchronous reset (clock must run during reset assertion)
) (

// AHB CLOCK, RESET & WAKEUP
    input  wire                 hclk_i,                 // AHB clock (gated by hclk_en_o at the SoC-level ICG)
    input  wire                 hclk_aon_i,             // Always-on AHB-frequency clock (NEVER gated). Same source/frequency as hclk_i
    input  wire                 hresetn_i,              // Active-low async reset
    output wire                 hclk_en_o,              // Clock enable output for SoC-level clock gating
    output wire [NUM_HARTS-1:0] mtimer_wake_lf_o,       // Wake-up signal for the SoC's LF-domain power controller to re-enable the main hclk PLL/oscillator on a programmed mtimecmp expiry.

// LOW-FREQUENCY CLOCK & RESET (e.g. 32 kHz always-on)
    input  wire                 clk_lf_i,               // LF clock for MTIME counter
    input  wire                 resetn_lf_i,            // Active-low async reset (LF domain)

// AHB-LITE SLAVE INTERFACE
    input  wire                 hsel_i,                 // Slave select
    input  wire          [15:0] haddr_i,                // AHB byte address (16-bit window)
    input  wire                 hwrite_i,               // Write enable
    input  wire           [2:0] hsize_i,                // Transfer size (only word is meaningful)
    input  wire           [1:0] htrans_i,               // Transfer type (NONSEQ/SEQ start an access)
    input  wire           [3:0] hprot_i,                // AHB-Lite protection; bit[1]=1 privileged, bit[1]=0 unprivileged. Other bits ignored. Consumed only when PRIV_CHECK_EN=1.
    input  wire                 hsmode_i,               // aRVern privilege extension: when hprot_i[1]=1, 0=M, 1=S. Don't-care when hprot_i[1]=0. Consumed only when PRIV_CHECK_EN=1.
    input  wire                 hready_i,               // Bus ready in
    input  wire          [31:0] hwdata_i,               // Write data
    output wire          [31:0] hrdata_o,               // Read data
    output wire                 hreadyout_o,            // Bus ready out
    output wire                 hresp_o,                // Bus error response

// PER-HART INTERRUPTS (hclk DOMAIN)
    output wire [NUM_HARTS-1:0] irq_m_software_o,       // MSIP per hart
    output wire [NUM_HARTS-1:0] irq_m_timer_o,          // MTIP per hart
    output wire [NUM_HARTS-1:0] irq_s_software_o,       // SSIP per hart; 1-hclk_i cycle pulse per SETSSIP write (edge, NOT a level). Consumer MUST sample on hclk_i. Tied 0 when SU_MODE_EN=0.

// ZICNTR TIME INTERFACE
    input  wire                 time_req_i,             // 1-hclk_i cycle pulse: request a fresh time_val. MUST be in the hclk_i domain (sampled directly without a synchronizer); the consumer is responsible for edge-syncing if generated elsewhere.
    output wire                 time_gnt_o,             // 1-hclk_i cycle pulse alongside a valid time_val_o (hclk_i domain).
    output wire          [63:0] time_val_o              // Latched 64-bit MTIME snapshot (hclk_i domain). Held stable between Zicntr reads from the cycle time_gnt_o pulses.
);


//=============================================================================
// 1)  LOCAL PARAMETERS
//=============================================================================
// Fixed base offsets per the ACLINT spec layout (see header).

localparam [15:0] MSWI_BASE_OFFSET    = 16'h0000;
localparam [15:0] MTIMER_BASE_OFFSET  = 16'h4000;
localparam [15:0] SSWI_BASE_OFFSET    = 16'hC000;

localparam        REG_AW              = 14;             // 16-KB per sub-component window


//=============================================================================
// 2)  AHB ADDRESS-PHASE -> DATA-PHASE LATCHING
//=============================================================================

wire        aph_valid = hsel_i    & hready_i & htrans_i[1];
wire        aph_write = aph_valid & hwrite_i;

wire        dph_capture = aph_valid;
wire        dph_en      = aph_valid | hready_i;
wire [19:0] dph_d       = dph_capture ? {1'b1, aph_write, haddr_i, hprot_i[1], hsmode_i}
                                      : 20'h00000;

wire        dph_valid;
wire        dph_write;
wire [15:0] dph_addr;
wire        dph_hprot1;
wire        dph_hsmode;

arv_ipdff #(.WIDTH(20), .ARST_EN(ASYNC_RST_EN)) u_dph (
                  .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dph_en),
                                                       .d_i (dph_d),
                                                       .q_o ({dph_valid, dph_write, dph_addr, dph_hprot1, dph_hsmode}));


//=============================================================================
// 3)  PRIVILEGE-MODE DECODE + ACCESS POLICY
//=============================================================================
// Per ACLINT 1.0-rc4 Chapter 1 / Table 1 each sub-device is classified by
// privilege level:
//   - MSWI   (MSIP[hart])           : Machine     -> M-mode only
//   - MTIMER (MTIME, MTIMECMP[])    : Machine     -> M-mode only
//   - SSWI   (SETSSIP[hart])        : Supervisor  -> M-mode AND S-mode
//
// AHB privilege encoding (aRVern dialect):
//   hprot[1]=1 & hsmode=0 -> M-mode
//   hprot[1]=1 & hsmode=1 -> S-mode
//   hprot[1]=0            -> U-mode
//
// Denied accesses get an AHB-Lite ERROR response

wire dph_mode_m = dph_hprot1 & ~dph_hsmode;
wire dph_mode_s = dph_hprot1 &  dph_hsmode;

// Per-sub-window privilege gates. PRIV_CHECK_EN=0 disables both checks
wire dph_priv_allowed_m_only = (PRIV_CHECK_EN == 1) ?  dph_mode_m              : 1'b1; // MSWI, MTIMER
wire dph_priv_allowed_m_or_s = (PRIV_CHECK_EN == 1) ? (dph_mode_m | dph_mode_s): 1'b1; // SSWI


//=============================================================================
// 4)  SUB-COMPONENT ADDRESS DECODE
//=============================================================================
// 16 KB windows aligned to MSWI/MTIMER/SSWI boundaries.
// The upper 2 bits of haddr_i pick MSWI (00), MTIMER (01), or upper half (1x).
// Within the upper half, haddr[13:12] = 2'b00 selects SSWI (0xC000-0xCFFF).

// Raw decode (unfiltered) used by the error FSM and lint sinks.
wire in_mswi_raw   = dph_valid & (dph_addr[15:14] == MSWI_BASE_OFFSET   [15:14]);
wire in_mtimer_raw = dph_valid & (dph_addr[15:14] == MTIMER_BASE_OFFSET [15:14]);
wire in_sswi_raw   = dph_valid & (dph_addr[15:12] == SSWI_BASE_OFFSET   [15:12]);

// Privilege-gated decode wires that feed reg_sel_i on each sub-block.
wire in_mswi       = in_mswi_raw   & dph_priv_allowed_m_only;
wire in_mtimer     = in_mtimer_raw & dph_priv_allowed_m_only;
wire in_sswi       = in_sswi_raw   & dph_priv_allowed_m_or_s;


//=============================================================================
// 5)  MSWI INSTANCE
//=============================================================================

wire         mswi_ready;
wire [31:0]  mswi_rdata;

aclint_mswi #(
    .NUM_HARTS         ( NUM_HARTS                ),
    .REG_AW            ( REG_AW                   ),
    .ARST_EN           ( ASYNC_RST_EN             )
) u_mswi (
    .hclk_i            ( hclk_i                   ),
    .hresetn_i         ( hresetn_i                ),
    .reg_sel_i         ( in_mswi                  ),
    .reg_addr_i        ( dph_addr[REG_AW-1:0]     ),
    .reg_wr_en_i       ( dph_write                ),
    .reg_wr_data_i     ( hwdata_i                 ),
    .reg_rd_data_o     ( mswi_rdata               ),
    .reg_ready_o       ( mswi_ready               ),
    .irq_m_software_o  ( irq_m_software_o         )
);


//=============================================================================
// 6)  MTIMER INSTANCE
//=============================================================================

wire         mtimer_ready;
wire [31:0]  mtimer_rdata;
wire         mtimer_active;

aclint_mtimer #(
    .NUM_HARTS         ( NUM_HARTS                ),
    .REG_AW            ( REG_AW                   ),
    .ARST_EN           ( ASYNC_RST_EN             )
) u_mtimer (
    .hclk_i            ( hclk_i                   ),
    .hclk_aon_i        ( hclk_aon_i               ),
    .hresetn_i         ( hresetn_i                ),
    .clk_lf_i          ( clk_lf_i                 ),
    .resetn_lf_i       ( resetn_lf_i              ),
    .reg_sel_i         ( in_mtimer                ),
    .reg_addr_i        ( dph_addr[REG_AW-1:0]     ),
    .reg_wr_en_i       ( dph_write                ),
    .reg_wr_data_i     ( hwdata_i                 ),
    .reg_rd_data_o     ( mtimer_rdata             ),
    .reg_ready_o       ( mtimer_ready             ),
    .irq_m_timer_o     ( irq_m_timer_o            ),
    .mtimer_wake_lf_o  ( mtimer_wake_lf_o         ),
    .time_req_i        ( time_req_i               ),
    .time_gnt_o        ( time_gnt_o               ),
    .time_val_o        ( time_val_o               ),
    .mtimer_active_o   ( mtimer_active            )
);


//=============================================================================
// 7)  SSWI INSTANCE (conditional on SU_MODE_EN)
//=============================================================================

wire                 sswi_ready;
wire          [31:0] sswi_rdata;
wire [NUM_HARTS-1:0] irq_s_software_int;
wire                 sswi_active;

generate
    if (SU_MODE_EN == 1) begin : G_SSWI

        aclint_sswi #(
            .NUM_HARTS         ( NUM_HARTS            ),
            .REG_AW            ( REG_AW               ),
            .ARST_EN           ( ASYNC_RST_EN         )
        ) u_sswi (
            .hclk_i            ( hclk_i               ),
            .hresetn_i         ( hresetn_i            ),
            .reg_sel_i         ( in_sswi              ),
            .reg_addr_i        ( dph_addr[REG_AW-1:0] ),
            .reg_wr_en_i       ( dph_write            ),
            .reg_wr_data_i     ( hwdata_i             ),
            .reg_rd_data_o     ( sswi_rdata           ),
            .reg_ready_o       ( sswi_ready           ),
            .irq_s_software_o  ( irq_s_software_int   ),
            .sswi_active_o     ( sswi_active          )
        );

    end else begin : G_NO_SSWI

        assign sswi_rdata         = 32'h0;
        assign sswi_ready         =  1'b1;
        assign irq_s_software_int = {NUM_HARTS{1'b0}};
        assign sswi_active        =  1'b0;

    end
endgenerate

assign irq_s_software_o = irq_s_software_int;


//=============================================================================
// 8)  AHB READ-DATA OR-MUX
//=============================================================================
// Each sub-component returns zero on its data bus unless it is being read.

assign hrdata_o = mswi_rdata   |
                  mtimer_rdata |
                  sswi_rdata   ;


//=============================================================================
// 9)  HREADYOUT AND-MUX
//=============================================================================
// A sub-component is allowed to stall the bus by lowering its reg_ready_o.

wire sub_ready = mswi_ready & mtimer_ready & sswi_ready;


//=============================================================================
// 9.b) HREADYOUT / HRESP -- two-cycle ERROR response on denied accesses
//=============================================================================
// PRIV_CHECK_EN = 0 -> single-cycle slave, no error path
// PRIV_CHECK_EN = 1 -> two-cycle ERROR on a denied access

generate
    if (PRIV_CHECK_EN == 1) begin : G_AHB_ERR_RSP
        localparam ERR_IDLE = 1'b0;
        localparam ERR_P2   = 1'b1;

        wire err_state;
        wire deny_mswi      = in_mswi_raw    & ~dph_priv_allowed_m_only;
        wire deny_mtimer    = in_mtimer_raw  & ~dph_priv_allowed_m_only;
        wire deny_sswi      = in_sswi_raw    & ~dph_priv_allowed_m_or_s;
        wire access_denied  = dph_valid      & (deny_mswi | deny_mtimer | deny_sswi);

        // 2-state error FSM: IDLE -> P2 on a denied access, P2 -> IDLE always.
        // Next-state = (in IDLE) & access_denied; identical to the original case.
        wire err_state_nxt  = (err_state == ERR_IDLE) & access_denied;

        arv_ipdff #(.WIDTH(1), .RST_VAL(ERR_IDLE), .ARST_EN(ASYNC_RST_EN)) u_err_state (
                                                   .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                                                        .d_i (err_state_nxt),
                                                                                        .q_o (err_state));

        wire in_err_p1     = access_denied & (err_state == ERR_IDLE);  // first error cycle
        wire in_err_p2     =                 (err_state == ERR_P2  );  // second error cycle

        assign hresp_o     = in_err_p1 | in_err_p2;
        assign hreadyout_o = in_err_p1 ? 1'b0 : sub_ready;             // stall in P1, normal ready otherwise

    end else begin : G_AHB_NO_ERR
        assign hresp_o     = 1'b0;
        assign hreadyout_o = sub_ready;
    end
endgenerate


//=============================================================================
// 10) hclk_en_o -- enable for SoC-side ICG cell.
//=============================================================================

assign hclk_en_o = aph_valid | dph_valid | mtimer_active | sswi_active;


//=============================================================================
// 11) PARAMETER VALIDATION
//=============================================================================
// pragma translate_off
generate
    if ((NUM_HARTS < 1) || (NUM_HARTS > 16)) begin : CHECK_NUM_HARTS
        initial $fatal(1, "ahb_aclint: NUM_HARTS (%0d) must be 1..16.", NUM_HARTS);
    end
    if ((SU_MODE_EN != 0) && (SU_MODE_EN != 1)) begin : CHECK_SU_MODE_EN
        initial $fatal(1, "ahb_aclint: SU_MODE_EN (%0d) must be 0 or 1.", SU_MODE_EN);
    end
     if ((ASYNC_RST_EN != 0) && (ASYNC_RST_EN != 1)) begin : CHECK_ASYNC_RST_EN
        initial $fatal(1, "ahb_aclint: ASYNC_RST_EN (%0d) must be 0 or 1.", ASYNC_RST_EN);
    end
endgenerate
// pragma translate_on


//=============================================================================
// 12) LINT CLEANUP
//=============================================================================

wire       htrans0_unused;
assign     htrans0_unused = htrans_i[0];

wire [2:0] hsize_unused;
assign     hsize_unused   = hsize_i;

wire [2:0] hprot_unused;
assign     hprot_unused = {hprot_i[3:2], hprot_i[0]};

generate
    if (SU_MODE_EN == 0) begin : G_SU_MODE_EN_SINK
        wire   in_decode_unused;
        assign in_decode_unused = in_sswi;
    end
endgenerate


generate
    if (PRIV_CHECK_EN == 0) begin : G_PRIV_OFF_SINK
        wire [3:0] priv_off_unused;
        assign     priv_off_unused = {dph_hprot1, dph_hsmode, dph_mode_m, dph_mode_s};
    end
endgenerate

endmodule // ahb_aclint

`default_nettype wire
