//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_fused_rom_ctrl
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_fused_rom_ctrl.v
// Module Description : AHB ROM controller fused into the interconnect data path.
//
// Port-level conventions:
//   * Port A (instruction fetch) is read-only and always 32-bit. HSIZE is
//     not consumed (no `a_hsize_i` port).
//   * Port B reads return the full 32-bit ROM word — HSIZE is NOT honored
//     (no `b_hsize_i` port). Masters performing sub-word reads must mask
//     the result themselves.
//   * Port B writes always return a 2-cycle AHB-Lite ERROR (see WRITE-ERROR
//     FSM, section 3a).
//
// Memory-macro contract: the attached ROM macro is expected to return data
// combinationally one cycle after `rom_cen_o` is asserted (low) with a
// stable `rom_addr_o`. Wait states from the macro are not supported.
//----------------------------------------------------------------------------
`default_nettype none

module ahb_fused_rom_ctrl #(
    // FIXED_B_PRIO selects the arbitration scheme between Port A and Port B:
    //   1'b0 (default) - Toggle priority: 1:1 round-robin between A and B
    //   1'b1           - Fixed priority for Port B (data bus): B always wins when requesting.
    parameter         [0:0] FIXED_B_PRIO = 1'b0,
    parameter               ARST_EN      = 1'b1   // 1=async active-low reset, 0=synchronous reset
) (

// AHB CLOCK & RESET
    input  wire             hclk_i,
    input  wire             hresetn_i,
    output wire             hclk_en_o,

// PORT A - Instruction fetch
    input  wire      [31:0] a_haddr_i,
    input  wire             a_hsel_i,
    input  wire       [1:0] a_htrans_i,
    input  wire             a_hready_i,

    output wire      [31:0] a_hrdata_o,
    output wire             a_hreadyout_o,
    output wire             a_hresp_o,

// PORT B - Data read
    input  wire      [31:0] b_haddr_i,
    input  wire             b_hsel_i,
    input  wire       [1:0] b_htrans_i,
    input  wire             b_hwrite_i,
    input  wire             b_hready_i,

    output wire      [31:0] b_hrdata_o,
    output wire             b_hreadyout_o,
    output wire             b_hresp_o,

// ROM MACRO INTERFACE
    input  wire      [31:0] rom_dout_i,
    output wire      [29:0] rom_addr_o,
    output wire             rom_cen_o,
    output wire             rom_clk_o
);


//=============================================================================
// 1)  ADDRESS PHASE DETECTION
//=============================================================================

wire       a_aph_read  =  a_hsel_i & a_htrans_i[1] & a_hready_i;                // Port A: instruction fetch
wire       b_aph_read  =  b_hsel_i & b_htrans_i[1] & b_hready_i & ~b_hwrite_i;  // Port B: read
wire       b_aph_write =  b_hsel_i & b_htrans_i[1] & b_hready_i &  b_hwrite_i;  // Port B: write → 2-cycle ERROR (section 3a)


//=============================================================================
// 2)  ARBITRATION  (selectable scheme via FIXED_B_PRIO)
//=============================================================================
//
// FIXED_B_PRIO=0 — Toggle priority (1:1 fairness, default):
//   arb[1:0] = {any_pending, priority_a}
//     2'b01 = A priority,  no pending
//     2'b00 = B priority,  no pending
//     2'b11 = A replay pending, A priority next contest
//     2'b10 = B replay pending, B priority next contest
//
//   Priority is updated only on a_lost/b_lost (not on uncontested grants),
//   keeping pending and priority in lock-step: arb[1]=1 always implies
//   arb[0]=a_pending.
//
// FIXED_B_PRIO=1 — Fixed Port-B priority:
//   B always wins; only A can pend. arb[1] = a_pending; arb[0] held 0.
//   States used: 2'b00 (idle), 2'b10 (A replay pending).
//

wire [1:0] arb;
wire       a_grant;
wire       a_lost;
wire       a_stall;
wire       b_lost;
wire [1:0] arb_nxt;

generate
if (FIXED_B_PRIO) begin : gen_arb_fixed
    // Only A can lose. arb[1] = a_pending.
    // a_lost  drives saved_addr/arb (initial contention only — a_haddr_i is valid).
    // a_stall drives a_hreadyout_o and also fires when B preempts a pending
    // replay (arb[1] & b_aph_read), since the rom_addr_o mux gives B priority
    // over saved_addr in fixed-B mode.
    assign a_grant = ~b_aph_read & (arb[1] | (a_aph_read & ~arb[1]));
    assign a_lost  =  a_aph_read &  b_aph_read & ~arb[1];
    assign a_stall =  b_aph_read & (a_aph_read |  arb[1]);
    assign b_lost  =  1'b0;
    assign arb_nxt =  a_lost              ? 2'b10 :
                      (a_grant & arb[1])  ? 2'b00 :
                                            arb   ;
end else begin : gen_arb_rr
    assign a_grant =  a_aph_read & (arb[0] | ~b_aph_read) & ~arb[1];
    assign a_lost  =  a_aph_read & ~arb[0] & (b_aph_read  |  arb[1]);
    assign a_stall =  a_lost;
    assign b_lost  =  b_aph_read &  arb[0] & (a_aph_read  |  arb[1]);
    assign arb_nxt =  a_lost ? 2'b11 :
                      b_lost ? 2'b10 :
                               {1'b0, arb[0]};
end
endgenerate

localparam [1:0] ARB_RESET = (FIXED_B_PRIO != 1'b0) ? 2'b00 : 2'b01;

arv_ipdff #(.WIDTH(2), .RST_VAL(ARB_RESET), .ARST_EN(ARST_EN)) u_arb (
                                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i (arb_nxt), .q_o (arb));

//=============================================================================
// 3)  ADDRESS SAVE
//=============================================================================
//
// When a port loses arbitration its address is captured and HREADYOUT is
// returned HIGH (address accepted).  One cycle later the saved address drives
// the ROM (pending cycle) while HREADYOUT is held LOW (data-phase wait state).
// The following cycle the ROM output is valid and HREADYOUT goes HIGH.
//

wire [1:0] b_err_st;
wire [1:0] b_err_st_nxt;

// saved_addr: capture losing port's address. a_lost has priority over b_lost
// (mutually exclusive in practice). Hold when neither loses.
wire [29:0] saved_addr;
arv_ipdff #(.WIDTH(30), .ARST_EN(ARST_EN)) u_saved_addr (
                    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(a_lost | b_lost),
                                                         .d_i (a_lost ? a_haddr_i[31:2] : b_haddr_i[31:2]),
                                                         .q_o (saved_addr));

// a_hreadyout_o: registered ~a_stall, resets HIGH.
arv_ipdff #(.WIDTH(1), .RST_VAL(1'b1), .ARST_EN(ARST_EN)) u_a_hreadyout (
                                    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                                         .d_i (~a_stall),
                                                                         .q_o ( a_hreadyout_o));

// b_hreadyout_o: resets HIGH; unconditional next-state priority mux.
//   b_aph_write          -> 0  (next cycle enters ERR_1)
//   b_err_st == 2'b01    -> 1  (next cycle enters ERR_2)
//   otherwise            -> ~b_lost
wire b_hreadyout_nxt = b_aph_write        ? 1'b0  :
                      (b_err_st == 2'b01) ? 1'b1  :
                                           ~b_lost;

arv_ipdff #(.WIDTH(1), .RST_VAL(1'b1), .ARST_EN(ARST_EN)) u_b_hreadyout (
                                    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                                         .d_i (b_hreadyout_nxt),
                                                                         .q_o (b_hreadyout_o));


//=============================================================================
// 3a) WRITE-ERROR FSM  (Port B — AHB-Lite 2-cycle ERROR response)
//=============================================================================

assign b_err_st_nxt = (b_err_st == 2'b00) ? (b_aph_write ? 2'b01 : 2'b00) :
                      (b_err_st == 2'b01) ?                2'b11          :
                      (b_err_st == 2'b11) ? (b_aph_write ? 2'b01 : 2'b00) :  // back-to-back write
                                                           2'b00          ;  // default

arv_ipdff #(.WIDTH(2), .ARST_EN(ARST_EN)) u_b_err_st (
                 .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                      .d_i (b_err_st_nxt),
                                                      .q_o (b_err_st));


//=============================================================================
// 4)  ROM MACRO CONTROL
//=============================================================================
//
// Address-mux structure depends on FIXED_B_PRIO:
//   - Round-robin: A-as-selectable, B-as-default (1 mux level for late A input).
//   - Fixed Port-B priority: B-as-selectable, A-as-default. The select is
//     b_aph_read which has no a_hsel_i fan-in — keeps a_hsel_i off the
//     ROM-address timing path.
//

generate
if (FIXED_B_PRIO) begin : gen_rom_addr_fixed
    assign rom_addr_o =  b_aph_read ? b_haddr_i[31:2] :   // B wins
                         arb[1]     ? saved_addr      :   // A pending replay
                                      a_haddr_i[31:2] ;   // A wins (or don't care when cen=1)
end else begin : gen_rom_addr_rr
    assign rom_addr_o =  a_grant ? a_haddr_i[31:2] :   // A wins (1 mux level for late input)
                         arb[1]  ? saved_addr      :   // pending replay (registered)
                                   b_haddr_i[31:2] ;   // B wins (or don't care when cen=1)
end
endgenerate

assign     rom_cen_o  = ~(a_aph_read | b_aph_read | arb[1]);

assign     rom_clk_o  =   hclk_i;


//=============================================================================
// 5)  AHB RESPONSES
//=============================================================================

// Port A
assign     a_hrdata_o =  rom_dout_i;
assign     a_hresp_o  =  1'b0;

// Port B
assign     b_hrdata_o =  rom_dout_i;
assign     b_hresp_o  =  b_err_st[0];


//=============================================================================
// 6)  CLOCK ENABLE  (for architectural clock-gating)
//=============================================================================

wire rom_was_active;

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_rom_was_active (
                       .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                            .d_i (~rom_cen_o),
                                                            .q_o ( rom_was_active));

assign hclk_en_o = a_aph_read | b_aph_read | b_aph_write | rom_was_active | (b_err_st != 2'b00);


//=============================================================================
// 7)  LINT CLEANUP
//=============================================================================

wire       a_htrans0_unused = a_htrans_i[0];
wire       b_htrans0_unused = b_htrans_i[0];

wire [1:0] a_haddr10_unused = a_haddr_i[1:0];
wire [1:0] b_haddr10_unused = b_haddr_i[1:0];


endmodule // ahb_fused_rom_ctrl

`default_nettype wire
