//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    aclint_mtimer
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : aclint_mtimer.v
// Module Description : ACLINT MTIMER block.
//
// ADDRESS MAP (relative to MTIMER_BASE, in bytes, word-aligned):
//      0x00 + 8*hart      : MTIMECMP_LO[hart]
//      0x04 + 8*hart      : MTIMECMP_HI[hart]
//      0x00 + 8*NUM_HARTS : MTIME_LO
//      0x04 + 8*NUM_HARTS : MTIME_HI
//
//----------------------------------------------------------------------------
`default_nettype none

module  aclint_mtimer #(
    parameter                        NUM_HARTS  =  1,          // Number of harts (1..16)
    parameter                        REG_AW     = 12,          // Reg-bank address width (bytes, MTIMER window)
    parameter                        ARST_EN    = 1'b1         // Reset style: 1=asynchronous, 0=synchronous
) (

// CLOCKS & RESETS
    input  wire                      hclk_i,                   // AHB clock domain (gated by hclk_en_o at the SoC-level ICG)
    input  wire                      hclk_aon_i,               // Always-on AHB-frequency clock (NEVER gated).
    input  wire                      hresetn_i,                // Active-low async reset (hclk + hclk_aon)
    input  wire                      clk_lf_i,                 // Low-frequency clock
    input  wire                      resetn_lf_i,              // Active-low async reset (LF)

// GENERIC REGISTER-BANK INTERFACE (from top-level decoder)
    input  wire                      reg_sel_i,                // Access in flight to this sub-component
    input  wire         [REG_AW-1:0] reg_addr_i,               // Byte address inside MTIMER window
    input  wire                      reg_wr_en_i,              // 1 = write, 0 = read
    input  wire               [31:0] reg_wr_data_i,            // Write data
    output wire               [31:0] reg_rd_data_o,            // Read data (0 when not selected)
    output wire                      reg_ready_o,              // 1 = transfer can complete this cycle

// PER-HART MTIMER INTERRUPT
    output wire      [NUM_HARTS-1:0] irq_m_timer_o,            // Per-hart MTIP level in the hclk_i domain. Driven by the LF -> hclk_aon 2-FF MTIP synchronizer, AND-masked combinationally with ~mtimecmp_write_busy at the output (see Section 8 CDC waiver). Consumer is the CPU on hclk_i.
    output wire      [NUM_HARTS-1:0] mtimer_wake_lf_o,         // Per-hart MTIP level in the clk_lf_i domain. Same comparator output as irq_m_timer_o, but BEFORE the LF -> hclk_aon synchronizer AND the write-busy mask. Valid even while hclk_i is gated. Route to the SoC's LF-domain power controller to re-enable hclk on a programmed mtimecmp expiry.

// ZICNTR TIME INTERFACE
    input  wire                      time_req_i,               // 1-hclk_i cycle pulse: request a fresh time_val. MUST be in the hclk_i domain (sampled directly without a synchronizer); the consumer is responsible for edge-syncing if generated elsewhere.
    output wire                      time_gnt_o,               // 1-hclk_i cycle pulse: time_val_o is valid this cycle (hclk_i domain).
    output wire               [63:0] time_val_o,               // Latest 64-bit MTIME snapshot (binary, hclk_i domain). Held stable between Zicntr reads from the cycle time_gnt_o pulses.

// SOC-LEVEL CLOCK-GATE ADVISORY
    output wire                      mtimer_active_o           // HIGH while a Zicntr time read is in flight, or while the gray-sync warmup / mtime_valid cleanup cycle is in flight
);


//=============================================================================
// 1)  CONSTANTS / LOCAL PARAMETERS
//=============================================================================

localparam       [31:0] MTIME_LO_ADDR_INT = 8 * NUM_HARTS;
localparam       [31:0] MTIME_HI_ADDR_INT = 8 * NUM_HARTS + 4;
localparam [REG_AW-1:0] MTIME_LO_ADDR     = MTIME_LO_ADDR_INT[REG_AW-1:0];
localparam [REG_AW-1:0] MTIME_HI_ADDR     = MTIME_HI_ADDR_INT[REG_AW-1:0];


//=============================================================================
// 2)  ADDRESS DECODE
//=============================================================================
// MTIMECMP hit: address lives in [0, 8*NUM_HARTS) and is word-aligned.

wire reg_active       =  reg_sel_i;

wire addr_in_mtimecmp = (reg_addr_i <  MTIME_LO_ADDR);
wire addr_is_mtime_lo = (reg_addr_i == MTIME_LO_ADDR);
wire addr_is_mtime_hi = (reg_addr_i == MTIME_HI_ADDR);

// Hart index extraction
wire    [REG_AW-1:0] hart_byte_index = (reg_addr_i >> 3);  // /8 = hart number
wire           [3:0] hart_idx        =  hart_byte_index[3:0];
wire                 half_is_hi      =  reg_addr_i[2];

// Per-hart MTIMECMP write strobes (one-hot among harts).
wire [NUM_HARTS-1:0] mtimecmp_hart_sel;
genvar gh;
generate
    for (gh = 0; gh < NUM_HARTS; gh = gh + 1) begin : G_HART_SEL
        assign mtimecmp_hart_sel[gh] = addr_in_mtimecmp & (hart_idx == gh[3:0]);
    end
endgenerate


//=============================================================================
// 3)  MTIME READ SHARED PATH + ARBITRATION FSM
//=============================================================================
// Single read_req pulse drives the shared gray-sync block (per-bit 2-FF sync
// of the LF Gray bus + 2-cycle warmup). A small FSM tracks who owns the
// in-flight read:
//
//   IDLE      : no read in flight; accept new requests
//   AHB_PEND  : AHB read of MTIME_LO is outstanding; valid will refresh the
//               main-side mtime buffer and complete the AHB transfer
//   TIME_PEND : Zicntr time_req is outstanding; valid will refresh the
//               main-side mtime buffer and pulse time_gnt_o
//
// Priority: when both sources request in IDLE on the same cycle, AHB wins
// and time_req is held off (its caller naturally re-asserts).
//
// LATENCY    : 2 hclk wait states inside the warmup pipeline
//              (pend_1 -> pend_2 = time to flush the gray-sync
//              chain). Master-visible AHB latency is 3 hclk cycles
//              from the data phase start: the cycle start_ahb fires
//              is itself a stall cycle (FSM still IDLE; transitions
//              to AHB_PEND on the next edge).

localparam [1:0] FSM_IDLE      = 2'b00;
localparam [1:0] FSM_AHB_PEND  = 2'b01;
localparam [1:0] FSM_TIME_PEND = 2'b10;

wire       [1:0] fsm_state;
reg        [1:0] fsm_state_nxt;

// AHB MTIME read request: the AHB master is in a data-phase read of MTIME_LO
// and reg_ready_o is currently low.
wire             ahb_mtime_lo_read = reg_active & ~reg_wr_en_i & addr_is_mtime_lo;

// Pending-time-request capture: latch time_req_i if it arrives while the FSM
// is busy serving AHB or while AHB is in its first pending cycle.
wire             time_req_pending;

wire             start_ahb  = (fsm_state == FSM_IDLE) &  ahb_mtime_lo_read ;
wire             start_time = (fsm_state == FSM_IDLE) & ~ahb_mtime_lo_read & (time_req_i | time_req_pending);
wire             read_req   = (start_ahb | start_time);

wire             mtime_valid;
wire      [63:0] mtime_binary;

always @(*) begin
    fsm_state_nxt = fsm_state;
    case (fsm_state)
        FSM_IDLE     : if      (start_ahb ) fsm_state_nxt = FSM_AHB_PEND;
                       else if (start_time) fsm_state_nxt = FSM_TIME_PEND;
        FSM_AHB_PEND : if (mtime_valid)     fsm_state_nxt = FSM_IDLE;
        FSM_TIME_PEND: if (mtime_valid)     fsm_state_nxt = FSM_IDLE;
        default      :                      fsm_state_nxt = FSM_IDLE;
    endcase
end

arv_ipdff #(.WIDTH(2), .RST_VAL(FSM_IDLE), .ARST_EN(ARST_EN)) u_fsm_state (
                                      .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(fsm_state_nxt), .q_o(fsm_state));

// Latch any time_req_i pulse that arrives in a cycle where we cannot launch it.
// start_time clears (priority), else time_req_i sets; identical to the original
// if-elsif chain since start_time and (time_req_i & ~start_time) are mutually exclusive.
arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_time_req_pending (
                         .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(start_time | (time_req_i & ~start_time)),
                                                              .d_i (~start_time),
                                                              .q_o (time_req_pending));


//=============================================================================
// 4)  MTIMER GRAY-SYNC INSTANCE
//=============================================================================

wire          [63:0] mtime_gray_lf;

aclint_mtimer_gray_sync #(
    .ARST_EN         ( ARST_EN       )
) u_gray_sync (
    .hclk_i          ( hclk_i        ),
    .hresetn_i       ( hresetn_i     ),
    .mtime_gray_lf_i ( mtime_gray_lf ),
    .read_req_i      ( read_req      ),
    .mtime_binary_o  ( mtime_binary  ),
    .mtime_valid_o   ( mtime_valid   )
);


//=============================================================================
// 5)  MTIME SHADOW (BINARY) + 64-BIT ATOMICITY LATCH
//=============================================================================
// Two independent 64-bit shadows so the AHB MTIME_LO/HI atomicity contract
// cannot be corrupted by a Zicntr time_req landing between an AHB LO and
// the following AHB HI read:
//
//   - mtime_shadow_ahb_hi : 32-bit, updated ONLY on AHB-pending read
//                        completion. Holds the upper half of the atomic
//                        64-bit snapshot for the subsequent MTIME_HI
//                        read (the LO half is returned directly from
//                        mtime_binary[31:0] on the cycle mtime_valid
//                        pulses, no LO shadow needed). Firmware must
//                        read MTIME_LO first (standard RISC-V
//                        convention) -- the LO read refreshes this
//                        shadow.
//   - mtime_shadow_zicntr : 64-bit, updated ONLY on Zicntr-pending read
//                        completion. Drives time_val_o (held stable
//                        between Zicntr reads). Independent of
//                        mtime_shadow_ahb_hi so a csrr time landing
//                        between an AHB LO and HI read cannot disturb
//                        the AHB atomicity contract.

wire [31:0] mtime_shadow_ahb_hi;
wire [63:0] mtime_shadow_zicntr;

arv_ipdff #(.WIDTH(32), .ARST_EN(ARST_EN)) u_mtime_shadow_ahb_hi (
                             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(mtime_valid & (fsm_state == FSM_AHB_PEND)),
                                                                  .d_i (mtime_binary[63:32]),
                                                                  .q_o (mtime_shadow_ahb_hi));

arv_ipdff #(.WIDTH(64), .ARST_EN(ARST_EN)) u_mtime_shadow_zicntr (
                             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(mtime_valid & (fsm_state == FSM_TIME_PEND)),
                                                                  .d_i (mtime_binary),
                                                                  .q_o (mtime_shadow_zicntr));


//=============================================================================
// 6)  MTIMECMP WRITE PATH
//=============================================================================

wire    [NUM_HARTS-1:0] write_lo_pulse;
wire    [NUM_HARTS-1:0] write_hi_pulse;
wire    [NUM_HARTS-1:0] write_lo_busy;
wire    [NUM_HARTS-1:0] write_hi_busy;
wire [64*NUM_HARTS-1:0] mtimecmp_lf;
wire [32*NUM_HARTS-1:0] mtimecmp_lo_main;
wire [32*NUM_HARTS-1:0] mtimecmp_hi_main;

// Per-hart wdata fanout
// (every hart's "write data input" is the same reg_wr_data_i bus;
//  the CDC samples only the addressed hart's input on its rising-edge pulse).
wire [32*NUM_HARTS-1:0] mtimecmp_lo_w;
wire [32*NUM_HARTS-1:0] mtimecmp_hi_w;

generate
    for (gh = 0; gh < NUM_HARTS; gh = gh + 1) begin : G_WDATA_FANOUT
        assign mtimecmp_lo_w[32*gh+:32] = reg_wr_data_i;
        assign mtimecmp_hi_w[32*gh+:32] = reg_wr_data_i;

        assign write_lo_pulse[gh] = reg_active & reg_wr_en_i & mtimecmp_hart_sel[gh] & ~half_is_hi & ~write_lo_busy[gh];
        assign write_hi_pulse[gh] = reg_active & reg_wr_en_i & mtimecmp_hart_sel[gh] &  half_is_hi & ~write_hi_busy[gh];
    end
endgenerate

aclint_mtimer_write_cdc #(
    .NUM_HARTS         ( NUM_HARTS         ),
    .ARST_EN           ( ARST_EN           )
) u_write_cdc (
    .hclk_i            ( hclk_i            ),
    .hresetn_i         ( hresetn_i         ),
    .clk_lf_i          ( clk_lf_i          ),
    .resetn_lf_i       ( resetn_lf_i       ),
    .mtimecmp_lo_i     ( mtimecmp_lo_w     ),
    .mtimecmp_hi_i     ( mtimecmp_hi_w     ),
    .write_lo_pulse_i  ( write_lo_pulse    ),
    .write_hi_pulse_i  ( write_hi_pulse    ),
    .write_lo_busy_o   ( write_lo_busy     ),
    .write_hi_busy_o   ( write_hi_busy     ),
    .mtimecmp_lo_main_o( mtimecmp_lo_main  ),
    .mtimecmp_hi_main_o( mtimecmp_hi_main  ),
    .mtimecmp_lf_o     ( mtimecmp_lf       )
);


//=============================================================================
// 7)  LF-DOMAIN COUNTER + COMPARATORS
//=============================================================================

wire [NUM_HARTS-1:0] irq_m_timer_lf;

aclint_mtimer_count_lf #(
    .NUM_HARTS         ( NUM_HARTS         ),
    .ARST_EN           ( ARST_EN           )
) u_count_lf (
    .clk_lf_i          ( clk_lf_i          ),
    .resetn_lf_i       ( resetn_lf_i       ),
    .mtimecmp_lf_i     ( mtimecmp_lf       ),
    .mtime_gray_lf_o   ( mtime_gray_lf     ),
    .irq_m_timer_lf_o  ( irq_m_timer_lf    )
);


//=============================================================================
// 8)  IRQ SYNCHRONIZER (LF -> hclk_aon, per-hart, 2-FF) + MTIP SUPPRESSION
//=============================================================================
// The 2-FF synchronizer tracks the raw LF-domain comparator output.

wire [NUM_HARTS-1:0] mtimecmp_write_busy;
wire [NUM_HARTS-1:0] irq_sync;

arv_synchronizer #(
    .W                 ( NUM_HARTS         ),
    .ARST_EN           ( ARST_EN           )
) u_irq_sync (
    .clk_i             ( hclk_aon_i        ),
    .resetn_i          ( hresetn_i         ),
    .async_i           ( irq_m_timer_lf    ),
    .sync_o            ( irq_sync          )
);

assign mtimecmp_write_busy = write_lo_busy | write_hi_busy;
// CDC WAIVER: irq_m_timer_o is the combinational AND of irq_sync
// (hclk_aon_i domain) and ~mtimecmp_write_busy (hclk_i domain),
// consumed by the CPU on hclk_i. Safe under the project's
// same-source-clock contract: hclk_i and hclk_aon_i are the same
// physical clock at the SoC level (hclk_i is just the ICG-gated copy of
// hclk_aon_i). Integrators MUST guarantee this -- hclk_i must never
// come from an independent oscillator. When hclk_i is running, the two
// clocks are edge-aligned and both AND operands are stable for the
// consumer's setup window. When hclk_i is gated, the CPU consumer is
// not sampling, so the combinational output never reaches a flop.
assign irq_m_timer_o       = irq_sync & ~mtimecmp_write_busy;
assign mtimer_wake_lf_o    = irq_m_timer_lf;


//=============================================================================
// 9)  READ MUX + READY GENERATION
//=============================================================================
// MTIMECMP reads return the hclk-domain shadow registers exposed by
// aclint_mtimer_write_cdc.

reg  [31:0] mtimecmp_rd_mux;
integer ii;
always @(*) begin
    mtimecmp_rd_mux = 32'h0;
    for (ii = 0; ii < NUM_HARTS; ii = ii + 1) begin
        if (mtimecmp_hart_sel[ii]) begin
            mtimecmp_rd_mux = half_is_hi ? mtimecmp_hi_main[32*ii+:32]
                                         : mtimecmp_lo_main[32*ii+:32];
        end
    end
end

// MTIME read selects: LO returns the freshly-latched lower half on the cycle
// mtime_valid lands (AHB-pending case); HI returns the buffered upper half
// from the same atomic snapshot (mtime_shadow_ahb_hi).
wire [31:0] mtime_lo_rd = mtime_binary[31:0];
wire [31:0] mtime_hi_rd = mtime_shadow_ahb_hi;

reg  [31:0] reg_rd_data_r;
always @(*) begin
    reg_rd_data_r = 32'h0;
    if (reg_active & ~reg_wr_en_i) begin
        if      (addr_in_mtimecmp) reg_rd_data_r = mtimecmp_rd_mux;
        else if (addr_is_mtime_hi) reg_rd_data_r = mtime_hi_rd;
        else if (addr_is_mtime_lo) reg_rd_data_r = mtime_lo_rd;
    end
end

assign reg_rd_data_o = reg_rd_data_r;

// reg_ready_o is low while:
//   (a) the AHB master is doing a MTIME_LO read and the CDC has not yet
//       returned (FSM in AHB_PEND, or about to enter it this cycle), OR
//   (b) the AHB master is writing a busy MTIMECMP half.
wire mtimecmp_write_stall = reg_active & reg_wr_en_i & addr_in_mtimecmp & (
                                (~half_is_hi & (|(write_lo_busy & mtimecmp_hart_sel))) |
                                ( half_is_hi & (|(write_hi_busy & mtimecmp_hart_sel)))
                            );

wire mtime_lo_read_stall = ahb_mtime_lo_read & (
                               ((fsm_state == FSM_AHB_PEND) & ~mtime_valid) |
                                (fsm_state == FSM_IDLE)                     |
                                (fsm_state == FSM_TIME_PEND)
                            );

assign reg_ready_o = ~mtime_lo_read_stall & ~mtimecmp_write_stall;


//=============================================================================
// 10) ZICNTR TIME RESPONSE
//=============================================================================
// time_val_o is the registered Zicntr shadow (mtime_shadow_zicntr),
// held stable between Zicntr reads and independent of the AHB shadow
// so the two paths cannot corrupt each other (see Section 5).
// time_gnt_r is a 1-cycle delayed flop of `(TIME_PEND & mtime_valid)`;
// the shadow is updated on the same edge that drives time_gnt_r high,
// so the (time_val_o, time_gnt_o) pair is coherent on the cycle the
// consumer latches the grant.

wire time_gnt_r;
arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_time_gnt_r (
                   .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                        .d_i ((fsm_state == FSM_TIME_PEND) & mtime_valid),
                                                        .q_o (time_gnt_r));

assign time_gnt_o = time_gnt_r;
assign time_val_o = mtime_shadow_zicntr;


//=============================================================================
// 11) SOC-LEVEL CLOCK-GATE ADVISORY
//=============================================================================
// mtimer_active_o is HIGH whenever internal mtimer flops still need hclk_i
// edges to drain.

assign mtimer_active_o = (fsm_state != FSM_IDLE)         |
                         (|write_lo_busy)                |
                         (|write_hi_busy)                |
                         (time_req_i | time_req_pending) |
                          time_gnt_r                     ;


//=============================================================================
// 12) PARAMETER RANGE CHECK
//=============================================================================
// pragma translate_off
generate
    if ((NUM_HARTS < 1) || (NUM_HARTS > 16)) begin : CHECK_NUM_HARTS
        initial $fatal(1, "aclint_mtimer: NUM_HARTS (%0d) must be 1..16.", NUM_HARTS);
    end
    if (REG_AW < 8) begin : CHECK_REG_AW
        initial $fatal(1, "aclint_mtimer: REG_AW (%0d) must be >= 8 (need to address MTIME_HI = 8*NUM_HARTS+4 for NUM_HARTS up to 16).", REG_AW);
    end
endgenerate
// pragma translate_on


//=============================================================================
// 13) LINT CLEANUP
//=============================================================================
// The mtime_binary bus is consumed directly (LO read tap) and via two
// shadow latches (mtime_shadow_ahb_hi for the AHB HI read mux,
// mtime_shadow_zicntr for time_val_o). All consumers are real; nothing to
// tie off.

wire   hart_byte_index_unused;
assign hart_byte_index_unused = |hart_byte_index[REG_AW-1:4];

endmodule // aclint_mtimer

`default_nettype wire
