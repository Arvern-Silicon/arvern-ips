//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    apb_usb_host_sie
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : apb_usb_host_sie.v
// Module Description : Low-speed USB serial engine of apb_usb_host: line
//                      sampling, bit clock, NRZI, bit stuffing, CRC5/CRC16,
//                      PID check and packet framing, one shift register for
//                      both directions (the bus is half duplex).
//
//   Bit clock: one tick per bit time. CLK_HZ a multiple of 1.5 MHz: a
//            counter wrapping every CLK_HZ / 1.5 MHz cycles (no jitter).
//            Otherwise: a power-of-two phase accumulator, ACC_W bits wide so
//            that the rate is within 0.01 %, ticking on its carry. It runs
//            free while idle or transmitting; while receiving, every D+ edge
//            sets it to half a bit so the ticks fall mid-bit. Every delay is
//            counted in ticks.
//   Line:    J = D- high (low-speed idle), K = D+ high. A tick samples J, K
//            or SE0. idle = consecutive J ticks. se0_long_o: SE0 for 2.25 us
//            with the lines released (disconnect).
//   Command: in IDLE, start_i launches kind_i (stable with pid_i, addr_i,
//            ep_i, len_i, resp_i and tx_byte_i until done_o):
//              KEEPALIVE  EOP only
//              TOKEN      sync, PID, address, endpoint, CRC5
//              DATA       sync, PID, len_i bytes (tx_idx_o -> tx_byte_i), CRC16
//              ACK        sync, PID
//            The packet starts after 4 J ticks (bus idle and inter-packet
//            delay); without them within 16 ticks the command ends with
//            BUSY, nothing sent. The EOP is 2 ticks of SE0, 1 of J, then the
//            lines are released. With resp_i the engine then waits for a
//            device packet: none within 24 ticks of the SE0-to-J edge is
//            TIMEOUT. reset_i (in IDLE) drives SE0 while high, from the
//            second J tick of an idle bus (or at once on a bus without J). abort_i
//            releases the lines and returns to IDLE from any state.
//   Receive: bytes after the PID are written as they arrive (rx_we_o,
//            rx_idx_o, rx_byte_o), the CRC bytes included. A packet ends on
//            the first SE0 tick: a handshake must carry no byte, a data
//            packet a valid CRC16 (rx_len_o = bytes - 2); any other PID is
//            returned as received. A bad sync, PID check or stuff bit is
//            BADPKT, more than 10 bytes LONG; both wait for 16 J ticks (at
//            most 256 ticks) before done_o. A good packet's done_o comes
//            with the J that ends its EOP (at most 3 ticks after the SE0).
//----------------------------------------------------------------------------
`default_nettype none

module  apb_usb_host_sie #(
    parameter               CLK_HZ       = 48000000,    // clk_i frequency (Hz)
    parameter               ASYNC_RST_EN = 1            // Reset style: 1=async active-low reset, 0=synchronous reset
) (
    input  wire             clk_i,                      // clock, the USB timebase
    input  wire             rst_n_i,                    // active-low reset, style per ASYNC_RST_EN

// COMMAND
    input  wire             start_i,                    // launch kind_i (in IDLE)
    input  wire       [1:0] kind_i,                     // 0 KEEPALIVE, 1 TOKEN, 2 DATA, 3 ACK
    input  wire       [3:0] pid_i,                      // PID of a TOKEN / DATA / ACK
    input  wire       [6:0] addr_i,                     // TOKEN address
    input  wire       [3:0] ep_i,                       // TOKEN endpoint
    input  wire       [3:0] len_i,                      // DATA byte count (0-8)
    input  wire             resp_i,                     // wait for a device packet after this one
    output wire       [3:0] tx_idx_o,                   // DATA byte requested
    input  wire       [7:0] tx_byte_i,                  // DATA byte at tx_idx_o
    input  wire             reset_i,                    // drive SE0 (bus reset) while high
    input  wire             abort_i,                    // release the lines, back to IDLE
    output wire             busy_o,                     // a command or the bus reset runs
    output wire             done_o,                     // command complete, one cycle
    output wire       [2:0] res_o,                      // 0 OK, 1 TIMEOUT, 2 BADPKT, 3 LONG, 4 BUSY

// RECEIVED PACKET
    output wire       [3:0] rx_pid_o,                   // PID of the received packet
    output wire       [3:0] rx_len_o,                   // data bytes (CRC excluded) of a data packet
    output wire             rx_we_o,                    // rx_byte_o is byte rx_idx_o after the PID
    output wire       [3:0] rx_idx_o,
    output wire       [7:0] rx_byte_o,

// LINE STATE
    output wire             tick_o,                     // bit-time tick (the sequencer's frame timebase)
    output wire       [1:0] line_o,                     // {D+, D-}, synchronised
    output wire             se0_long_o,                 // SE0 for 2.25 us, lines released

// PADS
    input  wire             usb_dp_i,                   // D+ pad read-back (asynchronous)
    input  wire             usb_dm_i,                   // D- pad read-back (asynchronous)
    output wire             usb_dp_o,                   // D+ driven value
    output wire             usb_dm_o,                   // D- driven value
    output wire             usb_oe_o                    // D+/D- output enable
);


//=============================================================================
// 1)  PARAMETERS
//=============================================================================

// round(1.5 MHz * 2^w / hz) by long division (no overflow, no real arithmetic)
function integer f_step;
    input integer hz;
    input integer w;
    integer q, r, i;
    begin
        q = 0;
        r = 1500000;
        for (i = 0; i < 31; i = i + 1)
            if (i < w) begin
                q = q * 2;
                r = r * 2;
                if (r >= hz) begin
                    q = q + 1;
                    r = r - hz;
                end
            end
        f_step = (2 * r >= hz) ? (q + 1) : q;
    end
endfunction

// Phase accumulator width: the smallest with a step of at least 5000
// (rounding error <= 0.01 %)
function integer f_acc_w;
    input integer hz;
    integer w;
    begin
        f_acc_w = 30;
        for (w = 30; w >= 4; w = w - 1)
            if (f_step(hz, w) >= 5000) f_acc_w = w;
    end
endfunction

localparam              BIT_HZ   = 1500000;
localparam              CNT_MODE = ((CLK_HZ % BIT_HZ) == 0);   // integer clocks per bit
localparam              CPB      = CLK_HZ / BIT_HZ;              // clocks per bit (CNT_MODE)
localparam              ACC_W    = CNT_MODE ? $clog2(CPB) : f_acc_w(CLK_HZ);
localparam              STEP     = CNT_MODE ? 1 : f_step(CLK_HZ, ACC_W);
localparam              DISC_CYC = (CLK_HZ / 1000) * 9 / 4000;  // 2.25 us
localparam              DISC_W   = $clog2(DISC_CYC + 1);
localparam              WRAP     = CNT_MODE ? (CPB - 1) : 0;
localparam              HALF     = CNT_MODE ? (CPB / 2) : (1 << (ACC_W - 1));
localparam  [ACC_W-1:0] STEP_V   = STEP[ACC_W-1:0];
localparam  [ACC_W-1:0] WRAP_V   = WRAP[ACC_W-1:0];
localparam  [ACC_W-1:0] HALF_V   = HALF[ACC_W-1:0];

// pragma translate_off
generate
    if (CLK_HZ < 12000000) begin : CHECK_CLK_MIN
        initial $fatal(1, "apb_usb_host_sie: CLK_HZ (%0d) must be at least 12 MHz.", CLK_HZ);
    end
    if (((CLK_HZ % BIT_HZ) != 0) && (CLK_HZ < 24000000)) begin : CHECK_CLK_JITTER
        initial $fatal(1, "apb_usb_host_sie: CLK_HZ (%0d) must be a multiple of 1.5 MHz or at least 24 MHz.", CLK_HZ);
    end
    if ((ASYNC_RST_EN != 0) && (ASYNC_RST_EN != 1)) begin : CHECK_ASYNC_RST_EN
        initial $fatal(1, "apb_usb_host_sie: ASYNC_RST_EN (%0d) must be 0 or 1.", ASYNC_RST_EN);
    end
endgenerate
// pragma translate_on

localparam              ARST_EN  = (ASYNC_RST_EN != 0);

localparam        [1:0] K_KEEP   = 2'd0,                // kind_i (2: DATA)
                        K_TOKEN  = 2'd1,
                        K_ACK    = 2'd3;

localparam        [2:0] R_OK     = 3'd0,
                        R_TMO    = 3'd1,
                        R_BAD    = 3'd2,
                        R_LONG   = 3'd3,
                        R_BUSY   = 3'd4;

localparam        [2:0] S_IDLE   = 3'd0,                // waiting for a command
                        S_WIDLE  = 3'd1,                // waiting for an idle bus
                        S_TX     = 3'd2,                // sending sync, PID, payload, CRC
                        S_EOP    = 3'd3,                // sending the EOP, then releasing
                        S_RXW    = 3'd4,                // waiting for the device's SOP
                        S_RX     = 3'd5,                // receiving
                        S_DRAIN  = 3'd6,                // after a bad packet: waiting for an idle bus
                        S_RST    = 3'd7;                // driving the bus reset

localparam        [1:0] P_SYNC   = 2'd0,                // phase of the packet (TX and RX)
                        P_PID    = 2'd1,
                        P_PAY    = 2'd2,
                        P_CRC    = 2'd3;


//=============================================================================
// 2)  DECLARATIONS
//=============================================================================

wire                    dp_s;                           // synchronised D+
wire                    dm_s;                           // synchronised D-
wire                    se0;
wire                    sym_j;
wire                    sym_k;
wire                    dp_q;                           // D+ and D- one cycle later: the RX samples
wire                    dm_q;
wire                    dp_edge;
wire                    rx_s;                           // sampled symbol, 1 = K
wire                    rx_se0;

wire        [ACC_W-1:0] acc;
wire          [ACC_W:0] acc_sum;                        // accumulator mode: {carry, sum}
wire                    tick;
wire                    rephase;
wire        [ACC_W-1:0] acc_nxt;

wire              [2:0] st;
wire              [7:0] cnt;                            // ticks / zero count / CRC bits left
wire              [4:0] icnt;                           // consecutive J ticks, saturating at 16
wire              [7:0] sr;                             // shift register
wire              [2:0] bitn;                           // bit in the byte
wire              [3:0] bcnt;                           // payload byte / received byte count
wire              [1:0] ph;                             // packet phase
wire              [2:0] ones;                           // consecutive ones (bit stuffing)
wire                    lvl;                            // TX line level / RX previous symbol (1 = K)
wire             [15:0] crc;
wire              [3:0] pid_q;                          // received PID
wire              [2:0] res_q;
wire                    eopw;                           // S_DRAIN after a good EOP: wait for its J only
wire                    done_q;
wire                    oe_q;
wire                    dpo_q;
wire                    dmo_q;
wire       [DISC_W-1:0] disc_cnt;

reg               [2:0] st_nxt;
reg               [7:0] cnt_nxt;
reg               [7:0] sr_nxt;
reg               [2:0] bitn_nxt;
reg               [3:0] bcnt_nxt;
reg               [1:0] ph_nxt;
reg               [2:0] ones_nxt;
reg                     lvl_nxt;
reg              [15:0] crc_nxt;
reg               [3:0] pid_nxt;
reg               [2:0] res_nxt;
reg                     done_nxt;
reg                     eopw_nxt;
reg                     oe_nxt;
reg                     dpo_nxt;
reg                     dmo_nxt;
reg                     rx_we;
reg                     rephase_r;

wire              [4:0] tok_crc;                        // CRC5 of the token
wire              [7:0] tok_byte1;                      // token byte 1: endpoint[3:1], CRC5
wire                    tok;                            // the TX packet is a token
wire                    tx_last;                        // the last payload byte has been loaded
wire                    tx_end;                         // every TX bit sent
wire                    tx_stuff;                       // the next TX bit is a stuffed zero
wire                    tx_bit;                         // the next TX data bit
wire                    rx_bit;                         // the received bit (NRZI decoded)
wire              [7:0] rx_byte;                        // the byte completed by rx_bit
wire             [15:0] crc_rx_step;                    // CRC16 after rx_bit
wire                    rx_hs_ok;
wire                    rx_data_ok;


//=============================================================================
// 3)  LINE SAMPLING
//=============================================================================

arv_synchronizer #(.W(1), .RST_VAL(1'b0), .ARST_EN(ARST_EN)) u_dp_sync (
    .clk_i   (clk_i),
    .rst_n_i (rst_n_i),
    .async_i (usb_dp_i),
    .sync_o  (dp_s));

arv_synchronizer #(.W(1), .RST_VAL(1'b0), .ARST_EN(ARST_EN)) u_dm_sync (
    .clk_i   (clk_i),
    .rst_n_i (rst_n_i),
    .async_i (usb_dm_i),
    .sync_o  (dm_s));

assign se0     = ~dp_s & ~dm_s;
assign sym_j   = ~dp_s &  dm_s;
assign sym_k   =  dp_s & ~dm_s;

arv_ipdff #(.WIDTH(2), .ARST_EN(ARST_EN)) u_line_q (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i({dp_s, dm_s}), .q_o({dp_q, dm_q}));

// A tick in the cycle of a D+ edge samples the level before the edge
assign dp_edge = dp_s ^ dp_q;
assign rx_s    = dp_q;
assign rx_se0  = ~dp_q & ~dm_q;

// Disconnect: SE0 with the lines released for DISC_CYC cycles
wire                    disc_run = se0 & ~oe_q;
wire                    disc_sat = (disc_cnt == DISC_CYC[DISC_W-1:0]);

wire       [DISC_W-1:0] disc_nxt = disc_run ? (disc_cnt + {{(DISC_W-1){1'b0}}, 1'b1}) : {DISC_W{1'b0}};

arv_ipdff #(.WIDTH(DISC_W), .ARST_EN(ARST_EN)) u_disc_cnt (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(~(disc_run & disc_sat)), .d_i(disc_nxt), .q_o(disc_cnt));

assign se0_long_o = disc_sat;
assign line_o     = {dp_s, dm_s};


//=============================================================================
// 4)  BIT CLOCK
//=============================================================================

assign rephase = rephase_r;
assign acc_sum = {1'b0, acc} + {1'b0, STEP_V};

generate
    if (CNT_MODE) begin : g_bit_cnt
        wire   acc_carry_unused = acc_sum[ACC_W];
        assign tick    = (acc == WRAP_V);
        assign acc_nxt = rephase ? HALF_V : tick ? {ACC_W{1'b0}} : acc_sum[ACC_W-1:0];
    end else begin : g_bit_acc
        assign tick    = acc_sum[ACC_W];
        assign acc_nxt = rephase ? HALF_V : acc_sum[ACC_W-1:0];
    end
endgenerate

arv_ipdff #(.WIDTH(ACC_W), .ARST_EN(ARST_EN)) u_acc (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(acc_nxt), .q_o(acc));

// Consecutive J ticks (bus idle; the inter-packet delay before a host packet),
// cleared at once when the line leaves J
wire              [4:0] icnt_nxt = sym_j ? (icnt + 5'd1) : 5'd0;
wire                    icnt_en  = (tick & ~(sym_j & icnt[4])) | ~sym_j;

arv_ipdff #(.WIDTH(5), .ARST_EN(ARST_EN)) u_icnt (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(icnt_en), .d_i(icnt_nxt), .q_o(icnt));


//=============================================================================
// 5)  PACKET ENGINE
//=============================================================================

function [15:0] f_crc16;                                // x^16 + x^15 + x^2 + 1, one bit
    input [15:0] c;
    input        d;
    begin
        f_crc16 = {c[14:0], 1'b0} ^ ({16{d ^ c[15]}} & 16'h8005);
    end
endfunction

function [4:0] f_crc5;                                  // x^5 + x^2 + 1 over a token's 11 bits
    input [10:0] d;                                     // {endpoint, address}, sent LSB first
    integer      i;
    reg    [4:0] c;
    begin
        c = 5'h1F;
        for (i = 0; i < 11; i = i + 1)
            c = {c[3:0], 1'b0} ^ ({5{d[i] ^ c[4]}} & 5'h05);
        f_crc5 = c;
    end
endfunction

// Token second byte: endpoint[3:1], then the inverted CRC5 MSB first
assign tok_crc     = f_crc5({ep_i, addr_i});
assign tok_byte1   = {~tok_crc[0], ~tok_crc[1], ~tok_crc[2], ~tok_crc[3], ~tok_crc[4], ep_i[3:1]};

assign tok         = (kind_i == K_TOKEN);
assign tx_end      = (ph == P_CRC) & (bcnt == 4'd0);
assign tx_stuff    = (ones == 3'd6);
assign tx_bit      = (ph == P_CRC) ? ~crc[15] : sr[0];
assign tx_last     = tok ? (bcnt == 4'd2) : (bcnt == len_i);
assign tx_idx_o    = bcnt;

assign rx_bit      = (rx_s == lvl);                     // no transition = 1
assign rx_byte     = {rx_bit, sr[7:1]};
assign crc_rx_step = f_crc16(crc, rx_bit);
assign rx_hs_ok    = (pid_q[1:0] == 2'b10) & (bcnt == 4'd0);
assign rx_data_ok  = (pid_q[1:0] == 2'b11) & (bcnt >= 4'd2) & (crc == 16'h800D);

always @(*) begin
    st_nxt    = st;
    cnt_nxt   = cnt;
    sr_nxt    = sr;
    bitn_nxt  = bitn;
    bcnt_nxt  = bcnt;
    ph_nxt    = ph;
    ones_nxt  = ones;
    lvl_nxt   = lvl;
    crc_nxt   = crc;
    pid_nxt   = pid_q;
    res_nxt   = res_q;
    done_nxt  = 1'b0;
    eopw_nxt  = eopw;
    oe_nxt    = oe_q;
    dpo_nxt   = dpo_q;
    dmo_nxt   = dmo_q;
    rx_we     = 1'b0;
    rephase_r = 1'b0;

    case (st)

    S_IDLE: begin
        cnt_nxt = 8'd0;
        if (reset_i & ((icnt >= 5'd2) | ~sym_j)) begin  // not over a device's EOP
            st_nxt  = S_RST;
            oe_nxt  = 1'b1;
            dpo_nxt = 1'b0;
            dmo_nxt = 1'b0;
        end else if (start_i) begin
            st_nxt  = S_WIDLE;
        end
    end

    S_RST: begin
        if (~reset_i) begin
            st_nxt  = S_IDLE;
            oe_nxt  = 1'b0;
        end
    end

    S_WIDLE: begin
        if (icnt >= 5'd4) begin
            st_nxt   = (kind_i == K_KEEP) ? S_EOP : S_TX;
            cnt_nxt  = 8'd0;
            sr_nxt   = 8'h80;                           // sync: KJKJKJKK
            bitn_nxt = 3'd0;
            bcnt_nxt = 4'd0;
            ph_nxt   = P_SYNC;
            ones_nxt = 3'd0;
            lvl_nxt  = 1'b0;                            // from J
            crc_nxt  = 16'hFFFF;
        end else if (tick) begin
            if (cnt == 8'd15) begin
                st_nxt   = S_IDLE;
                res_nxt  = R_BUSY;
                done_nxt = 1'b1;
            end else begin
                cnt_nxt  = cnt + 8'd1;
            end
        end
    end

    S_TX: if (tick) begin
        if (~oe_q & ~sym_j) begin                       // the line left J before the first bit
            st_nxt   = S_IDLE;
            res_nxt  = R_BUSY;
            done_nxt = 1'b1;
        end else if (tx_stuff) begin                    // stuffed zero: a transition
            ones_nxt = 3'd0;
            lvl_nxt  = ~lvl;
            oe_nxt   = 1'b1;
            dpo_nxt  = ~lvl;
            dmo_nxt  =  lvl;
        end else if (tx_end) begin                      // first SE0 bit of the EOP
            st_nxt   = S_EOP;
            bitn_nxt = 3'd1;
            dpo_nxt  = 1'b0;
            dmo_nxt  = 1'b0;
        end else begin
            ones_nxt = tx_bit ? (ones + 3'd1) : 3'd0;
            lvl_nxt  = lvl ^ ~tx_bit;
            oe_nxt   = 1'b1;
            dpo_nxt  =   lvl ^ ~tx_bit;
            dmo_nxt  = ~(lvl ^ ~tx_bit);
            sr_nxt   = {1'b0, sr[7:1]};
            bitn_nxt = bitn + 3'd1;
            if (ph == P_PAY)
                crc_nxt = f_crc16(crc, tx_bit);
            else if (ph == P_CRC)
                crc_nxt = {crc[14:0], 1'b1};
            if (bitn == 3'd7) begin
                case (ph)
                P_SYNC: begin
                    ph_nxt = P_PID;
                    sr_nxt = {~pid_i, pid_i};
                end
                P_PID: begin
                    if (kind_i == K_ACK) begin
                        ph_nxt   = P_CRC;               // no payload, no CRC
                    end else if (~tok & (len_i == 4'd0)) begin
                        ph_nxt   = P_CRC;
                        bcnt_nxt = 4'd14;               // 16 CRC bits: 14 -> 15 -> 0
                    end else begin
                        ph_nxt   = P_PAY;
                        sr_nxt   = tok ? {ep_i[0], addr_i} : tx_byte_i;
                        bcnt_nxt = 4'd1;
                    end
                end
                P_PAY: begin
                    if (tx_last) begin
                        ph_nxt   = P_CRC;
                        bcnt_nxt = tok ? 4'd0 : 4'd14;  // a token carries its CRC5 in byte 1
                    end else begin
                        sr_nxt   = tok ? tok_byte1 : tx_byte_i;
                        bcnt_nxt = bcnt + 4'd1;
                    end
                end
                default: bcnt_nxt = bcnt + 4'd1;        // P_CRC
                endcase
            end
        end
    end

    S_EOP: if (tick) begin
        case (bitn[1:0])
        2'd0: begin                                     // keep-alive: first SE0 bit
            if (~sym_j) begin                           // the line left J
                st_nxt   = S_IDLE;
                res_nxt  = R_BUSY;
                done_nxt = 1'b1;
            end else begin
                bitn_nxt = 3'd1;
                oe_nxt   = 1'b1;
                dpo_nxt  = 1'b0;
                dmo_nxt  = 1'b0;
            end
        end
        2'd1: bitn_nxt = 3'd2;                          // second SE0 bit
        2'd2: begin                                     // J
            bitn_nxt = 3'd3;
            dmo_nxt  = 1'b1;
        end
        default: begin                                  // release
            oe_nxt  = 1'b0;
            dmo_nxt = 1'b0;
            if (resp_i & (kind_i != K_KEEP)) begin
                st_nxt  = S_RXW;
                cnt_nxt = 8'd1;                         // one bit time since the SE0-to-J edge
            end else begin
                st_nxt   = S_IDLE;
                res_nxt  = R_OK;
                done_nxt = 1'b1;
            end
        end
        endcase
    end

    S_RXW: begin
        if (sym_k) begin                                // SOP
            st_nxt    = S_RX;
            rephase_r = 1'b1;
            cnt_nxt   = 8'd0;
            bitn_nxt  = 3'd0;
            bcnt_nxt  = 4'd0;
            ph_nxt    = P_SYNC;
            ones_nxt  = 3'd0;
            lvl_nxt   = 1'b0;                           // previous symbol: J
            crc_nxt   = 16'hFFFF;
        end else if (tick) begin
            if (cnt == 8'd23) begin
                st_nxt   = S_IDLE;
                res_nxt  = R_TMO;
                done_nxt = 1'b1;
            end else begin
                cnt_nxt  = cnt + 8'd1;
            end
        end
    end

    S_RX: begin
        rephase_r = dp_edge;
        if (tick) begin
            if (rx_se0) begin                           // EOP: done once its J is back
                st_nxt   = S_DRAIN;
                eopw_nxt = (ph == P_PAY);
                res_nxt  = ((ph == P_PAY) & ((pid_q[1:0] == 2'b10) ? rx_hs_ok
                                           : (pid_q[1:0] == 2'b11) ? rx_data_ok
                                           : 1'b1)) ? R_OK : R_BAD;
                cnt_nxt  = 8'd0;
            end else begin
                lvl_nxt = rx_s;
                if (ph == P_SYNC) begin
                    if (~rx_bit) begin
                        cnt_nxt = cnt + 8'd1;
                        if (cnt == 8'd15) begin
                            st_nxt  = S_DRAIN;
                            res_nxt = R_BAD;
                            cnt_nxt = 8'd0;
                        end
                    end else if (cnt >= 8'd5) begin
                        ph_nxt   = P_PID;
                        ones_nxt = 3'd1;                // the sync's last bit
                    end else begin
                        st_nxt  = S_DRAIN;
                        res_nxt = R_BAD;
                        cnt_nxt = 8'd0;
                    end
                end else if (ones == 3'd6) begin        // stuffed bit: must be a zero
                    ones_nxt = 3'd0;
                    if (rx_bit) begin
                        st_nxt  = S_DRAIN;
                        res_nxt = R_BAD;
                        cnt_nxt = 8'd0;
                    end
                end else begin
                    ones_nxt = rx_bit ? (ones + 3'd1) : 3'd0;
                    sr_nxt   = rx_byte;
                    bitn_nxt = bitn + 3'd1;
                    if (ph == P_PAY) crc_nxt = crc_rx_step;
                    if (bitn == 3'd7) begin
                        if (ph == P_PID) begin
                            pid_nxt = rx_byte[3:0];
                            if (rx_byte[3:0] == ~rx_byte[7:4]) begin
                                ph_nxt = P_PAY;
                            end else begin
                                st_nxt  = S_DRAIN;
                                res_nxt = R_BAD;
                                cnt_nxt = 8'd0;
                            end
                        end else begin
                            rx_we    = 1'b1;
                            bcnt_nxt = bcnt + 4'd1;
                            if (bcnt == 4'd10) begin
                                st_nxt  = S_DRAIN;
                                res_nxt = R_LONG;
                                cnt_nxt = 8'd0;
                            end
                        end
                    end
                end
            end
        end
    end

    default: begin                                      // S_DRAIN
        if (tick) begin
            cnt_nxt = cnt + 8'd1;
            if (eopw ? (sym_j | (cnt == 8'd3)) : (icnt[4] | (cnt == 8'd255))) begin
                st_nxt   = S_IDLE;
                done_nxt = 1'b1;
                eopw_nxt = 1'b0;
            end
        end
    end

    endcase

    if (abort_i) begin
        st_nxt   = S_IDLE;
        oe_nxt   = 1'b0;
        dpo_nxt  = 1'b0;
        dmo_nxt  = 1'b0;
        done_nxt = 1'b0;
    end
end


//=============================================================================
// 6)  REGISTERS
//=============================================================================

arv_ipdff #(.WIDTH(3),  .ARST_EN(ARST_EN)) u_st   (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(st_nxt),   .q_o(st));
arv_ipdff #(.WIDTH(8),  .ARST_EN(ARST_EN)) u_cnt  (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(cnt_nxt),  .q_o(cnt));
arv_ipdff #(.WIDTH(8),  .ARST_EN(ARST_EN)) u_sr   (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(sr_nxt),   .q_o(sr));
arv_ipdff #(.WIDTH(3),  .ARST_EN(ARST_EN)) u_bitn (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(bitn_nxt), .q_o(bitn));
arv_ipdff #(.WIDTH(4),  .ARST_EN(ARST_EN)) u_bcnt (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(bcnt_nxt), .q_o(bcnt));
arv_ipdff #(.WIDTH(2),  .ARST_EN(ARST_EN)) u_ph   (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(ph_nxt),   .q_o(ph));
arv_ipdff #(.WIDTH(3),  .ARST_EN(ARST_EN)) u_ones (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(ones_nxt), .q_o(ones));
arv_ipdff #(.WIDTH(1),  .ARST_EN(ARST_EN)) u_lvl  (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(lvl_nxt),  .q_o(lvl));
arv_ipdff #(.WIDTH(16), .ARST_EN(ARST_EN)) u_crc  (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(crc_nxt),  .q_o(crc));
arv_ipdff #(.WIDTH(4),  .ARST_EN(ARST_EN)) u_pid  (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(pid_nxt),  .q_o(pid_q));
arv_ipdff #(.WIDTH(3),  .ARST_EN(ARST_EN)) u_res  (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(res_nxt),  .q_o(res_q));
arv_ipdff #(.WIDTH(1),  .ARST_EN(ARST_EN)) u_eopw (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(eopw_nxt & ~abort_i), .q_o(eopw));
arv_ipdff #(.WIDTH(1),  .ARST_EN(ARST_EN)) u_done (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(done_nxt), .q_o(done_q));
arv_ipdff #(.WIDTH(3),  .ARST_EN(ARST_EN)) u_pads (.clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1),
                                                   .d_i({oe_nxt, dpo_nxt, dmo_nxt}), .q_o({oe_q, dpo_q, dmo_q}));


//=============================================================================
// 7)  OUTPUTS
//=============================================================================

assign busy_o    = (st != S_IDLE);
assign tick_o    = tick;
assign done_o    = done_q;
assign res_o     = res_q;
assign rx_pid_o  = pid_q;
assign rx_len_o  = rx_data_ok ? (bcnt - 4'd2) : 4'd0;
assign rx_we_o   = rx_we;
assign rx_idx_o  = bcnt;
assign rx_byte_o = rx_byte;

assign usb_oe_o  = oe_q;
assign usb_dp_o  = dpo_q;
assign usb_dm_o  = dmo_q;

endmodule // apb_usb_host_sie

`default_nettype wire
