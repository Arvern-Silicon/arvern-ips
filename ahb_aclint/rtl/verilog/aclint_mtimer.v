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
// ADDRESS MAP (byte offsets within the 32-KB MTIMER window, word-aligned):
//      0x0000 + 8*hart : MTIMECMP_LO[hart]      0x7FF8 : MTIME_LO
//      0x0004 + 8*hart : MTIMECMP_HI[hart]      0x7FFC : MTIME_HI
//
// MTIME sits at the top of the window per ACLINT 1.0-rc4 Table 2, so a
// CLINT-compatible map puts it at the legacy 0x0200_BFF8 and its address does
// not move with NUM_HARTS.
//
// STRUCTURE
//   clk_lf_i is sampled AS DATA and turned into a one-cycle tick (see
//   aclint_lf_tick.v, which owns the mechanism and its guarantees). LF_SYNC_EN
//   chooses only where the counter lives: clk_lf_i flops, which survive
//   hclk_aon_i stopping and can wake the oscillator (0), or hclk_aon_i gated by
//   the tick, which is single-clock but gives up osc-off deep sleep (1).
//
//   Writes, MTIMECMP reads and MTIME_HI reads never stall. The only wait state is
//   an MTIME_LO read while mirror_valid is low -- out of reset and once per
//   deep-sleep exit. That lasts up to two LF periods and typically one: trust
//   returns six hclk edges after the clock does (two through the release
//   synchronizer, four of pipeline warm-up), and the wait is then simply for the
//   next tick.
//
//   Every hclk_aon_i flop freezes at its pre-sleep value while the oscillator is
//   stopped, so on resume nothing in this domain can tell that time passed; only
//   the LF domain can. mirror_valid and the tick warm-up counter are therefore
//   reset by lf_trust_rstn_o, which falls combinationally as hclk_aon_en_i drops,
//   and trust is withdrawn before the clock stops in EITHER reset style: the
//   asynchronous build clears on that falling edge, the synchronous build on the
//   one further hclk_aon_i edge the oscillator controller delivers after
//   deasserting hclk_aon_en_i (its port contract in ahb_aclint.v).
//
//   The full CDC argument, including the SDC constraints it depends on, is in
//   doc/ahb_aclint.md.
//----------------------------------------------------------------------------
`default_nettype none

module  aclint_mtimer #(
    parameter                        NUM_HARTS  =  1,     // Number of harts (1..16)
    parameter                        REG_AW     = 15,     // Reg-bank address width in bytes. Must be >= 15
    parameter                        LF_SYNC_EN = 1'b0,   // 0 = clk_lf_i is an independent oscillator; 1 = synchronous mode
    parameter                        ARST_EN    = 1'b1    // Reset style: 1=asynchronous, 0=synchronous
) (

// CLOCKS & RESETS
    input  wire                      hclk_i,              // AHB clock (gated by hclk_en_o at the SoC-level ICG)
    input  wire                      hclk_aon_i,          // Always-on clock, stopped only in osc-off deep sleep
    input  wire                      hresetn_i,           // Active-low reset (hclk + hclk_aon); asynchronous when ARST_EN=1
    input  wire                      clk_lf_i,            // Timebase source
    input  wire                      resetn_lf_i,         // Active-low reset (LF); asynchronous when ARST_EN=1. UNUSED under LF_SYNC_EN -- tie high.
    input  wire                      hclk_aon_en_i,       // From the SoC oscillator controller. Deasserted synchronously one edge BEFORE the clock stops;
                                                          // asserted asynchronously on wake, before it restarts.
    input  wire                      scan_mode_i,         // 1 = scan/test mode; see aclint_lf_tick. Tie LOW functionally.

// GENERIC REGISTER-BANK INTERFACE (from top-level decoder)
    input  wire                      reg_sel_i,           // Access in flight to this sub-component
    input  wire         [REG_AW-1:0] reg_addr_i,          // Byte address inside MTIMER window
    input  wire                      reg_wr_en_i,         // 1 = write, 0 = read
    input  wire               [31:0] reg_wr_data_i,       // Write data
    output wire               [31:0] reg_rd_data_o,       // Read data (0 when not selected)
    output wire                      reg_ready_o,         // 1 = transfer can complete this cycle

// PER-HART MTIMER INTERRUPT
    output wire      [NUM_HARTS-1:0] irq_m_timer_o,       // MTIP per hart
    output wire                      mtimer_wake_lf_o,    // Wake-up for the SoC's LF-domain power controller to restart the main oscillator.

// ZICNTR TIME INTERFACE
    input  wire                      time_req_i,          // LEVEL: a Zicntr read is outstanding, held until granted
    output wire                      time_gnt_o,          // 1-hclk_i cycle pulse: time_val_o is valid this cycle
    output wire               [63:0] time_val_o,          // 64-bit MTIME snapshot, stable between Zicntr reads

// SOC-LEVEL CLOCK-GATE ADVISORY
    output wire                      mtimer_active_o      // HIGH while a write is crossing to LF, or a Zicntr read is unserved
);


//=============================================================================
// 1)  CONSTANTS / LOCAL PARAMETERS
//=============================================================================

// SEPARATE constants, deliberately: sharing one is what would make the MTIME
// address move with NUM_HARTS.
localparam       [31:0] MTIMECMP_LIMIT_INT = 8 * NUM_HARTS;
localparam [REG_AW-1:0] MTIMECMP_LIMIT     = MTIMECMP_LIMIT_INT[REG_AW-1:0];

localparam       [31:0] MTIME_LO_ADDR_INT  = 32'h7FF8;
localparam       [31:0] MTIME_HI_ADDR_INT  = 32'h7FFC;
localparam [REG_AW-1:0] MTIME_LO_ADDR      = MTIME_LO_ADDR_INT[REG_AW-1:0];
localparam [REG_AW-1:0] MTIME_HI_ADDR      = MTIME_HI_ADDR_INT[REG_AW-1:0];


//=============================================================================
// 2)  ADDRESS DECODE
//=============================================================================

wire reg_active       =  reg_sel_i;

// Word-alignment is part of the decode, deliberately. Without it this is a pure
// RANGE compare, so reg_addr_i[1:0] is ignored and every sub-word offset ALIASES
// onto the register below it -- while MTIME, decoded by exact compare, RAZ/WIs
// the same offsets. Two behaviours in one window, and the aliasing one is the
// dangerous half: aRVern replicates a store byte across all four lanes
// (arv_load_store.v), so `sb x0, 1(msip)` would land in bit 0 and clear a
// pending IPI. Sub-word accesses RAZ/WI everywhere, consistently.
wire addr_in_mtimecmp = (reg_addr_i <  MTIMECMP_LIMIT) & (reg_addr_i[1:0] == 2'b00);
wire addr_is_mtime_lo = (reg_addr_i == MTIME_LO_ADDR);
wire addr_is_mtime_hi = (reg_addr_i == MTIME_HI_ADDR);

wire    [REG_AW-1:0] hart_byte_index = (reg_addr_i >> 3);  // /8 = hart number
wire           [3:0] hart_idx        =  hart_byte_index[3:0];
wire                 half_is_hi      =  reg_addr_i[2];

wire [NUM_HARTS-1:0] mtimecmp_hart_sel;
genvar gh;
generate
    for (gh = 0; gh < NUM_HARTS; gh = gh + 1) begin : G_HART_SEL
        assign mtimecmp_hart_sel[gh] = addr_in_mtimecmp & (hart_idx == gh[3:0]);
    end
endgenerate

// Write strobes. Unconditional -- there is nothing to be busy with, so no
// transfer is ever refused or repeated.
wire [NUM_HARTS-1:0] mtimecmp_lo_wr;
wire [NUM_HARTS-1:0] mtimecmp_hi_wr;
generate
    for (gh = 0; gh < NUM_HARTS; gh = gh + 1) begin : G_CMP_WR
        assign mtimecmp_lo_wr[gh] = reg_active & reg_wr_en_i & mtimecmp_hart_sel[gh] & ~half_is_hi;
        assign mtimecmp_hi_wr[gh] = reg_active & reg_wr_en_i & mtimecmp_hart_sel[gh] &  half_is_hi;
    end
endgenerate

wire mtime_lo_wr = reg_active & reg_wr_en_i & addr_is_mtime_lo;
wire mtime_hi_wr = reg_active & reg_wr_en_i & addr_is_mtime_hi;


//=============================================================================
// 3)  LF OBSERVATION
//=============================================================================
// clk_lf_i is sampled as data and edge-detected into a tick in BOTH modes;
// LF_SYNC_EN selects only where the counter lives. The minimum clk_lf:hclk_aon
// ratio and scan_mode_i therefore apply to both. See aclint_lf_tick.v.

wire        lf_tick;        // trusted: suppressed while the observation pipeline may be stale
wire        lf_trust_rstn;  // async-asserted from the LF domain; resets tick-derived state
wire        clk_lf_use;
wire        resetn_lf_use;
wire        lf_en;
wire [63:0] mtime_view;

aclint_lf_tick #(
    .ARST_EN           ( ARST_EN       )
) u_lf_tick (
    .hclk_aon_i        ( hclk_aon_i    ),
    .hresetn_i         ( hresetn_i     ),
    .clk_lf_i          ( clk_lf_i      ),
    .hclk_aon_en_i     ( hclk_aon_en_i ),
    .scan_mode_i       ( scan_mode_i   ),
    .lf_tick_o         ( lf_tick       ),
    .lf_trust_rstn_o   ( lf_trust_rstn )
);

generate
if (LF_SYNC_EN != 0) begin : g_lf_sync
    assign clk_lf_use           = hclk_aon_i;
    assign resetn_lf_use        = hresetn_i;
    assign lf_en                = lf_tick;      // the counter advances on the tick

    // No mirror to invalidate in this mode, so the trust reset has no consumer.
    wire   lf_trust_rstn_unused = lf_trust_rstn;
end else begin : g_lf_async
    assign clk_lf_use           = clk_lf_i;
    assign resetn_lf_use        = resetn_lf_i;
    assign lf_en                = 1'b1;         // the counter advances on its own clock
end
endgenerate


//=============================================================================
// 4)  WRITE SHADOWS (NO HANDSHAKE, NO BACK-PRESSURE)
//=============================================================================

wire [64*NUM_HARTS-1:0] mtimecmp_main;
wire [64*NUM_HARTS-1:0] mtimecmp_cmp;
wire             [63:0] mtime_wr_main;
wire                    load_req;
wire             [63:0] load_val;
wire              [1:0] load_we;
wire                    mtime_lo_pending;
wire                    mtime_hi_pending;
wire                    wr_pending;

aclint_mtimer_wr_shadow #(
    .NUM_HARTS          ( NUM_HARTS        ),
    .ARST_EN            ( ARST_EN          )
) u_wr_shadow (
    .hclk_i             ( hclk_i           ),
    .hclk_aon_i         ( hclk_aon_i       ),
    .hresetn_i          ( hresetn_i        ),

    .lf_tick_i          ( lf_tick          ),

    .wr_data_i          ( reg_wr_data_i    ),
    .mtimecmp_lo_wr_i   ( mtimecmp_lo_wr   ),
    .mtimecmp_hi_wr_i   ( mtimecmp_hi_wr   ),
    .mtime_lo_wr_i      ( mtime_lo_wr      ),
    .mtime_hi_wr_i      ( mtime_hi_wr      ),

    .mtimecmp_main_o    ( mtimecmp_main    ),
    .mtime_wr_main_o    ( mtime_wr_main    ),
    .mtimecmp_cmp_o     ( mtimecmp_cmp     ),
    .load_req_o         ( load_req         ),
    .load_val_o         ( load_val         ),
    .load_we_o          ( load_we          ),
    .mtime_lo_pending_o ( mtime_lo_pending ),
    .mtime_hi_pending_o ( mtime_hi_pending ),
    .wr_pending_o       ( wr_pending       )
);


//=============================================================================
// 5)  LF-RESIDENT COUNTER + COMPARATORS
//=============================================================================

wire             [63:0] mtime_lf;
wire                    load_ack_lf;
wire [NUM_HARTS-1:0]    wake_lf;

aclint_mtimer_count_lf #(
    .NUM_HARTS          ( NUM_HARTS        ),
    .LF_SYNC_EN         ( LF_SYNC_EN       ),
    .ARST_EN            ( ARST_EN          )
) u_count_lf (
    .clk_lf_i           ( clk_lf_use       ),
    .resetn_lf_i        ( resetn_lf_use    ),

    .lf_en_i            ( lf_en            ),
    .mtimecmp_i         ( mtimecmp_cmp     ),
    .load_req_i         ( load_req         ),
    .load_val_i         ( load_val         ),
    .load_we_i          ( load_we          ),

    .mtime_lf_o         ( mtime_lf         ),
    .load_ack_lf_o      ( load_ack_lf      ),
    .wake_lf_o          ( wake_lf          )
);


//=============================================================================
// 6)  MTIME READ VIEW
//=============================================================================
// Asynchronous mode needs a mirror: the counter is in another clock domain and
// can only be sampled safely on the tick. Synchronous mode does not -- the
// counter is already in the reading domain -- so the mirror and its valid bit
// are parameterized away rather than left as redundant flops.

wire mirror_valid;

generate
if (LF_SYNC_EN != 0) begin : g_view_sync

    // Same domain: read the counter directly, and it is never stale because
    // there is no second clock that could keep running while this one stops.
    assign mtime_view   = mtime_lf;
    assign mirror_valid = 1'b1;

end else begin : g_view_async

    // Captured on the tick, i.e. at least 3 hclk AFTER the clk_lf_i edge, when
    // every bit has settled. This is the crossing the SDC max-delay constraint
    // (3 * CLOCK_PERIOD, see aclint_lf_tick.v) covers.
    wire [63:0] mtime_mirror;

    arv_ipdff #(.WIDTH(64), .ARST_EN(ARST_EN)) u_mtime_mirror (
                  .clk_i(hclk_aon_i), .rst_n_i(hresetn_i), .en_i(lf_tick),
                                                           .d_i (mtime_lf), .q_o(mtime_mirror));

    // Valid once a trusted tick has loaded the mirror. The ASYNC reset is the
    // point: hclk_aon_i is already stopped when trust is withdrawn, so nothing
    // clocked here could clear this flop and it would freeze at "valid",
    // serving an hours-old mirror on resumption.
    arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_mirror_valid (
                  .clk_i(hclk_aon_i), .rst_n_i(lf_trust_rstn), .en_i(lf_tick),
                                                               .d_i (1'b1), .q_o(mirror_valid));

    assign mtime_view = mtime_mirror;

end
endgenerate

// READ-AFTER-WRITE. A write is not on the counter until the next LF edge, so
// while a load is outstanding the read path returns the value the counter is
// ABOUT to take. This preserves MMIO write-then-read semantics at zero cost;
// the value is early rather than wrong.
//
// Selected PER HALF. A shadow half holds the last value written THERE, not the
// live count, so a LO-only write must not switch the HI read onto the shadow --
// that would report a stale HI (0 out of reset) for the LF period the write
// takes to cross.
wire [63:0] mtime_rd_src;

assign mtime_rd_src[31:0]  = mtime_lo_pending ? mtime_wr_main[31:0]  : mtime_view[31:0];
assign mtime_rd_src[63:32] = mtime_hi_pending ? mtime_wr_main[63:32] : mtime_view[63:32];


//=============================================================================
// 7)  MTIP -- COMPARED ON THE hclk SIDE
//=============================================================================
// Two comparators against two copies of MTIMECMP, deliberately:
//
//   irq_m_timer_o    : the READ view vs the hclk-side register -- exactly the
//                      two values firmware reads back, so MTIP cannot contradict
//                      a read of MTIME and MTIMECMP. Both operands are
//                      hclk_aon_i, so it needs no synchronizer and reacts to a
//                      write in ONE cycle. An LF-sourced MTIP would instead show
//                      the old deadline as met for the LF period a write takes
//                      to cross, and a handler that reprograms then MRETs would
//                      re-trap.
//   mtimer_wake_lf_o : the LF-resident comparator, which must stay there because
//                      it restarts a stopped oscillator. Built only under
//                      LF_SYNC_EN=0; asserted permanently otherwise, so that a
//                      controller honouring the wake can never stop the clock
//                      that MTIME then runs on.
//
// They disagree for the duration of a write -- bounded and self-correcting: a
// WFI'd hart wakes, finds nothing pending, re-sleeps. A stale mirror can only
// under-report, so it may delay MTIP but never invent one.

genvar gm;
generate
    for (gm = 0; gm < NUM_HARTS; gm = gm + 1) begin : G_MTIP
        assign irq_m_timer_o[gm] = (mtime_rd_src >= mtimecmp_main[64*gm +: 64]);
    end
endgenerate

// ORed across harts deliberately. The consumer is a power controller restarting
// the MAIN OSCILLATOR, which is inherently system-wide -- it has no use for the
// hart index, and per-hart wiring is one more thing an integrator can get wrong.
// Which hart expired is carried by irq_m_timer_o[] once the clock is back.
assign mtimer_wake_lf_o = |wake_lf;


//=============================================================================
// 8)  64-BIT READ ATOMICITY
//=============================================================================
// The mirror is one coherent register, so the snapshot needs no CDC assembly --
// but it is still assembled across two AHB transfers, and a tick can land
// between the LO read and the HI read. Latching the upper half on the LO read
// implements the documented "read MTIME_LO first" contract for one register.

wire        ahb_mtime_lo_read = reg_active & ~reg_wr_en_i & addr_is_mtime_lo;
wire [31:0] mtime_shadow_ahb_hi;

arv_ipdff #(.WIDTH(32), .ARST_EN(ARST_EN)) u_mtime_shadow_ahb_hi (
              .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(ahb_mtime_lo_read & mirror_valid),
                                                   .d_i (mtime_rd_src[63:32]),
                                                   .q_o (mtime_shadow_ahb_hi));


//=============================================================================
// 9)  READ MUX + READY GENERATION
//=============================================================================

reg  [31:0] mtimecmp_rd_mux;
integer ii;
always @(*) begin
    mtimecmp_rd_mux = 32'h0;
    for (ii = 0; ii < NUM_HARTS; ii = ii + 1) begin
        if (mtimecmp_hart_sel[ii]) begin
            mtimecmp_rd_mux = half_is_hi ? mtimecmp_main[64*ii+32 +: 32]
                                         : mtimecmp_main[64*ii    +: 32];
        end
    end
end

reg  [31:0] reg_rd_data_r;
always @(*) begin
    reg_rd_data_r = 32'h0;
    if (reg_active & ~reg_wr_en_i) begin
        if      (addr_in_mtimecmp) reg_rd_data_r = mtimecmp_rd_mux;
        else if (addr_is_mtime_hi) reg_rd_data_r = mtime_shadow_ahb_hi;
        else if (addr_is_mtime_lo) reg_rd_data_r = mtime_rd_src[31:0];
    end
end

assign reg_rd_data_o = reg_rd_data_r;

// The only stall. Writes and MTIMECMP reads never stall, and an MTIME_LO read
// stalls solely while the mirror is invalid -- out of reset and once per
// deep-sleep exit. MTIME_HI returns the snapshot taken by the last MTIME_LO read,
// which a wait would not refresh, so it never stalls.
wire mtime_read_stall = reg_active & ~reg_wr_en_i & addr_is_mtime_lo & ~mirror_valid;

assign reg_ready_o = ~mtime_read_stall;


//=============================================================================
// 10) ZICNTR TIME RESPONSE
//=============================================================================
// time_req_i is a LEVEL held by the consumer until granted. The grant is a
// 1-cycle pulse one hclk after the request, so a csrr time costs a single
// cycle. ~time_gnt_r blocks a re-grant only on the cycle after a grant, so the
// consumer must drop the request by then or it is granted again. The
// snapshot is latched on the same edge that raises the grant, so the
// (time_val_o, time_gnt_o) pair is coherent for the consumer.
// The grant is also held off for the cycle of an MTIME write strobe.

wire time_gnt_r;
wire time_grant_now = time_req_i & mirror_valid & ~(mtime_lo_wr | mtime_hi_wr) & ~time_gnt_r;

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_time_gnt_r (
              .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                   .d_i (time_grant_now), .q_o(time_gnt_r));

wire [63:0] mtime_shadow_zicntr;

arv_ipdff #(.WIDTH(64), .ARST_EN(ARST_EN)) u_mtime_shadow_zicntr (
              .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(time_grant_now),
                                                   .d_i (mtime_rd_src), .q_o(mtime_shadow_zicntr));

assign time_gnt_o = time_gnt_r;
assign time_val_o = mtime_shadow_zicntr;


//=============================================================================
// 11) SOC-LEVEL CLOCK-GATE ADVISORY
//=============================================================================
// What genuinely needs the clock: any write still crossing to the LF domain, and
// an unserved Zicntr read.
//
// For MTIME the hold is liveness only -- the LF-side one-shot makes a stopped
// clock harmless, the request just has to retire eventually. For MTIMECMP it is
// CORRECTNESS: `sw mtimecmp; wfi` would otherwise stop the oscillator with the
// new deadline still in the write shadow, leaving the LF comparator on the old
// one with nothing left running to wake the chip.
//
// ~mirror_valid is deliberately NOT a term here, though the mirror does need a
// tick to revalidate. Losing the clock is what invalidates the mirror, so adding
// it would make the block demand its clock back the instant the clock is taken
// away -- and with hclk_aon_en built as the OR of every IP's request that is a
// livelock the chip can never sleep through.
//
// An invalid mirror during sleep is harmless: reading it needs hclk. When a read
// does arrive, aph_valid/dph_valid hold the clock up for the transfer, ticks
// resume, and the mirror revalidates on its own -- which is what bounds the
// stall without this term.

assign mtimer_active_o = wr_pending | time_req_i | time_gnt_r;


//=============================================================================
// 12) PARAMETER RANGE CHECK
//=============================================================================
// pragma translate_off
generate
    if ((NUM_HARTS < 1) || (NUM_HARTS > 16)) begin : CHECK_NUM_HARTS
        initial $fatal(1, "aclint_mtimer: NUM_HARTS (%0d) must be 1..16.", NUM_HARTS);
    end
    if (REG_AW < 15) begin : CHECK_REG_AW
        initial $fatal(1, "aclint_mtimer: REG_AW (%0d) must be >= 15 (MTIME_HI sits at offset 0x7FFC, the top of a 32-KB MTIMER window).", REG_AW);
    end
endgenerate
// pragma translate_on


//=============================================================================
// 13) LINT CLEANUP
//=============================================================================

generate
if (LF_SYNC_EN != 0) begin : g_lf_ports_unused
    // Synchronous mode: nothing is clocked by clk_lf_i, so its reset has no
    // consumer. The port stays for pin compatibility -- tie it high. clk_lf_i
    // itself IS used, as the sampled timebase source.
    wire resetn_lf_unused = resetn_lf_i;
end
endgenerate

wire   hart_byte_index_unused;
assign hart_byte_index_unused = |hart_byte_index[REG_AW-1:4];

// LF-domain load strobe. Not consumed by the design -- it exists so a testbench
// can count loads and prove the one-shot admits exactly one per request.
wire   load_ack_lf_unused;
assign load_ack_lf_unused = load_ack_lf;

endmodule // aclint_mtimer

`default_nettype wire
