//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arv_dtm_rxfifo
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arv_dtm_rxfifo
// Module Description : Small synchronous byte FIFO for the serial DTM RX path.
//
//   WHY IT EXISTS
//     The serial command interpreter (arv_dtm_cmd) only consumes RX bytes while it
//     is in its receiving states (S_SYNC / S_RX). Any byte the PHY delivers while
//     the interpreter is busy (EXEC/WAIT/RESP) would otherwise be dropped -- which
//     forces the host to wait for each response before sending the next request
//     (one USB latency-timer stall per word). Buffering the RX bytes here lets the
//     host stream several requests ahead; the interpreter drains the queued next
//     request as soon as it returns to S_SYNC. See doc/arv_dtm_uart.md.
//
//   WHAT IT IS
//     A dumb circular byte buffer: DEPTH x 8 storage + read/write pointers and an
//     occupancy count. First-word-fall-through read -- dout_o is combinationally the
//     head byte, so a consumer can look at the head and pop it in the same cycle
//     (rd_i & ~empty_o). wr_i & ~full_o pushes din_i.
//
//   OVERRUN
//     overrun_o pulses for the single cycle a wr_i lands while full (a byte was
//     dropped). It carries NO sticky state -- the sticky overrun flag lives in
//     arv_dtm_cmd so it can survive a flush (an abort resyncs the framing; a
//     DTMSTS write acknowledges the cause).
//
//   FLUSH
//     flush_i resets the pointers/count to empty in one cycle (highest priority).
//     It does not touch the storage array (stale bytes are unreachable once the
//     pointers move) and carries no sticky state.
//
//   CLOCKING / RESET
//     Single clk_i domain (the always-on oscillator shared with the DMI bus and the
//     PHY). Pointer/count flops use arv_ipdff with the build-time ARST_EN reset
//     style, matching every other module in this IP. The storage array is an
//     un-reset reg array (infers block/distributed RAM on FPGA, flops on ASIC).
//----------------------------------------------------------------------------
`default_nettype none

module  arv_dtm_rxfifo #(
    parameter                   DEPTH   = 64,     // FIFO depth in bytes
    parameter                   ARST_EN = 1'b1    // 1=async active-low reset, 0=sync
) (
    input  wire                 clk_i,            // always-on oscillator (= DMI bus clock)
    input  wire                 dbgresetn_i,      // active-low reset

    input  wire                 flush_i,          // 1-cycle: reset pointers to empty (highest priority)

// write side
    input  wire                 wr_i,             // push request
    input  wire           [7:0] din_i,            // byte to push

// read side (first-word-fall-through)
    input  wire                 rd_i,             // pop request
    output wire           [7:0] dout_o,           // head byte (combinational)

// status
    output wire                 empty_o,
    output wire                 full_o,
    output wire                 overrun_o         // 1-cycle: a byte was dropped (wr_i while full)
);

// Address / count widths. clog2() below is used instead of $clog2 to match the
// rest of this IP (which never relies on $clog2) and to stay Verilog-2001 safe
// across the full simulator matrix.
//   AW = pointer width  (indexes 0 .. DEPTH-1)
//   CW = count width    (holds 0 .. DEPTH inclusive)
function integer clog2;
    input integer value;
    integer i;
    begin
        clog2 = 0;
        for (i = value - 1; i > 0; i = i >> 1)
            clog2 = clog2 + 1;
    end
endfunction

localparam AW = (DEPTH < 2) ? 1 : clog2(DEPTH);
localparam CW = clog2(DEPTH + 1);

localparam PTR_LAST = DEPTH - 1;                          // last pointer index (wrap target)

// Storage. Deliberately un-reset (RAM on FPGA, flop bank on ASIC): reads are gated by
// empty_o, so a location is always written before it can be read and the X it holds
// until then is never observed. Resetting it would cost a flop bank and block RAM
// inference. Note DEPTH*8 is scan-chain length on ASIC -- 64 bytes = 512 cells.
reg  [7:0] mem [0:DEPTH-1];

// Registered pointers / occupancy
wire [AW-1:0] wr_ptr;
wire [AW-1:0] rd_ptr;
wire [CW-1:0] count;

reg  [AW-1:0] wr_ptr_nxt;
reg  [AW-1:0] rd_ptr_nxt;
reg  [CW-1:0] count_nxt;

// Status
assign empty_o   = (count == {CW{1'b0}});
assign full_o    = (count == DEPTH[CW-1:0]);

// Effective push / pop (a push into a full FIFO is dropped, not stored)
// Accept the push when a pop frees the slot in the same cycle: at full, rd_ptr ==
// wr_ptr, and dout_o is a combinational read while the store is an NBA, so the pop
// still returns the OLD byte. Dropping it here misframes the fixed-length request
// stream and can synthesise a bogus DMI transaction.
wire   rd_en     = rd_i & ~empty_o;
wire   wr_en     = wr_i & (~full_o | rd_en);

assign overrun_o = wr_i & ~wr_en;   // only a push we actually refused

// First-word-fall-through head byte
assign dout_o    = mem[rd_ptr];

//=============================================================================
// Storage write (no reset -- standard RAM inference; flush only moves pointers)
//=============================================================================
always @(posedge clk_i) begin
    if (wr_en) mem[wr_ptr] <= din_i;
end

//=============================================================================
// Pointer / count next-state (flush has highest priority)
//=============================================================================
always @(*) begin
    // write pointer
    if      (flush_i) wr_ptr_nxt = {AW{1'b0}};
    else if (wr_en)   wr_ptr_nxt = (wr_ptr == PTR_LAST[AW-1:0]) ? {AW{1'b0}} : wr_ptr + 1'b1;
    else              wr_ptr_nxt = wr_ptr;

    // read pointer
    if      (flush_i) rd_ptr_nxt = {AW{1'b0}};
    else if (rd_en)   rd_ptr_nxt = (rd_ptr == PTR_LAST[AW-1:0]) ? {AW{1'b0}} : rd_ptr + 1'b1;
    else              rd_ptr_nxt = rd_ptr;

    // occupancy count
    if      (flush_i)            count_nxt = {CW{1'b0}};
    else case ({wr_en, rd_en})
        2'b10  : count_nxt = count + 1'b1;   // push only
        2'b01  : count_nxt = count - 1'b1;   // pop only
        default: count_nxt = count;          // idle or simultaneous push+pop
    endcase
end

//=============================================================================
// Pointer / count registers (arv_ipdff: build-time async/sync reset via ARST_EN)
//=============================================================================
arv_ipdff #(.WIDTH(AW), .ARST_EN(ARST_EN)) u_wr_ptr (
                 .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(wr_ptr_nxt), .q_o(wr_ptr));

arv_ipdff #(.WIDTH(AW), .ARST_EN(ARST_EN)) u_rd_ptr (
                 .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(rd_ptr_nxt), .q_o(rd_ptr));

arv_ipdff #(.WIDTH(CW), .ARST_EN(ARST_EN)) u_count (
                 .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(count_nxt),  .q_o(count));


//=============================================================================
// PARAMETER RANGE CHECK
//=============================================================================
// pragma translate_off
generate
    if (DEPTH < 1) begin : CHECK_DEPTH
        initial $fatal(1, "arv_dtm_rxfifo: DEPTH (%0d) must be at least 1.", DEPTH);
    end
endgenerate
// pragma translate_on

endmodule // arv_dtm_rxfifo

`default_nettype wire
