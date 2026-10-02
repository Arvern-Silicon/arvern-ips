//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arv_dtm_uart
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arv_dtm_uart
// Module Description : UART Debug Transport Module (DTM) for the aRVern core -- a
//                      serial, custom but DMI-native transport aimed at the
//                      student / hobbyist space. An FPGA board's native UART carries
//                      ordinary DMI transactions to the core's Debug Module, driven
//                      by a small custom host tool. It re-casts the openMSP430
//                      dbg_uart use-model onto RISC-V DMI: the UART is only the PHY,
//                      so the {address, op, data} transaction it moves is identical
//                      to the JTAG and I2C DTMs.
//
//   The link is self-calibrating: there is NO configured baud. The host opens every
//   session by sending one 0x80 sync char; the DTM measures the host baud from it and
//   echoes 0x80 back at that measured baud as a handshake ACK (see the auto-baud block).
//   The host thus never needs out-of-band knowledge of the DTM clock.
//
//   Every serial DTM shares the same brain and backend; only this PHY changes:
//     uart RX/TX (this file) -> arv_dtm_cmd (DMI command interpreter)
//                            -> arv_dtm_dmi_master (DMI bus + clock crossing)
//
//----------------------------------------------------------------------------
`default_nettype none

module  arv_dtm_uart #(
    parameter                   ARST_EN       = 1'b1,        // 1=async active-low reset, 0=sync
    parameter [31:0]            AB_BREAK_CLKS = 32'd1048576, // continuous-low clk_i cycles that force a break re-arm
                                                             //   (lowest baud = 16*f_clk/AB_BREAK_CLKS: 1Mi keeps 9600 up to ~629 MHz)
    parameter                   RX_FIFO_DEPTH = 64           // RX byte-FIFO depth (request pipelining window)
) (
    input  wire                 clk_i,                       // always-on oscillator (= DMI bus clock)
    input  wire                 dbgresetn_i,                 // active-low reset

// UART pins
    input  wire                 uart_rx_i,                   // serial in  (idle high)
    output wire                 uart_tx_o,                   // serial out (idle high)

// aRVern APB4 DMI bus (same clk_i domain)
    output wire                 dmi_psel_o,
    output wire                 dmi_penable_o,
    output wire           [8:0] dmi_paddr_o,                 // [DMI_ABITS+1:0]
    output wire                 dmi_pwrite_o,
    output wire          [31:0] dmi_pwdata_o,
    output wire           [2:0] dmi_pprot_o,
    input  wire                 dmi_pready_i,
    input  wire          [31:0] dmi_prdata_i,
    input  wire                 dmi_pslverr_i
);

//=============================================================================
// RX line 2-FF synchroniser (uart_rx_i is asynchronous to clk_i)
//=============================================================================

wire rx_sync;
arv_synchronizer #(.W(1), .RST_VAL(1'b1), .ARST_EN(ARST_EN)) u_rx_sync (
                                  .clk_i(clk_i), .rst_n_i(dbgresetn_i), .async_i(uart_rx_i),
                                                                        .sync_o (rx_sync));

//=============================================================================
// 3-tap majority-vote glitch filter (openMSP430 rxd_buf / rxd_maj). Produces a
// filtered level plus one-cycle edge strobes reused by auto-baud and re-centring.
// Reset HIGH (idle) so no spurious start bit is seen coming out of reset.
//=============================================================================
wire [1:0] rxd_buf;
wire       rxd_maj;
wire       rxd_maj_nxt = (rx_sync & rxd_buf[0]) |
                         (rx_sync & rxd_buf[1]) |
                         (rxd_buf[0] & rxd_buf[1]);

wire [1:0] rxd_buf_d   = {rxd_buf[0], rx_sync};
wire       rxd_maj_d   =  rxd_maj_nxt;

arv_ipdff #(.WIDTH(2), .RST_VAL(2'b11), .ARST_EN(ARST_EN)) u_rxd_buf (
                                .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                                      .d_i (rxd_buf_d),
                                                                      .q_o (rxd_buf));

arv_ipdff #(.WIDTH(1), .RST_VAL(1'b1),  .ARST_EN(ARST_EN)) u_rxd_maj (
                                .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                                      .d_i (rxd_maj_d),
                                                                      .q_o (rxd_maj));

wire       rxd_lvl     =  rxd_maj;                                  // filtered RX level
wire       rxd_fe      =  rxd_maj & ~rxd_maj_nxt;                   // falling edge
wire       rxd_edge    =  rxd_maj ^  rxd_maj_nxt;                   // any transition


//=============================================================================
// Auto-baud + sync handshake (openMSP430 DBG_UART_AUTO_SYNC lineage). No configured
// baud: the host sends one 0x80 sync char, whose low run is exactly 8 bit-times
// (8-N-1 LSB-first), and this unit measures the divisor from it. sync_ok gates the RX
// data FSM, so the 0x80 is consumed here and never reaches arv_dtm_cmd.
//
// Acquisition is 3-phase (ARM -> MEAS -> HOLD) so a glitch or a wrong first byte is
// rejected instead of freezing a garbage divisor. Three independent re-arm paths then
// recover a bad lock without a chip reset: sync echo, framing-error count, and break.
// Full protocol rationale + the AB_BREAK_CLKS sizing table: doc/arv_dtm_uart.md.
//=============================================================================

localparam [31:0] AB_DIV_FLOOR = 32'd2;                      // min bit period in clks (keeps RX bit_half >= 1)
// Upper bound, derived from the break sizing rather than a new magic number: a lock this
// slow could not be escaped, because one byte would outlast the break window itself
// (9.5 x ab_div > AB_BREAK_CLKS) and the RX FSM would still be mid-byte when the re-arm
// lands. >>4 leaves headroom and sets the lowest baud: 16*f_clk/AB_BREAK_CLKS (~763 at
// the 1Mi default and 50 MHz; 9600 up to ~629 MHz).
localparam [31:0] AB_DIV_CEIL  = AB_BREAK_CLKS >> 4;
// Longest low run ab_div_ok can accept: (ab_cnt + 4) >> 3 <= AB_DIV_CEIL. MEAS gives up
// past it, so ab_cnt stays bounded however long the line is held low.
localparam [31:0] AB_MEAS_MAX  = (AB_DIV_CEIL << 3) + 32'd3;
localparam [1:0]  AB_FERR_LIM  = 2'd3;                       // consecutive framing errors that force a re-arm

wire        rx_stop;
wire        rx_valid;
wire        ab_meas;                                         // phase 2: timing the low run
wire        ab_hold;                                         // phase 3: validating trailing high
wire        ab_done;                                         // locked on a validated 0x80
wire [31:0] ab_cnt;                                          // low-run count, then reused as hold count
wire [31:0] ab_div;                                          // provisional in HOLD, live once ab_done
wire        ab_re          = ~rxd_maj & rxd_maj_nxt;         // rising edge (end of the low period)

wire [31:0] ab_tent_div    = (ab_cnt + 32'd4) >> 3;          // low run / 8 (round-to-nearest)
wire        ab_div_ok      = (ab_tent_div >= AB_DIV_FLOOR) &  // reject degenerate glitch runs
                             (ab_tent_div <= AB_DIV_CEIL);   // ...and unescapable slow locks
wire [31:0] ab_hold_target = ab_div + (ab_div >> 1);         // ~1.5 measured bit periods

// Consecutive framing errors: a persistent wrong baud trips this (every stop bit
// corrupt), a single glitch cannot (any valid byte clears it).
wire        rx_frame_err   = rx_stop & ~rxd_lvl;             // stop bit sampled low
wire [1:0]  ferr_cnt;
wire        break_rearm;                                     // long-low reconnect (declared below)
wire        ab_rearm       = (ferr_cnt == AB_FERR_LIM) | break_rearm;
wire [1:0]  ferr_cnt_nxt   = (rx_valid | ab_rearm) ? 2'd0            :
                              rx_frame_err         ? ferr_cnt + 2'd1 : ferr_cnt;

// Break re-arm: host-initiated reconnect, and the only path that recovers a command
// interpreter stranded mid-frame (there the reconnecting 0x80 is eaten as payload, so
// the framing-error count never trips).
//
// DO NOT make the threshold baud-relative. The break exists to escape a BAD lock, so
// it must not depend on the measurement it is resetting -- a divisor mis-measured huge
// would push a baud-relative threshold out of the host's reach. Raw clk_i cycles make
// recovery identical whether the lock is right, aliased, or wildly wrong.
//
// AB_BREAK_CLKS must exceed the longest legal low (a 0x00 byte = 9 bit-times at the
// slowest supported baud) or real traffic false-fires. Sizing table: doc/arv_dtm_uart.md.
wire [31:0] lowrun_cnt;
assign      break_rearm  =   ab_done & (lowrun_cnt >= AB_BREAK_CLKS);
wire [31:0] lowrun_nxt   = (~ab_done | rxd_lvl | break_rearm) ? 32'd0 : lowrun_cnt + 32'd1;

reg         ab_meas_nxt;
reg         ab_hold_nxt;
reg         ab_done_nxt;
reg  [31:0] ab_cnt_nxt;
reg  [31:0] ab_div_nxt;

always @(*) begin
    ab_meas_nxt = ab_meas;
    ab_hold_nxt = ab_hold;
    ab_done_nxt = ab_done;
    ab_cnt_nxt  = ab_cnt;
    ab_div_nxt  = ab_div;
    if (ab_rearm) begin                               // wrong lock -> re-arm (host resends 0x80)
        ab_done_nxt = 1'b0;
        ab_meas_nxt = 1'b0;
        ab_hold_nxt = 1'b0;
    end else if (!ab_done) begin
        if (ab_hold) begin                            // phase 3: trailing-high validation
            if      (rxd_fe)                    ab_hold_nxt = 1'b0;  // early low -> reject, re-arm
            else if (ab_cnt >= ab_hold_target) begin
                ab_done_nxt = 1'b1;                                  // 0x80 confirmed -> lock div
                ab_hold_nxt = 1'b0;
            end else if (rxd_lvl)               ab_cnt_nxt  = ab_cnt + 32'd1;  // rxd_lvl always 1 here; kept for intent
        end else if (ab_meas) begin                   // phase 2: time the low run
            if (ab_re) begin                                         // end of the low run
                ab_meas_nxt = 1'b0;
                if (ab_div_ok) begin                                 // plausible bit period?
                    ab_div_nxt  = ab_tent_div;                       // provisional (not yet live)
                    ab_hold_nxt = 1'b1;
                    ab_cnt_nxt  = 32'd0;                             // reuse cnt for the hold
                end                                                  // else too short -> re-arm
            end else if (ab_cnt > AB_MEAS_MAX)
                ab_meas_nxt = 1'b0;                                  // too long for any 0x80 -> re-arm
            else
                ab_cnt_nxt  = ab_cnt + 32'd1;
        end else if (rxd_fe) begin                    // phase 1 (ARM): candidate start bit
            ab_meas_nxt = 1'b1;
            ab_cnt_nxt  = 32'd0;
        end
    end
end

arv_ipdff #(.WIDTH(1),                          .ARST_EN(ARST_EN)) u_ab_meas (
                                         .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                                               .d_i (ab_meas_nxt),
                                                                               .q_o (ab_meas));

arv_ipdff #(.WIDTH(1),                          .ARST_EN(ARST_EN)) u_ab_hold (
                                         .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                                               .d_i (ab_hold_nxt),
                                                                               .q_o (ab_hold));

arv_ipdff #(.WIDTH(1),                          .ARST_EN(ARST_EN)) u_ab_done (
                                         .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                                               .d_i (ab_done_nxt),
                                                                               .q_o (ab_done));

arv_ipdff #(.WIDTH(32),                         .ARST_EN(ARST_EN)) u_ab_cnt (
                                         .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                                               .d_i (ab_cnt_nxt),
                                                                               .q_o (ab_cnt));

arv_ipdff #(.WIDTH(32), .RST_VAL(AB_DIV_FLOOR), .ARST_EN(ARST_EN)) u_ab_div (
                                         .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                                               .d_i (ab_div_nxt),
                                                                               .q_o (ab_div));

arv_ipdff #(.WIDTH(2),                          .ARST_EN(ARST_EN)) u_ferr_cnt (
                                         .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                                               .d_i (ferr_cnt_nxt),
                                                                               .q_o (ferr_cnt));

arv_ipdff #(.WIDTH(32),                         .ARST_EN(ARST_EN)) u_lowrun_cnt (
                                         .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                                               .d_i (lowrun_nxt),
                                                                               .q_o (lowrun_cnt));

wire        sync_ok  = ab_done;
wire [31:0] baud_div = ab_div;

wire [31:0] bit_full = baud_div - 32'd1;                   // full bit period (counter target)
wire [31:0] bit_half = baud_div >> 1;                      // half period (mid-bit centring)


//=============================================================================
// UART receiver: one down-counter (rx_cnt) times each bit; rx_idx walks start +
// 8 data bits. The sample strobe (rx_tick) is COMBINATIONAL off rx_cnt==0, while
// the edge re-centre only rewrites rx_cnt's NEXT value -- so an edge coinciding
// with the terminal count can never suppress a sample (openMSP430 decoupling).
//   rx_idx: 0 = idle, 1 = start bit (discarded), 2..9 = data bits d0..d7.
//=============================================================================
wire [31:0] rx_cnt;
wire  [3:0] rx_idx;
wire  [6:0] rx_shift;                                                      // accumulates d0..d6 (LSB-first)
wire  [7:0] rx_data;

reg  [31:0] rx_cnt_nxt;
reg   [3:0] rx_idx_nxt;
reg   [6:0] rx_shift_nxt;
reg   [7:0] rx_data_nxt;
reg         rx_valid_nxt;

wire        rx_active   = (rx_idx != 4'd0);
wire        rx_start    = sync_ok   & ~rx_active & rxd_fe;                 // start-bit edge while idle & synced
wire        rx_tick     = rx_active & (rx_cnt == 32'd0);                   // one bit period elapsed
wire        rx_false_st = rx_tick   & (rx_idx == 4'd1) & rxd_lvl;          // line high again mid start bit
wire        rx_shift_en = rx_tick   & (rx_idx >= 4'd2) & (rx_idx <= 4'd8); // ticks 2..8 = d0..d6
wire        rx_data_end = rx_tick   & (rx_idx == 4'd9);                    // tick 9  = d7    -> byte assembled
assign      rx_stop     = rx_tick   & (rx_idx == 4'd10);                   // tick 10 = stop  -> frame check + retire

always @(*) begin
    rx_idx_nxt   = rx_idx;
    rx_cnt_nxt   = rx_cnt;
    rx_shift_nxt = rx_shift;
    rx_data_nxt  = rx_data;
    rx_valid_nxt = 1'b0;                                                   // 1-cycle strobe by default

    // Bit index: arm on the start edge, advance per tick, retire after the stop bit.
    // A start bit that is high again at its middle was a glitch: back to idle.
    if      (rx_start)             rx_idx_nxt   = 4'd1;
    else if (rx_stop | rx_false_st) rx_idx_nxt  = 4'd0;
    else if (rx_tick)              rx_idx_nxt   = rx_idx + 4'd1;

    // Bit-period counter (edge re-centre priority; sets only the NEXT value).
    if      (rx_start)             rx_cnt_nxt   = bit_half;                // center on mid of start bit
    else if (rx_active & rxd_edge) rx_cnt_nxt   = bit_half;                // re-centre on every transition
    else if (rx_tick)              rx_cnt_nxt   = bit_full;                // step to next bit
    else if (|rx_cnt)              rx_cnt_nxt   = rx_cnt - 32'd1;

    // Data assembly (right-shift, LSB-first). d0..d6 shift in; d7 caps the byte.
    if (rx_shift_en)               rx_shift_nxt = {rxd_lvl, rx_shift[6:1]};
    if (rx_data_end)               rx_data_nxt  = {rxd_lvl, rx_shift};     // {d7, d6..d0}

    // Retire only on a valid (high) stop bit. A framing error (stop bit low --
    // baud mismatch or line noise) DROPS the byte and discards the request it
    // belonged to (rx_error_i), so the fixed-length interpreter never completes a
    // frame with the next request's bytes. Persistent framing errors also drive
    // the auto-baud re-arm (ferr_cnt above).
    if (rx_stop && rxd_lvl)        rx_valid_nxt = 1'b1;

    // A re-arm means the baud is about to be re-measured, so a byte in flight is
    // garbage at the new rate and its stale bit_half can outlast the break window --
    // leaving rx_active stuck across the host's whole first request. Mirrors the TX
    // flush below. Cannot drop a good byte: on the break path the line was low
    // throughout, on the ferr path rx_idx is already 0.
    if (ab_rearm) begin
        rx_idx_nxt   =  4'd0;
        rx_cnt_nxt   = 32'd0;
        rx_valid_nxt =  1'b0;
    end
end

arv_ipdff #(.WIDTH(32), .ARST_EN(ARST_EN)) u_rx_cnt (
                 .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                       .d_i (rx_cnt_nxt),
                                                       .q_o (rx_cnt));

arv_ipdff #(.WIDTH(4),  .ARST_EN(ARST_EN)) u_rx_idx (
                 .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                       .d_i (rx_idx_nxt),
                                                       .q_o (rx_idx));

arv_ipdff #(.WIDTH(7),  .ARST_EN(ARST_EN)) u_rx_shift (
                 .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                       .d_i (rx_shift_nxt),
                                                       .q_o (rx_shift));

arv_ipdff #(.WIDTH(8),  .ARST_EN(ARST_EN)) u_rx_data (
                 .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                       .d_i (rx_data_nxt),
                                                       .q_o (rx_data));

arv_ipdff #(.WIDTH(1),  .ARST_EN(ARST_EN)) u_rx_valid (
                 .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                       .d_i (rx_valid_nxt),
                                                       .q_o (rx_valid));


//=============================================================================
// Sync-echo one-shot. On each rising edge of sync_ok (initial lock or a re-lock after
// a re-arm) transmit a single 0x80 back to the host at the measured baud, so the host
// can validate the baud round-trip.
//=============================================================================
wire       sync_ok_d;
arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_sync_ok_d (
                 .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                       .d_i (sync_ok),
                                                       .q_o (sync_ok_d));

wire       echo_pending;
wire       tx_ready;
wire       cmd_tx_valid;

wire       sync_lock_re     = sync_ok & ~sync_ok_d;                      // rising edge of the baud lock
wire       echo_fire        = echo_pending & tx_ready & ~cmd_tx_valid;   // fill an idle TX slot only
wire       echo_pending_nxt = sync_lock_re ? 1'b1 :
                              echo_fire    ? 1'b0 : echo_pending;

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_echo_pending (
                    .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                          .d_i (echo_pending_nxt),
                                                          .q_o (echo_pending));


//=============================================================================
// UART transmitter (8-N-1). tx_ready is combinational (high only when idle). Uses
// bit_full so the reply (cmd response or sync echo) goes out at the measured host baud.
// tx_data/tx_valid mux the sync echo (0x80) behind arv_dtm_cmd's response bytes.
//=============================================================================
localparam [1:0] TX_IDLE  = 2'd0,
                 TX_START = 2'd1,
                 TX_DATA  = 2'd2,
                 TX_STOP  = 2'd3;

wire       [1:0] tx_state;
wire       [7:0] cmd_tx_data;                              // arv_dtm_cmd response byte

assign           tx_ready = (tx_state == TX_IDLE);
wire       [7:0] tx_data  = echo_fire ? 8'h80 : cmd_tx_data;
wire             tx_valid = echo_fire ? 1'b1  : cmd_tx_valid;

wire      [31:0] tx_cnt;
wire       [2:0] tx_bit;
wire       [7:0] tx_shift;
wire             tx_line;

reg        [1:0] tx_state_nxt;
reg       [31:0] tx_cnt_nxt;
reg        [2:0] tx_bit_nxt;
reg        [7:0] tx_shift_nxt;
reg              tx_line_nxt;

always @(*) begin
    tx_state_nxt = tx_state;
    tx_cnt_nxt   = tx_cnt;
    tx_bit_nxt   = tx_bit;
    tx_shift_nxt = tx_shift;
    tx_line_nxt  = tx_line;
    case (tx_state)
        TX_IDLE : begin
            tx_line_nxt = 1'b1;
            tx_cnt_nxt  = 32'd0;
            if (tx_valid) begin                        // valid & ready -> accept
                tx_shift_nxt = tx_data;
                tx_state_nxt = TX_START;
            end
        end
        TX_START : begin
            tx_line_nxt = 1'b0;                        // start bit
            if (tx_cnt >= bit_full) begin
                tx_cnt_nxt   = 32'd0;
                tx_bit_nxt   = 3'd0;
                tx_state_nxt = TX_DATA;
            end else
                tx_cnt_nxt   = tx_cnt + 32'd1;
        end
        TX_DATA : begin
            tx_line_nxt = tx_shift[tx_bit];
            if (tx_cnt >= bit_full) begin
                tx_cnt_nxt = 32'd0;
                if (tx_bit == 3'd7) tx_state_nxt = TX_STOP;
                else                tx_bit_nxt   = tx_bit + 3'd1;
            end else tx_cnt_nxt = tx_cnt + 32'd1;
        end
        default /*TX_STOP*/ : begin
            tx_line_nxt = 1'b1;                        // stop bit
            if (tx_cnt >= bit_full) begin
                tx_state_nxt = TX_IDLE;
            end else tx_cnt_nxt = tx_cnt + 32'd1;
        end
    endcase

    // A re-arm means the baud is about to be re-measured, so a byte still in flight
    // is garbage at the new rate -- and its bit_full can shrink below tx_cnt, which
    // with a bare equality would strand the FSM. Drop it and idle the line, leaving
    // TX free to send the post-lock echo the host is waiting for.
    if (ab_rearm) begin
        tx_state_nxt = TX_IDLE;
        tx_cnt_nxt   = 32'd0;
        tx_line_nxt  = 1'b1;
    end
end

arv_ipdff #(.WIDTH(2), .RST_VAL(TX_IDLE), .ARST_EN(ARST_EN)) u_tx_state (
                                   .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                                         .d_i(tx_state_nxt),
                                                                         .q_o(tx_state));

arv_ipdff #(.WIDTH(32),                   .ARST_EN(ARST_EN)) u_tx_cnt (
                                   .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                                         .d_i (tx_cnt_nxt),
                                                                         .q_o (tx_cnt));

arv_ipdff #(.WIDTH(3),                    .ARST_EN(ARST_EN)) u_tx_bit (
                                   .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                                         .d_i (tx_bit_nxt),
                                                                         .q_o (tx_bit));

arv_ipdff #(.WIDTH(8),                    .ARST_EN(ARST_EN)) u_tx_shift (
                                   .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                                         .d_i (tx_shift_nxt),
                                                                         .q_o (tx_shift));

arv_ipdff #(.WIDTH(1), .RST_VAL(1'b1),    .ARST_EN(ARST_EN)) u_tx_line (
                                   .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1),
                                                                         .d_i (tx_line_nxt),
                                                                         .q_o (tx_line));

assign uart_tx_o = tx_line;

//=============================================================================
// DMI command interpreter + DMI master
//=============================================================================
// DMI address width. Fixed at the arvern core's value; not a knob.
localparam           DMI_ABITS = 7;

wire                 launch;
wire [DMI_ABITS-1:0] req_addr;
wire           [1:0] req_op;
wire          [31:0] req_data;
wire                 hardreset;
wire                 inflight;
wire          [31:0] dm_rdata;
wire           [1:0] dm_cstatus;

arv_dtm_cmd #(.ARST_EN(ARST_EN), .RX_FIFO_DEPTH(RX_FIFO_DEPTH)) u_cmd (

    .clk_i            ( clk_i              ),
    .dbgresetn_i      ( dbgresetn_i        ),
    .rx_data_i        ( rx_data            ),
    .rx_valid_i       ( rx_valid           ),
    .frame_boundary_i ( 1'b0               ),   // UART has no frame delimiters
    .frame_stop_i     ( 1'b0               ),   //   "     "   (break re-arm is the recovery path)
    .rx_error_i       ( rx_frame_err       ),   // a dropped byte discards the request it belonged to
    .abort_i          ( ab_rearm           ),   // any baud re-arm flushes the interpreter to a clean SYNC state
    .tx_data_o        ( cmd_tx_data        ),
    .tx_valid_o       ( cmd_tx_valid       ),
    .tx_ready_i       ( tx_ready           ),
    .launch_o         ( launch             ),
    .req_addr_o       ( req_addr           ),
    .req_op_o         ( req_op             ),
    .req_data_o       ( req_data           ),
    .hardreset_o      ( hardreset          ),
    .inflight_i       ( inflight           ),
    .rdata_i          ( dm_rdata           ),
    .cstatus_i        ( dm_cstatus         )
);

arv_dtm_dmi_master #(.TCK_ARST_EN ( ARST_EN ),   // tck_i is clk_i here: no external clock
                     .CLK_ARST_EN ( ARST_EN )) u_dmi_master (

    // transport side (same clock as the bus here -> no real CDC)
    .tck_i            ( clk_i              ),
    .tck_resetn_i     ( dbgresetn_i        ),
    .launch_i         ( launch             ),
    .req_addr_i       ( req_addr           ),
    .req_op_i         ( req_op             ),
    .req_data_i       ( req_data           ),
    .hardreset_i      ( hardreset          ),
    .inflight_o       ( inflight           ),
    .rdata_o          ( dm_rdata           ),
    .cstatus_o        ( dm_cstatus         ),

    // DMI bus side
    .hclk_i           ( clk_i              ),
    .hclk_resetn_i    ( dbgresetn_i        ),
    .dmi_psel_o       ( dmi_psel_o         ),
    .dmi_penable_o    ( dmi_penable_o      ),
    .dmi_paddr_o      ( dmi_paddr_o        ),
    .dmi_pwrite_o     ( dmi_pwrite_o       ),
    .dmi_pwdata_o     ( dmi_pwdata_o       ),
    .dmi_pprot_o      ( dmi_pprot_o        ),
    .dmi_pready_i     ( dmi_pready_i       ),
    .dmi_prdata_i     ( dmi_prdata_i       ),
    .dmi_pslverr_i    ( dmi_pslverr_i      )
);


//=============================================================================
// PARAMETER RANGE CHECK
//=============================================================================
// pragma translate_off
generate
    if (AB_BREAK_CLKS < 32) begin : CHECK_AB_BREAK_CLKS
        initial $fatal(1, "arv_dtm_uart: AB_BREAK_CLKS (%0d) must be at least 32: below that the auto-baud can never lock.", AB_BREAK_CLKS);
    end
endgenerate
// pragma translate_on

endmodule // arv_dtm_uart

`default_nettype wire
