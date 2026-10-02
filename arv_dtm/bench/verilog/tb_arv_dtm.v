//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tb_arv_dtm
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tb_arv_dtm.v
// Module Description : UNIFIED standalone testbench for every arv_dtm transport.
//
//   One shell drives every DTM. The transport is selected at compile time by a
//   +define+ (set by the runsim -dtm flag) resolving to DTM_SEL, which is passed
//   straight to the SHIPPING arv_dtm wrapper's DTM_TYPE parameter:
//       +define+DTM_JTAG  (default) -> 0 -> arv_dtm_jtag
//       +define+DTM_UART            -> 1 -> arv_dtm_uart
//       +define+DTM_I2C             -> 2 -> arv_dtm_i2c
//       +define+DTM_CJTAG           -> 3 -> arv_dtm_cjtag
//
//   Shared by every transport: the DMI-bus wires, the behavioral DMI slave
//   (dmi_slave_model.v), bookkeeping, the end-of-test report, and the waveform
//   dump. Transport-specific pieces (extra clocks/pins, host bit period, host
//   task library) are `ifdef-guarded. The host task library exposes a common
//   transport-neutral API (dtm_dmi_write/read/hardreset, dtm_init, dtm_settle)
//   in dtm_tasks.v, so a generic stimulus runs over any DTM; transport-specific
//   stimuli call the underlying JTAG/UART/I2C tasks directly.
//
//   CDC stress: for JTAG, TCK and the always-on oscillator run at a NON-INTEGER
//   period ratio with a randomized (seeded) TCK start phase; for the serial
//   transports the host bit period is set a hair off nominal per seed -- so a
//   CDC/sampling path that only works at a convenient alignment is exposed.
//----------------------------------------------------------------------------

`include "timescale.v"

module tb_arv_dtm;

//=============================================================================
// Transport selection (from +define+, set by runsim -dtm)
//=============================================================================
`ifdef DTM_UART
    localparam [1:0] DTM_SEL = 2'd1;
`elsif DTM_I2C
    localparam [1:0] DTM_SEL = 2'd2;
`elsif DTM_CJTAG
    localparam [1:0] DTM_SEL = 2'd3;
`else
    localparam [1:0] DTM_SEL = 2'd0;                  // JTAG (default)
`endif

//=============================================================================
// DMI constants (spec values, NOT taken from the RTL)
//=============================================================================
// Reset style under test. Default async; -sync_rst builds the SYNCHRONOUS variant.
// Both are regression modes: a fix holding for only one reset style fails the other.
`ifdef SYNC_RST
localparam        DUT_ARST_EN = 1'b0;
`else
localparam        DUT_ARST_EN = 1'b1;
`endif
localparam        ABITS      = 7;
// IDCODE is a DUT parameter read back through the IDCODE DR. The default value
// has 23 leading zeros, so the upper shift-register positions only ever carry
// zeros and never toggle. IDCODE_ALT elaborates a dense alternating value
// instead, proving every bit of the DR is wired and carries data.
// Bit 0 must stay 1 in either case (IEEE 1149.1).
`ifdef IDCODE_ALT
localparam [31:0] DUT_IDCODE = 32'hAAAA_AAAB;
`else
localparam [31:0] DUT_IDCODE = 32'h0000_01F7;         // must match the JTAG DUT param
`endif
// [31:28] arrives on a port (ECO-strapped), [27:0] is the IDCODE_BASE parameter, so
// split DUT_IDCODE here and let the tests keep checking the whole word.
localparam  [3:0] DUT_IDVER   = DUT_IDCODE[31:28];   // -> idcode_version_i port
localparam [27:0] DUT_IDBASE  = DUT_IDCODE[27:0];    // -> IDCODE_BASE parameter
localparam [2:0]  DUT_IDLE   = 3'd3;                  // dtmcs.idle hint
localparam        DMI_DR_W   = ABITS + 34;            // 41 bits at ABITS=7 (JTAG DMI DR)

// IR opcodes (5-bit, JTAG)
localparam [4:0] IR_IDCODE = 5'h01,
                 IR_DTMCS  = 5'h10,
                 IR_DMI    = 5'h11,
                 IR_BYPASS = 5'h1f;

// DMI op / status encodings
localparam [1:0] OP_NOP     = 2'd0,
                 OP_READ    = 2'd1,
                 OP_WRITE   = 2'd2,
                 OP_HRST    = 2'd3;
localparam [1:0] OP_SUCCESS = 2'd0,
                 OP_FAILED  = 2'd2,
                 OP_BUSY    = 2'd3;

// JTAG default settle-idle count used by the common dtm_dmi_* API.
localparam integer DTM_IDLE_N = 16;

// UART host baud, expressed as clk cycles per bit. Bench-side only: the DTM has no
// configured baud -- it auto-measures whatever the host drives -- so this just sets
// how fast the host BFM talks (BIT_NS below), not any DUT parameter.
localparam        HOST_CLKS_PER_BIT = 16;
localparam [6:0]  I2C_ADDR     = 7'h30;

// Clock periods (ns). Non-integer TCK:free ratio 31/10 = 3.1 for the JTAG CDC.
localparam real   FREE_HALF = 5.0;                    // 100 MHz always-on oscillator
localparam real   TCK_HALF  = 15.5;                   // ~32.26 MHz TCK

// I2C master bit timing (ns), slow vs clk so the 2-FF sync has ample margin.
// I2C bit timing. VARIABLES, not localparams, so a test can tighten the data setup and
// exercise the START/STOP detector's margin against clk_i (see i2c_setup_margin).
// Defaults: 200 ns half-periods = 20 clk at 100 MHz, i.e. exactly the documented
// f_clk >= 40 x f_SCL floor; 50 ns setup = 5 clk, comfortably outside the danger window.
// T_SU is the DATA setup (tSU;DAT) before a clock; T_SU_STA is the setup used to build a
// START/STOP (tSU;STA / tSU;STO). They are different I2C parameters and only the former
// is what the START/STOP detector's margin is measured against -- conflating them makes
// a margin test shrink the legitimate START it needs.
real T_HIGH, T_LOW, T_SU, T_SU_STA;
initial begin
    T_HIGH   = 200.0;
    T_LOW    = 200.0;
    T_SU     =  50.0;
    T_SU_STA = 200.0;
end

// Watchdog scaled per transport (serial links are much slower than JTAG).
// SLOW_BAUD stretches the UART watchdog: a legal-but-slow host baud costs
// 10 x div clocks per byte, so a divisor near AB_DIV_CEIL needs far longer than
// the normal UART budget. Only the slow-baud test defines it.
`ifdef SLOW_BAUD
localparam real   WATCHDOG_NS = 60000000.0;                   // UART, slow host baud
`else
localparam real   WATCHDOG_NS = (DTM_SEL == 1) ? 5000000.0 :   // UART
                                (DTM_SEL == 2) ? 10000000.0 :  // I2C
                                (DTM_SEL == 3) ? 40000000.0 :  // cJTAG (3 oversampled phases/bit)
                                                 2000000.0;    // JTAG
`endif

`ifdef SEED
localparam integer SEEDV = `SEED;
`else
localparam integer SEEDV = 32'h1234_5678;
`endif

//=============================================================================
// Clocks & resets (all present; TCK only matters for JTAG, unused otherwise)
//=============================================================================
reg free_clk;
reg tck;
reg clk_gate;
reg scan_mode;
initial scan_mode = 1'b0;
initial clk_gate = 1'b1;   // 0 = oscillator stopped (cold-attach tests)
reg dbgresetn;
reg trst_n;

integer seed_r;
integer tck_phase;

initial begin
    free_clk = 1'b0;
    // clk_gate lets a test STOP the always-on oscillator, so cold-attach behaviour
    // (dbg_wakeup_o) can be exercised for real rather than asserted.
    forever #(FREE_HALF) if (clk_gate) free_clk = ~free_clk;
end

initial begin
    seed_r    = SEEDV;
    tck_phase = {$random(seed_r)} % 16;               // randomized TCK start phase (0..15 ns)
    tck       = 1'b0;
    #(tck_phase);
    forever #(TCK_HALF) tck = ~tck;
end

// UART RX FIFO depth of the DUT; -D UART_FIFO_DEPTH=128 builds the FPGA's value.
`ifndef UART_FIFO_DEPTH
  `define UART_FIFO_DEPTH 32
`endif

`ifdef NO_TRST
// TRST NOT WIRED: 1149.1 makes it optional, and the aRVern FPGA board leaves it
// pulled high. The TAP must still come up usable and be reachable via TMS alone.
initial trst_n = 1'b1;
initial begin
    dbgresetn = 1'b0;
    repeat (6) @(posedge free_clk);
    #1 dbgresetn = 1'b1;
end
`else
initial begin
    dbgresetn = 1'b0;
    trst_n  = 1'b0;
    repeat (6) @(posedge free_clk);
    #1 dbgresetn = 1'b1;
    // Stagger trst_n after dbgresetn so a JTAG test waiting on the two posedges
    // sequentially sees both edges.
    repeat (2) @(posedge free_clk);
    #1 trst_n = 1'b1;
end
`endif

`ifdef ARV_COV_RESET_ZERO
// Coverage counts start once reset is applied: the Verilator coverage flow starts every
// flop at 1 so the asynchronous resets see an edge, and the reset driving them to 0 would
// otherwise count as a toggle of every bit.
initial begin
    @(posedge dbgresetn);
    $c("Verilated::threadContextp()->coveragep()->zero();");
end
`endif

//=============================================================================
// Union of PHY pins (all declared; the wrapper binds all, drives the active set)
//=============================================================================
// -- JTAG --
reg  tms;
reg  tdi;
wire tdo;
wire tdo_oe;
reg  tdo_sampled;

// -- UART --
reg  uart_rx;
wire uart_tx;

// host bit period (UART). Nominal +/- a small per-seed offset so the async RX
// path drifts within a byte. host_bit_ns is live: an auto-baud test retunes it.
localparam integer JIT = ((SEEDV % 5) + 5) % 5 - 2;   // -2..+2
real BIT_NS;
real host_bit_ns;

// -- I2C (open-drain wired-AND: master PD, DUT PD, pull-up) --
reg  m_scl_pd;
reg  m_sda_pd;
wire dbg_wakeup;
wire dut_scl_pd;
wire dut_sda_pd;
wire scl = (m_scl_pd | dut_scl_pd) ? 1'b0 : 1'b1;
wire sda = (m_sda_pd | dut_sda_pd) ? 1'b0 : 1'b1;

// -- cJTAG (2-wire; TMSC is bidirectional with a bus-keeper) --
// TCKC is host-driven. TMSC is driven by the host during the nTDI/TMS phases and
// by the DUT during the TDO phase; a keeper holds the last driven level in the
// brief turnaround windows (models the HW bus-keeper SEGGER requires). Simultaneous
// host and DUT driving at the same time is a framing bug -> flagged.
reg  tckc;
reg  host_tmsc;          // host (probe) TMSC drive value
reg  host_tmsc_oe;       // host drives TMSC (nTDI/TMS/activation/idle phases)
wire tmsc_dut;           // DUT TMSC drive value (arv_dtm_cjtag.tmsc_o)
wire tmsc_dut_oe;        // DUT drives TMSC (TDO phase, arv_dtm_cjtag.tmsc_oe_o)
reg  tmsc_keep;          // bus-keeper: last driven level
reg  cjtag_active_done;  // one-shot: activate the bridge on first tap_reset
wire tmsc = tmsc_dut_oe  ? tmsc_dut  :
            host_tmsc_oe ? host_tmsc : tmsc_keep;
always @(*) if (tmsc_dut_oe | host_tmsc_oe) tmsc_keep = tmsc;
// Any cycle with both drivers enabled is a violation, whether or not the values
// happen to agree: a matching value only hides the drive fight. Sampled on the
// falling edge: the host tasks and the TCKC-clocked DUT both update right after the
// rising edge, so a rising-edge sample would depend on the simulator's event order.
always @(negedge free_clk)
    if (tmsc_dut_oe & host_tmsc_oe) begin
        $display("ERROR: TMSC contention host=%b dut=%b  %0t ns", host_tmsc, tmsc_dut, $time);
        error = error + 1;
    end

initial begin
    tms         = 1'b1;
    tdi         = 1'b0;
    tdo_sampled = 1'b0;
    uart_rx     = 1'b1;                                // idle high
    m_scl_pd    = 1'b0;                                // I2C bus idle (released)
    m_sda_pd    = 1'b0;
    tckc        = 1'b0;                                // cJTAG clock idle low
    host_tmsc   = 1'b1;                                // TMSC idles high
    host_tmsc_oe = 1'b1;                               // host owns TMSC until a TDO phase
    tmsc_keep   = 1'b1;
    cjtag_active_done = 1'b0;
    BIT_NS      = (HOST_CLKS_PER_BIT * (FREE_HALF * 2.0)) + JIT;
    host_bit_ns = BIT_NS;
end

//=============================================================================
// DMI bus (DUT master <-> shared behavioral slave)
//=============================================================================
wire             dmi_psel;
wire             dmi_penable;
wire [ABITS+1:0] dmi_paddr;
wire             dmi_pwrite;
wire [31:0]      dmi_pwdata;
wire [2:0]       dmi_pprot;
wire             dmi_pready;
wire [31:0]      dmi_prdata;
wire             dmi_pslverr;

//=============================================================================
// DUT: the SHIPPING transport wrapper (arv_dtm)
//=============================================================================
// This is the same rtl/verilog/arv_dtm.v that goes into silicon -- the bench does
// NOT use a bench-only selector. DTM_TYPE picks the transport at elaboration from
// the +define+-derived DTM_SEL, so each build contains exactly one front-end, and
// the regression exercises the wrapper's own mux/idle logic rather than a copy of it.
arv_dtm #(
    .DTM_TYPE     (DTM_SEL),
    .IDCODE_BASE  (DUT_IDBASE),
    .IDLE_HINT    (DUT_IDLE),
    .I2C_ADDR     (I2C_ADDR),
    .ARST_EN      (DUT_ARST_EN),
    // Small break threshold for fast sim: above the longest legal locked low in any
    // UART test (a 0x00 at the slowest bench baud, 40 clk/bit => 360 clks) with margin.
`ifdef SLOW_BAUD
    // AB_DIV_CEIL = AB_BREAK_CLKS>>4, so the usual 700 caps the measurable bit
    // period at 43 clocks -- the whole slow half of the autobaud range is then
    // unreachable by construction. 65536 lifts the ceiling to 4096 clk/bit.
    .AB_BREAK_CLKS (32'd65536),
`else
    .AB_BREAK_CLKS (32'd700),
`endif
    // Modest RX request-FIFO depth for fast/clean overrun tests (flood 48 > 32).
    // uart_overrun / uart_break_overrun overflow this; dtmsts_reg asserts the DTMSTS
    // depth field == 32, validating the parameter is honored.
    .UART_RX_FIFO_DEPTH (`UART_FIFO_DEPTH)
) dut (
    .idcode_version_i (DUT_IDVER),
    .clk_i           (free_clk),
    .dbgresetn_i     (dbgresetn),
    .scan_mode_i     (scan_mode),            // held low except by dtm_scan_mode
    .dbg_wakeup_o    (dbg_wakeup),

    .tck_i           (tck),
    .trst_n_i        (trst_n),
    .tms_i           (tms),
    .tdi_i           (tdi),
    .tdo_o           (tdo),
    .tdo_oe_o        (tdo_oe),

    .tckc_i          (tckc),
    .tmsc_i          (tmsc),
    .tmsc_o          (tmsc_dut),
    .tmsc_oe_o       (tmsc_dut_oe),

    .uart_rx_i       (uart_rx),
    .uart_tx_o       (uart_tx),

    .scl_i           (scl),
    .sda_i           (sda),
    .scl_pd_o        (dut_scl_pd),
    .sda_pd_o        (dut_sda_pd),

    .dmi_psel_o      (dmi_psel),
    .dmi_penable_o   (dmi_penable),
    .dmi_paddr_o     (dmi_paddr),
    .dmi_pwrite_o    (dmi_pwrite),
    .dmi_pwdata_o    (dmi_pwdata),
    .dmi_pprot_o     (dmi_pprot),
    .dmi_pready_i    (dmi_pready),
    .dmi_prdata_i    (dmi_prdata),
    .dmi_pslverr_i   (dmi_pslverr)
);

//=============================================================================
// Shared behavioral DMI slave (stand-in for the arvern Debug Module)
//=============================================================================
`include "dmi_slave_model.v"

//----------------------------------------------------------------------------
// Pins of the transports the wrapper did NOT select must sit at their idle level
// on every cycle: UART TX high, I2C pull-downs released, TDO / TMSC not driven.
// Serial transports have no probe clock and tie dbg_wakeup_o low.
//----------------------------------------------------------------------------
wire idle_uart  = (uart_tx === 1'b1);
wire idle_i2c   = (dut_scl_pd === 1'b0) & (dut_sda_pd === 1'b0);
wire idle_jtag  = (tdo_oe === 1'b0);
wire idle_cjtag = (tmsc_dut_oe === 1'b0);
wire ties_ok =
`ifdef DTM_UART
               idle_i2c  & idle_jtag & idle_cjtag & (dbg_wakeup === 1'b0);
`elsif DTM_I2C
               idle_uart & idle_jtag & idle_cjtag & (dbg_wakeup === 1'b0);
`elsif DTM_CJTAG
               idle_uart & idle_i2c  & idle_jtag;
`else
               idle_uart & idle_i2c  & idle_cjtag;
`endif
always @(posedge free_clk)
   if ((dbgresetn === 1'b1) && !ties_ok) begin
      $display("ERROR: unselected transport pin not idle (uart_tx=%b scl_pd=%b sda_pd=%b tdo_oe=%b tmsc_oe=%b wakeup=%b)  %0t ns",
               uart_tx, dut_scl_pd, dut_sda_pd, tdo_oe, tmsc_dut_oe, dbg_wakeup, $time);
      error = error + 1;
   end

//----------------------------------------------------------------------------
// JTAG: tdo_oe checked against an independent IEEE 1149.1 TAP model driven by
// TCK / TMS / TRST_N only (reset released after two TCK edges). TDO is driven from the falling edge that follows the
// entry into Shift-DR / Shift-IR until the falling edge after leaving it.
//----------------------------------------------------------------------------
`ifndef DTM_UART
`ifndef DTM_I2C
`ifndef DTM_CJTAG
localparam [3:0] TM_TLR = 4'd0,  TM_RTI = 4'd1,  TM_SDS = 4'd2,  TM_CDR = 4'd3,
                 TM_SDR = 4'd4,  TM_E1D = 4'd5,  TM_PDR = 4'd6,  TM_E2D = 4'd7,
                 TM_UDR = 4'd8,  TM_SIS = 4'd9,  TM_CIR = 4'd10, TM_SIR = 4'd11,
                 TM_E1I = 4'd12, TM_PIR = 4'd13, TM_E2I = 4'd14, TM_UIR = 4'd15;
reg  [3:0] tm_state;
reg        tm_oe_exp;
wire       tm_rst_a = trst_n & dbgresetn;   // asserts asynchronously ...
reg  [1:0] tm_rst_sync;                    // ... and releases after two TCK edges, like the DUT
always @(posedge tck or negedge tm_rst_a)
   if (!tm_rst_a) tm_rst_sync <= 2'b00;
   else           tm_rst_sync <= {tm_rst_sync[0], 1'b1};
wire       tm_rst_n = tm_rst_sync[1];
always @(posedge tck or negedge tm_rst_n)
   if (!tm_rst_n) tm_state <= TM_TLR;
   else case (tm_state)
      TM_TLR: tm_state <= tms ? TM_TLR : TM_RTI;
      TM_RTI: tm_state <= tms ? TM_SDS : TM_RTI;
      TM_SDS: tm_state <= tms ? TM_SIS : TM_CDR;
      TM_CDR: tm_state <= tms ? TM_E1D : TM_SDR;
      TM_SDR: tm_state <= tms ? TM_E1D : TM_SDR;
      TM_E1D: tm_state <= tms ? TM_UDR : TM_PDR;
      TM_PDR: tm_state <= tms ? TM_E2D : TM_PDR;
      TM_E2D: tm_state <= tms ? TM_UDR : TM_SDR;
      TM_UDR: tm_state <= tms ? TM_SDS : TM_RTI;
      TM_SIS: tm_state <= tms ? TM_TLR : TM_CIR;
      TM_CIR: tm_state <= tms ? TM_E1I : TM_SIR;
      TM_SIR: tm_state <= tms ? TM_E1I : TM_SIR;
      TM_E1I: tm_state <= tms ? TM_UIR : TM_PIR;
      TM_PIR: tm_state <= tms ? TM_E2I : TM_PIR;
      TM_E2I: tm_state <= tms ? TM_UIR : TM_SIR;
      default: tm_state <= tms ? TM_SDS : TM_RTI;   // TM_UIR
   endcase
always @(negedge tck or negedge tm_rst_n)
   if (!tm_rst_n) tm_oe_exp <= 1'b0;
   else           tm_oe_exp <= (tm_state == TM_SDR) | (tm_state == TM_SIR);
always @(posedge tck)
   if (tm_rst_n && (tdo_oe !== tm_oe_exp)) begin
      $display("ERROR: tdo_oe %b, TAP model expects %b (state %0d)  %0t ns", tdo_oe, tm_oe_exp, tm_state, $time);
      error = error + 1;
   end
`endif
`endif
`endif

//----------------------------------------------------------------------------
// APB4 protocol monitor on the DMI port (the DUT is the manager). Sampled on the
// DMI clock edge (flop outputs, pre-update values):
//   PENABLE only with PSEL, and only after exactly one SETUP cycle;
//   SETUP is always followed by ACCESS; PADDR / PWRITE / PWDATA stable from SETUP
//   to completion; PPROT = 0;
//   PSEL held until PREADY -- except the cycle after a dmihardreset edge or while a
//   TAP-only reset clears the master, which abandon the transfer by design (accepted
//   deviation, doc/arv_dtm.md).
//----------------------------------------------------------------------------
`ifdef DTM_UART
  `define DMI_MST dut.g_uart.u_dtm.u_dmi_master
`elsif DTM_I2C
  `define DMI_MST dut.g_i2c.u_dtm.u_dmi_master
`elsif DTM_CJTAG
  `define DMI_MST dut.g_cjtag.u_dtm.u_tap.u_dmi_master
`else
  `define DMI_MST dut.g_jtag.u_dtm.u_tap.u_dmi_master
`endif
reg             apb_p_psel, apb_p_pen, apb_p_ready, apb_p_write, apb_p_hr;
wire            apb_mst_rstn = `DMI_MST.hclk_resetn_i;
reg [ABITS+1:0] apb_p_addr;
reg      [31:0] apb_p_wdata;
initial begin apb_p_psel = 1'b0; apb_p_pen = 1'b0; apb_p_ready = 1'b0; apb_p_hr = 1'b0; end
task apb_err;
   input [8*48-1:0] msg;
   begin
      $display("ERROR: APB4 %0s  %0t ns", msg, $time);
      error = error + 1;
   end
endtask
always @(posedge free_clk) begin
   if (dbgresetn === 1'b1) begin
      if (dmi_penable & ~dmi_psel)                                   apb_err("PENABLE without PSEL");
      if (dmi_penable & ~apb_p_pen & ~(apb_p_psel & ~apb_p_pen))     apb_err("ACCESS without a SETUP cycle");
      if (apb_p_psel & ~apb_p_pen & ~(dmi_psel & dmi_penable) & ~apb_p_hr & apb_mst_rstn)
                                                                     apb_err("SETUP not followed by ACCESS");
      if (apb_p_psel & ~(apb_p_pen & apb_p_ready) & dmi_psel &
          ((dmi_paddr !== apb_p_addr) | (dmi_pwrite !== apb_p_write) | (dmi_pwrite & (dmi_pwdata !== apb_p_wdata))))
                                                                     apb_err("address/control/data changed mid-transfer");
      if (apb_p_psel & apb_p_pen & ~apb_p_ready & ~dmi_psel & ~apb_p_hr & apb_mst_rstn)
                                                                     apb_err("PSEL dropped before PREADY");
      if (dmi_psel & (dmi_pprot !== 3'b000))                         apb_err("PPROT not 0");
   end
   apb_p_psel  <= dmi_psel;
   apb_p_pen   <= dmi_penable;
   apb_p_ready <= dmi_pready;
   apb_p_addr  <= dmi_paddr;
   apb_p_write <= dmi_pwrite;
   apb_p_wdata <= dmi_pwdata;
   apb_p_hr    <= `DMI_MST.hardreset_h_edge;
end

//=============================================================================
// Bookkeeping
//=============================================================================
integer error;
reg     stimulus_done;

initial begin
    error         = 0;
    stimulus_done = 1'b0;
end

//=============================================================================
// Host tasks (transport-specific + common dtm_* API) + per-test stimulus
//=============================================================================
// "First branch wins" fork idiom, portably. Icarus takes disable-of-a-sibling at its
// default -g2005; Verilator rejects it but accepts join_any + disable fork.
`ifdef VERILATOR
  `define FORK_KILL(blk)
  `define JOIN_FIRST join_any disable fork;
`else
  `define FORK_KILL(blk) disable blk;
  `define JOIN_FIRST join
`endif

`include "dtm_tasks.v"
`include "stimulus.v"

//=============================================================================
// End-of-test report + watchdog
//=============================================================================
initial begin
    wait (stimulus_done == 1'b1);
    repeat (20) @(posedge free_clk);
    $display("");
    if (error == 0) $display(" ====================  SIMULATION PASSED  ====================");
    else            $display(" ====================  SIMULATION FAILED (%0d errors) ========", error);
    $display("");
    $finish;
end

initial begin
    #(WATCHDOG_NS);
    $display(" ====================  SIMULATION FAILED (TIMEOUT) ====================");
    $finish;
end

`ifndef NODUMP
initial begin
    $dumpfile("tb_arv_dtm.vcd");
    $dumpvars(0, tb_arv_dtm);
end
`endif

endmodule
