//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arv_dtm_cmd
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arv_dtm_cmd
// Module Description : Turns a byte stream into DMI transactions ("DMI over
//                      serial") for the non-JTAG Debug Transport Modules.
//
//   WHAT IT IS
//     The shared logic core of the serial DTMs: arv_dtm_uart and arv_dtm_i2c both
//     wrap this one module and differ ONLY in their physical byte engine (PHY).
//     The DMI transaction it produces is identical across every transport,
//     JTAG included -- so one host tool speaks to all of them.
//
//   WIRE FORMAT  (byte-aligned; data is MSB-first 32-bit; one addr byte, so
//                 DMI_ABITS must be <= 8)
//     Request  (host -> DTM):  [SYNC][addr][d31:24][d23:16][d15:8][d7:0][op]
//     Response (DTM -> host):      [status][d31:24][d23:16][d15:8][d7:0]
//
//       op      (request) :  0 = nop/poll   1 = read   2 = write   3 = dmihardreset
//       status  (response):  the DMI op -- 0 = success   2 = failed (never busy)
//       SYNC              :  0x55, leads every request
//
//   FRAMING
//     Frames are fixed length, so a stray or lost byte only corrupts one frame;
//     the leading SYNC lets the FSM realign on the next one.
//
//   BUSY IS HIDDEN FROM THE HOST
//     On read/write the FSM launches the DMI op and stalls in S_WAIT until
//     arv_dtm_dmi_master drops 'inflight', then emits the response. A DMI access
//     takes a few clk cycles while the host runs at baud rate, so the result is
//     always ready by the time the host reads it -- it never polls busy or issues
//     dmireset. (A failed op still returns status=2; op=3 finds nothing outstanding.)
//
//   CLOCKING
//     Runs on the always-on oscillator clk_i (shared with the DMI bus and PHY), so
//     an incoming command can wake a WFI clock-gated hart -- same always-on
//     requirement as the JTAG DTM.
//----------------------------------------------------------------------------
`default_nettype none

module  arv_dtm_cmd #(
    parameter                   ARST_EN       = 1'b1, // 1=async active-low reset, 0=sync
    parameter                   RX_FIFO_DEPTH = 64    // RX byte-FIFO depth (request pipelining window)
) (
    input  wire                 clk_i,            // always-on oscillator (= DMI bus clock)
    input  wire                 dbgresetn_i,         // active-low reset

// Byte receive interface (from PHY)
    input  wire           [7:0] rx_data_i,        // received byte
    input  wire                 rx_valid_i,       // 1-cycle strobe: a byte arrived

// Frame resync (from PHY)
    input  wire                 frame_boundary_i, //  a frame delimiter (e.g. I2C STOP/START): resync only if mid-REQUEST (S_RX)
    input  wire                 frame_stop_i,     //  terminating delimiter (I2C STOP): also resyncs an abandoned response (S_RESP)
    input  wire                 rx_error_i,       //  a received byte was dropped (UART framing error): discard the partial request
    input  wire                 abort_i,          //  a hard abort (e.g. read-side watchdog): resync from ANY state (1-cycle pulse)

// Byte transmit interface (to PHY)
    output wire           [7:0] tx_data_o,        // byte to send
    output wire                 tx_valid_o,       // this module has a byte to send
    input  wire                 tx_ready_i,       // PHY accepts a byte this cycle (valid&ready=xfer)

// arv_dtm_dmi_master control interface
    output wire                 launch_o,         // 1-cycle: start a DMI read/write
    output wire           [6:0] req_addr_o,       // DMI address (DMI_ABITS bits)
    output wire           [1:0] req_op_o,         // 1=read, 2=write
    output wire          [31:0] req_data_o,
    output wire                 hardreset_o,      // 1-cycle: dmihardreset (abort + clear)
    input  wire                 inflight_i,       // a DMI transaction is in flight
    input  wire          [31:0] rdata_i,          // last completed read data
    input  wire           [1:0] cstatus_i         // last completed status (0 ok / 2 failed)
);

// DMI address width. Fixed at the arvern core's value; not a knob (no use case
// for another width). One address byte carries it (DMI_ABITS <= 8).
localparam           DMI_ABITS = 7;

localparam     [7:0] SYNC = 8'h55;

// request op encodings
localparam     [1:0] OP_READ  = 2'd1,
                     OP_WRITE = 2'd2,
                     OP_HRST  = 2'd3;             // OP_NOP=0 is the default case

// DTMSTS: a DTM-local status register at the top of the 7-bit DMI address space.
// It is intercepted here (NOT forwarded to the DMI master): the host reads it to
// discover the RX FIFO depth (pipelining window) and the sticky overrun flag, and
// writes bit0=1 to clear that flag (write-1-to-clear). 0x7F is reserved -- it does
// not collide with any real DM register (standard DM regs are <= ~0x40).
localparam [DMI_ABITS-1:0] DTMSTS_ADDR = 7'h7F;

// rx_fifo_depth field in DTMSTS[15:8]. Saturated, not truncated: the host sizes its
// pipeline from it, and a 256-deep FIFO must not report 0.
localparam           [7:0] RX_FIFO_DEPTH8 = (RX_FIFO_DEPTH > 255) ? 8'hFF : RX_FIFO_DEPTH[7:0];

// FSM states
localparam     [2:0] S_SYNC   = 3'd0,             // wait for the SYNC byte
                     S_RX     = 3'd1,             // collect the 6 payload bytes
                     S_EXEC   = 3'd2,             // issue the DMI op (1-cycle launch/hardreset pulse)
                     S_WAIT   = 3'd3,             // block until the DMI op completes (busy hidden)
                     S_RESP   = 3'd4;             // serialise the 5 response bytes

// Registered state
wire           [2:0] state;
wire           [2:0] rxcnt;                       // 0..5 request payload byte index
wire           [2:0] txcnt;                       // 0..4 response byte index
wire [DMI_ABITS-1:0] addr_r;
wire          [31:0] data_r;
wire           [1:0] op_r;
wire          [31:0] rdata_r;                     // captured read data for the response
wire           [1:0] status_r;                    // captured status for the response

reg            [2:0] state_nxt;
reg            [2:0] rxcnt_nxt;
reg            [2:0] txcnt_nxt;
reg  [DMI_ABITS-1:0] addr_nxt;
reg           [31:0] data_nxt;
reg            [1:0] op_nxt;
reg           [31:0] rdata_nxt;
reg            [1:0] status_nxt;

// DTMSTS interception (resolved combinationally in S_EXEC; addr_r is stable there).
wire                 dtmsts_sel = (addr_r == DTMSTS_ADDR);

//=============================================================================
// RX byte FIFO. Buffers request bytes that arrive while the FSM is busy
// (EXEC/WAIT/RESP) so the host can pipeline requests. The FSM reads the FIFO head
// (fifo_dout) instead of the PHY strobe, and pops one byte per consuming cycle.
//=============================================================================
wire           [7:0] fifo_dout;
wire                 fifo_empty;
wire                 fifo_full_unused;   // full_o is exposed by the FIFO but not consumed here
wire                 fifo_overrun;

// Drop stale/garbage queued bytes on a resync: a hard abort (from any state), a
// frame boundary, or an overrun. Framing recovery must start from a clean, empty
// FIFO so a crashed/aborted session's bytes cannot replay after re-sync, and a
// frame truncated by an overrun cannot be completed by the bytes that follow it.
wire                 fifo_flush = abort_i | frame_boundary_i | frame_stop_i | fifo_overrun | rx_error_i;

// The FSM consumes one queued byte per cycle whenever it is in a receiving state.
// In S_SYNC it pops every byte (staying in S_SYNC until it sees 0x55); in S_RX it
// collects the 6 payload bytes. rd_i = rx_take pops the current head this cycle.
wire                 rx_take = ~fifo_empty & ((state == S_SYNC) | (state == S_RX));

arv_dtm_rxfifo #(.DEPTH(RX_FIFO_DEPTH), .ARST_EN(ARST_EN)) u_rxfifo (
    .clk_i       ( clk_i        ),
    .dbgresetn_i ( dbgresetn_i  ),
    .flush_i     ( fifo_flush   ),
    .wr_i        ( rx_valid_i   ),
    .din_i       ( rx_data_i    ),
    .rd_i        ( rx_take      ),
    .dout_o      ( fifo_dout    ),
    .empty_o     ( fifo_empty       ),
    .full_o      ( fifo_full_unused ),
    .overrun_o   ( fifo_overrun     )
);

// transfer strobes
wire                 tx_xfer = tx_valid_o & tx_ready_i; // a response byte was accepted

//=============================================================================
// Sticky RX overrun (DTMSTS[0]). SET when the FIFO drops a byte (fifo_overrun);
// CLEARED only by a DTMSTS write with data bit0=1 (write-1-to-clear). It survives
// fifo_flush/abort by design so the host can read the cause after a resync -- the
// flop is not touched by the flush path. Set takes priority over clear so a drop
// coincident with a W1C stays recorded.
//=============================================================================
wire                 rx_overrun;
wire                 dtmsts_w1c  = (state == S_EXEC) & dtmsts_sel &
                                   (op_r == OP_WRITE) & data_r[0]; // DTMSTS write, bit0=1
wire                 rx_overrun_nxt = fifo_overrun ? 1'b1 :
                                      dtmsts_w1c   ? 1'b0 : rx_overrun;

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_rx_overrun (
                 .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                       .d_i (rx_overrun_nxt),
                                                       .q_o (rx_overrun));

// Locally-composed DTMSTS read data (bit0 = sticky overrun, [15:8] = FIFO depth).
wire          [31:0] dtmsts_rdata = {16'b0, RX_FIFO_DEPTH8, 7'b0, rx_overrun};


//=============================================================================
// FSM next-state (combinational; every register holds its value by default)
//=============================================================================
// A terminating STOP that arrives while the op executes (S_EXEC) or is still in flight
// (S_WAIT) has no response state to resync yet -- and the FSM then enters S_RESP with
// txcnt == 0, which the S_RESP guard deliberately ignores. Remember it, so the reply
// is discarded rather than serialised to a host that has already gone.
wire abandoned;
reg  abandoned_nxt;

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_abandoned (
    .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(abandoned_nxt), .q_o(abandoned));

always @(*) begin
    state_nxt  = state;
    rxcnt_nxt  = rxcnt;
    txcnt_nxt  = txcnt;
    addr_nxt   = addr_r;
    data_nxt   = data_r;
    op_nxt     = op_r;
    rdata_nxt  = rdata_r;
    status_nxt = status_r;

    abandoned_nxt = (state == S_SYNC) ? 1'b0 :
                    (frame_stop_i && ((state == S_EXEC) || (state == S_WAIT))) ? 1'b1
                                                                               : abandoned;

    case (state)

        //-----------------------------------------------------------------
        S_SYNC : begin
            txcnt_nxt = 3'd0;
            if (rx_take && (fifo_dout == SYNC)) begin
                rxcnt_nxt = 3'd0;
                state_nxt = S_RX;
            end
        end

        //-----------------------------------------------------------------
        // Collect [addr][d31:24][d23:16][d15:8][d7:0][op]
        S_RX : begin
            if (rx_take) begin
                case (rxcnt)
                    3'd0 : addr_nxt        = fifo_dout[DMI_ABITS-1:0];
                    3'd1 : data_nxt[31:24] = fifo_dout;
                    3'd2 : data_nxt[23:16] = fifo_dout;
                    3'd3 : data_nxt[15:8]  = fifo_dout;
                    3'd4 : data_nxt[7:0]   = fifo_dout;
                    3'd5 : op_nxt          = fifo_dout[1:0];
                    default : ;
                endcase
                if (rxcnt == 3'd5) state_nxt = S_EXEC;
                else               rxcnt_nxt = rxcnt + 3'd1;
            end
        end

        //-----------------------------------------------------------------
        // Issue the op. launch_o / hardreset_o are combinational pulses that
        // are high only during this single cycle.
        S_EXEC : begin
            if (dtmsts_sel && ((op_r == OP_READ) || (op_r == OP_WRITE))) begin
                // DTMSTS local register: do NOT launch a DMI op. Skip S_WAIT and
                // respond locally with the status word, READ and WRITE alike (a WRITE
                // returns the value before its W1C effect, applied by dtmsts_w1c).
                status_nxt = 2'd0;                       // success
                rdata_nxt  = dtmsts_rdata;
                state_nxt  = S_RESP;
            end else if (inflight_i && ((op_r == OP_READ) || (op_r == OP_WRITE))) begin
                // Unreachable by construction (S_WAIT blocks, and abort_i drops any
                // outstanding op via hardreset_o). Kept so that a broken invariant
                // fails loudly rather than returning the previous op's data as
                // this one's result.
                status_nxt = 2'd2;                       // failed
                rdata_nxt  = 32'b0;
                state_nxt  = S_RESP;
            end else begin
                case (op_r)
                    OP_READ, OP_WRITE : state_nxt = S_WAIT;  // launch_o pulses now
                    OP_HRST           : begin                // hardreset_o pulses now
                        status_nxt = 2'd0;
                        rdata_nxt  = 32'b0;
                        state_nxt  = S_RESP;
                    end
                    default : begin                          // OP_NOP: poll last result
                        status_nxt = cstatus_i;
                        rdata_nxt  = rdata_i;
                        state_nxt  = S_RESP;
                    end
                endcase
            end
        end

        //-----------------------------------------------------------------
        // Block until the DMI op completes (inflight goes high one cycle
        // after launch and stays high until the response returns). This is
        // what hides busy from the host.
        S_WAIT : begin
            if (!inflight_i) begin
                status_nxt = cstatus_i;
                rdata_nxt  = rdata_i;
                // A STOP in this same cycle abandons the response too.
                state_nxt  = (abandoned | frame_stop_i) ? S_SYNC : S_RESP;
                txcnt_nxt  = 3'd0;
            end
        end

        //-----------------------------------------------------------------
        // Serialise [status][d31:24][d23:16][d15:8][d7:0]
        S_RESP : begin
            if (tx_xfer) begin
                if (txcnt == 3'd4) state_nxt = S_SYNC;
                else               txcnt_nxt = txcnt + 3'd1;
            end
        end

        //-----------------------------------------------------------------
        default : state_nxt = S_SYNC;
    endcase

    // Frame resync (overrides the case above). A hard abort resyncs from any state; a
    // frame boundary or a dropped byte only a mid-request FSM (S_RX, or S_SYNC taking a
    // SYNC in that cycle) -- never the repeated START between a request and its response.
    // fifo_overrun cannot fire here (these states always pop, so a full FIFO never drops):
    // the flush handles an overrun; the term is kept as a guard.
    //
    // frame_stop_i (I2C STOP, never a repeated START) additionally resyncs an ABANDONED
    // response, which would otherwise park the FSM in S_RESP forever and hand its stale
    // tail to the next read. Safe: the 5th tx_xfer returns to S_SYNC before the normal
    // NACK+STOP, so a STOP seen in S_RESP means the host gave up.
    // abandoned in S_RESP is a STOP taken in the S_EXEC cycle of a locally
    // answered request (poll, hardreset, DTMSTS), which skips S_WAIT.
    if (abort_i) begin
        state_nxt = S_SYNC;
        rxcnt_nxt = 3'd0;
        txcnt_nxt = 3'd0;
    end else if ((frame_boundary_i | fifo_overrun | rx_error_i) && ((state == S_RX) || (state == S_SYNC))) begin
        state_nxt = S_SYNC;
        rxcnt_nxt = 3'd0;
    end else if ((frame_stop_i || abandoned || (frame_boundary_i && (txcnt != 3'd0))) && (state == S_RESP)) begin
        // Both terms are needed: a STOP resyncs at any txcnt, a repeated START only
        // with txcnt != 0. txcnt can only leave 0 via tx_xfer (needs the read-address
        // ACK), so at the legitimate request->response repeated START txcnt is 0 --
        // any boundary here with txcnt != 0 is an abandoned response.
        state_nxt = S_SYNC;
        txcnt_nxt = 3'd0;
    end
end

//=============================================================================
// State registers (arv_ipdff: build-time async/sync reset via ARST_EN)
//=============================================================================

arv_ipdff #(.WIDTH(3), .RST_VAL(S_SYNC), .ARST_EN(ARST_EN)) u_state  (
                       .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(state_nxt),  .q_o(state));

arv_ipdff #(.WIDTH(3),                   .ARST_EN(ARST_EN)) u_rxcnt  (
                       .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(rxcnt_nxt),  .q_o(rxcnt));

arv_ipdff #(.WIDTH(3),                   .ARST_EN(ARST_EN)) u_txcnt  (
                       .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(txcnt_nxt),  .q_o(txcnt));

arv_ipdff #(.WIDTH(DMI_ABITS),           .ARST_EN(ARST_EN)) u_addr   (
                       .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(addr_nxt),   .q_o(addr_r));

arv_ipdff #(.WIDTH(32),                  .ARST_EN(ARST_EN)) u_data   (
                       .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(data_nxt),   .q_o(data_r));

arv_ipdff #(.WIDTH(2),                   .ARST_EN(ARST_EN)) u_op     (
                       .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(op_nxt),     .q_o(op_r));

arv_ipdff #(.WIDTH(32),                  .ARST_EN(ARST_EN)) u_rdata  (
                       .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(rdata_nxt),  .q_o(rdata_r));

arv_ipdff #(.WIDTH(2),                   .ARST_EN(ARST_EN)) u_status (
                       .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(status_nxt), .q_o(status_r));


//=============================================================================
// Outputs
//=============================================================================
// inflight rises exactly one cycle after launch (arv_dtm_dmi_master.u_inflight is
// a flop with d=launch), so entering S_WAIT we are guaranteed inflight=1 already.
// ~inflight_i: never launch on top of an outstanding transaction (matches the JTAG
// TAP's guard). Launching on top silently answers with the previous op's data.
// ~abort_i: launch and hardreset must be MUTUALLY EXCLUSIVE -- asserting both wedges
// inflight (the master latches it while the hclk side refuses the request).
assign launch_o    = (state == S_EXEC) & ((op_r == OP_READ) | (op_r == OP_WRITE)) & ~dtmsts_sel & ~inflight_i & ~abort_i;

// A resync must also DROP any outstanding transaction, else the next request collides
// with it. The master turns hardreset_i into a level TOGGLE, so it must be exactly one
// cycle wide -- edge-detect abort_i rather than trusting each PHY to pulse it.
wire abort_d;
arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_abort_d (
                       .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(abort_i), .q_o(abort_d));

assign hardreset_o = ((state == S_EXEC) & (op_r == OP_HRST)) | (abort_i & ~abort_d);

assign req_addr_o  = addr_r;
assign req_op_o    = op_r;
assign req_data_o  = data_r;

// response byte mux
reg [7:0] tx_byte;
always @(*) begin
    case (txcnt)
        3'd0    : tx_byte = {6'b0, status_r};
        3'd1    : tx_byte = rdata_r[31:24];
        3'd2    : tx_byte = rdata_r[23:16];
        3'd3    : tx_byte = rdata_r[15:8];
        default : tx_byte = rdata_r[7:0];
    endcase
end

assign tx_data_o  = tx_byte;
assign tx_valid_o = (state == S_RESP);

endmodule // arv_dtm_cmd

`default_nettype wire
