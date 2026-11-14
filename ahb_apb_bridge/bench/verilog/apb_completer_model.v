//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    apb_completer_model
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : apb_completer_model.v
// Module Description : APB4 completer for the bridge bench: 2^AW bytes of
//                      memory (the low address bits), 0 to wmax wait states
//                      per transfer (random), PSLVERR on the last word of a
//                      window wider than one word (the write is dropped
//                      there). Outside its ACCESS phase PREADY and PSLVERR
//                      take random values, as does PSLVERR in its own wait
//                      states: the bridge must ignore both there. Records
//                      every transfer's attributes for the tests.
//----------------------------------------------------------------------------
`timescale 1ns/1ps
module  apb_completer_model #(
    parameter          AW    = 8,                  // window = 2^AW bytes
    parameter          ADDRW = 12,
    parameter          SEED  = 1
) (
    input  wire             clk_i,
    input  wire       [7:0] wmax_i,             // most wait states per transfer
    input  wire             psel_i,
    input  wire             penable_i,
    input  wire             pwrite_i,
    input  wire [ADDRW-1:0] paddr_i,
    input  wire      [31:0] pwdata_i,
    input  wire       [3:0] pstrb_i,
    input  wire       [2:0] pprot_i,
    input  wire             psmode_i,
    output wire      [31:0] prdata_o,
    output wire             pready_o,
    output wire             pslverr_o
);

localparam         WORDS = (AW > 2) ? (1 << (AW - 2)) : 1;
localparam         IW    = (AW > 2) ? (AW - 2) : 1;   // word index width

reg   [31:0] mem [0:WORDS-1];
integer      wait_n;                       // wait states left in this transfer
integer      xfers = 0;                    // transfers completed
integer      waits = 0;                    // wait states given in total
reg    [2:0] last_prot;
reg          last_smode;
reg    [3:0] last_strb;
reg          last_write;
reg   [AW-1:0] last_off;
integer      k;
integer      seed;
integer      nz_seed;
reg    [1:0] nz = 2'b00;                   // PREADY and PSLVERR where they are not valid

initial begin
    for (k = 0; k < WORDS; k = k + 1) mem[k] = 32'h0;
    wait_n  = 0;
    seed    = SEED;
    nz_seed = SEED + 100;
end

wire [AW-1:0] off   = paddr_i[AW-1:0];
wire [IW-1:0] widx;
wire          err;
generate
    if (AW > 2) begin : g_words
        assign widx = paddr_i[AW-1:2];
        assign err  = (widx == {IW{1'b1}});
    end else begin : g_one_word
        assign widx = 1'b0;
        assign err  = 1'b0;
    end
endgenerate
wire          own   = psel_i & penable_i;
wire          rdy   = own & (wait_n == 0);
wire [31:0]   word  = mem[widx];

assign pready_o  = rdy | (~own & nz[0]);
assign pslverr_o = (rdy & err) | (~rdy & nz[1]);
assign prdata_o  = rdy ? word : 32'hDEAD_BEEF;   // only valid with PREADY

always @(posedge clk_i) nz <= $random(nz_seed);

always @(posedge clk_i) begin
    if (psel_i & ~penable_i)                     // SETUP: draw the wait states
        wait_n = (wmax_i == 8'd0) ? 0 : ({$random(seed)} % (wmax_i + 1));
    else if (psel_i & penable_i & (wait_n != 0)) begin
        wait_n = wait_n - 1;
        waits  = waits + 1;
    end else if (rdy) begin
        xfers      = xfers + 1;
        last_prot  = pprot_i;
        last_smode = psmode_i;
        last_strb  = pstrb_i;
        last_write = pwrite_i;
        last_off   = off;
        if (pwrite_i & ~err) begin
            if (pstrb_i[0]) mem[widx][ 7: 0] = pwdata_i[ 7: 0];
            if (pstrb_i[1]) mem[widx][15: 8] = pwdata_i[15: 8];
            if (pstrb_i[2]) mem[widx][23:16] = pwdata_i[23:16];
            if (pstrb_i[3]) mem[widx][31:24] = pwdata_i[31:24];
        end
    end
end

endmodule // apb_completer_model
