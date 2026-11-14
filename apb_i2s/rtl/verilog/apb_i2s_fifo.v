//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    apb_i2s_fifo
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : apb_i2s_fifo.v
// Module Description : Flip-flop FIFO of 1 << AW 32-bit words with a
//                      registered head: the oldest word is always in head_q,
//                      so the read side sees a flop and the storage read mux
//                      only feeds that register. level_o counts the head and
//                      the stored words; the head holds a word whenever the
//                      storage does, so the storage holds at most DEPTH-1.
//                      The user pushes only while full_o is low; clr_i
//                      empties the FIFO.
//----------------------------------------------------------------------------
`default_nettype none

module  apb_i2s_fifo #(
    parameter               AW           = 5,       // depth = 1 << AW words (1..8)
    parameter               ASYNC_RST_EN = 1        // Reset style: 1=async active-low reset, 0=synchronous reset
) (
    input  wire             clk_i,                  // clock
    input  wire             rst_n_i,                // active-low reset, style per ASYNC_RST_EN
    input  wire             clr_i,                  // empty the FIFO (wins over push and pop)
    input  wire             push_i,                 // write din_i (only while full_o is low)
    input  wire      [31:0] din_i,                  // word written
    input  wire             pop_i,                  // remove the head (ignored when empty)
    output wire      [31:0] head_o,                 // oldest word (0 when empty)
    output wire             valid_o,                // head_o holds a word
    output wire             full_o,                 // level_o = depth
    output wire      [AW:0] level_o                 // words held
);

// pragma translate_off
generate
    if ((AW < 1) || (AW > 8)) begin : CHECK_AW
        initial $fatal(1, "apb_i2s_fifo: AW (%0d) must be 1..8.", AW);
    end
    if ((ASYNC_RST_EN != 0) && (ASYNC_RST_EN != 1)) begin : CHECK_ASYNC_RST_EN
        initial $fatal(1, "apb_i2s_fifo: ASYNC_RST_EN (%0d) must be 0 or 1.", ASYNC_RST_EN);
    end
endgenerate
// pragma translate_on

localparam              ARST_EN = (ASYNC_RST_EN != 0);
localparam              DEPTH   = 1 << AW;

wire           [AW-1:0] wptr;
wire           [AW-1:0] rptr;
wire           [AW-1:0] mcnt;                       // words in storage (excluding the head), at most DEPTH-1
wire             [31:0] head_q;
wire                    head_v;
wire                    pop;                        // accepted pop
wire                    load;                       // the head register loads
wire                    from_mem;                   // ... from storage (else straight from din_i)
wire                    mem_wr;
wire             [31:0] mem_rd;
wire             [AW:0] level;
wire           [AW-1:0] wptr_nxt;
wire           [AW-1:0] rptr_nxt;
wire           [AW-1:0] mcnt_nxt;
wire      [DEPTH*32-1:0] mem_q;                     // entry e in [e*32 +: 32]

assign level    = {1'b0, mcnt} + {{AW{1'b0}}, head_v};
assign pop      = pop_i & head_v;
assign load     = (~head_v | pop) & ((mcnt != {AW{1'b0}}) | push_i);
assign from_mem = (mcnt != {AW{1'b0}});
assign mem_wr   = push_i & ~(load & ~from_mem);

assign wptr_nxt = clr_i ? {AW{1'b0}} : (wptr + 1'b1);
assign rptr_nxt = clr_i ? {AW{1'b0}} : (rptr + 1'b1);
assign mcnt_nxt = clr_i ? {AW{1'b0}} : mem_wr ? (mcnt + 1'b1) : (mcnt - 1'b1);

arv_ipdff #(.WIDTH(AW), .ARST_EN(ARST_EN)) u_wptr (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(clr_i | mem_wr), .d_i(wptr_nxt), .q_o(wptr));

arv_ipdff #(.WIDTH(AW), .ARST_EN(ARST_EN)) u_rptr (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(clr_i | (load & from_mem)), .d_i(rptr_nxt), .q_o(rptr));

arv_ipdff #(.WIDTH(AW), .ARST_EN(ARST_EN)) u_mcnt (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(clr_i | (mem_wr != (load & from_mem))), .d_i(mcnt_nxt), .q_o(mcnt));

arv_ipdff #(.WIDTH(33), .ARST_EN(ARST_EN)) u_head (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(clr_i | load | pop),
    .d_i(clr_i ? 33'h0 : load ? {1'b1, from_mem ? mem_rd : din_i} : 33'h0), .q_o({head_v, head_q}));

// Storage: one register per entry, read through an AND-OR mux into the head
genvar ge;
generate
    for (ge = 0; ge < DEPTH; ge = ge + 1) begin : g_mem
        arv_ipdff #(.WIDTH(32), .ARST_EN(ARST_EN)) u_word (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(mem_wr & (wptr == ge[AW-1:0])),
            .d_i(din_i), .q_o(mem_q[ge*32 +: 32]));
    end
endgenerate

reg              [31:0] rd_mux;
integer                 mi;
always @(*) begin
    rd_mux = 32'h0;
    for (mi = 0; mi < DEPTH; mi = mi + 1)
        rd_mux = rd_mux | ({32{rptr == mi[AW-1:0]}} & mem_q[mi*32 +: 32]);
end
assign mem_rd = rd_mux;

assign head_o   = head_q;
assign valid_o  = head_v;
assign full_o   = (level == DEPTH[AW:0]);
assign level_o  = level;

endmodule // apb_i2s_fifo

`default_nettype wire
