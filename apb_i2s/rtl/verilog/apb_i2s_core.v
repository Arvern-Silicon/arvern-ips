//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    apb_i2s_core
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : apb_i2s_core.v
// Module Description : Serial-audio master shift engine, independent of any
//                      bus: clock generator (MCLK, BCLK, LRCK from clk_i by
//                      integer division), serialiser and deserialiser, with
//                      a frame-level stereo sample stream on each side.
//
//   Clocks:  MCLK toggles every MDIV clk_i cycles (mdiv_i = MDIV-1); BCLK
//            toggles every K MCLK half-periods, K = RATIO / (2 * S) with S
//            the slot width (32, or 16 with slot16_i); a frame is 2 * S BCLK
//            periods. Every output is a flop output.
//   Run:     run_i raised while idle launches position 0 of a frame on the
//            next edge (running_o rises). A frame boundary taken with run_i
//            low is the last: the engine stops at the launch of position D
//            of that frame (D = effective delay, 0 or 1) if run_i is still
//            low, so the last frame is complete, its delayed last bit
//            included, and BCLK goes idle on a launch edge. Every output is
//            idle from the stop on; the counters run one more BCLK
//            half-period (the tail, running_o still high) for the last
//            receive capture. Idle: BCLK at bclk_inv_i, LRCK at the
//            right-slot level (the non-pulse level with fsync_i), MCLK and
//            SD low.
//   Frame:   position n (0 .. 2S-1) is launched on the launch edge of BCLK
//            (falling with bclk_inv_i = 0) and sampled on the other edge.
//            LRCK is the word clock (left slot n < S) or, with fsync_i, a
//            one-BCLK pulse at n = 0. Position n carries stream bit
//            k = n - D: bit k of a frame is bit j = k mod S of the left
//            (k < S) or right slot, which holds the 16-bit sample MSB first
//            at j < 16 (rjust_i = 0) or j >= 16 (rjust_i = 1, 32-bit slots
//            only, which ignore delay_i), zeros elsewhere. A delayed
//            position 0 carries the last bit of the previous frame.
//   TX:      at each frame boundary (the launch of position 0) the engine
//            takes tx_data_i ({right, left}) when tx_on_i and tx_valid_i
//            (tx_take_o pulses), or sends zeros; tx_under_o pulses when
//            tx_on_i is high without data.
//   RX:      (RX_EN) the receive input (i2s_sd_i, or the serial output with
//            loopback_i) crosses a two-flop synchroniser; the pad value at
//            the clk_i edge rx_dly_i cycles after each sampling edge is
//            captured. At the end of each frame that started with rx_on_i
//            high, rx_valid_o pulses with rx_data_o = {right, left}.
//----------------------------------------------------------------------------
`default_nettype none

module  apb_i2s_core #(
    parameter               TX_EN        = 1,       // transmit path present (0: SD low, tx_* inputs unused)
    parameter               RX_EN        = 1,       // receive path present (0: rx_* outputs low, receive inputs unused)
    parameter               ASYNC_RST_EN = 1        // Reset style: 1=async active-low reset, 0=synchronous reset
) (
    input  wire             clk_i,                  // clock: every audio clock divides it
    input  wire             rst_n_i,                // active-low reset, style per ASYNC_RST_EN

// CONFIGURATION (static while running_o, except run_i, mclk_en_i, tx_on_i, rx_on_i)
    input  wire             run_i,                  // run the clock generator
    input  wire             mclk_en_i,              // drive i2s_mclk_o (takes effect at the next MCLK toggle)
    input  wire       [7:0] mdiv_i,                 // MCLK half-period - 1, in clk_i cycles
    input  wire       [2:0] ratio_i,                // MCLK / LRCK: 0=256, 1=384, 2=512, 3=768, 4=1024 (5-7 as 0)
    input  wire       [3:0] rx_dly_i,               // receive sampling point: clk_i cycles after the sampling edge
    input  wire             bclk_inv_i,             // 0: launch on the falling BCLK edge, sample on the rising one
    input  wire             delay_i,                // first data bit one BCLK after the slot edge
    input  wire             rjust_i,                // sample at the end of a 32-bit slot
    input  wire             lrck_inv_i,             // left slot while LRCK high (frame-sync pulse low with fsync_i)
    input  wire             fsync_i,                // LRCK is a one-BCLK frame-sync pulse at the start of the frame
    input  wire             slot16_i,               // 16-bit slots (BCLK = 32 Fs) instead of 32-bit
    input  wire             loopback_i,             // receive the serial output instead of i2s_sd_i
    output wire             running_o,              // the engine runs (outputs not idle), or its tail

// TRANSMIT STREAM
    input  wire             tx_on_i,                // transmit (sampled at each frame boundary)
    input  wire             tx_valid_i,             // tx_data_i holds a frame
    input  wire      [31:0] tx_data_i,              // {right, left}
    output wire             tx_take_o,              // tx_data_i taken (frame boundary)
    output wire             tx_under_o,             // frame sent as zeros for lack of data while transmitting
    output wire             tx_active_o,            // the current frame was started with tx_on_i high

// RECEIVE STREAM
    input  wire             rx_on_i,                // receive (sampled at the start of each frame)
    output wire             rx_valid_o,             // a received frame, one cycle
    output wire      [31:0] rx_data_o,              // {right, left}
    output wire             rx_active_o,            // the frame being received started with rx_on_i high

// SERIAL AUDIO PINS
    output wire             i2s_mclk_o,             // master clock
    output wire             i2s_bclk_o,             // bit clock
    output wire             i2s_lrck_o,             // word clock / frame sync
    output wire             i2s_sd_o,               // serial data out
    input  wire             i2s_sd_i                // serial data in
);


//=============================================================================
// 1)  DECLARATIONS
//=============================================================================

// pragma translate_off
generate
    if ((TX_EN != 0) && (TX_EN != 1)) begin : CHECK_TX_EN
        initial $fatal(1, "apb_i2s_core: TX_EN (%0d) must be 0 or 1.", TX_EN);
    end
    if ((RX_EN != 0) && (RX_EN != 1)) begin : CHECK_RX_EN
        initial $fatal(1, "apb_i2s_core: RX_EN (%0d) must be 0 or 1.", RX_EN);
    end
    if ((TX_EN == 0) && (RX_EN == 0)) begin : CHECK_PATHS
        initial $fatal(1, "apb_i2s_core: TX_EN and RX_EN cannot both be 0.");
    end
    if ((ASYNC_RST_EN != 0) && (ASYNC_RST_EN != 1)) begin : CHECK_ASYNC_RST_EN
        initial $fatal(1, "apb_i2s_core: ASYNC_RST_EN (%0d) must be 0 or 1.", ASYNC_RST_EN);
    end
endgenerate
// pragma translate_on

localparam              ARST_EN = (ASYNC_RST_EN != 0);

wire                    dly;                        // effective delay D (right-justified 32-bit slots: none)
wire                    running;                    // the engine runs
wire                    tail;                       // stopped, the counters still run for the last capture
wire                    tick_on;                    // the counters run
wire                    tail_end;                   // the tail ends
wire                    stop_arm;                   // the last frame boundary was taken with run_i low
wire                    start;                      // run_i while idle: launch position 0
wire                    stop;                       // run_i low at the launch of position D of the last frame: go idle
wire                    act;                        // running and not stopping this cycle
wire              [7:0] mcnt;                       // clk_i cycles in the MCLK half-period
wire              [7:0] mcnt_nxt;
wire              [4:0] bcnt_nxt;
wire                    mclk_nxt;
wire                    bclk_nxt;
wire                    smp_busy;                   // a sample waits for its capture
wire                    mtick;                      // MCLK half-period ends
wire              [4:0] bcnt;                       // MCLK half-periods in the BCLK half-period
wire              [4:0] bk_last;                    // K - 1
wire                    btick;                      // BCLK half-period ends
wire                    mclk_q;
wire                    bclk_q;                     // the i2s_bclk_o level
wire                    bhigh;                      // BCLK in its sampling-edge-to-launch-edge half
wire                    btlaunch;                   // a BCLK launch edge
wire                    launch;                     // a position is launched this cycle
wire                    sample;                     // the sampling edge of the current position
wire              [5:0] pos;                        // position in the frame
wire              [5:0] pos_last;                   // 2S - 1
wire              [5:0] pos_nxt;
wire                    boundary;                   // the launch of position 0 (frame start)
wire                    tx_act;                     // the current frame transmits
wire             [31:0] tx_word;                    // the current frame's {right, left}
wire             [31:0] tx_word_nxt;
wire                    tx_last_bit;                // stream bit 2S-1 of the current frame
wire                    sd_nxt;
wire                    lrck_nxt;
wire                    lrck_idle;                  // LRCK while idle: the right-slot (non-pulse) level
wire                    lrck_q;
wire                    sd_q;
wire                    cap;                        // capture the synchronised input
wire                    rx_run;                     // the frame being received started with rx_on_i


//=============================================================================
// 2)  RUN CONTROL AND CLOCK GENERATOR
//=============================================================================
// K = RATIO / (2 * S): 4, 6, 8, 12, 16 with 32-bit slots, twice that with
// 16-bit slots. Every BCLK edge falls on an MCLK edge.

assign bk_last  = slot16_i ? ((ratio_i == 3'd1) ? 5'd11 : (ratio_i == 3'd2) ? 5'd15 :
                              (ratio_i == 3'd3) ? 5'd23 : (ratio_i == 3'd4) ? 5'd31 : 5'd7)
                           : ((ratio_i == 3'd1) ? 5'd5  : (ratio_i == 3'd2) ? 5'd7  :
                              (ratio_i == 3'd3) ? 5'd11 : (ratio_i == 3'd4) ? 5'd15 : 5'd3);

assign dly      = delay_i & ~(rjust_i & ~slot16_i);
assign tick_on  = running | tail;
assign mtick    = tick_on & (mcnt == mdiv_i);
assign btick    = mtick & (bcnt == bk_last);
assign bhigh    = bclk_q ^ bclk_inv_i;
assign btlaunch = btick &  bhigh;
assign sample   = btick & ~bhigh;
assign start    = run_i & ~running & ~tail;
assign pos_last = slot16_i ? 6'd31 : 6'd63;
assign pos_nxt  = (start | (pos == pos_last)) ? 6'd0 : (pos + 6'd1);
assign stop     = ~run_i & btlaunch & (dly ? ((pos_nxt == 6'd1) & stop_arm) : (pos_nxt == 6'd0));
assign act      = running & ~stop;
assign launch   = start | (btlaunch & ~stop);
assign boundary = launch & (pos_nxt == 6'd0);
assign tail_end = tail & btick & (~smp_busy | cap);

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_running (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(start | stop), .d_i(start), .q_o(running));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_tail (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(stop | tail_end), .d_i(stop), .q_o(tail));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_stop_arm (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(boundary | stop), .d_i(boundary & ~run_i), .q_o(stop_arm));

// MCLK_EN is sampled at the toggle instants: no partial MCLK pulse
assign mcnt_nxt = (~tick_on | mtick) ? 8'd0 : (mcnt + 8'd1);
assign bcnt_nxt = (~tick_on | btick) ? 5'd0 : (bcnt + 5'd1);
assign mclk_nxt = act & ~mclk_q & mclk_en_i;
assign bclk_nxt = act ? (bclk_q ^ btick) : bclk_inv_i;

arv_ipdff #(.WIDTH(8), .ARST_EN(ARST_EN)) u_mcnt (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(mcnt_nxt), .q_o(mcnt));

arv_ipdff #(.WIDTH(5), .ARST_EN(ARST_EN)) u_bcnt (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(~tick_on | mtick), .d_i(bcnt_nxt), .q_o(bcnt));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_mclk (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(~act | mtick), .d_i(mclk_nxt), .q_o(mclk_q));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_bclk (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(bclk_nxt), .q_o(bclk_q));


//=============================================================================
// 3)  FRAME POSITION AND SERIALISER
//=============================================================================

arv_ipdff #(.WIDTH(6), .ARST_EN(ARST_EN)) u_pos (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(launch), .d_i(pos_nxt), .q_o(pos));

// Stream bit k of a frame word: slot, bit j in the slot, sample bit
function stream_bit;
    input [31:0] word;
    input  [5:0] k;
    input        s16;
    input        rj;
    reg          right;
    reg    [4:0] j;
    reg          in_fld;
    reg   [15:0] smp;
    begin
        right  = s16 ? k[4] : k[5];
        j      = s16 ? {1'b0, k[3:0]} : k[4:0];
        in_fld = s16 | (rj ? j[4] : ~j[4]);
        smp    = right ? word[31:16] : word[15:0];
        stream_bit = in_fld & smp[4'd15 - j[3:0]];
    end
endfunction

assign tx_take_o   = boundary & run_i & tx_on_i &  tx_valid_i;
assign tx_under_o  = boundary & run_i & tx_on_i & ~tx_valid_i;
assign tx_word_nxt = tx_take_o ? tx_data_i : 32'h0;
assign tx_last_bit = stream_bit(tx_word, pos_last, slot16_i, rjust_i);

generate
    if (TX_EN != 0) begin : g_tx_word

        arv_ipdff #(.WIDTH(32), .ARST_EN(ARST_EN)) u_tx_word (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(boundary | stop),
            .d_i(tx_word_nxt), .q_o(tx_word));

        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_tx_act (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(boundary | stop),
            .d_i(boundary & run_i & tx_on_i), .q_o(tx_act));

    end else begin : g_no_tx_word

        assign tx_word = 32'h0;
        assign tx_act  = 1'b0;
        wire [31:0] tx_word_nxt_unused = tx_word_nxt;

    end
endgenerate

// A delayed position 0 carries the last bit of the frame that ends
assign sd_nxt    = (dly & (pos_nxt == 6'd0)) ? (~start & tx_last_bit)
                                             : stream_bit(boundary ? tx_word_nxt : tx_word, pos_nxt - {5'd0, dly}, slot16_i, rjust_i);
assign lrck_nxt  = fsync_i ? ((pos_nxt == 6'd0) ^ lrck_inv_i)
                           : ((slot16_i ? pos_nxt[4] : pos_nxt[5]) ^ lrck_inv_i);
assign lrck_idle = fsync_i ? lrck_inv_i : ~lrck_inv_i;

// While idle LRCK and SD follow their idle levels; LRCK resets to the idle
// level of the reset FORMAT (I2S: high)
arv_ipdff #(.WIDTH(1), .RST_VAL(1'b1), .ARST_EN(ARST_EN)) u_lrck (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(launch | ~act),
    .d_i(launch ? lrck_nxt : lrck_idle), .q_o(lrck_q));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_sd (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(launch | ~act),
    .d_i(launch & sd_nxt), .q_o(sd_q));


//=============================================================================
// 4)  DESERIALISER
//=============================================================================
// The sampling edge of position n samples stream bit k = n - D (the last bit
// of the previous frame for a delayed position 0). The pad value at the edge
// rx_dly_i cycles after the sampling edge reaches the synchroniser output two
// cycles later, when it is captured.

generate
    if (RX_EN != 0) begin : g_rx

        wire                    rx_in;                      // receive input before the synchroniser
        wire                    rx_sync;                    // receive input, synchronised
        wire              [4:0] smp_cnt;                    // cycles to the capture of the last sample
        wire              [4:0] smp_cnt_nxt;
        wire              [5:0] smp_k;                      // stream bit of the pending sample
        wire              [5:0] smp_k_nxt;
        wire                    cap_right;                  // capture into the right sample
        wire                    cap_in;                     // capture inside the sample field
        wire             [15:0] rx_left;
        wire             [15:0] rx_left_nxt;
        wire             [15:0] rx_right;
        wire             [15:0] rx_right_nxt;
        wire                    rx_end;                     // the last stream bit of a frame is captured

        assign rx_in = loopback_i ? sd_q : i2s_sd_i;

        arv_synchronizer #(.W(1), .ARST_EN(ARST_EN)) u_rx_sync (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .async_i(rx_in), .sync_o(rx_sync));

        assign smp_k_nxt   = (dly & (pos == 6'd0)) ? pos_last : (pos - {5'd0, dly});
        assign smp_cnt_nxt = sample ? ({1'b0, rx_dly_i} + 5'd2) : (smp_cnt - 5'd1);
        assign smp_busy    = (smp_cnt != 5'd0);

        arv_ipdff #(.WIDTH(5), .ARST_EN(ARST_EN)) u_smp_cnt (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(sample | smp_busy), .d_i(smp_cnt_nxt), .q_o(smp_cnt));

        arv_ipdff #(.WIDTH(6), .ARST_EN(ARST_EN)) u_smp_k (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(sample),
            .d_i(smp_k_nxt), .q_o(smp_k));

        assign cap       = (smp_cnt == 5'd1);
        assign cap_right = slot16_i ? smp_k[4] : smp_k[5];
        assign cap_in    = slot16_i | (rjust_i ? smp_k[4] : ~smp_k[4]);

        assign rx_left_nxt  = {rx_left[14:0],  rx_sync};
        assign rx_right_nxt = {rx_right[14:0], rx_sync};

        arv_ipdff #(.WIDTH(16), .ARST_EN(ARST_EN)) u_rx_left (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(cap & ~cap_right & cap_in), .d_i(rx_left_nxt), .q_o(rx_left));

        arv_ipdff #(.WIDTH(16), .ARST_EN(ARST_EN)) u_rx_right (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(cap & cap_right & cap_in), .d_i(rx_right_nxt), .q_o(rx_right));

        // A frame is received when rx_on_i is high as its first stream bit
        // is captured; cleared at a start and at the end of the tail, so no
        // frame is delivered across a stop and the stream reads inactive
        // once stopped
        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_rx_run (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(start | tail_end | (cap & (smp_k == 6'd0))),
            .d_i(~start & ~tail_end & rx_on_i), .q_o(rx_run));

        assign rx_end     = cap & (smp_k == pos_last);
        assign rx_valid_o = rx_end & rx_run;
        assign rx_data_o  = {(cap_in ? rx_right_nxt : rx_right), rx_left};

    end else begin : g_no_rx

        assign smp_busy   = 1'b0;
        assign cap        = 1'b0;
        assign rx_run     = 1'b0;
        assign rx_valid_o = 1'b0;
        assign rx_data_o  = 32'h0;
        wire       sample_unused   = sample;
        wire       rx_on_unused    = rx_on_i;
        wire [3:0] rx_dly_unused   = rx_dly_i;
        wire       loopback_unused = loopback_i;
        wire       sd_i_unused     = i2s_sd_i;

    end
endgenerate


//=============================================================================
// 5)  OUTPUTS
//=============================================================================

assign running_o   = tick_on;
assign tx_active_o = tx_act;
assign rx_active_o = rx_run;
assign i2s_mclk_o  = mclk_q;
assign i2s_bclk_o  = bclk_q;
assign i2s_lrck_o  = lrck_q;
assign i2s_sd_o    = sd_q;

endmodule // apb_i2s_core

`default_nettype wire
