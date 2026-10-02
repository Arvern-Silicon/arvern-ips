//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arv_dtm_i2c
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arv_dtm_i2c
// Module Description : I2C-target Debug Transport Module for the aRVern core.
//                      Shares the arv_dtm_cmd interpreter and arv_dtm_dmi_master
//                      backend with the UART DTM -- only this PHY differs.
//                      (openMSP430 dbg_i2c use-model, recast onto RISC-V DMI.)
//
//   Frame, addressing and the clock-stretch busy scheme: doc/arv_dtm_i2c.md.
//   Delimiter handling across the read phase (asymmetric by design) and its known
//   residual: same doc, "Bus robustness".
//
//   Open-drain: the target never drives a line high. sda_pd_o/scl_pd_o are pull-down
//   REQUESTS; the SoC wraps them into open-drain pads with pull-ups.
//
//   ===================== HARD INTEGRATION REQUIREMENTS ========================
//   * clk_i MUST be the always-on oscillator (= DMI bus clock).
//   * f_clk >= 40 x f_SCL (>= 20 clk per SCL half-period). The input path is ~4 clk
//     deep; below this the target's own SDA release lands after SCL has risen and
//     decodes as a spurious STOP. At the 1 MHz SCL ceiling that is f_clk >= 40 MHz.
//   * i2c_addr_i must be 0x08..0x77 -- the compare is unfiltered, so a strap in
//     I2C-reserved space would answer a reserved address.
//----------------------------------------------------------------------------
`default_nettype none

module  arv_dtm_i2c #(
    parameter                   ARST_EN       = 1'b1,     // 1=async active-low reset, 0=sync
    parameter                   WD_BITS       = 16        // read-side bus-watchdog width (see below)
) (
    input  wire                 clk_i,                    // always-on oscillator (= DMI bus clock)
    input  wire                 dbgresetn_i,              // active-low reset

// I2C pins
    input  wire                 scl_i,                    // SCL line level
    input  wire                 sda_i,                    // SDA line level
    output wire                 sda_pd_o,                 // 1 = target pulls SDA low
    output wire                 scl_pd_o,                 // 1 = target pulls SCL low (clock stretch)

// I2C target address (SoC straps or a config register)
    input  wire           [6:0] i2c_addr_i,               // 7-bit I2C target address

// arvern DMI bus (same clk_i domain)
    output wire                 dmi_psel_o,
    output wire                 dmi_penable_o,
    output wire           [8:0] dmi_paddr_o,              // [DMI_ABITS+1:0]
    output wire                 dmi_pwrite_o,
    output wire          [31:0] dmi_pwdata_o,
    output wire           [2:0] dmi_pprot_o,
    input  wire                 dmi_pready_i,
    input  wire          [31:0] dmi_prdata_i,
    input  wire                 dmi_pslverr_i
);

//=============================================================================
// SCL / SDA synchronisers + glitch filter + edge / START / STOP detection
//=============================================================================
// 2-FF synchroniser then a 3-tap majority vote (openMSP430 omsp_dbg_i2c lineage).
// Everything downstream uses the FILTERED levels, never the raw sync output.
//
// Reset everything HIGH to match the idle line (open-drain + pull-up): a reset-low
// value would flush 0->1 and look like a STOP out of reset.
wire scl_sync, sda_sync;

arv_synchronizer #(.W(1), .RST_VAL(1'b1), .ARST_EN(ARST_EN)) u_scl_sync (
                                   .clk_i(clk_i), .rst_n_i(dbgresetn_i), .async_i(scl_i), .sync_o(scl_sync));

arv_synchronizer #(.W(1), .RST_VAL(1'b1), .ARST_EN(ARST_EN)) u_sda_sync (
                                   .clk_i(clk_i), .rst_n_i(dbgresetn_i), .async_i(sda_i), .sync_o(sda_sync));

// (1) 3-tap majority-vote glitch filter (openMSP430 scl_buf/sda_buf + majority).
wire [1:0] scl_buf, sda_buf;

arv_ipdff #(.WIDTH(2), .RST_VAL(2'b11), .ARST_EN(ARST_EN)) u_scl_buf (
                   .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i({scl_buf[0], scl_sync}), .q_o(scl_buf));

arv_ipdff #(.WIDTH(2), .RST_VAL(2'b11), .ARST_EN(ARST_EN)) u_sda_buf (
                   .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i({sda_buf[0], sda_sync}), .q_o(sda_buf));

wire       scl_lvl = (scl_sync & scl_buf[0]) | (scl_sync & scl_buf[1]) | (scl_buf[0] & scl_buf[1]);
wire       sda_lvl = (sda_sync & sda_buf[0]) | (sda_sync & sda_buf[1]) | (sda_buf[0] & sda_buf[1]);


// Delayed filtered levels, for edge detection.
wire scl_dly, sda_dly;

arv_ipdff #(.WIDTH(1), .RST_VAL(1'b1), .ARST_EN(ARST_EN)) u_scl_dly (
                  .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(scl_lvl), .q_o(scl_dly));

arv_ipdff #(.WIDTH(1), .RST_VAL(1'b1), .ARST_EN(ARST_EN)) u_sda_dly (
                  .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(sda_lvl), .q_o(sda_dly));

wire scl_rise   = ~scl_dly &  scl_lvl;
wire scl_fall   =  scl_dly & ~scl_lvl;

// Startup settle. scl_dly/sda_dly reset HIGH (idle-bus assumption), but if the DUT
// comes out of reset onto a bus that is mid-transaction (SDA already low, SCL high),
// the first sda_lvl 1->0 as the synchroniser/majority pipeline captures the real
// level looks EXACTLY like a START
wire [2:0] settle_cnt;
wire       bus_primed     = &settle_cnt;             // 7 clk after reset release (> pipeline depth)
wire [2:0] settle_cnt_nxt = bus_primed ? settle_cnt : settle_cnt + 3'd1;

arv_ipdff #(.WIDTH(3), .RST_VAL(3'd0), .ARST_EN(ARST_EN)) u_settle (
                 .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(settle_cnt_nxt), .q_o(settle_cnt));

// SCL must be observed high for TWO consecutive cycles (scl_lvl & scl_dly), not just the
// same cycle as the SDA edge. SCL and SDA travel independent 4-deep pipelines whose
// metastability aperture can delay one and not the other, always late -- so a same-cycle
// qualifier leaves the guaranteed separation at floor(tSU;DAT/T_clk) - 1, i.e. exactly
// one cycle of margin at the declared f_clk >= 40 x f_SCL floor. Requiring the extra
// cycle costs nothing: SCL is high for >= 20 cycles at a real START/STOP.
wire start_cond =  bus_primed & scl_lvl & scl_dly &  sda_dly & ~sda_lvl;  // SDA falls, SCL high
wire stop_cond  =  bus_primed & scl_lvl & scl_dly & ~sda_dly &  sda_lvl;  // SDA rises, SCL high

// (2) Delayed mid-high SDA sample point (openMSP430 scl_re_dly / scl_sample):
// sample incoming SDA ~2 cycles INTO the SCL-high window instead of right at the
// rising edge, buying margin against SCL/SDA synchroniser skew and slow line
// settling. Data-receiving states shift on scl_sample; scl_rise/scl_fall stay
// the FSM's clock-edge bookkeeping.
wire [1:0] scl_re_dly;

arv_ipdff #(.WIDTH(2), .RST_VAL(2'b00), .ARST_EN(ARST_EN)) u_scl_re_dly (
                      .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i({scl_re_dly[0], scl_rise}), .q_o(scl_re_dly));

wire scl_sample = scl_re_dly[1];


//=============================================================================
// Byte interface to arv_dtm_cmd
//=============================================================================

wire [7:0] tx_data;     // cmd -> PHY (response bytes)
wire       tx_valid;
wire       tx_ready_r;

wire [7:0] rx_data_r;   // PHY -> cmd (request bytes)
wire       rx_valid_r;


//=============================================================================
// I2C target FSM
//=============================================================================
localparam   [2:0] ST_IDLE      = 3'd0,
                   ST_ADDR      = 3'd1,   // receive address byte (7 addr + R/W)
                   ST_ADDR_ACK  = 3'd2,
                   ST_WRITE     = 3'd3,   // receive a data byte (-> cmd)
                   ST_WRITE_ACK = 3'd4,
                   ST_READ_LOAD = 3'd5,   // stretch SCL, pull a byte from cmd
                   ST_READ      = 3'd6,   // transmit a data byte (<- cmd)
                   ST_READ_ACK  = 3'd7;

// Read-side bus watchdog (2^WD_BITS clk_i with no SCL edge -> release the bus). It
// must exceed the longest legitimate clock-stretch yet fire before a host gives up,
// so it also sets the MAXIMUM TOLERATED DMI LATENCY: a slower DMI op is aborted as a
// wedged bus (~1.3 ms at 50 MHz with the default). A parameter so an integrator can
// match it to their DM.

wire         [2:0] state;
wire         [2:0] bit_cnt;
wire         [7:0] shft;
wire               rw;          // 0 = master writes, 1 = master reads
wire               matched;
wire               ack_ph;      // ACK sub-phase
wire               sda_pd;
wire               scl_pd;
wire [WD_BITS-1:0] wd_cnt;      // read-side bus watchdog counter

reg          [2:0] state_nxt;
reg          [2:0] bit_cnt_nxt;
reg          [7:0] shft_nxt;
reg                rw_nxt;
reg                matched_nxt;
reg                ack_ph_nxt;
reg                sda_pd_nxt;
reg                scl_pd_nxt;
reg          [7:0] rx_data_nxt;
reg                rx_valid_nxt;
reg                tx_ready_nxt;

// START and STOP are treated ASYMMETRICALLY across the read phase; the asymmetry is
// load-bearing, and the reasoning is in doc/arv_dtm_i2c.md (Bus robustness).
//   STOP  masked throughout -- an SDA rise is indistinguishable from the target
//         releasing a 1 bit, or the master releasing its ACK.
//   START honoured -- else an abandoned read parks the PHY, which then drives SDA
//         and stretches SCL into the NEXT frame on a shared bus. The watchdog does
//         not save that case: foreign SCL edges keep clearing it.
wire               read_phase  = (state == ST_READ) | (state == ST_READ_ACK) | (state == ST_READ_LOAD);
wire               bus_listen  = ~read_phase;

// A START is an SDA FALL, so it is only decodable where the TARGET owns SDA.
// ST_READ/ST_READ_LOAD: guard our own sda_pd change (defence in depth: the
// stretch-release handoff moves SCL only after the guard has expired). ST_READ_ACK: the MASTER drives SDA
// there, so a pull-down-keyed guard is blind to it -- use an SCL-high dwell instead.
localparam   [3:0] SDA_GUARD_LEN = 4'd8;

wire               sda_pd_d;

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_sda_pd_d (
                     .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(sda_pd),  .q_o(sda_pd_d));

// Data-setup count for the stretch-release handoff (ST_READ_LOAD).
wire         [3:0] su_cnt;
wire               su_load    = (state == ST_READ_LOAD) & ~ack_ph & tx_valid & ~scl_lvl & scl_pd;
wire         [3:0] su_cnt_nxt = su_load       ? SDA_GUARD_LEN :
                                (|su_cnt)     ? su_cnt - 4'd1 : 4'd0;

arv_ipdff #(.WIDTH(4), .ARST_EN(ARST_EN)) u_su_cnt (
                     .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(su_cnt_nxt), .q_o(su_cnt));

wire         [3:0] sda_guard;
wire         [3:0] sda_guard_nxt = (sda_pd ^ sda_pd_d) ? SDA_GUARD_LEN    :
                                   (|sda_guard)        ? sda_guard - 4'd1 : 4'd0;

arv_ipdff #(.WIDTH(4), .ARST_EN(ARST_EN)) u_sda_guard (
                     .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(sda_guard_nxt), .q_o(sda_guard));

// ST_READ_ACK qualifier: SCL continuously high. Structurally dead in live operation
// (scl_sample leaves the state ~12 clk before the dwell threshold), so it is reachable
// only with the FSM parked. Below the declared clock floor it reverts to masking.
wire         [3:0] scl_hi_cnt;
wire         [3:0] scl_hi_nxt = ~scl_lvl      ? 4'd0       :
                                (&scl_hi_cnt) ? scl_hi_cnt : scl_hi_cnt + 4'd1;

arv_ipdff #(.WIDTH(4), .ARST_EN(ARST_EN)) u_scl_hi (
                     .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(scl_hi_nxt), .q_o(scl_hi_cnt));

wire               scl_hi_settled = &scl_hi_cnt;          // SCL high for >= 15 clk

wire               start_listen = bus_listen |
                                  (~(|sda_guard) & ((state != ST_READ_ACK) | scl_hi_settled));

// Read-side bus watchdog: the read states can hold SCL or SDA low indefinitely on a
// host fault, wedging a shared bus. On expiry force ST_IDLE and release both
// pull-downs. Any SCL edge clears it, so it only fires when the master has gone.
// Arm wherever the TARGET is holding a line down, not just in the read phase: the
// ADDR/WRITE ACK states assert sda_pd on scl_fall and release it on the NEXT scl_fall,
// so a master that stops clocking mid-ACK leaves SDA low forever -- and the PHY itself
// then prevents the STOP that would free it. Any SCL edge still clears the counter, so
// this never fires while a master is actually clocking.
wire               wd_active   =   read_phase | sda_pd | scl_pd;
wire               wd_clr      =  ~wd_active | scl_rise | scl_fall;
wire               wd_expired  =   wd_active & (&wd_cnt);
wire [WD_BITS-1:0] wd_cnt_nxt  =   wd_clr    ? {WD_BITS{1'b0}} :
                                 (&wd_cnt)   ? wd_cnt          :   // saturate at max
                                               wd_cnt + 1'b1   ;

// Frame resync to arv_dtm_cmd. A (repeated) START or STOP delimits an I2C frame;
// while listening it snaps a mid-request interpreter back to SYNC. The watchdog
// trip is a hard abort (an abandoned read leaves cmd mid-response).
wire               frame_boundary = (start_cond & start_listen) | (stop_cond & bus_listen);

// STOP only: a repeated START legitimately separates a request from its response, but
// a STOP during a response means the host abandoned the read.
wire               frame_stop     = stop_cond & bus_listen;

always @(*) begin
    state_nxt    = state;
    bit_cnt_nxt  = bit_cnt;
    shft_nxt     = shft;
    rw_nxt       = rw;
    matched_nxt  = matched;
    ack_ph_nxt   = ack_ph;
    sda_pd_nxt   = sda_pd;
    scl_pd_nxt   = scl_pd;
    rx_data_nxt  = rx_data_r;
    rx_valid_nxt = 1'b0;                          // 1-cycle strobes by default
    tx_ready_nxt = 1'b0;

    if (wd_expired) begin                         // read-side watchdog: release bus, recover
        state_nxt   = ST_IDLE;
        bit_cnt_nxt = 3'd0;
        ack_ph_nxt  = 1'b0;
        sda_pd_nxt  = 1'b0;
        scl_pd_nxt  = 1'b0;
    end else if (start_cond && start_listen) begin // (repeated) START: (re)address
        state_nxt   = ST_ADDR;
        bit_cnt_nxt = 3'd0;
        ack_ph_nxt  = 1'b0;
        sda_pd_nxt  = 1'b0;
        scl_pd_nxt  = 1'b0;
    end else if (stop_cond && bus_listen) begin   // STOP: release the bus
        state_nxt  = ST_IDLE;
        sda_pd_nxt = 1'b0;
        scl_pd_nxt = 1'b0;
    end else begin
        case (state)
            //---------------------------------------------------------
            ST_IDLE : sda_pd_nxt = 1'b0;

            //---------------------------------------------------------
            ST_ADDR : if (scl_sample) begin
                shft_nxt = {shft[6:0], sda_lvl};
                if (bit_cnt == 3'd7) begin bit_cnt_nxt = 3'd0; ack_ph_nxt = 1'b0; state_nxt = ST_ADDR_ACK; end
                else                       bit_cnt_nxt = bit_cnt + 3'd1;
            end

            ST_ADDR_ACK : if (scl_fall) begin
                if (!ack_ph) begin
                    matched_nxt = (shft[7:1] == i2c_addr_i);
                    rw_nxt      =  shft[0];
                    sda_pd_nxt  = (shft[7:1] == i2c_addr_i);  // ACK (low) if addressed
                    ack_ph_nxt  = 1'b1;
                end else begin
                    sda_pd_nxt  = 1'b0;                       // release ACK
                    ack_ph_nxt  = 1'b0;
                    bit_cnt_nxt = 3'd0;
                    shft_nxt    = 8'd0;
                    if (matched) state_nxt = rw ? ST_READ_LOAD : ST_WRITE;
                    else         state_nxt = ST_IDLE;
                end
            end

            //---------------------------------------------------------
            ST_WRITE : if (scl_sample) begin
                shft_nxt = {shft[6:0], sda_lvl};
                if (bit_cnt == 3'd7) begin bit_cnt_nxt = 3'd0; ack_ph_nxt = 1'b0; state_nxt = ST_WRITE_ACK; end
                else                       bit_cnt_nxt = bit_cnt + 3'd1;
            end

            ST_WRITE_ACK : if (scl_fall) begin
                if (!ack_ph) begin
                    sda_pd_nxt   = 1'b1;          // ACK the data byte
                    rx_data_nxt  = shft;          // forward byte to arv_dtm_cmd
                    rx_valid_nxt = 1'b1;
                    ack_ph_nxt   = 1'b1;
                end else begin
                    sda_pd_nxt  = 1'b0;
                    ack_ph_nxt  = 1'b0;
                    bit_cnt_nxt = 3'd0;
                    shft_nxt    = 8'd0;
                    state_nxt   = ST_WRITE;       // next byte
                end
            end

            //---------------------------------------------------------
            // Stretch SCL until cmd produces the next response byte.
            // CRITICAL: only ever pull SCL low while it is ALREADY low. Pulling
            // it low while high would create a self-induced falling edge that
            // our own detector would mistake for a data-shift clock; and we only
            // hand off to ST_READ from the low phase, so the first edge there is
            // the master's rising (sample) edge -- never a leftover fall.
            //
            // When the byte arrives while SCL is being stretched, two steps: present
            // the MSB with SCL still held (ack_ph marks the byte as loaded), then
            // release SCL after SDA_GUARD_LEN cycles (su_cnt), so the master sees the
            // full data setup and no device on the bus sees SDA move with SCL high.
            // The count does not depend on the data value. A byte that is ready
            // before the stretch engages goes out at once: the master times the rise.
            ST_READ_LOAD : begin
                if (!scl_lvl) scl_pd_nxt = 1'b1;         // hold the clock low
                if (!ack_ph) begin
                    if (tx_valid && !scl_lvl) begin
                        shft_nxt     =  tx_data;
                        sda_pd_nxt   = ~tx_data[7];      // present MSB while SCL low
                        tx_ready_nxt = 1'b1;             // consume the byte from cmd
                        bit_cnt_nxt  = 3'd0;
                        if (scl_pd) ack_ph_nxt = 1'b1;   // stretching: release after su_cnt
                        else begin                       // not holding SCL: the master times the rise
                            scl_pd_nxt = 1'b0;
                            state_nxt  = ST_READ;
                        end
                    end
                end else if (su_cnt == 4'd0) begin
                    scl_pd_nxt   = 1'b0;                 // release the clock
                    ack_ph_nxt   = 1'b0;
                    state_nxt    = ST_READ;
                end
            end

            ST_READ : begin
                if (scl_fall) begin               // change SDA while SCL low
                    shft_nxt   = {shft[6:0], 1'b0};
                    sda_pd_nxt = ~shft[6];        // next MSB
                end
                if (scl_rise) begin               // master samples this bit
                    if (bit_cnt == 3'd7) begin ack_ph_nxt  = 1'b0; state_nxt = ST_READ_ACK; end
                    else                       bit_cnt_nxt = bit_cnt + 3'd1;
                end
            end

            default /*ST_READ_ACK*/ : begin
                if (scl_fall && !ack_ph) begin
                    sda_pd_nxt = 1'b0;            // release SDA for master's ACK/NACK
                    ack_ph_nxt = 1'b1;
                end
                if (scl_sample && ack_ph) begin
                    if (!sda_lvl)  state_nxt = ST_READ_LOAD;  // ACK -> another byte
                    else           state_nxt = ST_IDLE;       // NACK -> done
                    ack_ph_nxt  = 1'b0;
                    bit_cnt_nxt = 3'd0;
                end
            end

        endcase
    end
end

//=============================================================================
// I2C target state registers (arv_ipdff: build-time async/sync reset)
//=============================================================================

arv_ipdff #(.WIDTH(3), .RST_VAL(ST_IDLE), .ARST_EN(ARST_EN)) u_state (
                     .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(state_nxt),    .q_o(state));

arv_ipdff #(.WIDTH(3),                    .ARST_EN(ARST_EN)) u_bit_cnt (
                     .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(bit_cnt_nxt),  .q_o(bit_cnt));

arv_ipdff #(.WIDTH(8),                    .ARST_EN(ARST_EN)) u_shft (
                     .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(shft_nxt),     .q_o(shft));

arv_ipdff #(.WIDTH(1),                    .ARST_EN(ARST_EN)) u_rw (
                     .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(rw_nxt),       .q_o(rw));

arv_ipdff #(.WIDTH(1),                    .ARST_EN(ARST_EN)) u_matched (
                     .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(matched_nxt),  .q_o(matched));

arv_ipdff #(.WIDTH(1),                    .ARST_EN(ARST_EN)) u_ack_ph (
                     .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(ack_ph_nxt),   .q_o(ack_ph));

arv_ipdff #(.WIDTH(1),                    .ARST_EN(ARST_EN)) u_sda_pd (
                     .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(sda_pd_nxt),   .q_o(sda_pd));

arv_ipdff #(.WIDTH(1),                   .ARST_EN(ARST_EN)) u_scl_pd (
                     .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(scl_pd_nxt),   .q_o(scl_pd));

arv_ipdff #(.WIDTH(8),                    .ARST_EN(ARST_EN)) u_rx_data (
                     .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(rx_data_nxt),  .q_o(rx_data_r));

arv_ipdff #(.WIDTH(1),                    .ARST_EN(ARST_EN)) u_rx_valid (
                     .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(rx_valid_nxt), .q_o(rx_valid_r));

arv_ipdff #(.WIDTH(1),                   .ARST_EN(ARST_EN)) u_tx_ready (
                     .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(tx_ready_nxt), .q_o(tx_ready_r));

arv_ipdff #(.WIDTH(WD_BITS),             .ARST_EN(ARST_EN)) u_wd_cnt (
                     .clk_i(clk_i), .rst_n_i(dbgresetn_i), .en_i(1'b1), .d_i(wd_cnt_nxt),   .q_o(wd_cnt));

assign sda_pd_o = sda_pd;
assign scl_pd_o = scl_pd;

//=============================================================================
// DMI command interpreter + DMI master
//=============================================================================
// DMI address width. Fixed at the arvern core's value; not a knob.
localparam           DMI_ABITS = 7;

// RX byte-FIFO depth: a handoff buffer only, hence a localparam (UART exposes it as
// the pipelining window; I2C cannot pipeline -- the repeated START between a request
// and its response flushes the FIFO). The write phase always ACKs and never stretches,
// so the FIFO must hold one whole 7-byte request: 8. Kept small deliberately: on ASIC
// the FIFO is a flop bank.
localparam           RX_FIFO_DEPTH = 8;

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
    .rx_data_i        ( rx_data_r          ),
    .rx_valid_i       ( rx_valid_r         ),
    .frame_boundary_i ( frame_boundary     ),
    .frame_stop_i     ( frame_stop         ),
    .rx_error_i       ( 1'b0               ),   // every byte is ACKed or the frame is delimited
    .abort_i          ( wd_expired         ),
    .tx_data_o        ( tx_data            ),
    .tx_valid_o       ( tx_valid           ),
    .tx_ready_i       ( tx_ready_r         ),
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
    if (WD_BITS < 1) begin : CHECK_WD_BITS
        initial $fatal(1, "arv_dtm_i2c: WD_BITS (%0d) must be at least 1.", WD_BITS);
    end
endgenerate
// pragma translate_on

endmodule // arv_dtm_i2c

`default_nettype wire
