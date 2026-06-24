//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_plic
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_plic.v
// Module Description : RISC-V Platform-Level Interrupt Controller (PLIC),
//
//                      Contains:
//
//                        + plic_priority : per-source priority register file
//                        + plic_pending  : per-source pending + in-service
//                                          flops, level-triggered gateway,
//                                          read-only AHB view
//                        + plic_enable   : per-context enable matrix
//                        + plic_target   : per-context threshold + arbiter +
//                                          claim/complete handshake
//                                          (instantiated NUM_CONTEXTS times)
//
//                      Context numbering:
//                        SU_MODE_EN=1: ctx = 2*hart + s_mode (M=0, S=1)
//                                      -> NUM_CONTEXTS = 2 * NUM_HARTS
//                        SU_MODE_EN=0: ctx = hart
//                                      -> NUM_CONTEXTS =     NUM_HARTS
//                                      irq_s_external_o tied 0.
//
// ADDRESS MAP (22-bit byte address, SiFive-PLIC compatible):
//   0x000000 + 4*src             priority[src]    (PRIO_BITS-wide,  src=1..NS)
//   0x001000 + 4*word            pending[word]    (RO from AHB)
//   0x002000 + 0x80*ctx + 4*word enable[ctx,word] (RW)
//   0x200000 + 0x1000*ctx + 0x0  threshold[ctx]   (RW)
//   0x200000 + 0x1000*ctx + 0x4  claim/complete[ctx]
//                                                 (read = claim; write = complete)
//   Everything else              RAZ/WI
//
//----------------------------------------------------------------------------
`default_nettype none

module  ahb_plic #(
    parameter                   NUM_SOURCES     = 31,  // Number of interrupt sources (1..1023, src 0 reserved)
    parameter                   NUM_HARTS       = 1,   // Number of harts (1..16)
    parameter                   SU_MODE_EN      = 1,   // 1 => instantiate per-hart S-context too
    parameter                   PRIO_BITS       = 3,   // Priority width per source (1..7)
    parameter                   PRIV_CHECK_EN   = 1,   // 1 => enforce M/S/U privilege checker via hprot_i[1] + hsmode_i; 0 => allow any access (legacy / fabric-policed)
    parameter                   ASYNC_RST_EN    = 1'b1 // Reset architecture: 1=async active-low reset, 0=synchronous reset (threaded to all flops via arv_ipdff)
) (

// AHB CLOCK & RESET
    input  wire                 hclk_i,                // AHB clock
    input  wire                 hresetn_i,             // Active-low async reset (sync-deassert)
    output wire                 hclk_en_o,             // Clock enable output for SoC-level clock gating

// AHB-LITE SLAVE INTERFACE
    input  wire                 hsel_i,                // Slave select
    input  wire          [21:0] haddr_i,               // AHB byte address (4 MB PLIC window per the SiFive layout)
    input  wire                 hwrite_i,              // Write enable
    input  wire           [2:0] hsize_i,               // Transfer size (only word is meaningful)
    input  wire           [1:0] htrans_i,              // Transfer type (NONSEQ/SEQ start an access)
    input  wire           [3:0] hprot_i,               // AHB-Lite protection; bit[1]=1 privileged, bit[1]=0 unprivileged. Other bits ignored.
    input  wire                 hsmode_i,              // aRVern privilege extension: when hprot_i[1]=1, 0=M, 1=S. Don't-care when hprot_i[1]=0.
    input  wire                 hready_i,              // Bus ready in
    input  wire          [31:0] hwdata_i,              // Write data
    output wire          [31:0] hrdata_o,              // Read data
    output wire                 hreadyout_o,           // Bus ready out
    output wire                 hresp_o,               // Bus error response

// PER-SOURCE LEVEL-TRIGGERED INTERRUPT INPUTS
    input  wire [NUM_SOURCES:0] irq_src_i,             // External level lines; hclk DOMAIN; irq_src_i[0] ignored

// PER-HART INTERRUPT OUTPUTS (hclk DOMAIN)
    output wire [NUM_HARTS-1:0] irq_m_external_o,      // M-mode external interrupt
    output wire [NUM_HARTS-1:0] irq_s_external_o       // S-mode external interrupt (0 when SU_MODE_EN=0)

);


//=============================================================================
// 1)  LOCAL PARAMETERS
//=============================================================================

localparam        NUM_CONTEXTS    = SU_MODE_EN ? 2*NUM_HARTS : NUM_HARTS;

localparam [21:0] PRIORITY_BASE   = 22'h000000;
localparam [21:0] PENDING_BASE    = 22'h001000;
localparam [21:0] ENABLE_BASE     = 22'h002000;
localparam [21:0] TARGET_BASE     = 22'h200000;

localparam        PRIO_REG_AW     = 12;                                        // 4 KB priority window
localparam        PEND_REG_AW     = 12;                                        // 4 KB pending  window
localparam        EN_REG_AW       = 12;                                        // 4 KB enable   window (up to 32 contexts)
localparam        TGT_REG_AW      = 3;                                         // 8 bytes per target (0x0 threshold, 0x4 claim)


//=============================================================================
// 2)  AHB ADDRESS-PHASE -> DATA-PHASE LATCHING
//=============================================================================

wire        dph_valid;
wire        dph_write;
wire [21:0] dph_addr;
wire  [2:0] dph_size;
wire        dph_hprot1;
wire        dph_hsmode;

wire        aph_valid = hsel_i & hready_i & htrans_i[1];

// Address-phase -> data-phase latch (set on aph_valid, clear otherwise when
// hready_i). Captured as one WIDTH=29 enabled flop: the enable fires on a new
// access (aph_valid) or on a bus-ready idle cycle (hready_i), and the d_i
// ternary supplies the captured fields on a new access or the all-zero clear
// value on a ready-idle cycle. Bit order of d_i matches the q_o concat below.
wire        dph_en   = aph_valid | hready_i;
wire [28:0] dph_d    = aph_valid ? {1'b1, hwrite_i, haddr_i, hsize_i, hprot_i[1], hsmode_i}
                                 : 29'b0;

arv_ipdff #(.WIDTH(29), .ARST_EN(ASYNC_RST_EN)) u_dph (
                  .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dph_en),
                                                       .d_i (dph_d),
                                                       .q_o ({dph_valid, dph_write, dph_addr, dph_size, dph_hprot1, dph_hsmode}));


//=============================================================================
// 3) PRIVILEGE-MODE DECODE
//=============================================================================
// PRIV_CHECK_EN=1 enforces a defense-in-depth privilege filter on every
// PLIC register access.
// AHB bus encoding goes as following:
//                                     hprot[1]=1 & hsmode=0 -> M-mode
//                                     hprot[1]=1 & hsmode=1 -> S-mode

wire    dph_mode_m  =  dph_hprot1 & ~dph_hsmode;
wire    dph_mode_s  =  dph_hprot1 &  dph_hsmode;
wire    dph_mode_u  = ~dph_hprot1;


//=============================================================================
// 4)  SUB-COMPONENT ADDRESS DECODE
//=============================================================================

genvar             gctx;
localparam   [8:0] TGT_INSTRIDE_RAZ = 9'h000;

wire in_priority = dph_valid & (dph_addr[21:12] == PRIORITY_BASE[21:12]) ;
wire in_pending  = dph_valid & (dph_addr[21:12] == PENDING_BASE [21:12]) ;

wire in_enable   = dph_valid & (dph_addr[21:12] == ENABLE_BASE  [21:12]) ;
wire in_target_w = dph_valid & (dph_addr[21]    == TARGET_BASE  [21]   ) &
                               (dph_addr[11:3]  == TGT_INSTRIDE_RAZ    ) ;

// Per-context target decode: the context index occupies dph_addr[20:12]
// (up to 9 bits, of which only the low ceil(log2(NUM_CONTEXTS)) matter
wire [NUM_CONTEXTS-1:0] in_target;
generate
    for (gctx = 0; gctx < NUM_CONTEXTS; gctx = gctx + 1) begin : G_TGT_SEL
        assign in_target[gctx] = in_target_w & (dph_addr[20:12] == gctx[8:0]);
    end
endgenerate

// Per-context enable decode (mirrors plic_enable's internal ctx_sel). The
// context index sits at dph_addr[11:7] (0x80-byte stride).
wire [NUM_CONTEXTS-1:0] in_enable_per_ctx;
generate
    for (gctx = 0; gctx < NUM_CONTEXTS; gctx = gctx + 1) begin : G_EN_CTX_SEL
        assign in_enable_per_ctx[gctx] = in_enable & (dph_addr[11:7] == gctx[4:0]);
    end
endgenerate


//=============================================================================
// 5) PRIVILEGE-MODE ACCESS POLICY
//=============================================================================
// Policy:
//   U-mode             : DENY everything.
//   M-mode             : ALLOW everything.
//   S-mode             : ALLOW priority / pending
//                        ALLOW enable / target for S-context windows
//                        DENY  enable / target for M-context windows
//
// The deny rule is built off the per-context decode (in_enable_per_ctx,
// in_target) AND-ed against a per-context M-class mask, then OR-reduced.
// This makes the privilege check fire ONLY when the access actually lands
// on a valid M-context register -- out-of-range addresses inside the
// enable / target windows that no real context owns are left to the
// sub-block's RAZ/WI path, avoiding an address-layout info leak via
// ERROR-vs-OK probing.
//
// Per-context class:
//       SU_MODE_EN=1 lays contexts out as ctx = 2*hart + s_mode,
//                    so even context indices are M and odd are S.
//       SU_MODE_EN=0 makes every context M, so any S-mode access
//                    to enable/target is denied.
//
// Denied accesses get an AHB ERROR response

wire [NUM_CONTEXTS-1:0] ctx_is_m_ctx;
generate
    for (gctx = 0; gctx < NUM_CONTEXTS; gctx = gctx + 1) begin : G_CTX_CLASS
        if (SU_MODE_EN == 1) begin : G_CTX_CLASS_MS
            assign ctx_is_m_ctx[gctx] = (gctx[0] == 1'b0);
        end else begin : G_CTX_CLASS_M_ONLY
            assign ctx_is_m_ctx[gctx] = 1'b1;
        end
    end
endgenerate

wire dph_enable_m_only_hit = |(in_enable_per_ctx & ctx_is_m_ctx);
wire dph_target_m_only_hit = |(in_target         & ctx_is_m_ctx);

wire dph_priv_allowed_raw;
generate
    if (PRIV_CHECK_EN == 1) begin : G_PRIV_CHK
        assign dph_priv_allowed_raw = dph_mode_m | (dph_mode_s & ~dph_enable_m_only_hit & ~dph_target_m_only_hit);
    end else begin : G_PRIV_BYPASS
        assign dph_priv_allowed_raw = 1'b1;
    end
endgenerate

// U-mode is is always denied
wire dph_priv_allowed = (PRIV_CHECK_EN == 1) ? (dph_priv_allowed_raw & ~dph_mode_u) : 1'b1;

// Size check (always enforced).
wire dph_size_ok   = (dph_size == 3'b010);
wire dph_access_ok = dph_priv_allowed & dph_size_ok;

// Gated decode wires that feed reg_sel_i on each sub-block.
wire                    in_priority_priv = in_priority & dph_access_ok;
wire                    in_pending_priv  = in_pending  & dph_access_ok;
wire                    in_enable_priv   = in_enable   & dph_access_ok;
wire [NUM_CONTEXTS-1:0] in_target_priv;
generate
    for (gctx = 0; gctx < NUM_CONTEXTS; gctx = gctx + 1) begin : G_TGT_PRIV
        assign in_target_priv[gctx] = in_target[gctx]  & dph_access_ok;
    end
endgenerate


//=============================================================================
// 6)  PRIORITY INSTANCE
//=============================================================================

wire [31:0]                            prio_rdata;
wire                                   prio_ready;
wire [PRIO_BITS*(NUM_SOURCES+1)-1:0]   priority_flat;

plic_priority #(
    .NUM_SOURCES       ( NUM_SOURCES                  ),
    .PRIO_BITS         ( PRIO_BITS                    ),
    .REG_AW            ( PRIO_REG_AW                  ),
    .ARST_EN           ( ASYNC_RST_EN                 )
) u_priority (
    .hclk_i            ( hclk_i                       ),
    .hresetn_i         ( hresetn_i                    ),
    .reg_sel_i         ( in_priority_priv             ),
    .reg_addr_i        ( dph_addr[PRIO_REG_AW-1:0]    ),
    .reg_wr_en_i       ( dph_write                    ),
    .reg_wr_data_i     ( hwdata_i                     ),
    .reg_rd_data_o     ( prio_rdata                   ),
    .reg_ready_o       ( prio_ready                   ),
    .priority_o        ( priority_flat                )
);


//=============================================================================
// 7)  PENDING INSTANCE
//=============================================================================

wire [31:0]               pend_rdata;
wire                      pend_ready;
wire [NUM_SOURCES:0]      pending_flat;
wire [NUM_SOURCES:0]      in_service_flat;

// Per-context claim/complete pulses from the targets
wire                      claim_pulse_or;
wire [10:0]               claim_id_or;
wire                      complete_pulse_or;
wire [10:0]               complete_id_or;

plic_pending #(
    .NUM_SOURCES         ( NUM_SOURCES                  ),
    .REG_AW              ( PEND_REG_AW                  ),
    .ARST_EN             ( ASYNC_RST_EN                 )
) u_pending (
    .hclk_i              ( hclk_i                       ),
    .hresetn_i           ( hresetn_i                    ),
    .irq_src_i           ( irq_src_i                    ),
    .claim_pulse_i       ( claim_pulse_or               ),
    .claim_source_id_i   ( claim_id_or                  ),
    .complete_pulse_i    ( complete_pulse_or            ),
    .complete_source_id_i( complete_id_or               ),
    .reg_sel_i           ( in_pending_priv              ),
    .reg_addr_i          ( dph_addr[PEND_REG_AW-1:0]    ),
    .reg_wr_en_i         ( dph_write                    ),
    .reg_wr_data_i       ( hwdata_i                     ),
    .reg_rd_data_o       ( pend_rdata                   ),
    .reg_ready_o         ( pend_ready                   ),
    .pending_o           ( pending_flat                 ),
    .in_service_o        ( in_service_flat              )
);


//=============================================================================
// 8)  ENABLE INSTANCE
//=============================================================================

wire [31:0]                              en_rdata;
wire                                     en_ready;
wire [NUM_CONTEXTS*(NUM_SOURCES+1)-1:0]  enable_flat;

plic_enable #(
    .NUM_SOURCES       ( NUM_SOURCES                  ),
    .NUM_CONTEXTS      ( NUM_CONTEXTS                 ),
    .REG_AW            ( EN_REG_AW                    ),
    .ARST_EN           ( ASYNC_RST_EN                 )
) u_enable (
    .hclk_i            ( hclk_i                       ),
    .hresetn_i         ( hresetn_i                    ),
    .reg_sel_i         ( in_enable_priv               ),
    .reg_addr_i        ( dph_addr[EN_REG_AW-1:0]      ),
    .reg_wr_en_i       ( dph_write                    ),
    .reg_wr_data_i     ( hwdata_i                     ),
    .reg_rd_data_o     ( en_rdata                     ),
    .reg_ready_o       ( en_ready                     ),
    .enable_o          ( enable_flat                  )
);


//=============================================================================
// 9)  TARGET INSTANCES (one per context)
//=============================================================================

wire [31:0]               tgt_rdata     [0:NUM_CONTEXTS-1];
wire                      tgt_ready     [0:NUM_CONTEXTS-1];
wire                      tgt_irq       [0:NUM_CONTEXTS-1];
wire [10:0]               tgt_top_id    [0:NUM_CONTEXTS-1];
wire                      tgt_claim_p   [0:NUM_CONTEXTS-1];
wire [10:0]               tgt_claim_id  [0:NUM_CONTEXTS-1];
wire                      tgt_compl_p   [0:NUM_CONTEXTS-1];
wire [10:0]               tgt_compl_id  [0:NUM_CONTEXTS-1];

generate
    for (gctx = 0; gctx < NUM_CONTEXTS; gctx = gctx + 1) begin : G_TGT
        plic_target #(
            .NUM_SOURCES         ( NUM_SOURCES                   ),
            .PRIO_BITS           ( PRIO_BITS                     ),
            .REG_AW              ( TGT_REG_AW                    ),
            .ARST_EN             ( ASYNC_RST_EN                  )
        ) u_target (
            .hclk_i              ( hclk_i                        ),
            .hresetn_i           ( hresetn_i                     ),
            .pending_i           ( pending_flat                  ),
            .enable_i            ( enable_flat[(NUM_SOURCES+1)*gctx +: (NUM_SOURCES+1)] ),
            .priority_i          ( priority_flat                 ),
            .reg_sel_i           ( in_target_priv[gctx]          ),
            .reg_addr_i          ( dph_addr[TGT_REG_AW-1:0]      ),
            .reg_wr_en_i         ( dph_write                     ),
            .reg_wr_data_i       ( hwdata_i                      ),
            .reg_rd_data_o       ( tgt_rdata[gctx]               ),
            .reg_ready_o         ( tgt_ready[gctx]               ),
            .claim_pulse_o       ( tgt_claim_p[gctx]             ),
            .claim_source_id_o   ( tgt_claim_id[gctx]            ),
            .complete_pulse_o    ( tgt_compl_p[gctx]             ),
            .complete_source_id_o( tgt_compl_id[gctx]            ),
            .irq_o               ( tgt_irq[gctx]                 ),
            .top_source_id_o     ( tgt_top_id[gctx]              )
        );
    end
endgenerate


//=============================================================================
// 10) TARGET RDATA / PULSE OR-REDUCTION
//=============================================================================

reg  [31:0] tgt_rdata_or;
reg         claim_pulse_acc;
reg  [10:0] claim_id_acc;
reg         complete_pulse_acc;
reg  [10:0] complete_id_acc;
integer     ti;
always @(*) begin
    tgt_rdata_or       = 32'h0;
    claim_pulse_acc    = 1'b0;
    claim_id_acc       = 11'h0;
    complete_pulse_acc = 1'b0;
    complete_id_acc    = 11'h0;
    for (ti = 0; ti < NUM_CONTEXTS; ti = ti + 1) begin
        tgt_rdata_or       = tgt_rdata_or       | tgt_rdata[ti];
        claim_pulse_acc    = claim_pulse_acc    | tgt_claim_p[ti];
        claim_id_acc       = claim_id_acc       | tgt_claim_id[ti];
        complete_pulse_acc = complete_pulse_acc | tgt_compl_p[ti];
        complete_id_acc    = complete_id_acc    | tgt_compl_id[ti];
    end
end

assign claim_pulse_or    = claim_pulse_acc;
assign claim_id_or       = claim_id_acc;
assign complete_pulse_or = complete_pulse_acc;
assign complete_id_or    = complete_id_acc;


//=============================================================================
// 11) AHB READ-DATA OR-MUX
//=============================================================================

assign hrdata_o = prio_rdata | pend_rdata | en_rdata | tgt_rdata_or;


//=============================================================================
// 12) HREADYOUT / HRESP -- two-cycle ERROR response for denied accesses
//=============================================================================
// Denied = bad size (always) OR privilege violation (when PRIV_CHECK_EN=1).

localparam ERR_IDLE = 1'b0;
localparam ERR_P2   = 1'b1;

wire err_state;
wire access_denied = dph_valid & ~dph_access_ok;

// Two-state error FSM: IDLE(0) -> P2(1) on a denied access, P2 -> IDLE always.
// Updates every cycle (en_i tied 1); reset value is ERR_IDLE (1'b0).
wire err_state_next = ~err_state & access_denied;

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_err_state (
                       .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                            .d_i (err_state_next),
                                                            .q_o (err_state));

wire in_err_p1 = access_denied & (err_state == ERR_IDLE);  // first error cycle
wire in_err_p2 =                 (err_state == ERR_P2  );  // second error cycle

assign hresp_o     =  in_err_p1 | in_err_p2;
assign hreadyout_o = ~in_err_p1 ;                          // stall in P1, release in P2


//=============================================================================
// 13) hclk_en_o -- enable for SoC-side ICG cell.
//=============================================================================

wire [NUM_SOURCES:1] pending_set_needed = ~in_service_flat[NUM_SOURCES:1] &
                                           irq_src_i      [NUM_SOURCES:1] &
                                          ~pending_flat   [NUM_SOURCES:1];

assign               hclk_en_o =  aph_valid           |
                                  dph_valid           |
                                (|pending_set_needed) ;


//=============================================================================
// 14) PER-HART IRQ OUTPUT MUX
//=============================================================================
// SU_MODE_EN=1: ctx 2*h carries M-mode IRQ for hart h, ctx 2*h+1 carries S.
// SU_MODE_EN=0: ctx h carries M-mode IRQ for hart h; S output tied 0.

wire [NUM_HARTS-1:0] irq_m_external_w;
wire [NUM_HARTS-1:0] irq_s_external_w;

genvar gh;
generate
    if (SU_MODE_EN == 1) begin : G_IRQ_MS
        for (gh = 0; gh < NUM_HARTS; gh = gh + 1) begin : G_IRQ_HART
            assign irq_m_external_w[gh] = tgt_irq[2*gh];
            assign irq_s_external_w[gh] = tgt_irq[2*gh + 1];
        end
    end else begin : G_IRQ_M_ONLY
        for (gh = 0; gh < NUM_HARTS; gh = gh + 1) begin : G_IRQ_HART
            assign irq_m_external_w[gh] = tgt_irq[gh];
        end
        assign irq_s_external_w = {NUM_HARTS{1'b0}};
    end
endgenerate

assign irq_m_external_o = irq_m_external_w;
assign irq_s_external_o = irq_s_external_w;


//=============================================================================
// 15) PARAMETER VALIDATION
//=============================================================================
// pragma translate_off
generate
    if ((NUM_SOURCES < 1) || (NUM_SOURCES > 1023)) begin : CHECK_NUM_SOURCES
        initial $fatal(1, "ahb_plic: NUM_SOURCES (%0d) must be 1..1023.", NUM_SOURCES);
    end
    if ((NUM_HARTS < 1) || (NUM_HARTS > 16)) begin : CHECK_NUM_HARTS
        initial $fatal(1, "ahb_plic: NUM_HARTS (%0d) must be 1..16.", NUM_HARTS);
    end
    if ((SU_MODE_EN != 0) && (SU_MODE_EN != 1)) begin : CHECK_SU_MODE_EN
        initial $fatal(1, "ahb_plic: SU_MODE_EN (%0d) must be 0 or 1.", SU_MODE_EN);
    end
    if ((PRIO_BITS < 1) || (PRIO_BITS > 7)) begin : CHECK_PRIO_BITS
        initial $fatal(1, "ahb_plic: PRIO_BITS (%0d) must be 1..7.", PRIO_BITS);
    end
    if ((PRIV_CHECK_EN != 0) && (PRIV_CHECK_EN != 1)) begin : CHECK_PRIV_CHECK_EN
        initial $fatal(1, "ahb_plic: PRIV_CHECK_EN (%0d) must be 0 or 1.", PRIV_CHECK_EN);
    end
     if ((ASYNC_RST_EN != 0) && (ASYNC_RST_EN != 1)) begin : CHECK_ASYNC_RST_EN
        initial $fatal(1, "ahb_plic: ASYNC_RST_EN (%0d) must be 0 or 1.", ASYNC_RST_EN);
    end
endgenerate
// pragma translate_on


//=============================================================================
// 16) LINT CLEANUP
//=============================================================================

wire       htrans0_unused;
assign     htrans0_unused = htrans_i[0];

wire [2:0] hprot_unused;
assign     hprot_unused   = {hprot_i[3:2], hprot_i[0]};

generate
    if (PRIV_CHECK_EN == 0) begin : G_PRIV_OFF_SINK
        // dph_priv_allowed_raw is tied 1'b1 when PRIV_CHECK_EN=0; omitting
        // it from the sink avoids an "OR with constant" lint flag.
        wire   dph_priv_off_unused;
        assign dph_priv_off_unused = dph_hprot1 | dph_hsmode | dph_mode_m | dph_mode_s | dph_mode_u |
                                     dph_enable_m_only_hit | dph_target_m_only_hit;
    end
endgenerate

wire                 prio_ready_unused;
assign               prio_ready_unused       = prio_ready;

wire                 pend_ready_unused;
assign               pend_ready_unused       = pend_ready;

// Only bit [0] is truly unused (reserved source 0); [NUM_SOURCES:1] feed
// `pending_set_needed` in the hclk_en_o computation.
wire                 in_service0_unused;
assign               in_service0_unused      = in_service_flat[0];

wire                 en_ready_unused;
assign               en_ready_unused         = en_ready;

wire                 tgt_ready_unused  [0:NUM_CONTEXTS-1];
wire          [10:0] tgt_top_id_unused [0:NUM_CONTEXTS-1];

generate
    for (gctx = 0; gctx < NUM_CONTEXTS; gctx = gctx + 1) begin : G_TGT_LINT
        assign       tgt_ready_unused [gctx] = tgt_ready[gctx];
        assign       tgt_top_id_unused[gctx] = tgt_top_id[gctx];
    end
endgenerate


endmodule // ahb_plic

`default_nettype wire
