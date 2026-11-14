//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tb_apb_spi
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tb_apb_spi.v
// Module Description : Block-level testbench for the apb_spi IP.
//                      Parameter-driven DUT instantiation; the sweep runner
//                      overrides the parameters with -D SPI_TB_<PARAM>=<v>
//                      (see bin/sim_configs.py). The selected stimulus file
//                      is `included into the module body as stimulus.v.
//
//  Clocking (doc "Clock request"): pclk_i is free_clk through an ICG latch
//  enabled by pclk_en_o ONLY (plus tb_pclk_force, 0 by default, and the
//  SPI_TB_FREE_CLK build that never gates), and during reset, as the SoC
//  reset generator requests every clock then.
//
//  Pads: each lane is a bidirectional pad with a pull-up. The pad value is
//  the IP's output when it drives, the device's when it drives, 1 when
//  nobody does; both driving at once is reported as contention.
//
//  Devices (spi_dev.v): a monitor follows the entries the tests push and
//  checks every frame on the wire (lanes, bit and byte order, chip select,
//  clock timing), records the frame the IP must receive from the pads, and
//  a device answers on the lanes (a scripted frame source, an SD card in
//  SPI mode, sd_card.v, or a quad SPI NOR flash, spi_flash.v).
//
//  Always-on checks (after the first reset): pslverr_o low outside an ACCESS
//  cycle, prdata_o 0 outside a read ACCESS cycle, pready_o high, pclk_en_o
//  = psel_i | STATUS.BUSY | (an entry waiting & CTRL.EN), no output X.
//----------------------------------------------------------------------------
`include "timescale.v"

`ifndef SPI_TB_LANES_MAX
 `define SPI_TB_LANES_MAX      4
`endif
`ifndef SPI_TB_CS_NR
 `define SPI_TB_CS_NR          1
`endif
`ifndef SPI_TB_RX_EN
 `define SPI_TB_RX_EN          1
`endif
`ifndef SPI_TB_POLL_EN
 `define SPI_TB_POLL_EN        1
`endif
`ifndef SPI_TB_TX_FIFO_AW
 `define SPI_TB_TX_FIFO_AW     4
`endif
`ifndef SPI_TB_RX_FIFO_AW
 `define SPI_TB_RX_FIFO_AW     4
`endif
`ifndef SPI_TB_ADDRW
 `define SPI_TB_ADDRW          7
`endif
`ifndef SPI_TB_MDELEG_RST
 `define SPI_TB_MDELEG_RST     271
`endif
`ifndef SPI_TB_DBG_MASK
 `define SPI_TB_DBG_MASK       8
`endif
`ifndef SPI_TB_ASYNC_RST_EN
 `define SPI_TB_ASYNC_RST_EN   1
`endif
`ifndef SPI_TB_FREE_CLK
 `define SPI_TB_FREE_CLK       0
`endif

module  tb_apb_spi;

//
// DUT parameters
//------------------------------
localparam            LANES_MAX     = `SPI_TB_LANES_MAX;
localparam            CS_NR         = `SPI_TB_CS_NR;
localparam            RX_EN         = `SPI_TB_RX_EN;
localparam            POLL_EN       = `SPI_TB_POLL_EN;
localparam            TX_FIFO_AW    = `SPI_TB_TX_FIFO_AW;
localparam            RX_FIFO_AW    = `SPI_TB_RX_FIFO_AW;
localparam            ADDRW         = `SPI_TB_ADDRW;
localparam      [8:0] MDELEG_RST    = `SPI_TB_MDELEG_RST;
localparam      [3:0] DBG_MASK      = `SPI_TB_DBG_MASK;
localparam            ASYNC_RST_EN  = `SPI_TB_ASYNC_RST_EN;
localparam            FREE_CLK      = `SPI_TB_FREE_CLK;

// Derived constants
localparam            TX_DEPTH      = 1 << TX_FIFO_AW;
localparam            RX_DEPTH      = (RX_EN != 0) ? (1 << RX_FIFO_AW) : 0;
localparam            POLL_USE      = (POLL_EN != 0) && (RX_EN != 0);
localparam      [1:0] LANES_CODE    = (LANES_MAX == 4) ? 2'd2 : (LANES_MAX == 2) ? 2'd1 : 2'd0;
localparam     [31:0] CFG_VALUE     = {4'h1, 11'h0, (DBG_MASK != 4'h0), POLL_USE[0], (RX_EN != 0), LANES_CODE, 1'b0,
                                       CS_NR[2:0] - 3'd1, (RX_EN != 0) ? RX_FIFO_AW[3:0] : 4'h0, TX_FIFO_AW[3:0]};
localparam     [31:0] MDELEG_RST_WORD = {23'h0, MDELEG_RST[8], 4'h0, MDELEG_RST[3:0]};
localparam     [31:0] WIN_SIZE      = 32'h1 << ADDRW;
localparam real       PCLK_P        = 20.0;                                 // pclk period, ns

// Register map (doc "Register map")
localparam     [31:0] SPI_BASE      = 32'h00400000;
localparam     [31:0] R_CFG         = SPI_BASE + 32'h00;
localparam     [31:0] R_CTRL        = SPI_BASE + 32'h04;
localparam     [31:0] R_CTRL_SET    = SPI_BASE + 32'h08;
localparam     [31:0] R_CTRL_CLR    = SPI_BASE + 32'h0C;
localparam     [31:0] R_CLKDIV      = SPI_BASE + 32'h10;
localparam     [31:0] R_CSCFG       = SPI_BASE + 32'h14;
localparam     [31:0] R_XFER        = SPI_BASE + 32'h18;
localparam     [31:0] R_STATUS      = SPI_BASE + 32'h1C;
localparam     [31:0] R_THRESH      = SPI_BASE + 32'h20;
localparam     [31:0] R_IRQ_EN      = SPI_BASE + 32'h24;
localparam     [31:0] R_IRQ_EN_SET  = SPI_BASE + 32'h28;
localparam     [31:0] R_IRQ_EN_CLR  = SPI_BASE + 32'h2C;
localparam     [31:0] R_IRQ_PEND    = SPI_BASE + 32'h30;
localparam     [31:0] R_TXDATA      = SPI_BASE + 32'h34;
localparam     [31:0] R_RXDATA      = SPI_BASE + 32'h38;
localparam     [31:0] R_CMD         = SPI_BASE + 32'h3C;
localparam     [31:0] R_POLLMASK    = SPI_BASE + 32'h40;
localparam     [31:0] R_POLLVAL     = SPI_BASE + 32'h44;
localparam     [31:0] R_MDELEG      = SPI_BASE + 32'h60;

// CTRL fields
localparam     [31:0] C_EN          = 32'h001;
localparam     [31:0] C_CPOL        = 32'h002;
localparam     [31:0] C_CPHA        = 32'h004;
localparam     [31:0] C_LSB         = 32'h008;
localparam     [31:0] C_IDLE_LOW    = 32'h000;
localparam     [31:0] C_IDLE_HIGH   = 32'h010;
localparam     [31:0] C_IDLE_REL    = 32'h020;
localparam     [31:0] C_RX_IO0      = 32'h040;
localparam     [31:0] C_IO23_REL    = 32'h080;
localparam     [31:0] C_LOOPBACK    = 32'h100;
localparam     [31:0] C_DBG_POP     = 32'h200;
localparam     [31:0] C_BSWAP       = 32'h400;

// IRQ_PEND bits
localparam     [31:0] I_TX_LOW      = 32'h01;
localparam     [31:0] I_RX_HIGH     = 32'h02;
localparam     [31:0] I_DONE        = 32'h04;
localparam     [31:0] I_TX_OVF      = 32'h08;
localparam     [31:0] I_RX_UDF      = 32'h10;
localparam     [31:0] I_XFER_ERR    = 32'h20;
localparam     [31:0] I_POLL_TO     = 32'h40;

// CMD bits
localparam     [31:0] K_TX_FLUSH    = 32'h1;
localparam     [31:0] K_RX_FLUSH    = 32'h2;
localparam     [31:0] K_ABORT       = 32'h4;

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

// SPI
wire                  spi_sck;
wire      [CS_NR-1:0] spi_cs;
wire            [3:0] spi_io_o;
wire            [3:0] spi_io_oe;
wire            [3:0] spi_pad;              // resolved pad values (spi_io_i)
reg             [3:0] dev_oe;               // device output enables (after the round trip)
reg             [3:0] dev_v;                // device output values (after the round trip)
wire                  irq;

// Testbench variables
integer               tmp_seed;
integer               error = 0;
reg                   stimulus_done = 1'b0;
reg                   tb_rst_done = 1'b0;   // first reset completed
integer               free_cnt = 0;         // rising free_clk edges


//
// Include files
//------------------------------

// Verilog tasks, device models & stimulus
`include "apb_tasks.v"
`include "spi_dev.v"
`include "sd_card.v"
`include "spi_flash.v"
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
          #10;   // 50 MHz
          free_clk = ~free_clk;
       end
  end

// Bus clock: ICG latch transparent while the clock is low
always @(free_clk or pclk_en or tb_pclk_force or presetn)
  if (~free_clk)
    pclk_en_latch <= pclk_en | tb_pclk_force | ~presetn | (FREE_CLK != 0);
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
// Pads
//----------------------------------
genvar gp;
generate
  for (gp = 0; gp < 4; gp = gp + 1) begin : g_pad
    assign spi_pad[gp] = (spi_io_oe[gp] & dev_oe[gp]) ? 1'bx :
                          spi_io_oe[gp]                ? spi_io_o[gp] :
                          dev_oe[gp]                   ? dev_v[gp] :
                                                         1'b1;
  end
endgenerate


//
// APB SPI INSTANCE
//----------------------------------
apb_spi #(
    .LANES_MAX         ( LANES_MAX              ),
    .CS_NR             ( CS_NR                  ),
    .RX_EN             ( RX_EN                  ),
    .POLL_EN           ( POLL_EN                ),
    .TX_FIFO_AW        ( TX_FIFO_AW             ),
    .RX_FIFO_AW        ( RX_FIFO_AW             ),
    .ADDRW             ( ADDRW                  ),
    .MDELEG_RST        ( MDELEG_RST             ),
    .DBG_PMASTER_MASK  ( DBG_MASK               ),
    .ASYNC_RST_EN      ( ASYNC_RST_EN           )
) apb_spi_inst0 (

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

// SPI
    .spi_sck_o         ( spi_sck                ),
    .spi_cs_o          ( spi_cs                 ),
    .spi_io_o          ( spi_io_o               ),
    .spi_io_oe_o       ( spi_io_oe              ),
    .spi_io_i          ( spi_pad                ),

// INTERRUPT
    .irq_o             ( irq                    )
);


//
// Always-on checks
//----------------------------------

// PSLVERR only in an ACCESS cycle, PRDATA only in a read ACCESS cycle,
// PREADY always high, the clock request per its formula, no X on an output
// (doc "Ports", "Clock request").
wire       tb_busy = apb_spi_inst0.core_busy;
wire [8:0] tb_inflight;                      // capturing frames in flight (0 without a receive path)
generate
  if (RX_EN != 0) begin : g_tb_rx
    assign tb_inflight = apb_spi_inst0.g_rx.inflight;
  end else begin : g_tb_no_rx
    assign tb_inflight = 9'h000;
  end
endgenerate
wire tb_head = apb_spi_inst0.e_valid_raw;
wire tb_en   = apb_spi_inst0.ctrl_en;
always @(negedge free_clk)
  if (tb_rst_done && (presetn === 1'b1))
    begin
       #1;                                   // after any change a task makes on this edge
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
       if (pclk_en !== (psel | tb_busy | (tb_head & tb_en)))
         begin
            $display("ERROR: pclk_en_o=%b, expected %b (PSEL %b, BUSY %b, entry %b, EN %b) %t ns", pclk_en,
                     psel | tb_busy | (tb_head & tb_en), psel, tb_busy, tb_head, tb_en, $time);
            error = error+1;
         end
       if ((^{spi_sck, spi_cs, spi_io_o, spi_io_oe, irq}) === 1'bx)
         begin
            $display("ERROR: X on an SPI output or irq_o: sck %b cs %b io %b oe %b irq %b %t ns",
                     spi_sck, spi_cs, spi_io_o, spi_io_oe, irq, $time);
            error = error+1;
         end
    end


//
// Functional coverage: one flag per bin, reported at the end
//----------------------------------
reg cv_write = 0, cv_read = 0, cv_b2b = 0, cv_pslverr = 0, cv_strb_part = 0, cv_idle_noise = 0;
reg cv_silent_drop = 0, cv_s_admitted = 0, cv_u_admitted = 0, cv_pclk_off = 0, cv_reset_busy = 0;
reg [3:0] cv_mode = 0;                       // CPOL/CPHA pairs seen on a clocked frame
reg [3:0] cv_kind_l1 = 0, cv_kind_l2 = 0, cv_kind_l4 = 0;   // KIND x lane width
reg cv_bits1 = 0, cv_bits32 = 0, cv_lsb = 0, cv_bswap = 0, cv_lsb_bswap = 0;
reg cv_hold_cont = 0, cv_hold_switch = 0, cv_hold_none = 0, cv_cs_none = 0, cv_cs_high = 0;
reg cv_held_gated = 0, cv_stall = 0, cv_stall_mid = 0, cv_tail_after_rel = 0;
reg cv_rxdly0 = 0, cv_rxdly15 = 0, cv_rxdly_late = 0;
reg cv_poll_first = 0, cv_poll_mid = 0, cv_poll_last = 0, cv_poll_to = 0, cv_poll_pause = 0, cv_poll_quad = 0;
reg cv_xfer_err = 0, cv_tx_ovf = 0, cv_rx_udf = 0, cv_sparse = 0, cv_w1c_race = 0, cv_done = 0;
reg cv_abort_shift = 0, cv_abort_pause = 0, cv_abort_wait = 0, cv_abort_setup = 0;
reg cv_en_off_mid = 0, cv_cpol_held = 0, cv_resume = 0, cv_3wire = 0, cv_io23_rel = 0;
reg cv_loopback = 0, cv_dbg_peek = 0, cv_dbg_pop = 0, cv_tx_low = 0, cv_rx_high = 0;
reg cv_tx_flush = 0, cv_rx_flush = 0, cv_tx_full = 0, cv_rx_full = 0, cv_setup16 = 0, cv_inact_q = 0;
reg cv_prev_access = 0;
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
          if (psel && penable && !apb_spi_inst0.acc_allowed && !pslverr) cv_silent_drop = 1;
          if (psel && penable && apb_spi_inst0.acc_allowed && pprot[0] && psmode) cv_s_admitted = 1;
          if (psel && penable && apb_spi_inst0.acc_allowed && !pprot[0]) cv_u_admitted = 1;
          if (pclk_en === 1'b0) cv_pclk_off = 1;
          if (pclk_en === 1'b0 && apb_spi_inst0.core_cs) cv_held_gated = 1;
          if (apb_spi_inst0.xfer_err) cv_xfer_err = 1;
          if (apb_spi_inst0.tx_ovf)   cv_tx_ovf   = 1;
          if (apb_spi_inst0.rx_udf)   cv_rx_udf   = 1;
          if (psel && penable && pwrite && apb_spi_inst0.sel_txdata && (pstrb != 4'hF)) cv_sparse = 1;
          if (|(apb_spi_inst0.irq_set & apb_spi_inst0.irq_w1c)) cv_w1c_race = 1;
          if (apb_spi_inst0.irq_set[0]) cv_done = 1;
          if (apb_spi_inst0.irq_pend[0] && apb_spi_inst0.irq_en[0] && irq) cv_tx_low  = 1;
          if (apb_spi_inst0.irq_pend[1] && apb_spi_inst0.irq_en[1] && irq) cv_rx_high = 1;
          if (apb_spi_inst0.core_stall) cv_stall = 1;
          if (apb_spi_inst0.core_stall && apb_spi_inst0.u_core.mid) cv_stall_mid = 1;
          if (apb_spi_inst0.tx_flush && (apb_spi_inst0.tx_level != 0)) cv_tx_flush = 1;
          if (apb_spi_inst0.rx_flush && (apb_spi_inst0.rx_level != 0)) cv_rx_flush = 1;
          if (apb_spi_inst0.tx_level == TX_DEPTH) cv_tx_full = 1;
          if ((RX_DEPTH != 0) && (apb_spi_inst0.rx_level == RX_DEPTH)) cv_rx_full = 1;
          if (apb_spi_inst0.abort && (apb_spi_inst0.u_core.st == 3'd2)) cv_abort_shift = 1;
          if (apb_spi_inst0.abort && (apb_spi_inst0.u_core.st == 3'd3)) cv_abort_pause = 1;
          if (apb_spi_inst0.abort && (apb_spi_inst0.u_core.st == 3'd4)) cv_abort_wait  = 1;
          if (apb_spi_inst0.abort && (apb_spi_inst0.u_core.st == 3'd1)) cv_abort_setup = 1;
          if (apb_spi_inst0.u_core.st == 3'd3) cv_poll_pause = 1;
          if (apb_spi_inst0.u_core.cap && !apb_spi_inst0.core_cs && (apb_spi_inst0.u_core.st == 3'd6)) cv_tail_after_rel = 1;
          if (psel && penable && pwrite && apb_spi_inst0.acc_allowed && apb_spi_inst0.core_cs &&
              (apb_spi_inst0.ctrl_n[1] != apb_spi_inst0.ctrl[1])) cv_cpol_held = 1;
          if (apb_spi_inst0.ctrl[0] && !apb_spi_inst0.ctrl_n[0] && apb_spi_inst0.core_busy) cv_en_off_mid = 1;
          if (psel && penable && !pwrite && apb_spi_inst0.sel_rxdata && apb_spi_inst0.acc_dbg &&
              apb_spi_inst0.acc_allowed && !apb_spi_inst0.ctrl[9] && (apb_spi_inst0.rx_level != 0)) cv_dbg_peek = 1;
          if (psel && penable && !pwrite && apb_spi_inst0.sel_rxdata && apb_spi_inst0.acc_dbg &&
              apb_spi_inst0.acc_allowed &&  apb_spi_inst0.ctrl[9] && (apb_spi_inst0.rx_level != 0)) cv_dbg_pop = 1;
       end
     cv_prev_access = psel && penable;
  end
always @(negedge presetn) if (psel || (tb_busy === 1'b1)) cv_reset_busy = 1;

task cover_report;
   begin
      if (cv_write)          $display("COVERAGE HIT: write");
      if (cv_read)           $display("COVERAGE HIT: read");
      if (cv_b2b)            $display("COVERAGE HIT: back_to_back");
      if (cv_pslverr)        $display("COVERAGE HIT: pslverr");
      if (cv_strb_part)      $display("COVERAGE HIT: partial_strobe");
      if (cv_idle_noise)     $display("COVERAGE HIT: penable_without_psel");
      if (cv_silent_drop)    $display("COVERAGE HIT: silent_drop");
      if (cv_s_admitted)     $display("COVERAGE HIT: smode_admitted");
      if (cv_u_admitted)     $display("COVERAGE HIT: umode_admitted");
      if (cv_pclk_off)       $display("COVERAGE HIT: pclk_gated");
      if (cv_reset_busy)     $display("COVERAGE HIT: reset_in_operation");
      if (cv_mode[0])        $display("COVERAGE HIT: mode0");
      if (cv_mode[1])        $display("COVERAGE HIT: mode1");
      if (cv_mode[2])        $display("COVERAGE HIT: mode2");
      if (cv_mode[3])        $display("COVERAGE HIT: mode3");
      if (cv_kind_l1[0])     $display("COVERAGE HIT: tx_single");
      if (cv_kind_l1[1])     $display("COVERAGE HIT: rx_single");
      if (cv_kind_l1[2])     $display("COVERAGE HIT: dummy_single");
      if (cv_kind_l1[3])     $display("COVERAGE HIT: poll_single");
      if (cv_kind_l2[0])     $display("COVERAGE HIT: tx_dual");
      if (cv_kind_l2[1])     $display("COVERAGE HIT: rx_dual");
      if (cv_kind_l2[2])     $display("COVERAGE HIT: dummy_dual");
      if (cv_kind_l2[3])     $display("COVERAGE HIT: poll_dual");
      if (cv_kind_l4[0])     $display("COVERAGE HIT: tx_quad");
      if (cv_kind_l4[1])     $display("COVERAGE HIT: rx_quad");
      if (cv_kind_l4[2])     $display("COVERAGE HIT: dummy_quad");
      if (cv_kind_l4[3])     $display("COVERAGE HIT: poll_quad");
      if (cv_bits1)          $display("COVERAGE HIT: frame_1bit");
      if (cv_bits32)         $display("COVERAGE HIT: frame_32bit");
      if (cv_lsb)            $display("COVERAGE HIT: lsb_first");
      if (cv_bswap)          $display("COVERAGE HIT: bswap");
      if (cv_lsb_bswap)      $display("COVERAGE HIT: lsb_first_bswap");
      if (cv_hold_cont)      $display("COVERAGE HIT: cs_hold_continued");
      if (cv_hold_switch)    $display("COVERAGE HIT: cs_hold_switched");
      if (cv_hold_none)      $display("COVERAGE HIT: cs_hold_to_none");
      if (cv_cs_none)        $display("COVERAGE HIT: cs_none");
      if (cv_cs_high)        $display("COVERAGE HIT: cs_active_high");
      if (cv_held_gated)     $display("COVERAGE HIT: cs_held_clock_gated");
      if (cv_stall)          $display("COVERAGE HIT: stall");
      if (cv_stall_mid)      $display("COVERAGE HIT: stall_mid_entry");
      if (cv_tail_after_rel) $display("COVERAGE HIT: capture_after_release");
      if (cv_rxdly0)         $display("COVERAGE HIT: rx_dly_0");
      if (cv_rxdly15)        $display("COVERAGE HIT: rx_dly_15");
      if (cv_rxdly_late)     $display("COVERAGE HIT: rx_dly_ge_2half");
      if (cv_poll_first)     $display("COVERAGE HIT: poll_first_frame");
      if (cv_poll_mid)       $display("COVERAGE HIT: poll_mid");
      if (cv_poll_last)      $display("COVERAGE HIT: poll_last_frame");
      if (cv_poll_to)        $display("COVERAGE HIT: poll_timeout");
      if (cv_poll_pause)     $display("COVERAGE HIT: poll_pause");
      if (cv_xfer_err)       $display("COVERAGE HIT: xfer_err");
      if (cv_tx_ovf)         $display("COVERAGE HIT: tx_ovf");
      if (cv_rx_udf)         $display("COVERAGE HIT: rx_udf");
      if (cv_sparse)         $display("COVERAGE HIT: sparse_txdata");
      if (cv_w1c_race)       $display("COVERAGE HIT: w1c_event_race");
      if (cv_done)           $display("COVERAGE HIT: done");
      if (cv_abort_shift)    $display("COVERAGE HIT: abort_shift");
      if (cv_abort_pause)    $display("COVERAGE HIT: abort_pause");
      if (cv_abort_wait)     $display("COVERAGE HIT: abort_wait");
      if (cv_abort_setup)    $display("COVERAGE HIT: abort_setup");
      if (cv_en_off_mid)     $display("COVERAGE HIT: en_cleared_busy");
      if (cv_cpol_held)      $display("COVERAGE HIT: cpol_write_held");
      if (cv_resume)         $display("COVERAGE HIT: resume");
      if (cv_3wire)          $display("COVERAGE HIT: three_wire");
      if (cv_io23_rel)       $display("COVERAGE HIT: io23_released");
      if (cv_loopback)       $display("COVERAGE HIT: loopback");
      if (cv_dbg_peek)       $display("COVERAGE HIT: dbg_peek");
      if (cv_dbg_pop)        $display("COVERAGE HIT: dbg_pop");
      if (cv_tx_low)         $display("COVERAGE HIT: tx_low_irq");
      if (cv_rx_high)        $display("COVERAGE HIT: rx_high_irq");
      if (cv_tx_flush)       $display("COVERAGE HIT: tx_flush");
      if (cv_rx_flush)       $display("COVERAGE HIT: rx_flush");
      if (cv_tx_full)        $display("COVERAGE HIT: tx_full");
      if (cv_rx_full)        $display("COVERAGE HIT: rx_full");
      if (cv_setup16)        $display("COVERAGE HIT: cs_timing_16");
      if (cv_inact_q)        $display("COVERAGE HIT: inact_enforced");
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
        $vcdplusfile("tb_apb_spi.vpd");
        $vcdpluson();
     `else
       `ifdef TRN_FILE
          $recordfile ("tb_apb_spi.trn");
          $recordvars;
       `else
          $dumpfile("tb_apb_spi.vcd");
          $dumpvars(0, tb_apb_spi);
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
     mon_final;
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
         $display("CONFIG: LANES_MAX=%0d CS_NR=%0d RX_EN=%0d POLL_EN=%0d TX_FIFO_AW=%0d RX_FIFO_AW=%0d ADDRW=%0d MDELEG_RST=9'h%03h DBG_MASK=4'h%h ASYNC_RST_EN=%0d FREE_CLK=%0d",
                  LANES_MAX, CS_NR, RX_EN, POLL_EN, TX_FIFO_AW, RX_FIFO_AW, ADDRW, MDELEG_RST, DBG_MASK, ASYNC_RST_EN, FREE_CLK);
         $display("SIMULATION SEED: %d", `SEED);
         $display("");
      end
   endtask

endmodule
