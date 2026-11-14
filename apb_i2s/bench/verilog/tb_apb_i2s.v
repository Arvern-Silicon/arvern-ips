//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tb_apb_i2s
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tb_apb_i2s.v
// Module Description : Block-level testbench for the apb_i2s IP.
//                      Parameter-driven DUT instantiation; the sweep runner
//                      overrides the parameters with -D I2S_TB_<PARAM>=<v>
//                      (see bin/sim_configs.py). The selected stimulus file
//                      is `included into the module body as stimulus.v.
//
//  Clocking (doc "Clocks and sample rate"): pclk_i is free_clk through an
//  ICG latch enabled by pclk_en_o ONLY (plus tb_pclk_force, 0 by default),
//  and during reset, as the SoC reset generator requests every clock then.
//  pclk_en_o must be high while a transfer is in progress and while CTRL.EN
//  is set, or the transfer or the stream breaks here.
//
//  Device (i2s_dev.v): a monitor decodes i2s_sd_o into frames following the
//  configured format, a source drives i2s_sd_i after a round-trip delay, and
//  a clock checker measures every MCLK and BCLK half-period against the
//  dividers and checks edge alignment (doc "Clocks and sample rate", "Frame
//  format"). Tests describe the configuration with i2s_setup() so the device
//  and the DUT agree.
//
//  Always-on checks (after the first reset): pslverr_o low outside an ACCESS
//  cycle, prdata_o 0 outside a read ACCESS cycle, pready_o high, pclk_en_o
//  = psel_i | CTRL.EN | engine busy (running or its stop tail) | a transfer
//  ended on the last edge.
//----------------------------------------------------------------------------
`include "timescale.v"

`ifndef I2S_TB_TX_EN
 `define I2S_TB_TX_EN          1
`endif
`ifndef I2S_TB_RX_EN
 `define I2S_TB_RX_EN          1
`endif
`ifndef I2S_TB_TX_FIFO_AW
 `define I2S_TB_TX_FIFO_AW     5
`endif
`ifndef I2S_TB_RX_FIFO_AW
 `define I2S_TB_RX_FIFO_AW     5
`endif
`ifndef I2S_TB_ADDRW
 `define I2S_TB_ADDRW          7
`endif
`ifndef I2S_TB_MDELEG_RST
 `define I2S_TB_MDELEG_RST     271
`endif
`ifndef I2S_TB_DBG_MASK
 `define I2S_TB_DBG_MASK       8
`endif
`ifndef I2S_TB_ASYNC_RST_EN
 `define I2S_TB_ASYNC_RST_EN   1
`endif

module  tb_apb_i2s;

//
// DUT parameters
//------------------------------
localparam            TX_EN         = `I2S_TB_TX_EN;
localparam            RX_EN         = `I2S_TB_RX_EN;
localparam            TX_FIFO_AW    = `I2S_TB_TX_FIFO_AW;
localparam            RX_FIFO_AW    = `I2S_TB_RX_FIFO_AW;
localparam            ADDRW         = `I2S_TB_ADDRW;
localparam      [8:0] MDELEG_RST    = `I2S_TB_MDELEG_RST;
localparam      [3:0] DBG_MASK      = `I2S_TB_DBG_MASK;
localparam            ASYNC_RST_EN  = `I2S_TB_ASYNC_RST_EN;

// Derived constants
localparam            TX_DEPTH      = (TX_EN != 0) ? (1 << TX_FIFO_AW) : 0;
localparam            RX_DEPTH      = (RX_EN != 0) ? (1 << RX_FIFO_AW) : 0;
localparam     [31:0] INFO_VALUE    = {4'h1, 17'h0, (DBG_MASK != 4'h0), (RX_EN != 0), (TX_EN != 0),
                                       (RX_EN != 0) ? RX_FIFO_AW[3:0] : 4'h0, (TX_EN != 0) ? TX_FIFO_AW[3:0] : 4'h0};
localparam     [31:0] MDELEG_RST_WORD = {23'h0, MDELEG_RST[8], 4'h0, MDELEG_RST[3:0]};
localparam     [31:0] WIN_SIZE      = 32'h1 << ADDRW;
localparam real       PCLK_P        = 50.0;                                 // pclk period, ns

// Register map (doc "Register map")
localparam     [31:0] I2S_BASE      = 32'h00400000;
localparam     [31:0] R_INFO        = I2S_BASE + 32'h00;
localparam     [31:0] R_CTRL        = I2S_BASE + 32'h04;
localparam     [31:0] R_CLKDIV      = I2S_BASE + 32'h08;
localparam     [31:0] R_STATUS      = I2S_BASE + 32'h0C;
localparam     [31:0] R_THRESH      = I2S_BASE + 32'h10;
localparam     [31:0] R_IRQ_EN      = I2S_BASE + 32'h14;
localparam     [31:0] R_IRQ_PEND    = I2S_BASE + 32'h18;
localparam     [31:0] R_TXDATA      = I2S_BASE + 32'h1C;
localparam     [31:0] R_RXDATA      = I2S_BASE + 32'h20;
localparam     [31:0] R_CMD         = I2S_BASE + 32'h24;
localparam     [31:0] R_FORMAT      = I2S_BASE + 32'h28;
localparam     [31:0] R_MDELEG      = I2S_BASE + 32'h40;

// CTRL fields
localparam     [31:0] C_EN          = 32'h0001;
localparam     [31:0] C_TX_ON       = 32'h0002;
localparam     [31:0] C_RX_ON       = 32'h0004;
localparam     [31:0] C_MCLK_EN     = 32'h0008;
localparam     [31:0] C_TX_MONO     = 32'h0020;
localparam     [31:0] C_RX_MONO     = 32'h0040;
localparam     [31:0] C_RX_SEL_R    = 32'h0100;
localparam     [31:0] C_RX_SEL_AVG  = 32'h0200;
localparam     [31:0] C_LOOPBACK    = 32'h1000;
localparam     [31:0] C_DBG_POP     = 32'h2000;

// FORMAT presets {SLOT16, FSYNC, LRCK_INV, RJUST, DELAY, BCLK_INV}
localparam      [5:0] F_I2S         = 6'b000010;
localparam      [5:0] F_LJ          = 6'b001000;
localparam      [5:0] F_RJ          = 6'b001100;
localparam      [5:0] F_DSPA        = 6'b010010;
localparam      [5:0] F_DSPB        = 6'b010000;
localparam      [5:0] F_BCLK_INV    = 6'b000001;
localparam      [5:0] F_SLOT16      = 6'b100000;

// IRQ_PEND bits
localparam     [31:0] I_TX_LOW      = 32'h01;
localparam     [31:0] I_RX_HIGH     = 32'h02;
localparam     [31:0] I_TX_UNDER    = 32'h04;
localparam     [31:0] I_RX_OVER     = 32'h08;
localparam     [31:0] I_TX_OVF      = 32'h10;
localparam     [31:0] I_RX_UDF      = 32'h20;

//
// Wire & Register definition
//------------------------------

// Clock / Reset
reg                   presetn;
reg                   free_clk;
wire                  pclk;                 // bus clock (after the ICG)
wire                  pclk_en;
reg                   tb_pclk_force = 1'b0; // test-controlled: keep pclk running regardless of pclk_en_o
reg                   pclk_en_latch;        // bus-clock ICG latch

// APB Completer Interface
reg                   psel;
reg                   penable;
reg       [ADDRW-1:0] paddr;
reg                   pwrite;
reg            [31:0] pwdata;
reg             [3:0] pstrb;
reg             [2:0] pprot;
reg                   psmode;
reg             [3:0] pmaster;
wire           [31:0] prdata;
wire                  pready;
wire                  pslverr;

// Serial audio
wire                  i2s_mclk;
wire                  i2s_bclk;
wire                  i2s_lrck;
wire                  i2s_sd_o;
reg                   i2s_sd_dev;           // device data output (after the round trip)
wire                  irq;
wire                  tb_tx_half;           // mono transmit half pointer (0 without a transmit path)
wire                  tb_rx_half;           // mono receive held-sample flag (0 without a receive path)
wire                  tb_tx_drop;           // mono transmit: TX_ON cleared with a half pending (0 without a transmit path)

// Testbench variables
integer               tmp_seed;
integer               error = 0;
reg                   stimulus_done = 1'b0;
reg                   tb_rst_done = 1'b0;   // first reset completed
integer               free_cnt = 0;         // rising free_clk edges


//
// Include files
//------------------------------

// Verilog tasks, device model & stimulus
`include "apb_tasks.v"
`include "i2s_dev.v"
`include "stimulus.v"


//
// Generate Clock & Reset
//------------------------------

// Free running clock
initial
  begin
     free_clk  = 1'b0;
     forever
       begin
          #25;   // 20 MHz
          free_clk = ~free_clk;
       end
  end

// Bus clock: ICG latch transparent while the clock is low
always @(free_clk or pclk_en or tb_pclk_force or presetn)
  if (~free_clk)
    pclk_en_latch <= pclk_en | tb_pclk_force | ~presetn;
assign  pclk  =  (free_clk & pclk_en_latch);

// Reset generation
initial
  begin
     presetn       = 1'b1;
     #93;
     presetn       = 1'b0;
     #593;
     presetn       = 1'b1;
  end

initial
  begin
     tb_rst_done = 1'b0;
     wait (presetn === 1'b0);
     @(posedge presetn);
     tb_rst_done = 1'b1;
  end

always @(posedge free_clk)
  free_cnt = free_cnt + 1;

// Variables initialization
initial
  begin
     tmp_seed      = `SEED;
     tmp_seed      = $urandom(tmp_seed);
     error         = 0;
     stimulus_done = 0;
     tb_pclk_force = 0;
     free_cnt      = 0;

     psel    = 1'b0;
     penable = 1'b0;
     paddr   = {ADDRW{1'b0}};
     pwrite  = 1'b0;
     pwdata  = 32'h00000000;
     pstrb   = 4'h0;
     pprot   = 3'h0;
     psmode  = 1'b0;
     pmaster = 4'h0;
  end


//
// APB I2S INSTANCE
//----------------------------------
apb_i2s #(
    .TX_EN             ( TX_EN                  ),
    .RX_EN             ( RX_EN                  ),
    .TX_FIFO_AW        ( TX_FIFO_AW             ),
    .RX_FIFO_AW        ( RX_FIFO_AW             ),
    .ADDRW             ( ADDRW                  ),
    .MDELEG_RST        ( MDELEG_RST             ),
    .DBG_PMASTER_MASK  ( DBG_MASK               ),
    .ASYNC_RST_EN      ( ASYNC_RST_EN           )
) apb_i2s_inst0 (

// APB CLOCK & RESET
    .pclk_i            ( pclk                   ),
    .presetn_i         ( presetn                ),
    .pclk_en_o         ( pclk_en                ),

// APB INTERFACE
    .psel_i            ( psel                   ),
    .penable_i         ( penable                ),
    .paddr_i           ( paddr                  ),
    .pwrite_i          ( pwrite                 ),
    .pwdata_i          ( pwdata                 ),
    .pstrb_i           ( pstrb                  ),
    .pprot_i           ( pprot                  ),
    .psmode_i          ( psmode                 ),
    .pmaster_i         ( pmaster                ),
    .prdata_o          ( prdata                 ),
    .pready_o          ( pready                 ),
    .pslverr_o         ( pslverr                ),

// SERIAL AUDIO
    .i2s_mclk_o        ( i2s_mclk               ),
    .i2s_bclk_o        ( i2s_bclk               ),
    .i2s_lrck_o        ( i2s_lrck               ),
    .i2s_sd_o          ( i2s_sd_o               ),
    .i2s_sd_i          ( i2s_sd_dev             ),

// INTERRUPT
    .irq_o             ( irq                    )
);


generate
  if (TX_EN != 0) begin : g_tb_tx
    assign tb_tx_half = apb_i2s_inst0.g_tx.tx_half;
    assign tb_tx_drop = apb_i2s_inst0.g_tx.tx_drop;
  end else begin : g_tb_no_tx
    assign tb_tx_half = 1'b0;
    assign tb_tx_drop = 1'b0;
  end
  if (RX_EN != 0) begin : g_tb_rx
    assign tb_rx_half = apb_i2s_inst0.g_rx.rx_half;
  end else begin : g_tb_no_rx
    assign tb_rx_half = 1'b0;
  end
endgenerate


//
// Always-on checks
//----------------------------------

// PSLVERR only in an ACCESS cycle, PRDATA only in a read ACCESS cycle,
// PREADY always high, pclk_en_o = psel_i | CTRL.EN | STATUS.RUNNING | a
// transfer ended on the last edge (doc "Ports", "Clock request").
always @(negedge free_clk)
  if (tb_rst_done && (presetn === 1'b1))
    begin
       if (!(psel && penable) && (pslverr !== 1'b0))
         begin
            $display("ERROR: pslverr_o=%b outside an ACCESS cycle %t ns", pslverr, $time);
            error = error+1;
         end
       if (!(psel && penable && !pwrite) && (prdata !== 32'h0))
         begin
            $display("ERROR: prdata_o=0x%h outside a read ACCESS cycle %t ns", prdata, $time);
            error = error+1;
         end
       if (pready !== 1'b1)
         begin
            $display("ERROR: pready_o=%b %t ns", pready, $time);
            error = error+1;
         end
       if (pclk_en !== (psel | m_en | ck_busy | ck_xfer_q))
         begin
            $display("ERROR: pclk_en_o=%b, expected %b (PSEL %b, EN %b, running %b, transfer %b) %t ns", pclk_en,
                     psel | m_en | ck_busy | ck_xfer_q, psel, m_en, ck_busy, ck_xfer_q, $time);
            error = error+1;
         end
    end


//
// Functional coverage: one flag per bin, reported at the end
//----------------------------------
reg cv_write = 0, cv_read = 0, cv_b2b = 0, cv_pslverr = 0, cv_strb_part = 0, cv_idle_noise = 0;
reg cv_silent_drop = 0, cv_s_admitted = 0, cv_u_admitted = 0, cv_pclk_off = 0, cv_reset_busy = 0;
reg cv_fmt_i2s = 0, cv_fmt_lj = 0, cv_fmt_rj = 0, cv_fmt_dspa = 0, cv_fmt_dspb = 0, cv_bclk_inv = 0, cv_slot16 = 0;
reg [4:0] cv_ratio = 0;
reg cv_mdiv_big = 0, cv_mclk_off = 0, cv_tx_mono = 0, cv_rx_left = 0, cv_rx_right = 0, cv_rx_avg = 0;
reg cv_tx_under = 0, cv_rx_over = 0, cv_tx_ovf = 0, cv_rx_udf = 0, cv_tx_low = 0, cv_rx_high = 0;
reg cv_dbg_peek = 0, cv_dbg_pop = 0, cv_loopback = 0, cv_tx_flush = 0, cv_rx_flush = 0;
reg cv_tx_full = 0, cv_rx_full = 0, cv_cfg_locked = 0, cv_w1c_race = 0, cv_irq = 0;
reg cv_stop_dly = 0, cv_tail_cap = 0, cv_drop_at_take = 0;
reg cv_prev_access = 0;
wire [5:0] cv_fmt = apb_i2s_inst0.fmt;
always @(posedge free_clk)
  begin
     if (tb_rst_done && (presetn === 1'b1))
       begin
          if (psel && penable &&  pwrite) cv_write = 1;
          if (psel && penable && !pwrite) cv_read  = 1;
          if (psel && !penable && cv_prev_access) cv_b2b = 1;
          if (psel && penable && pslverr) cv_pslverr = 1;
          if (psel && penable && pwrite && (pstrb != 4'hF) && (pstrb != 4'h0)) cv_strb_part = 1;
          if (!psel && penable) cv_idle_noise = 1;
          if (psel && penable && !apb_i2s_inst0.acc_allowed && !pslverr) cv_silent_drop = 1;
          if (psel && penable && apb_i2s_inst0.acc_allowed && pprot[0] && psmode) cv_s_admitted = 1;
          if (psel && penable && apb_i2s_inst0.acc_allowed && !pprot[0]) cv_u_admitted = 1;
          if (pclk_en === 1'b0) cv_pclk_off = 1;
          if (ck_run && dev_frames > 1)
            begin
               if ((cv_fmt & 6'b011110) == F_I2S)  cv_fmt_i2s  = 1;
               if ((cv_fmt & 6'b011110) == F_LJ)   cv_fmt_lj   = 1;
               if ((cv_fmt & 6'b011110) == F_RJ)   cv_fmt_rj   = 1;
               if ((cv_fmt & 6'b011110) == F_DSPA) cv_fmt_dspa = 1;
               if ((cv_fmt & 6'b011110) == F_DSPB) cv_fmt_dspb = 1;
               if (cv_fmt[0]) cv_bclk_inv = 1;
               if (cv_fmt[5]) cv_slot16   = 1;
               cv_ratio[apb_i2s_inst0.clk_ratio] = 1;
               if (apb_i2s_inst0.clk_mdiv != 8'd0) cv_mdiv_big = 1;
               if (!apb_i2s_inst0.ctrl_mclk_en) cv_mclk_off = 1;
               if (apb_i2s_inst0.ctrl_loop && apb_i2s_inst0.ctrl_rx_on) cv_loopback = 1;
            end
          if (apb_i2s_inst0.ctrl_tx_mono && apb_i2s_inst0.tx_take) cv_tx_mono = 1;
          if (apb_i2s_inst0.ctrl_rx_mono && apb_i2s_inst0.rx_frame_v)
            begin
               if (apb_i2s_inst0.ctrl_rx_sel == 2'd0) cv_rx_left  = 1;
               if (apb_i2s_inst0.ctrl_rx_sel == 2'd1) cv_rx_right = 1;
               if (apb_i2s_inst0.ctrl_rx_sel == 2'd2) cv_rx_avg   = 1;
            end
          if (apb_i2s_inst0.tx_under) cv_tx_under = 1;
          if (apb_i2s_inst0.rx_over)  cv_rx_over  = 1;
          if (apb_i2s_inst0.tx_ovf)   cv_tx_ovf   = 1;
          if (apb_i2s_inst0.rx_udf)   cv_rx_udf   = 1;
          if (apb_i2s_inst0.irq_pend[0] && apb_i2s_inst0.irq_en[0] && irq) cv_tx_low  = 1;
          if (apb_i2s_inst0.irq_pend[1] && apb_i2s_inst0.irq_en[1] && irq) cv_rx_high = 1;
          if (irq && (apb_i2s_inst0.irq_pend[5:2] & apb_i2s_inst0.irq_en[5:2])) cv_irq = 1;
          if (psel && penable && !pwrite && apb_i2s_inst0.sel_rxdata && apb_i2s_inst0.acc_dbg &&
              apb_i2s_inst0.acc_allowed && !apb_i2s_inst0.ctrl_dbg_pop && (apb_i2s_inst0.rx_level != 0)) cv_dbg_peek = 1;
          if (psel && penable && !pwrite && apb_i2s_inst0.sel_rxdata && apb_i2s_inst0.acc_dbg &&
              apb_i2s_inst0.acc_allowed &&  apb_i2s_inst0.ctrl_dbg_pop && (apb_i2s_inst0.rx_level != 0)) cv_dbg_pop = 1;
          if (apb_i2s_inst0.tx_flush && (apb_i2s_inst0.tx_level != 0)) cv_tx_flush = 1;
          if (apb_i2s_inst0.rx_flush && (apb_i2s_inst0.rx_level != 0)) cv_rx_flush = 1;
          if ((TX_DEPTH != 0) && (apb_i2s_inst0.tx_level == TX_DEPTH)) cv_tx_full = 1;
          if ((RX_DEPTH != 0) && (apb_i2s_inst0.rx_level == RX_DEPTH)) cv_rx_full = 1;
          if (psel && penable && pwrite && apb_i2s_inst0.acc_allowed && apb_i2s_inst0.cfg_lock &&
              (apb_i2s_inst0.sel_clkdiv || apb_i2s_inst0.sel_format)) cv_cfg_locked = 1;
          if (|(apb_i2s_inst0.irq_set & apb_i2s_inst0.irq_w1c)) cv_w1c_race = 1;
          if (apb_i2s_inst0.u_core.stop && apb_i2s_inst0.u_core.dly) cv_stop_dly = 1;
          if (apb_i2s_inst0.u_core.tail && apb_i2s_inst0.u_core.cap && apb_i2s_inst0.u_core.rx_run) cv_tail_cap = 1;
          if (tb_tx_drop && apb_i2s_inst0.tx_take) cv_drop_at_take = 1;
       end
     cv_prev_access = psel && penable;
  end
always @(negedge presetn) if (psel) cv_reset_busy = 1;

task cover_report;
   begin
      if (cv_write)        $display("COVERAGE HIT: write");
      if (cv_read)         $display("COVERAGE HIT: read");
      if (cv_b2b)          $display("COVERAGE HIT: back_to_back");
      if (cv_pslverr)      $display("COVERAGE HIT: pslverr");
      if (cv_strb_part)    $display("COVERAGE HIT: partial_strobe");
      if (cv_idle_noise)   $display("COVERAGE HIT: penable_without_psel");
      if (cv_silent_drop)  $display("COVERAGE HIT: silent_drop");
      if (cv_s_admitted)   $display("COVERAGE HIT: smode_admitted");
      if (cv_u_admitted)   $display("COVERAGE HIT: umode_admitted");
      if (cv_pclk_off)     $display("COVERAGE HIT: pclk_gated");
      if (cv_reset_busy)   $display("COVERAGE HIT: reset_in_transfer");
      if (cv_fmt_i2s)      $display("COVERAGE HIT: fmt_i2s");
      if (cv_fmt_lj)       $display("COVERAGE HIT: fmt_lj");
      if (cv_fmt_rj)       $display("COVERAGE HIT: fmt_rj");
      if (cv_fmt_dspa)     $display("COVERAGE HIT: fmt_dsp_a");
      if (cv_fmt_dspb)     $display("COVERAGE HIT: fmt_dsp_b");
      if (cv_bclk_inv)     $display("COVERAGE HIT: bclk_inv");
      if (cv_slot16)       $display("COVERAGE HIT: slot16");
      if (cv_ratio[0])     $display("COVERAGE HIT: ratio_256");
      if (cv_ratio[1])     $display("COVERAGE HIT: ratio_384");
      if (cv_ratio[2])     $display("COVERAGE HIT: ratio_512");
      if (cv_ratio[3])     $display("COVERAGE HIT: ratio_768");
      if (cv_ratio[4])     $display("COVERAGE HIT: ratio_1024");
      if (cv_mdiv_big)     $display("COVERAGE HIT: mdiv_gt_1");
      if (cv_mclk_off)     $display("COVERAGE HIT: mclk_off");
      if (cv_tx_mono)      $display("COVERAGE HIT: tx_mono");
      if (cv_rx_left)      $display("COVERAGE HIT: rx_mono_left");
      if (cv_rx_right)     $display("COVERAGE HIT: rx_mono_right");
      if (cv_rx_avg)       $display("COVERAGE HIT: rx_mono_avg");
      if (cv_tx_under)     $display("COVERAGE HIT: tx_under");
      if (cv_rx_over)      $display("COVERAGE HIT: rx_over");
      if (cv_tx_ovf)       $display("COVERAGE HIT: tx_ovf");
      if (cv_rx_udf)       $display("COVERAGE HIT: rx_udf");
      if (cv_tx_low)       $display("COVERAGE HIT: tx_low_irq");
      if (cv_rx_high)      $display("COVERAGE HIT: rx_high_irq");
      if (cv_irq)          $display("COVERAGE HIT: sticky_irq");
      if (cv_dbg_peek)     $display("COVERAGE HIT: dbg_peek");
      if (cv_dbg_pop)      $display("COVERAGE HIT: dbg_pop");
      if (cv_loopback)     $display("COVERAGE HIT: loopback");
      if (cv_tx_flush)     $display("COVERAGE HIT: tx_flush");
      if (cv_rx_flush)     $display("COVERAGE HIT: rx_flush");
      if (cv_tx_full)      $display("COVERAGE HIT: tx_full");
      if (cv_rx_full)      $display("COVERAGE HIT: rx_full");
      if (cv_cfg_locked)   $display("COVERAGE HIT: cfg_locked");
      if (cv_w1c_race)     $display("COVERAGE HIT: w1c_event_race");
      if (cv_stop_dly)     $display("COVERAGE HIT: stop_delayed");
      if (cv_tail_cap)     $display("COVERAGE HIT: tail_capture");
      if (cv_drop_at_take) $display("COVERAGE HIT: mono_drop_at_take");
   end
endtask


//
// Generate Waveform
//----------------------------------------
initial
  begin
   `ifdef NODUMP
   `else
     `ifdef VPD_FILE
        $vcdplusfile("tb_apb_i2s.vpd");
        $vcdpluson();
     `else
       `ifdef TRN_FILE
          $recordfile ("tb_apb_i2s.trn");
          $recordvars;
       `else
          $dumpfile("tb_apb_i2s.vcd");
          $dumpvars(0, tb_apb_i2s);
       `endif
     `endif
   `endif
  end

`ifdef ARV_COV_RESET_ZERO
// Coverage counts start once reset is released: the Verilator coverage flow starts
// every flop at 1 so the asynchronous resets see an edge, and the reset driving them
// to 0 would otherwise count as a toggle of every bit.
initial begin
    wait (presetn === 1'b0);
    @(posedge presetn);
    $c("Verilated::threadContextp()->coveragep()->zero();");
end
`endif


//
// End of simulation
//----------------------------------------

initial // Timeout
  begin
   `ifdef NO_TIMEOUT
   `else
     `ifdef VERY_LONG_TIMEOUT
       #2000000000;
     `else
     `ifdef LONG_TIMEOUT
       #200000000;
     `else
       #50000000;
     `endif
     `endif
       $display(" ===============================================");
       $display("|               SIMULATION FAILED               |");
       $display("|              (simulation Timeout)             |");
       $display(" ===============================================");
       $display("");
       tb_extra_report;
       $finish;
   `endif
  end

initial // Normal end of test
  begin
     @(posedge stimulus_done);
     $display(" ===============================================");
     if (error!=0)
       begin
          $display("|               SIMULATION FAILED               |");
          $display("|     (some verilog stimulus checks failed)     |");
       end
     else
       begin
          $display("|               SIMULATION PASSED               |");
       end
     $display(" ===============================================");
     $display("");
     tb_extra_report;
     cover_report;
     $finish;
  end


//
// Tasks Definition
//------------------------------

   task tb_error;
      input [80*8-1:0] error_string;
      begin
         $display("ERROR: %0s %t ns", error_string, $time);
         error = error+1;
      end
   endtask

   task tb_skip;
      input [80*8-1:0] why;
      begin
         $display(" ===============================================");
         $display("|               SIMULATION SKIPPED              |");
         $display(" ===============================================");
         $display("  (%0s)", why);
         tb_extra_report;
         $finish;
      end
   endtask

   task tb_extra_report;
      begin
         $display("");
         $display("CONFIG: TX_EN=%0d RX_EN=%0d TX_FIFO_AW=%0d RX_FIFO_AW=%0d ADDRW=%0d MDELEG_RST=9'h%03h DBG_MASK=4'h%h ASYNC_RST_EN=%0d",
                  TX_EN, RX_EN, TX_FIFO_AW, RX_FIFO_AW, ADDRW, MDELEG_RST, DBG_MASK, ASYNC_RST_EN);
         $display("SIMULATION SEED: %d", `SEED);
         $display("");
      end
   endtask

endmodule
