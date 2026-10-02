//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    plic_target
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : plic_target.v
// Module Description : PLIC per-context target block: threshold register +
//                      priority-encoded arbiter + claim/complete handshake.
//                      Instantiated NUM_CONTEXTS times by the top wrapper.
//
//                      Arbiter rule: among sources s in [1..NUM_SOURCES]
//                      where pending_i[s] & enable_i[s] & (priority_i[s] !=
//                      0), pick the one with the highest priority (the
//                      threshold does not apply to the claim); ties broken by
//                      lowest source ID. Output is
//                      top_source_id_o (0 if none qualify); irq_o is high
//                      when a qualifying source has priority > threshold.
//
//                      Address map (3-bit byte address inside the per-target
//                      register area):
//                        0x0 : threshold (read-write, PRIO_BITS in LSBs).
//                        0x4 : claim/complete.
//                              Read  : returns top_source_id_o (32-bit zero
//                                      extended). If the access is a read
//                                      and top is non-zero, asserts a
//                                      one-cycle claim_pulse_o with
//                                      claim_source_id_o = top.
//                              Write : asserts a one-cycle complete_pulse_o
//                                      with complete_source_id_o =
//                                      reg_wr_data_i[10:0], only for a valid
//                                      ID (1..NUM_SOURCES as a whole word,
//                                      enabled for this context).
//
//                      Pulses are masked with the pulse condition: when the
//                      pulse is low, the corresponding *_source_id_o output
//                      is 11'h0. This lets the top wrapper combine the
//                      per-context pulses with a flat bit-wise OR.
//----------------------------------------------------------------------------
`default_nettype none

module  plic_target #(
    parameter                                   NUM_SOURCES = 31,        // Number of interrupt sources (1..1023)
    parameter                                   PRIO_BITS   = 3,         // Priority width (1..7)
    parameter                                   REG_AW      = 3,         // Reg-bank byte-address width (per-target window)
    parameter                                   ARST_EN     = 1'b1       // Reset architecture: 1=async active-low, 0=synchronous (passed to arv_ipdff)
) (

// CLOCK & RESET
    input  wire                                 hclk_i,                  // AHB clock
    input  wire                                 hresetn_i,               // Active-low async reset (sync-deassert)

// PER-SOURCE STATUS FROM CENTRAL BLOCKS
    input  wire                 [NUM_SOURCES:0] pending_i,               // Per-source pending bits
    input  wire                 [NUM_SOURCES:0] enable_i,                // Per-source enable bits (this context only)
    input  wire [PRIO_BITS*(NUM_SOURCES+1)-1:0] priority_i,              // Per-source priority (flat-packed)

// GENERIC REGISTER-BANK INTERFACE
    input  wire                                 reg_sel_i,               // Access in flight to this target
    input  wire                    [REG_AW-1:0] reg_addr_i,              // Byte address inside the per-target window
    input  wire                                 reg_wr_en_i,             // 1 = write, 0 = read
    input  wire                          [31:0] reg_wr_data_i,           // Write data
    output wire                          [31:0] reg_rd_data_o,           // Read data (0 when not selected)
    output wire                                 reg_ready_o,             // Always 1 (single-cycle)

// CLAIM / COMPLETE PULSES
    output wire                                 claim_pulse_o,           // 1-cycle: claim accepted on a read of 0x4
    output wire                          [10:0] claim_source_id_o,       // = top_source_id_o when pulse high, else 0
    output wire                                 complete_pulse_o,        // 1-cycle: complete written on a write of 0x4
    output wire                          [10:0] complete_source_id_o,    // = reg_wr_data_i[10:0] when pulse high, else 0

// IRQ + TOP-SOURCE STATUS (combinational)
    output wire                                 irq_o,                   // 1 when a qualifying source has priority > threshold
    output wire                          [10:0] top_source_id_o          // Winning source ID; 0 if none qualify
);


//=============================================================================
// 1)  THRESHOLD REGISTER
//=============================================================================
// PRIO_BITS-wide, reset 0. Written when reg_sel_i & reg_wr_en_i and the
// 3-bit byte address is 0x0 (i.e. reg_addr_i[2]==0). The byte-lane bits
// reg_addr_i[1:0] are ignored.

wire access_thresh = reg_sel_i & ~reg_addr_i[2];
wire access_claim  = reg_sel_i &  reg_addr_i[2];

wire [PRIO_BITS-1:0] threshold;

arv_ipdff #(.WIDTH(PRIO_BITS), .ARST_EN(ARST_EN)) u_threshold (
                          .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(access_thresh & reg_wr_en_i),
                                                               .d_i (reg_wr_data_i[PRIO_BITS-1:0]),
                                                               .q_o (threshold));


//=============================================================================
// 2)  PRIORITY ARBITER
//=============================================================================
//   Claim winner: highest-priority (pending & enable & priority != 0) source,
//   IGNORING the threshold. Per PLIC 1.0.0, Chapter 8: "The claim operation is
//   not affected by the setting of the priority threshold register." Feeds the
//   claim read data and the claim pulse. Ties go to the lowest source ID.
//
//   irq_o: some qualifying source has priority > threshold (Chapter 7: the
//   PLIC masks interrupts of priority <= threshold). Only the existence of
//   such a source matters, so it is an OR-reduce, not a second max.
//
// The claim winner is a binary tree over the sources, depth clog2(NUM_SOURCES+1):
// each node keeps its right (higher-ID) child only if that child is valid and
// has a strictly higher priority, so a tie keeps the left (lower-ID) child.
// Source 0 is a leaf that never qualifies (priority and pending hard-tied 0).
// Per RISC-V PLIC 1.0 Chapter 4: "A priority value of 0 is reserved to mean
// 'never interrupt' and effectively disables the interrupt."

// Sized casts of the unsigned NUM_SOURCES parameter so loop bounds and array
// indices stay width-clean for both DC (no VER-318) and Verilator.
localparam        [31:0] NUM_SOURCES_INT = NUM_SOURCES;
localparam        [10:0] NUM_SOURCES_S11 = NUM_SOURCES_INT[10:0];
localparam               SRC_IDX_W       = $clog2(NUM_SOURCES + 1);

localparam LEAF_W = (NUM_SOURCES < 1) ? 1 : $clog2(NUM_SOURCES + 1);
localparam NLEAF  = 1 << LEAF_W;                 // leaves: sources 0..NLEAF-1

// One vector set per tree level: level 0 holds the leaves (source i at index
// i), level l+1 node k combines level-l nodes 2k (lower IDs) and 2k+1; the
// root is level LEAF_W, node 0.
wire [NUM_SOURCES:1] qual_irq;

genvar gl, gk;
generate
    for (gl = 0; gl <= LEAF_W; gl = gl + 1) begin : G_LVL
        localparam NN = NLEAF >> gl;
        wire [NN-1:0]           v;
        wire [NN*PRIO_BITS-1:0] p;
        wire [NN*LEAF_W-1:0]    id;
        if (gl == 0) begin : G_LEAVES
            for (gk = 0; gk < NLEAF; gk = gk + 1) begin : G_LEAF
                if ((gk >= 1) && (gk <= NUM_SOURCES)) begin : G_SRC
                    wire [PRIO_BITS-1:0] prio = priority_i[PRIO_BITS*gk +: PRIO_BITS];
                    wire                 qual = pending_i[gk] & enable_i[gk] & (prio != {PRIO_BITS{1'b0}});
                    assign v[gk]                          = qual;
                    assign p[PRIO_BITS*gk +: PRIO_BITS]   = prio;
                    assign qual_irq[gk]                   = qual & (prio > threshold);
                end else begin : G_NONE
                    assign v[gk]                          = 1'b0;
                    assign p[PRIO_BITS*gk +: PRIO_BITS]   = {PRIO_BITS{1'b0}};
                end
                assign id[LEAF_W*gk +: LEAF_W] = gk[LEAF_W-1:0];
            end
        end else begin : G_NODES
            for (gk = 0; gk < NN; gk = gk + 1) begin : G_NODE
                wire                 lv = G_LVL[gl-1].v[2*gk];
                wire                 rv = G_LVL[gl-1].v[2*gk+1];
                wire [PRIO_BITS-1:0] lp = G_LVL[gl-1].p[PRIO_BITS*(2*gk)   +: PRIO_BITS];
                wire [PRIO_BITS-1:0] rp = G_LVL[gl-1].p[PRIO_BITS*(2*gk+1) +: PRIO_BITS];
                wire [LEAF_W-1:0]    li = G_LVL[gl-1].id[LEAF_W*(2*gk)   +: LEAF_W];
                wire [LEAF_W-1:0]    ri = G_LVL[gl-1].id[LEAF_W*(2*gk+1) +: LEAF_W];
                wire                 take_r = rv & (~lv | (rp > lp));
                assign v[gk]                        = lv | rv;
                assign p[PRIO_BITS*gk +: PRIO_BITS] = take_r ? rp : lp;
                assign id[LEAF_W*gk +: LEAF_W]      = take_r ? ri : li;
            end
        end
    end
endgenerate

wire [10:0] top_id_claim = G_LVL[LEAF_W].v[0] ? {{(11-LEAF_W){1'b0}}, G_LVL[LEAF_W].id[LEAF_W-1:0]} : 11'h0;

assign top_source_id_o = top_id_claim;
assign irq_o           = |qual_irq;


//=============================================================================
// 3)  CLAIM / COMPLETE PULSE GENERATION
//=============================================================================
// Claim pulse:    read of 0x4 with a non-zero claim-side top source ->
//                 1-cycle pulse. Claim returns the threshold-INDEPENDENT
//                 top (see arbiter comment above).
// Complete pulse: write of 0x4 -> 1-cycle pulse, ID = reg_wr_data_i[10:0],
//                 BUT silently dropped if the target's enable bit for that
//                 source is 0 (or the ID is 0 / out of range). Per PLIC 1.0.0
//                 spec, Chapter 9: "If the completion ID does not match an
//                 interrupt source that is currently enabled for the target,
//                 the completion is silently ignored."
// Both pulse generators are gated to one cycle by reg_sel_i, which the AHB
// top guarantees is one-cycle (every sub-block is single-cycle, hreadyout_o=1,
// so dph_valid is asserted for exactly one cycle per transfer).

assign claim_pulse_o        = access_claim & ~reg_wr_en_i & (top_id_claim != 11'h0);
assign claim_source_id_o    = claim_pulse_o ? top_id_claim : 11'h0;

// Per-target enable check for completion: id in 1..NUM_SOURCES AND enable_i[id]=1.
// enable_i[0] is hard-tied 0 by plic_enable, so id=0 also drops the pulse via
// the same gate -- explicit upper-bound check keeps the dropout deterministic
// for out-of-range ids.
//
// `complete_id_enabled` is OR-AND-decoded across the 1..NUM_SOURCES range so
// the index is always in-bounds of `enable_i`. The textbook form
//     enable_i[complete_id_w[EN_IDX_W-1:0]]
// would index outside `enable_i[NUM_SOURCES:0]` whenever `NUM_SOURCES+1` is
// not a power of two (e.g. NUM_SOURCES=50,100) -- functionally masked by
// `complete_id_in_range` but a real X-prop hazard in sim.

// The ID is the whole data word: a value with any bit above [10] set is out of
// range, not an alias of its low bits.
wire [10:0]            complete_id_w        = reg_wr_data_i[10:0];
wire                   complete_id_in_range = (complete_id_w != 11'h0) &
                                              (complete_id_w <= NUM_SOURCES[10:0]) &
                                              ~|reg_wr_data_i[31:11];

reg          complete_id_enabled_r;
reg   [10:0] ee;    // 1..NUM_SOURCES (max 1023)
always @* begin
    complete_id_enabled_r = 1'b0;
    for (ee = 11'h1; ee <= NUM_SOURCES_S11; ee = ee + 11'h1)
        complete_id_enabled_r = complete_id_enabled_r |
                                ((complete_id_w == ee) & enable_i[ee[SRC_IDX_W-1:0]]);
end
wire   complete_id_enabled  = complete_id_in_range & complete_id_enabled_r;

assign complete_pulse_o     = access_claim &  reg_wr_en_i & complete_id_enabled;
assign complete_source_id_o = complete_pulse_o ? complete_id_w : 11'h0;


//=============================================================================
// 4)  READ MUX
//=============================================================================
// 0x0 reads zero-extended threshold; 0x4 reads zero-extended top_source_id
// (the claim-side, threshold-independent value -- see arbiter comment).

reg  [31:0] rd_mux;
always @(*) begin
    if (access_claim)
        rd_mux = {21'h0, top_id_claim};
    else
        rd_mux = {{(32-PRIO_BITS){1'b0}}, threshold};
end

assign reg_rd_data_o = (reg_sel_i & ~reg_wr_en_i) ? rd_mux : 32'h0;
assign reg_ready_o   = 1'b1;


//=============================================================================
// 5)  PARAMETER RANGE CHECK
//=============================================================================
// pragma translate_off
generate
    if ((NUM_SOURCES < 1) || (NUM_SOURCES > 1023)) begin : CHECK_NUM_SOURCES
        initial $fatal(1, "plic_target: NUM_SOURCES (%0d) must be 1..1023.", NUM_SOURCES);
    end
    if ((PRIO_BITS < 1) || (PRIO_BITS > 7)) begin : CHECK_PRIO_BITS
        initial $fatal(1, "plic_target: PRIO_BITS (%0d) must be 1..7.", PRIO_BITS);
    end
    if (REG_AW < 3) begin : CHECK_REG_AW
        initial $fatal(1, "plic_target: REG_AW (%0d) must be >= 3.", REG_AW);
    end
endgenerate
// pragma translate_on


//=============================================================================
// 6)  LINT CLEANUP
//=============================================================================

wire [1:0] reg_addr_lsb_unused;
assign     reg_addr_lsb_unused = reg_addr_i[1:0];

generate
    if (REG_AW > 3) begin : G_REG_ADDR_HI_UNUSED
        wire [REG_AW-4:0] reg_addr_hi_unused;
        assign reg_addr_hi_unused = reg_addr_i[REG_AW-1:3];
    end
endgenerate

wire          [31:0] reg_wr_data_unused;
assign               reg_wr_data_unused      = reg_wr_data_i;

wire [PRIO_BITS-1:0] priority0_unused;
assign               priority0_unused        = priority_i[PRIO_BITS-1:0];

wire                 pending0_enable0_unused;
assign               pending0_enable0_unused = pending_i[0] | enable_i[0];

wire                 top_prio_unused         = |G_LVL[LEAF_W].p;

endmodule // plic_target

`default_nettype wire
