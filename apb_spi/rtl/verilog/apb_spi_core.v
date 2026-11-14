//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    apb_spi_core
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : apb_spi_core.v
// Module Description : SPI controller shift engine, independent of any bus:
//                      serial-clock generator, chip-select sequencer,
//                      serialiser and deserialiser on one, two or four lanes,
//                      driven by a stream of entries (attribute word +
//                      payload, the XFER layout of apb_spi).
//
//   Timebase: SCK half-period = HALF = div + 1 clk_i cycles. Every serial
//             output is a flop output and moves only on a half-period tick
//             or on an instant named below.
//   Transaction: an entry taken while no transaction is open asserts its
//             chip select (none with CS_NONE) and latches the clock mode,
//             divider, RX_DLY, bit and byte order and chip-select timing;
//             SETUP half-periods later comes the first SCK edge. Frames
//             follow each other with no gap. An entry ending with CS_HOLD
//             keeps the select; the next entry on the same select continues
//             the transaction, with no gap when it is there in time, else
//             it resumes (CPHA = 0: first bit on the resume edge, leading
//             edge HALF later; CPHA = 1: leading edge and first bit on the
//             resume edge). Otherwise the select is released HOLD
//             half-periods after the last edge and INACT half-periods
//             later the next transaction may start. A new transaction
//             also waits for the previous one's last capture.
//   Frame end F: HALF after the last sampling edge (the trailing edge with
//             CPHA = 0). The lanes return to their no-frame state there
//             unless a frame launches on it; a lane a dual or quad frame of
//             the transaction used stays released until the select is
//             released (a device may go on driving it). A POLL frame ends on
//             P = max(F, capture + 1): when P > F the engine pauses with
//             SCK idle and the next frame resumes.
//   Receive: each used lane crosses a two-flop synchroniser; the pad value
//             RX_DLY clk_i edges after the sampling edge is captured
//             RX_DLY + 2 edges after it. Each sampling edge enters a delay
//             line with the attributes its capture needs, so frames of
//             different shapes may overlap their captures.
//----------------------------------------------------------------------------
`default_nettype none

module  apb_spi_core #(
    parameter                 LANES_MAX    = 4,       // widest lane mode built: 1, 2 or 4
    parameter                 CS_NR        = 1,       // chip selects (1..8)
    parameter                 RX_EN        = 1,       // receive path present
    parameter                 POLL_EN      = 1,       // POLL entries supported (needs RX_EN)
    parameter                 ASYNC_RST_EN = 1        // Reset style: 1=async active-low reset, 0=synchronous reset
) (
    input  wire               clk_i,                  // clock: SCK divides it
    input  wire               rst_n_i,                // active-low reset, style per ASYNC_RST_EN

// CONFIGURATION (latched at transaction start unless noted; the immediate idle
// levels are the values after the current edge, so a write moves them on its
// ACCESS edge)
    input  wire        [11:0] div_i,                  // SCK half-period - 1, in clk_i cycles
    input  wire         [3:0] rx_dly_i,               // receive sampling point: clk_i cycles after the sampling edge
    input  wire               cpol_i,                 // SCK idle level (after this edge; followed whenever no transaction is open)
    input  wire               cpha_i,                 // 0: sample on the leading edge, 1: on the trailing edge
    input  wire               lsb_first_i,            // bit order
    input  wire               bswap_i,                // byte order of 16-, 24- and 32-bit frames
    input  wire   [CS_NR-1:0] cs_pol_i,               // 1: chip select active high (after this edge; followed while none is asserted)
    input  wire         [3:0] cs_setup_i,             // SETUP - 1, in half-periods
    input  wire         [3:0] cs_hold_i,              // HOLD - 1
    input  wire         [3:0] cs_inact_i,             // INACT - 1
    input  wire         [1:0] tx_idle_i,              // IO0 with no transmit frame: 0 low, 1 high, 2-3 released (immediate)
    input  wire               io23_rel_i,             // IO2 / IO3 when not data lanes: 0 driven high, 1 released (immediate)
    input  wire               rx_io0_i,               // single-lane receive lane: 0 IO1, 1 IO0 (per frame)
    input  wire               loopback_i,             // single-lane receive from the IO0 output (per frame)

// ENTRY STREAM
    input  wire               e_valid_i,              // an entry is offered
    input  wire               e_present_i,            // the FIFO holds an entry (STATUS only: no write-data path)
    input  wire        [15:0] e_attr_i,               // its attributes (XFER layout)
    input  wire        [31:0] e_data_i,               // its payload
    output wire               e_take_o,               // the entry starts (pop it)
    input  wire               e_abort_i,              // abort the transaction in progress

// CONTROL AND STATUS
    input  wire               run_i,                  // take new entries
    input  wire               rx_room_i,              // a capturing frame may start
    output wire               busy_o,                 // work that needs clock edges
    output wire               cs_active_o,            // a chip select is asserted
    output wire               stall_o,                // a capturing frame is held back for receive room
    output wire               quiet_nxt_o,            // after this edge: not busy and no select asserted
    output wire               poll_to_o,              // a POLL entry ran out of frames (pulse)

// RECEIVE STREAM
    output wire               rx_start_o,             // a capturing frame starts (pulse)
    output wire               rx_done_o,              // a capturing frame's capture completed, pushed or not (pulse)
    output wire               rx_valid_o,             // rx_data_o is to be pushed (pulse, subset of rx_done_o)
    output wire        [31:0] rx_data_o,              // received frame, right-aligned

// PINS
    output wire               spi_sck_o,              // serial clock
    output wire   [CS_NR-1:0] spi_cs_o,               // chip selects
    output wire         [3:0] spi_io_o,               // lane output values
    output wire         [3:0] spi_io_oe_o,            // lane output enables
    input  wire         [3:0] spi_io_i                // lane inputs (asynchronous)
);


//=============================================================================
// 1)  DECLARATIONS
//=============================================================================

// pragma translate_off
generate
    if ((LANES_MAX != 1) && (LANES_MAX != 2) && (LANES_MAX != 4)) begin : CHECK_LANES_MAX
        initial $fatal(1, "apb_spi_core: LANES_MAX (%0d) must be 1, 2 or 4.", LANES_MAX);
    end
    if ((CS_NR < 1) || (CS_NR > 8)) begin : CHECK_CS_NR
        initial $fatal(1, "apb_spi_core: CS_NR (%0d) must be 1..8.", CS_NR);
    end
    if ((RX_EN != 0) && (RX_EN != 1)) begin : CHECK_RX_EN
        initial $fatal(1, "apb_spi_core: RX_EN (%0d) must be 0 or 1.", RX_EN);
    end
    if ((POLL_EN != 0) && (POLL_EN != 1)) begin : CHECK_POLL_EN
        initial $fatal(1, "apb_spi_core: POLL_EN (%0d) must be 0 or 1.", POLL_EN);
    end
    if ((POLL_EN == 1) && (RX_EN == 0)) begin : CHECK_POLL_RX
        initial $fatal(1, "apb_spi_core: POLL_EN = 1 needs RX_EN = 1.");
    end
    if ((ASYNC_RST_EN != 0) && (ASYNC_RST_EN != 1)) begin : CHECK_ASYNC_RST_EN
        initial $fatal(1, "apb_spi_core: ASYNC_RST_EN (%0d) must be 0 or 1.", ASYNC_RST_EN);
    end
endgenerate
// pragma translate_on

localparam              ARST_EN  = (ASYNC_RST_EN != 0);
localparam              RX_USE   = (RX_EN != 0);
localparam              POLL_USE = (POLL_EN != 0) && (RX_EN != 0);

// Lane codes a build can hold: single only, up to dual, up to quad
localparam        [1:0] LN_MASK  = (LANES_MAX == 4) ? 2'b11 : (LANES_MAX == 2) ? 2'b01 : 2'b00;

// Engine states
localparam        [2:0] S_IDLE   = 3'd0,      // no transaction
                        S_SETUP  = 3'd1,      // select asserted, waiting for the first edge
                        S_SHIFT  = 3'd2,      // a frame is clocked
                        S_PAUSE  = 3'd3,      // after a POLL frame, waiting for its evaluation
                        S_WAIT   = 3'd4,      // select held, nothing to do (or stalled)
                        S_HOLD   = 3'd5,      // waiting to release the select
                        S_INACT  = 3'd6;      // select released, inactive time

// Entry kinds
localparam        [1:0] K_TX     = 2'd0,
                        K_RX     = 2'd1,
                        K_DUMMY  = 2'd2,
                        K_POLL   = 2'd3;

// Metadata of a sampling edge: {first, last, lanes[1:0], loop, rx_io0, poll, pfin}
localparam              MW       = 8;
localparam              DL_N     = 17;        // delay-line stages: captures 2..17 edges after the sample

// Engine registers
wire              [2:0] st;
wire             [11:0] hcnt;                 // clk_i cycles in the half-period
wire              [3:0] hn;                   // half-periods left in SETUP / HOLD / INACT
wire                    act;                  // SCK away from its idle level
wire                    fa;                   // a frame owns the lanes
wire                    mid;                  // WAIT: the entry in progress is stalled between frames
wire                    abrt;                 // ABORT pending, acted on at the frame boundary
wire                    cs_on;                // the transaction's select is asserted
wire              [2:0] cs_sel;               // the transaction's select

// Configuration latched at transaction start
wire             [11:0] div_l;
wire              [3:0] rxd_l;
wire                    cpha_l;
wire                    lsb_l;
wire                    bswap_l;
wire              [3:0] hold_l;
wire              [3:0] inact_l;
wire                    cpol_l;               // SCK idle level in force
wire        [CS_NR-1:0] cspol_l;              // select polarity in force

// Entry in progress
wire              [4:0] c_bits;
wire              [1:0] c_lanes;
wire              [1:0] c_kind;
wire                    c_capt;
wire                    c_hold;
wire                    c_none;
wire             [15:0] frames;               // frames left after the current one

// Frame in progress
wire              [4:0] ccnt;                 // clocks left after the current one
wire                    ffirst;               // the next sample is the frame's first
wire                    frxio0;               // RX_IO0 of the frame
wire                    floop;                // LOOPBACK of the frame
wire             [31:0] tx_sr;                // transmit bits not yet launched

// POLL evaluation
wire              [7:0] pmask;                // POLL mask and value of the entry, from its payload
wire              [7:0] pval;
wire                    pdone;                // the POLL frame's compare is registered
wire                    phit;                 // ... and its frame qualified

// Pins
wire                    sck_q;
wire        [CS_NR-1:0] cs_q;
wire              [3:0] io_q;
wire              [3:0] oe_q;

// Receive side
wire              [4:0] npend;                // sampling edges whose capture is pending
wire                    cap;                  // a capture this cycle
wire           [MW-1:0] cmeta;                // its metadata
wire             [31:0] cword;                // the frame word a last capture completes
wire                    chit;                 // POLL compare of cword

// Head entry fields
wire              [4:0] h_bits   = e_attr_i[4:0];
wire              [1:0] h_lanes  = e_attr_i[6:5] & LN_MASK;
wire              [1:0] h_kind   = e_attr_i[9:8];
wire                    h_capt   = e_attr_i[10];
wire                    h_hold   = e_attr_i[11];
wire                    h_none   = e_attr_i[12];
wire              [2:0] h_sel    = e_attr_i[15:13];
wire                    h_cap    = RX_USE & ((h_kind == K_RX) | (h_kind == K_POLL) | ((h_kind == K_TX) & h_capt & (h_lanes == 2'b00)));
wire              [4:0] h_clk_m1 = (h_kind == K_DUMMY) ? 5'd0 : (h_bits >> h_lanes);
wire                    c_cap    = RX_USE & ((c_kind == K_RX) | (c_kind == K_POLL) | ((c_kind == K_TX) & c_capt & (c_lanes == 2'b00)));
wire              [4:0] c_clk_m1 = (c_kind == K_DUMMY) ? 5'd0 : (c_bits >> c_lanes);
wire                    c_poll   = (c_kind == K_POLL);
wire                    h_rsvd_unused = e_attr_i[7];
wire              [1:0] h_lanes_unused = e_attr_i[6:5];   // masked to the lane codes the build has

wire                    tick     = (hcnt == div_l);
wire                    txn_open = (st != S_IDLE) & (st != S_INACT);
wire                    lsb_e    = txn_open ? lsb_l   : lsb_first_i;
wire                    bswap_e  = txn_open ? bswap_l : bswap_i;


//=============================================================================
// 2)  BIT AND BYTE ORDER HELPERS
//=============================================================================

// Byte reversal of a frame of n bits (16, 24, 32; any other length unchanged)
function [31:0] bsw;
    input [31:0] w;
    input  [5:0] n;
    begin
        case (n)
            6'd16:   bsw = {16'h0000, w[7:0], w[15:8]};
            6'd24:   bsw = {8'h00, w[7:0], w[15:8], w[23:16]};
            6'd32:   bsw = {w[7:0], w[15:8], w[23:16], w[31:24]};
            default: bsw = w;
        endcase
    end
endfunction

// The lanes of the next group to launch (hi: bits 31:28, lo: bits 3:0)
function [3:0] grp;
    input  [3:0] hi;
    input  [3:0] lo;
    input  [1:0] ln;
    input        lsb;
    begin
        case ({lsb, ln})
            3'b000:  grp = {3'b000, hi[3]};
            3'b001:  grp = {2'b00, hi[3:2]};
            3'b010:  grp = hi;
            3'b100:  grp = {3'b000, lo[0]};
            3'b101:  grp = {2'b00, lo[1:0]};
            3'b110:  grp = lo;
            default: grp = 4'h0;
        endcase
    end
endfunction

// The transmit bits left after a group
function [31:0] gshift;
    input [31:0] s;
    input  [1:0] ln;
    input        lsb;
    begin
        case ({lsb, ln})
            3'b000:  gshift = {s[30:0], 1'b0};
            3'b001:  gshift = {s[29:0], 2'b00};
            3'b010:  gshift = {s[27:0], 4'h0};
            3'b100:  gshift = {1'b0, s[31:1]};
            3'b101:  gshift = {2'b00, s[31:2]};
            3'b110:  gshift = {4'h0, s[31:4]};
            default: gshift = s;
        endcase
    end
endfunction

// Head payload in launch order: byte-swapped, then MSB-first frames moved to
// the top so their first bit is bit 31
wire              [5:0] h_n       = {1'b0, h_bits} + 6'd1;
wire             [31:0] h_word    = bswap_e ? bsw(e_data_i, h_n) : e_data_i;
wire             [31:0] h_aligned = lsb_e ? h_word : (h_word << (5'd31 - h_bits));


//=============================================================================
// 3)  ENTRY DECISIONS
//=============================================================================
// Taken at a frame end (F or P), in WAIT (every cycle) and in PAUSE once the
// POLL compare is registered. cont: the entry in progress has another frame.

wire                    abort_now = e_abort_i | abrt;
wire                    more      = (frames != 16'h0000) & ~(c_poll & phit);
wire                    cont_in   = (st == S_WAIT) ? mid : more;
wire                    h_same    = ~h_none & (h_sel == cs_sel);

wire                    dc_cont   = cont_in & ~abort_now;
wire                    dc_same   = dc_cont & (~c_cap | rx_room_i);
wire                    dc_stl_s  = dc_cont & c_cap & ~rx_room_i;
wire                    dc_try    = ~cont_in & ~abort_now & c_hold & ~c_none & e_valid_i & run_i & h_same;
wire                    dc_new    = dc_try & (~h_cap | rx_room_i);
wire                    dc_hold   = ~dc_cont & (abort_now | ~c_hold | c_none | (e_valid_i & run_i & ~h_same));

// A new transaction: an entry offered, the engine enabled, no capture pending
wire                    take_ok   = e_valid_i & run_i & ~e_abort_i & (npend == 5'd0) & (~h_cap | rx_room_i);


//=============================================================================
// 4)  ENGINE NEXT STATE
//=============================================================================

reg               [2:0] st_n;
reg              [11:0] hcnt_n;
reg               [3:0] hn_n;
reg                     act_n;
reg                     fa_n;
reg                     mid_n;
reg                     abrt_n;
reg                     cs_on_n;
reg              [15:0] frames_n;
reg               [4:0] ccnt_n;
reg                     ffirst_n;
reg                     start;                // a transaction starts (latch configuration, take the entry)
reg                     take;                 // an entry is taken (start or continuation)
reg                     lnch;                 // a group is launched
reg                     lnch_new;             // ... the first of the entry being taken
reg                     ld_frame;             // a frame is loaded (frame registers, RX_IO0, LOOPBACK)
reg                     smp;                  // a sampling edge of a capturing frame
reg                     rxs;                  // a capturing frame starts
reg                     rxd_abort;            // an aborted SETUP ends a capturing frame that never clocked
reg                     pclr;                 // a POLL frame starts: forget the previous compare

// Hold time from a decision: counted from the frame end, one half-period
// shorter with CPHA = 1 (the last edge was HALF before F)
wire                    hold_f_imm = cpha_l & (hold_l == 4'h0);
wire              [3:0] hold_f_hn  = cpha_l ? (hold_l - 4'h1) : hold_l;

always @(*) begin
    st_n      = st;
    hcnt_n    = ((st == S_SETUP) | (st == S_SHIFT) | (st == S_HOLD) | (st == S_INACT)) ?
                (tick ? 12'h000 : (hcnt + 12'h001)) : 12'h000;
    hn_n      = hn;
    act_n     = act;
    fa_n      = fa;
    mid_n     = mid;
    abrt_n    = abrt;
    cs_on_n   = cs_on;
    frames_n  = frames;
    ccnt_n    = ccnt;
    ffirst_n  = ffirst;
    start     = 1'b0;
    take      = 1'b0;
    lnch      = 1'b0;
    lnch_new  = 1'b0;
    ld_frame  = 1'b0;
    smp       = 1'b0;
    rxs       = 1'b0;
    rxd_abort = 1'b0;
    pclr      = 1'b0;

    case (st)

        // A transaction starts: the select asserts; with CPHA = 0 the first
        // group is on the lanes from the assertion
        S_IDLE, S_INACT: begin
            if ((st == S_IDLE) | (tick & (hn == 4'h0))) begin
                st_n = S_IDLE;
                if (take_ok) begin
                    start    = 1'b1;
                    take     = 1'b1;
                    st_n     = S_SETUP;
                    hcnt_n   = 12'h000;
                    hn_n     = cs_setup_i;
                    cs_on_n  = ~h_none;
                    frames_n = (h_kind == K_TX) ? 16'h0000 : e_data_i[15:0];
                    ccnt_n   = h_clk_m1;
                    ffirst_n = 1'b1;
                    rxs      = h_cap;
                    pclr     = (h_kind == K_POLL);
                    act_n    = 1'b0;
                    mid_n    = 1'b0;
                    abrt_n   = 1'b0;
                    ld_frame = ~cpha_i;
                    lnch     = ~cpha_i;
                    lnch_new = ~cpha_i;
                    fa_n     = ~cpha_i;
                end
            end else if (tick) begin
                hn_n = hn - 4'h1;
            end
        end

        // First edge after SETUP: CPHA = 0 samples, CPHA = 1 launches.
        // ABORT ends the setup without an edge.
        S_SETUP: begin
            if (abort_now) begin
                st_n      = S_HOLD;
                hcnt_n    = 12'h000;
                hn_n      = hold_l;
                fa_n      = 1'b0;
                abrt_n    = 1'b0;
                rxd_abort = c_cap;
            end else if (tick) begin
                if (hn == 4'h0) begin
                    st_n  = S_SHIFT;
                    act_n = 1'b1;
                    if (cpha_l) begin
                        lnch     = 1'b1;
                        ld_frame = 1'b1;
                        fa_n     = 1'b1;
                    end else begin
                        smp      = c_cap;
                    end
                end else begin
                    hn_n = hn - 4'h1;
                end
            end
        end

        S_SHIFT: begin
            if (e_abort_i)
                abrt_n = 1'b1;
            if (tick) begin
                if (~act & ~cpha_l) begin                       // leading edge, sample
                    act_n = 1'b1;
                    smp   = c_cap;
                end else if (~act & (ccnt != 5'd0)) begin       // leading edge, next group
                    act_n  = 1'b1;
                    lnch   = 1'b1;
                    ccnt_n = ccnt - 5'd1;
                end else if (act & cpha_l) begin                // trailing edge, sample
                    act_n = 1'b0;
                    smp   = c_cap;
                end else if (act & (ccnt != 5'd0)) begin        // trailing edge, next group
                    act_n  = 1'b0;
                    lnch   = 1'b1;
                    ccnt_n = ccnt - 5'd1;
                end else begin                                  // frame end F
                    act_n = 1'b0;
                    fa_n  = 1'b0;
                    if (c_poll & ~pdone) begin
                        st_n = S_PAUSE;
                    end else begin
                        // decision at F: a following frame launches with no gap
                        if (dc_same | dc_new) begin
                            frames_n = dc_new ? ((h_kind == K_TX) ? 16'h0000 : e_data_i[15:0]) : (frames - 16'h0001);
                            take     = dc_new;
                            lnch     = 1'b1;
                            lnch_new = dc_new;
                            ld_frame = 1'b1;
                            fa_n     = 1'b1;
                            ccnt_n   = dc_new ? h_clk_m1 : c_clk_m1;
                            ffirst_n = 1'b1;
                            rxs      = dc_new ? h_cap : c_cap;
                            pclr     = dc_new ? (h_kind == K_POLL) : c_poll;
                            act_n    = cpha_l;
                                end else if (dc_hold) begin
                            abrt_n = 1'b0;
                            if (hold_f_imm) begin
                                cs_on_n = 1'b0;
                                st_n    = S_INACT;
                                hn_n    = inact_l;
                            end else begin
                                st_n    = S_HOLD;
                                hn_n    = hold_f_hn;
                            end
                        end else begin
                            st_n  = S_WAIT;
                            mid_n = dc_stl_s;
                        end
                    end
                end
            end
        end

        // After a pause the next frame resumes on this edge: CPHA = 0 launches
        // its first group (leading edge HALF later), CPHA = 1 its leading
        // edge with the first group (SCK has been idle at least HALF)
        S_PAUSE, S_WAIT: begin
            if ((st == S_WAIT) | abort_now | pdone) begin
                if (dc_same | dc_new) begin
                    st_n     = S_SHIFT;
                    hcnt_n   = 12'h000;
                    frames_n = dc_new ? ((h_kind == K_TX) ? 16'h0000 : e_data_i[15:0]) : (frames - 16'h0001);
                    take     = dc_new;
                    lnch     = 1'b1;
                    lnch_new = dc_new;
                    ld_frame = 1'b1;
                    fa_n     = 1'b1;
                    ccnt_n   = dc_new ? h_clk_m1 : c_clk_m1;
                    ffirst_n = 1'b1;
                    rxs      = dc_new ? h_cap : c_cap;
                    pclr     = dc_new ? (h_kind == K_POLL) : c_poll;
                    act_n    = cpha_l;
                    mid_n    = 1'b0;
                end else if (dc_hold) begin
                    st_n   = S_HOLD;
                    hcnt_n = 12'h000;
                    hn_n   = hold_l;
                    mid_n  = 1'b0;
                    abrt_n = 1'b0;
                end else begin
                    st_n  = S_WAIT;
                    mid_n = dc_stl_s;
                end
            end
        end

        S_HOLD: begin
            if (tick) begin
                if (hn == 4'h0) begin
                    cs_on_n = 1'b0;
                    st_n    = S_INACT;
                    hn_n    = inact_l;
                end else begin
                    hn_n = hn - 4'h1;
                end
            end
        end

        default: begin                                    // state 7: never entered
            st_n = S_IDLE;
        end
    endcase
end

//=============================================================================
// 5)  ENGINE REGISTERS
//=============================================================================

arv_ipdff #(.WIDTH(3), .ARST_EN(ARST_EN)) u_st (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(st_n), .q_o(st));

arv_ipdff #(.WIDTH(12), .ARST_EN(ARST_EN)) u_hcnt (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(hcnt_n), .q_o(hcnt));

arv_ipdff #(.WIDTH(4), .ARST_EN(ARST_EN)) u_hn (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(hn_n), .q_o(hn));

arv_ipdff #(.WIDTH(5), .ARST_EN(ARST_EN)) u_flags (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1),
    .d_i({act_n, fa_n, mid_n, abrt_n, cs_on_n}), .q_o({act, fa, mid, abrt, cs_on}));

arv_ipdff #(.WIDTH(3), .ARST_EN(ARST_EN)) u_cs_sel (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(start), .d_i(h_sel), .q_o(cs_sel));

arv_ipdff #(.WIDTH(27), .ARST_EN(ARST_EN)) u_cfg (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(start),
    .d_i({div_i, rx_dly_i & {4{RX_USE}}, cpha_i, lsb_first_i, bswap_i, cs_hold_i, cs_inact_i}),
    .q_o({div_l, rxd_l, cpha_l, lsb_l, bswap_l, hold_l, inact_l}));

// The idle levels follow the configuration whenever no transaction holds them;
// a transaction starts with the levels in force, so a write on its start edge
// applies from the next one, as every other latched setting
wire                    txn_open_n = (st_n != S_IDLE) & (st_n != S_INACT);
wire                    cpol_e     = ~txn_open_n ? cpol_i : cpol_l;
wire        [CS_NR-1:0] cspol_e    = ~cs_on_n ? cs_pol_i : cspol_l;

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_cpol (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(cpol_e), .q_o(cpol_l));

arv_ipdff #(.WIDTH(CS_NR), .ARST_EN(ARST_EN)) u_cspol (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(cspol_e), .q_o(cspol_l));

arv_ipdff #(.WIDTH(12), .ARST_EN(ARST_EN)) u_entry (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(take),
    .d_i({h_bits, h_lanes, h_kind, h_capt & RX_USE, h_hold, h_none}),
    .q_o({c_bits, c_lanes, c_kind, c_capt, c_hold, c_none}));

arv_ipdff #(.WIDTH(16), .ARST_EN(ARST_EN)) u_frames (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(frames_n), .q_o(frames));

arv_ipdff #(.WIDTH(6), .ARST_EN(ARST_EN)) u_frame (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i({ccnt_n, ffirst_n & ~smp}), .q_o({ccnt, ffirst}));

arv_ipdff #(.WIDTH(2), .ARST_EN(ARST_EN)) u_frame_rx (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(ld_frame),
    .d_i({rx_io0_i & RX_USE, loopback_i & RX_USE}), .q_o({frxio0, floop}));


//=============================================================================
// 6)  SERIALISER
//=============================================================================
// A launch takes the next group from the entry being taken (its first) or
// from the bits left; a CPHA = 1 transaction start stores the aligned payload
// for the launch at the end of SETUP.

wire             [31:0] l_src     = lnch_new ? h_aligned : tx_sr;
wire              [1:0] l_lanes   = lnch_new ? h_lanes   : c_lanes;
wire              [3:0] l_grp     = grp(l_src[31:28], l_src[3:0], l_lanes, lsb_e);
wire             [31:0] tx_sr_n   = lnch ? gshift(l_src, l_lanes, lsb_e) : h_aligned;

arv_ipdff #(.WIDTH(32), .ARST_EN(ARST_EN)) u_tx_sr (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(lnch | (start & cpha_i)), .d_i(tx_sr_n), .q_o(tx_sr));


//=============================================================================
// 7)  PINS
//=============================================================================
// Lane k is a data lane during a transmit frame of at least k+1 lanes and is
// released during a dual or quad frame of another kind; otherwise it is in
// its no-frame state: IO0 per TX_IDLE, IO1 released, IO2 / IO3 per IO23_REL.

wire              [1:0] k_n       = take ? h_kind  : c_kind;
wire              [1:0] ln_n      = take ? h_lanes : c_lanes;
wire              [3:0] ln_msk    = (ln_n == 2'b10) ? 4'b1111 : (ln_n == 2'b01) ? 4'b0011 : 4'b0001;
wire              [3:0] dl_lane   = {4{fa_n & (k_n == K_TX)}} & ln_msk;
wire              [3:0] rl_lane   = {4{fa_n & (k_n != K_TX) & (ln_n != 2'b00)}} & ln_msk;
wire              [3:0] idle_val  = {~io23_rel_i, ~io23_rel_i, 1'b0, (tx_idle_i == 2'b01)};
wire              [3:0] idle_oe   = {~io23_rel_i, ~io23_rel_i, 1'b0, ~tx_idle_i[1]};
// A lane a dual or quad frame released stays released until a frame drives
// it or the select is released: a device may go on driving it (a flash
// streams data, or starts after its latency cycles)
wire              [3:0] rel_lanes;
wire                    release_n = (st != S_INACT) & (st_n == S_INACT);
wire              [3:0] lnch_rel  = {4{lnch & (l_lanes != 2'b00)}} & ((l_lanes == 2'b10) ? 4'b1111 : 4'b0011);
wire              [3:0] rel_n     = (release_n | start) ? lnch_rel : (rel_lanes | lnch_rel);

arv_ipdff #(.WIDTH(4), .ARST_EN(ARST_EN)) u_rel (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(rel_n), .q_o(rel_lanes));

wire              [3:0] io_n      = (dl_lane & (lnch ? l_grp : io_q)) | (~dl_lane & ~rl_lane & ~rel_n & idle_val);
wire              [3:0] oe_n      = dl_lane | (~rl_lane & ~rel_n & idle_oe);

wire        [CS_NR-1:0] cs_n;
genvar gc;
generate
    for (gc = 0; gc < CS_NR; gc = gc + 1) begin : g_cs
        assign cs_n[gc] = ~((cs_on_n & ((start ? h_sel : cs_sel) == gc[2:0])) ^ cspol_e[gc]);
    end
endgenerate

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_sck (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(cpol_e ^ act_n), .q_o(sck_q));

arv_ipdff #(.WIDTH(CS_NR), .RST_VAL({CS_NR{1'b1}}), .ARST_EN(ARST_EN)) u_cs (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(cs_n), .q_o(cs_q));

arv_ipdff #(.WIDTH(8), .RST_VAL(8'b1101_1101), .ARST_EN(ARST_EN)) u_io (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i({oe_n, io_n}), .q_o({oe_q, io_q}));


//=============================================================================
// 8)  DESERIALISER
//=============================================================================

generate
    if (RX_USE) begin : g_rx

        wire  [DL_N-1:0]        sl;                     // sampling-edge delay line
        wire  [DL_N*MW-1:0]     ml;                     // ... its metadata
        wire  [3:0]             sin;                    // synchronised lanes
        wire                    lb1;
        wire                    lb2;                    // IO0 output, delayed as the synchronisers delay a pad
        wire  [31:0]            rsr;                    // frame being assembled
        wire  [5:0]             rcnt;                   // its bits
        wire  [MW-1:0]          smeta;
        wire  [4:0]             ins = 5'd15 - {1'b0, rxd_l};    // stage a sampling edge enters
        wire  [DL_N-1:0]        sl_n;
        wire  [DL_N*MW-1:0]     ml_n;

        assign smeta = {ffirst, (ccnt == 5'd0), c_lanes, floop, frxio0, c_poll, (frames == 16'h0000)};

        // A sampling edge enters the line at stage 15 - RX_DLY and is captured
        // from its last stage, RX_DLY + 2 edges after the sampling edge: the
        // variable delay sits on the way in, not on the capture path. Samples
        // are at least two cycles apart, so the stages below the entry stage
        // are always empty. A transaction starts only with the line empty.
        genvar gd;
        for (gd = 0; gd < DL_N; gd = gd + 1) begin : g_dl
            wire hit = smp & (ins == gd[4:0]);
            if (gd == 0) begin : g_first
                assign sl_n[gd]           = hit;
                assign ml_n[gd*MW +: MW]  = hit ? smeta : {MW{1'b0}};
            end else begin : g_next
                assign sl_n[gd]           = hit | sl[gd-1];
                assign ml_n[gd*MW +: MW]  = hit ? smeta : ml[(gd-1)*MW +: MW];
            end
        end

        arv_ipdff #(.WIDTH(DL_N), .ARST_EN(ARST_EN)) u_sl (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(sl_n), .q_o(sl));

        arv_ipdff #(.WIDTH(DL_N*MW), .ARST_EN(ARST_EN)) u_ml (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(smp | (npend != 5'd0)), .d_i(ml_n), .q_o(ml));

        assign cap   = sl[DL_N-1];
        assign cmeta = ml[(DL_N-1)*MW +: MW];

        // IO0 and IO1 are read in every build (IO0 by RX_IO0), IO2 / IO3 in quad builds
        arv_synchronizer #(.W(1), .RST_VAL(1'b1), .ARST_EN(ARST_EN)) u_io0_sync (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .async_i(spi_io_i[0]), .sync_o(sin[0]));

        arv_synchronizer #(.W(1), .RST_VAL(1'b1), .ARST_EN(ARST_EN)) u_io1_sync (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .async_i(spi_io_i[1]), .sync_o(sin[1]));

        if (LANES_MAX == 4) begin : g_quad_in
            arv_synchronizer #(.W(1), .RST_VAL(1'b1), .ARST_EN(ARST_EN)) u_io2_sync (
                .clk_i(clk_i), .rst_n_i(rst_n_i), .async_i(spi_io_i[2]), .sync_o(sin[2]));

            arv_synchronizer #(.W(1), .RST_VAL(1'b1), .ARST_EN(ARST_EN)) u_io3_sync (
                .clk_i(clk_i), .rst_n_i(rst_n_i), .async_i(spi_io_i[3]), .sync_o(sin[3]));
        end else begin : g_no_quad_in
            assign sin[3:2] = 2'b11;
            wire [1:0] io_i_unused = spi_io_i[3:2];
        end

        arv_ipdff #(.WIDTH(1), .RST_VAL(1'b1), .ARST_EN(ARST_EN)) u_lb1 (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(io_q[0]), .q_o(lb1));

        arv_ipdff #(.WIDTH(1), .RST_VAL(1'b1), .ARST_EN(ARST_EN)) u_lb2 (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(1'b1), .d_i(lb1), .q_o(lb2));

        // Capture: shift a group in (MSB first: at the bottom; LSB first: at the top)
        wire              m_first = cmeta[7];
        wire              m_last  = cmeta[6];
        wire        [1:0] m_lanes = cmeta[5:4];
        wire              m_loop  = cmeta[3];
        wire              m_rxio0 = cmeta[2];
        wire              m_poll  = cmeta[1];
        wire              m_pfin  = cmeta[0];
        wire              s1      = m_loop ? lb2 : m_rxio0 ? sin[0] : sin[1];
        wire       [31:0] base    = m_first ? 32'h0 : rsr;
        wire        [5:0] rbase   = m_first ? 6'd0  : rcnt;
        reg        [31:0] rsr_n;
        reg         [5:0] rcnt_n;

        always @(*) begin
            case ({lsb_l, m_lanes})
                3'b000:  begin rsr_n = {base[30:0], s1};           rcnt_n = rbase + 6'd1; end
                3'b001:  begin rsr_n = {base[29:0], sin[1:0]};     rcnt_n = rbase + 6'd2; end
                3'b010:  begin rsr_n = {base[27:0], sin[3:0]};     rcnt_n = rbase + 6'd4; end
                3'b100:  begin rsr_n = {s1, base[31:1]};           rcnt_n = rbase + 6'd1; end
                3'b101:  begin rsr_n = {sin[1:0], base[31:2]};     rcnt_n = rbase + 6'd2; end
                3'b110:  begin rsr_n = {sin[3:0], base[31:4]};     rcnt_n = rbase + 6'd4; end
                default: begin rsr_n = base;                       rcnt_n = rbase;        end
            endcase
        end

        arv_ipdff #(.WIDTH(38), .ARST_EN(ARST_EN)) u_rsr (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(cap), .d_i({rcnt_n, rsr_n}), .q_o({rcnt, rsr}));

        // The completed frame, right-aligned, then byte-swapped
        wire        [4:0] rsh     = 5'd0 - rcnt_n[4:0];      // 32 - bits, modulo 32
        wire       [31:0] w_al    = lsb_l ? (rsr_n >> rsh) : rsr_n;
        assign cword = bswap_l ? bsw(w_al, rcnt_n) : w_al;

        wire              clast   = cap & m_last;
        wire              keep    = ~m_poll | chit | m_pfin;

        assign rx_done_o  = clast | rxd_abort;
        assign rx_valid_o = clast & keep;
        assign rx_data_o  = cword;
        assign poll_to_o  = clast & m_poll & ~chit & m_pfin;

        wire        [4:0] npend_n = npend + {4'h0, smp} - {4'h0, cap};

        arv_ipdff #(.WIDTH(5), .ARST_EN(ARST_EN)) u_npend (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(smp | cap), .d_i(npend_n), .q_o(npend));

        arv_ipdff #(.WIDTH(2), .ARST_EN(ARST_EN)) u_poll_res (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(pclr | (clast & m_poll)),
            .d_i(pclr ? 2'b00 : {1'b1, chit}), .q_o({pdone, phit}));

    end else begin : g_no_rx

        assign cap        = 1'b0;
        assign cmeta      = {MW{1'b0}};
        assign cword      = 32'h0;
        assign npend      = 5'd0;
        assign pdone      = 1'b0;
        assign phit       = 1'b0;
        assign rx_done_o  = 1'b0;
        assign rx_valid_o = 1'b0;
        assign rx_data_o  = 32'h0;
        assign poll_to_o  = 1'b0;
        wire        smp_unused    = smp;
        wire        rxd_unused    = rxd_abort;
        wire        pclr_unused   = pclr;
        wire  [3:0] io_i_unused   = spi_io_i;
        wire  [3:0] rxd_l_unused  = rxd_l;
        wire        rx_cfg_unused = frxio0 | floop | ffirst;
        wire        cm_unused     = |cmeta | chit;
        wire        capt_unused   = c_capt | h_capt;
        wire  [3:0] rx_dly_unused = rx_dly_i;
        wire        rx_sel_unused = rx_io0_i | loopback_i;

    end
endgenerate


//=============================================================================
// 9)  POLL COMPARE
//=============================================================================

generate
    if (POLL_USE) begin : g_poll

        // The entry's payload carries the mask [31:24] and value [23:16]; the
        // compare is on the frame's low byte
        arv_ipdff #(.WIDTH(16), .ARST_EN(ARST_EN)) u_pmv (
            .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(take & (h_kind == K_POLL)),
            .d_i(e_data_i[31:16]), .q_o({pmask, pval}));

        assign chit = ((cword[7:0] & pmask) != pval);

    end else begin : g_no_poll

        assign pmask = 8'h00;
        assign pval  = 8'h00;
        assign chit  = 1'b0;
        wire [31:0] pm_unused = {pmask, pval, 16'h0000} | cword;

    end
endgenerate


//=============================================================================
// 10) STATUS AND OUTPUTS
//=============================================================================

wire                    busy    = (st == S_SETUP) | (st == S_SHIFT) | (st == S_PAUSE) | (st == S_HOLD) |
                                  ((st == S_WAIT) & mid) | (npend != 5'd0);
wire              [4:0] npend_x = npend + {4'h0, smp} - {4'h0, cap};
wire                    busy_n  = (st_n == S_SETUP) | (st_n == S_SHIFT) | (st_n == S_PAUSE) | (st_n == S_HOLD) |
                                  ((st_n == S_WAIT) & mid_n) | (npend_x != 5'd0);

assign busy_o      = busy;
assign cs_active_o = cs_on;
assign quiet_nxt_o = ~busy_n & ~cs_on_n;
// STALL from registered state only (no path from a flush or abort write)
assign stall_o     = ((st == S_WAIT) & mid & c_cap & ~rx_room_i) |
                     ((st == S_WAIT) & ~mid & ~abrt & c_hold & ~c_none & e_present_i & run_i & h_same & h_cap & ~rx_room_i) |
                     ((st == S_IDLE) & e_present_i & run_i & h_cap & ~rx_room_i);

assign e_take_o    = take;
assign rx_start_o  = rxs;

assign spi_sck_o   = sck_q;
assign spi_cs_o    = cs_q;
assign spi_io_o    = io_q;
assign spi_io_oe_o = oe_q;

endmodule // apb_spi_core

`default_nettype wire
