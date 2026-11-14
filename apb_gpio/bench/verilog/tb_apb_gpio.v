//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tb_apb_gpio
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tb_apb_gpio.v
// Module Description : Block-level testbench for the apb_gpio IP.
//                      Parameter-driven DUT instantiation; the sweep runner
//                      overrides the parameters with -D GPIO_TB_<PARAM>=<v>
//                      (see bin/sim_configs.py). The selected stimulus file
//                      is `included into the module body as stimulus.v.
//
//  Clocking (doc "Clocks"): the oscillator is free_clk through an
//  oscillator gate (tb_osc_off=1 stops it, modelling the oscillator being
//  off: BOTH clocks stop); pclk_aon_i is the oscillator output; pclk_i is
//  pclk_aon_i through an ICG latch enabled by pclk_en_o ONLY (plus the
//  test-controlled tb_pclk_force, 0 by default), and during reset, as the
//  SoC reset generator requests every clock then. pclk_en_o must be high
//  while a transfer is in progress, or the transfer is lost here. Tests time
//  themselves on free_clk; with the oscillator on, its edges are the
//  pclk_aon_i edges.
//
//  Pins: gpio_i is driven from gpio_ext; with tb_pad_loop=1 a driven pin
//  (gpio_oe_o=1) reads back its own gpio_o through the modelled pad.
//
//  Always-on checks (after the first reset): irq_any_o == |irq_o at every
//  falling free_clk edge; the outputs gpio_o / gpio_oe_o / irq_o / irq_any_o
//  change only on a rising pclk_aon_i edge or during reset (they are
//  functions of registers); pslverr_o stays low outside an ACCESS cycle,
//  prdata_o is 0 outside a read ACCESS cycle, and pready_o is always high.
//  PSLVERR in an ACCESS cycle follows MDELEG, checked by the BFM and the
//  model. gpio_ie_o equals IN_EN (the model's copy) at every falling edge.
//  gpio_wake_o is combinational from gpio_i and is checked by the model and
//  the wake tests only.
//  The reference model (gpio_model.v) always tracks the DUT and compares
//  every cycle when a test sets model_check_en.
//----------------------------------------------------------------------------
`include "timescale.v"

`ifndef GPIO_TB_NR
 `define GPIO_TB_NR            32
`endif
`ifndef GPIO_TB_ADDRW
 `define GPIO_TB_ADDRW         7
`endif
`ifndef GPIO_TB_SYNC_EN
 `define GPIO_TB_SYNC_EN       1
`endif
`ifndef GPIO_TB_MDELEG_RST
 `define GPIO_TB_MDELEG_RST    271
`endif
`ifndef GPIO_TB_ASYNC_RST_EN
 `define GPIO_TB_ASYNC_RST_EN  1
`endif
`ifndef GPIO_TB_ALT_NR
 `define GPIO_TB_ALT_NR        0
`endif
`ifndef GPIO_TB_INP_CGATE_EN
 `define GPIO_TB_INP_CGATE_EN  1
`endif

module  tb_apb_gpio;

//
// DUT parameters
//------------------------------
localparam            GPIO_NR       = `GPIO_TB_NR;
localparam            ADDRW         = `GPIO_TB_ADDRW;
localparam            SYNC_EN       = `GPIO_TB_SYNC_EN;
localparam      [8:0] MDELEG_RST    = `GPIO_TB_MDELEG_RST;
localparam            ASYNC_RST_EN  = `GPIO_TB_ASYNC_RST_EN;
localparam            INP_CGATE_EN  = `GPIO_TB_INP_CGATE_EN;
localparam            ALT_NR        = `GPIO_TB_ALT_NR;

// Derived constants
localparam     [31:0] GPIO_MASK     = (GPIO_NR >= 32) ? 32'hFFFFFFFF : ((32'h1 << GPIO_NR) - 32'h1);
localparam            L_IN          = (SYNC_EN != 0) ? 3 : 1;     // gpio_i -> INPUT latency, in pclk edges (doc "Inputs")
localparam     [31:0] INFO_VALUE    = GPIO_MASK;                              // pin mask, bits [GPIO_NR-1:0]
localparam     [31:0] CFG_VALUE     = {4'h1, 22'h0, (INP_CGATE_EN != 0), (SYNC_EN != 0), 1'b0, ALT_NR[2:0]};  // doc "Register map", CFG
localparam     [31:0] MDELEG_RST_WORD = {23'h0, MDELEG_RST[8], 4'h0, MDELEG_RST[3:0]};
localparam            PICK_PIN_NR   = 9;                                    // entries of pick_pin()
localparam     [31:0] WIN_SIZE      = 32'h1 << ADDRW;

// Register map (doc "Register map")
localparam     [31:0] GPIO_BASE     = 32'h00400000;
localparam     [31:0] R_INFO        = GPIO_BASE + 32'h00;
localparam     [31:0] R_IN_EN       = GPIO_BASE + 32'h04;
localparam     [31:0] R_OE          = GPIO_BASE + 32'h08;
localparam     [31:0] R_INPUT       = GPIO_BASE + 32'h0C;
localparam     [31:0] R_OUTPUT      = GPIO_BASE + 32'h10;
localparam     [31:0] R_OUT_SET     = GPIO_BASE + 32'h14;
localparam     [31:0] R_OUT_CLR     = GPIO_BASE + 32'h18;
localparam     [31:0] R_OUT_TGL     = GPIO_BASE + 32'h1C;
localparam     [31:0] R_IRQ_EN      = GPIO_BASE + 32'h20;
localparam     [31:0] R_IRQ_PEND    = GPIO_BASE + 32'h24;
localparam     [31:0] R_WAKE_EN     = GPIO_BASE + 32'h28;
localparam     [31:0] R_CFG         = GPIO_BASE + 32'h2C;
localparam     [31:0] R_IRQ_RISE    = GPIO_BASE + 32'h30;
localparam     [31:0] R_IRQ_FALL    = GPIO_BASE + 32'h34;
localparam     [31:0] R_IRQ_HIGH    = GPIO_BASE + 32'h38;
localparam     [31:0] R_IRQ_LOW     = GPIO_BASE + 32'h3C;
localparam     [31:0] R_ALT_EN      = GPIO_BASE + 32'h40;                   // present with ALT_NR >= 1
localparam     [31:0] R_ALT_SEL0    = GPIO_BASE + 32'h44;                   // present with ALT_NR >= 2
localparam     [31:0] R_ALT_SEL1    = GPIO_BASE + 32'h48;                   // present with ALT_NR >= 3
localparam     [31:0] R_IRQ_STAT    = GPIO_BASE + 32'h4C;
localparam     [31:0] R_OE_SET      = GPIO_BASE + 32'h50;
localparam     [31:0] R_OE_CLR      = GPIO_BASE + 32'h54;
localparam     [31:0] R_IRQ_EN_SET  = GPIO_BASE + 32'h58;
localparam     [31:0] R_IRQ_EN_CLR  = GPIO_BASE + 32'h5C;
localparam     [31:0] R_MDELEG      = GPIO_BASE + 32'h60;
localparam     [31:0] R_FIRST_UNMAP = GPIO_BASE + 32'h64;
localparam            REG_NR        = 21;                                   // mapped words but MDELEG, see reg_addr()

//
// Wire & Register definition
//------------------------------

// Clock / Reset
reg                   presetn;
reg                   free_clk;
wire                  pclk_aon;             // always-on clock (oscillator output)
wire                  pclk;                 // bus clock (after the ICG)
wire                  pclk_en;
reg                   tb_pclk_force;        // test-controlled: keep pclk running regardless of pclk_en_o
reg                   tb_osc_off;           // test-controlled: oscillator off, both clocks stopped
reg                   tb_scan_mode;         // test-controlled: scan_mode_i
reg                   osc_en_latch;         // oscillator gate (glitch-free, low-phase latch)
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
wire           [31:0] prdata;
wire                  pready;
wire                  pslverr;

// Pins
reg            [31:0] gpio_ext;             // external pin drive
reg                   tb_pad_loop;          // 1: a driven pin reads back gpio_o
wire    [GPIO_NR-1:0] gpio_in_w;
wire    [GPIO_NR-1:0] gpio_o_w;
wire    [GPIO_NR-1:0] gpio_oe_w;
wire    [GPIO_NR-1:0] gpio_ie_w;
wire    [GPIO_NR-1:0] irq_w;
wire                  irq_any;
wire                  gpio_wake;
wire           [31:0] gpio_o32;             // zero-extended DUT outputs
wire           [31:0] gpio_oe32;
wire           [31:0] gpio_ie32;
wire           [31:0] irq32;
wire           [31:0] gpio_in32;

// Alternate functions (doc "Alternate functions"): bench-driven peripheral
// side, changed only through alt_drive() so the output-timing check below
// knows when a combinational change on gpio_o / gpio_oe_o is legitimate
reg            [31:0] tb_alt_o  [0:3];
reg            [31:0] tb_alt_oe [0:3];
wire    [GPIO_NR-1:0] alt_act_w [0:3];
wire           [31:0] alt_act32 [0:3];      // zero-extended alt<k>_act_o
realtime              t_last_alt;           // time of the last alt_drive() call

// Testbench variables
integer               tmp_seed;
integer               error;
reg                   stimulus_done;
reg                   tb_rst_done;          // first reset completed
integer               free_cnt;             // rising free_clk edges
integer               pclk_cnt;             // rising pclk edges with presetn high
integer               pclk_cnt_rst;         // rising pclk edges since the last reset release
integer               aon_cnt;              // rising pclk_aon edges with presetn high
realtime              t_last_pclk;          // time of the last rising pclk edge
realtime              t_last_aon;           // time of the last rising pclk_aon edge


//
// Include files
//------------------------------

// Verilog tasks, reference model & stimulus
`include "apb_tasks.v"
`include "gpio_model.v"
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

// Oscillator: stops cleanly (low-phase latch) while tb_osc_off is set
always @(free_clk or tb_osc_off)
  if (~free_clk)
    osc_en_latch <= ~tb_osc_off;
assign  pclk_aon = (free_clk & osc_en_latch);

// Bus clock: ICG latch transparent while the clock is low
always @(free_clk or pclk_en or tb_pclk_force)
  if (~free_clk)
    pclk_en_latch <= pclk_en | tb_pclk_force | ~presetn;
assign  pclk  =  (pclk_aon & pclk_en_latch);

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

// Edge counters
always @(posedge free_clk)
  free_cnt = free_cnt + 1;

always @(posedge pclk)
  begin
     t_last_pclk = $realtime;
     if (presetn === 1'b1)
       pclk_cnt = pclk_cnt + 1;
  end

always @(posedge pclk_aon)
  begin
     t_last_aon = $realtime;
     if (presetn === 1'b1)
       aon_cnt = aon_cnt + 1;
  end

always @(posedge pclk or negedge presetn)
  if (presetn !== 1'b1) pclk_cnt_rst = 0;
  else                  pclk_cnt_rst = pclk_cnt_rst + 1;

// Variables initialization
initial
  begin
     tmp_seed      = `SEED;
     tmp_seed      = $urandom(tmp_seed);
     error         = 0;
     stimulus_done = 0;
     tb_pclk_force = 0;
     tb_osc_off    = 0;
     tb_scan_mode  = 0;
     aon_cnt       = 0;
     t_last_aon    = 0;
     t_last_alt    = -1;
     tb_alt_o[0]   = 32'h0; tb_alt_o[1]  = 32'h0; tb_alt_o[2]  = 32'h0; tb_alt_o[3]  = 32'h0;
     tb_alt_oe[0]  = 32'h0; tb_alt_oe[1] = 32'h0; tb_alt_oe[2] = 32'h0; tb_alt_oe[3] = 32'h0;
     tb_pad_loop   = 0;
     gpio_ext      = 32'h00000000;
     free_cnt      = 0;
     pclk_cnt      = 0;
     pclk_cnt_rst  = 0;
     t_last_pclk   = 0;

     psel    = 1'b0;
     penable = 1'b0;
     paddr   = {ADDRW{1'b0}};
     pwrite  = 1'b0;
     pwdata  = 32'h00000000;
     pstrb   = 4'h0;
     pprot   = 3'h0;
     psmode  = 1'b0;
  end

assign gpio_o32  = gpio_o_w;
assign gpio_oe32 = gpio_oe_w;
assign gpio_ie32 = gpio_ie_w;
assign irq32     = irq_w;
assign gpio_in32 = tb_pad_loop ? ((gpio_oe32 & gpio_o32) | (~gpio_oe32 & gpio_ext)) : gpio_ext;
assign gpio_in_w = gpio_in32[GPIO_NR-1:0];
assign alt_act32[0] = alt_act_w[0];
assign alt_act32[1] = alt_act_w[1];
assign alt_act32[2] = alt_act_w[2];
assign alt_act32[3] = alt_act_w[3];


//
// APB GPIO INSTANCE
//----------------------------------
apb_gpio #(
    .GPIO_NR           ( GPIO_NR                ),
    .ADDRW             ( ADDRW                  ),
    .SYNC_EN           ( SYNC_EN                ),
    .MDELEG_RST        ( MDELEG_RST             ),
    .ALT_NR            ( ALT_NR                 ),
    .INP_CGATE_EN      ( INP_CGATE_EN           ),
    .ASYNC_RST_EN      ( ASYNC_RST_EN           )
) apb_gpio_inst0 (

// APB CLOCK & RESET
    .pclk_i            ( pclk                   ),
    .pclk_aon_i        ( pclk_aon               ),
    .presetn_i         ( presetn                ),
    .pclk_en_o         ( pclk_en                ),
    .scan_mode_i       ( tb_scan_mode           ),     // 0 = functional mode (doc "Ports")

// APB INTERFACE
    .psel_i            ( psel                   ),
    .penable_i         ( penable                ),
    .paddr_i           ( paddr                  ),
    .pwrite_i          ( pwrite                 ),
    .pwdata_i          ( pwdata                 ),
    .pstrb_i           ( pstrb                  ),
    .pprot_i           ( pprot                  ),
    .psmode_i          ( psmode                 ),
    .prdata_o          ( prdata                 ),
    .pready_o          ( pready                 ),
    .pslverr_o         ( pslverr                ),

// PINS & INTERRUPTS
    .gpio_i            ( gpio_in_w              ),
    .gpio_o            ( gpio_o_w               ),
    .gpio_oe_o         ( gpio_oe_w              ),
    .gpio_ie_o         ( gpio_ie_w              ),

// ALTERNATE FUNCTIONS
    .alt0_o_i          ( tb_alt_o[0][GPIO_NR-1:0]  ),
    .alt0_oe_i         ( tb_alt_oe[0][GPIO_NR-1:0] ),
    .alt0_act_o        ( alt_act_w[0]           ),
    .alt1_o_i          ( tb_alt_o[1][GPIO_NR-1:0]  ),
    .alt1_oe_i         ( tb_alt_oe[1][GPIO_NR-1:0] ),
    .alt1_act_o        ( alt_act_w[1]           ),
    .alt2_o_i          ( tb_alt_o[2][GPIO_NR-1:0]  ),
    .alt2_oe_i         ( tb_alt_oe[2][GPIO_NR-1:0] ),
    .alt2_act_o        ( alt_act_w[2]           ),
    .alt3_o_i          ( tb_alt_o[3][GPIO_NR-1:0]  ),
    .alt3_oe_i         ( tb_alt_oe[3][GPIO_NR-1:0] ),
    .alt3_act_o        ( alt_act_w[3]           ),

// INTERRUPTS & WAKE
    .irq_o             ( irq_w                  ),
    .irq_any_o         ( irq_any                ),
    .gpio_wake_o       ( gpio_wake              )
);


//
// Always-on checks
//----------------------------------

// irq_any_o is the OR of irq_o (doc "Ports")
always @(negedge free_clk)
  if (tb_rst_done && (presetn === 1'b1) && (irq_any !== (|irq32)))
    begin
       $display("ERROR: irq_any_o=%b is not the OR of irq_o=0x%h %t ns", irq_any, irq32, $time);
       error = error+1;
    end

// gpio_o / gpio_oe_o are register outputs, or pass an alternate function's
// inputs through a mux, and irq_o / irq_any_o AND-OR functions of registers
// (doc "Ports"): in this zero-delay simulation they change only on a rising
// pclk_aon edge outside reset, or when alt_drive() changes the alternate-function
// inputs (no path from gpio_i or the bus inputs). Glitch-freedom is NOT claimed
// by the document and not checked.
always @(gpio_o32 or gpio_oe32 or irq32 or irq_any)
  if (tb_rst_done && (presetn === 1'b1) && ($realtime != t_last_aon) && ($realtime != t_last_alt))
    begin
       $display("ERROR: an output changed away from a rising pclk_aon edge -- gpio_o=0x%h gpio_oe_o=0x%h irq_o=0x%h irq_any_o=%b %t ns", gpio_o32, gpio_oe32, irq32, irq_any, $time);
       error = error+1;
    end

// PSLVERR only in an ACCESS cycle, PRDATA only in a read ACCESS cycle,
// PREADY always high (doc "Bus interface").
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
       if (gpio_ie32 !== (m_in_en & GPIO_MASK))
         begin
            $display("ERROR: gpio_ie_o=0x%h is not IN_EN=0x%h %t ns", gpio_ie32, m_in_en & GPIO_MASK, $time);
            error = error+1;
         end
    end


//
// Functional coverage: one flag per bin, reported at the end
//----------------------------------
reg cv_write = 0, cv_read = 0, cv_b2b = 0, cv_pslverr = 0, cv_strb_part = 0, cv_idle_noise = 0;
reg cv_w1c_race = 0, cv_in_en_flush = 0, cv_wake_osc_off = 0, cv_pclk_off = 0, cv_reset_busy = 0;
reg cv_alt_owned = 0, cv_level_irq = 0, cv_edge_irq = 0;
reg cv_silent_drop = 0, cv_s_admitted = 0, cv_u_admitted = 0, cv_wake_masked = 0, cv_alias_oe_ien = 0;
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
          if (|(apb_gpio_inst0.wr_irq_pend & apb_gpio_inst0.wdata & apb_gpio_inst0.irq_edge)) cv_w1c_race = 1;
          if ((apb_gpio_inst0.in_en_q == {GPIO_NR{1'b0}}) && apb_gpio_inst0.in_vld_any) cv_in_en_flush = 1;
          if (tb_osc_off && gpio_wake) cv_wake_osc_off = 1;
          if (pclk_en === 1'b0) cv_pclk_off = 1;
          if ((alt_act32[0] | alt_act32[1] | alt_act32[2] | alt_act32[3]) != 32'h0) cv_alt_owned = 1;
          if (|(irq32 & ~apb_gpio_inst0.irq_latch_q)) cv_level_irq = 1;
          if (|(irq32 &  apb_gpio_inst0.irq_latch_q)) cv_edge_irq = 1;
          if (psel && penable && !apb_gpio_inst0.acc_allowed && !pslverr) cv_silent_drop = 1;
          if (psel && penable && apb_gpio_inst0.acc_allowed && pprot[0] && psmode) cv_s_admitted = 1;
          if (psel && penable && apb_gpio_inst0.acc_allowed && !pprot[0]) cv_u_admitted = 1;
          if (|(apb_gpio_inst0.wake_pin & (gpio_in_w ^ apb_gpio_inst0.gpio_in)) && !gpio_wake) cv_wake_masked = 1;
          if (|{apb_gpio_inst0.wr_oe_set, apb_gpio_inst0.wr_oe_clr, apb_gpio_inst0.wr_ien_set, apb_gpio_inst0.wr_ien_clr}) cv_alias_oe_ien = 1;
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
      if (cv_w1c_race)     $display("COVERAGE HIT: w1c_edge_race");
      if (cv_in_en_flush)  $display("COVERAGE HIT: in_en_flush");
      if (cv_wake_osc_off) $display("COVERAGE HIT: wake_osc_off");
      if (cv_pclk_off)     $display("COVERAGE HIT: pclk_gated");
      if (cv_reset_busy)   $display("COVERAGE HIT: reset_in_transfer");
      if (cv_alt_owned)    $display("COVERAGE HIT: alt_owned");
      if (cv_level_irq)    $display("COVERAGE HIT: level_irq");
      if (cv_edge_irq)     $display("COVERAGE HIT: edge_irq");
      if (cv_silent_drop)  $display("COVERAGE HIT: silent_drop");
      if (cv_s_admitted)   $display("COVERAGE HIT: smode_admitted");
      if (cv_u_admitted)   $display("COVERAGE HIT: umode_admitted");
      if (cv_wake_masked)  $display("COVERAGE HIT: wake_polarity_masked");
      if (cv_alias_oe_ien) $display("COVERAGE HIT: oe_irq_en_alias");
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
        $vcdplusfile("tb_apb_gpio.vpd");
        $vcdpluson();
     `else
       `ifdef TRN_FILE
          $recordfile ("tb_apb_gpio.trn");
          $recordvars;
       `else
          $dumpfile("tb_apb_gpio.vcd");
          $dumpvars(0, tb_apb_gpio);
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
       #500000000;
     `else
     `ifdef LONG_TIMEOUT
       #5000000;
     `else
       #500000;
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

   task tb_extra_report;
      begin
         $display("");
         $display("CONFIG: GPIO_NR=%0d ADDRW=%0d SYNC_EN=%0d MDELEG_RST=9'h%03h ALT_NR=%0d INP_CGATE_EN=%0d ASYNC_RST_EN=%0d", GPIO_NR, ADDRW, SYNC_EN, MDELEG_RST, ALT_NR, INP_CGATE_EN, ASYNC_RST_EN);
         $display("SIMULATION SEED: %d", `SEED);
         $display("");
      end
   endtask

   task tb_skip_finish;
      input [65*8-1:0] skip_string;
      begin
         $display(" ===============================================");
         $display("|               SIMULATION SKIPPED              |");
         $display("%0s", skip_string);
         $display(" ===============================================");
         $display("");
         tb_extra_report;
         $finish;
      end
   endtask

   // Condition check
   task chk;
      input            cond;
      input [80*8-1:0] msg;
      begin
         if (cond !== 1'b1)
           begin
              $display("ERROR: %0s %t ns", msg, $time);
              error = error+1;
           end
      end
   endtask

   // Value check with both values printed
   task chk32;
      input     [31:0] actual;
      input     [31:0] expected;
      input [80*8-1:0] msg;
      begin
         if (actual !== expected)
           begin
              $display("ERROR: %0s -- got 0x%h / expected 0x%h %t ns", msg, actual, expected, $time);
              error = error+1;
           end
         else
           $display("PASS:  %0s -- 0x%h %t ns", msg, actual, $time);
      end
   endtask

   // Pin index wrapped into the configured pin range, and its bit
   function integer pin;
      input integer n;
      begin
         pin = n % GPIO_NR;
      end
   endfunction

   function [31:0] pbit;
      input integer n;
      begin
         pbit = 32'h1 << (n % GPIO_NR);
      end
   endfunction

   // Register n of the tests' index order (0..20 = INPUT, OUTPUT, OE, OUT_SET,
   // OUT_CLR, OUT_TGL, IRQ_EN, IRQ_RISE, IRQ_FALL, IRQ_HIGH, IRQ_LOW, IRQ_PEND,
   // INFO, IN_EN, WAKE_EN, CFG, IRQ_STAT, OE_SET, OE_CLR, IRQ_EN_SET,
   // IRQ_EN_CLR; MDELEG is not in the list); 21.. = words from 0x64 (above
   // MDELEG, unmapped)
   function [31:0] reg_addr;
      input integer n;
      begin
         case (n)
           0       : reg_addr = R_INPUT;
           1       : reg_addr = R_OUTPUT;
           2       : reg_addr = R_OE;
           3       : reg_addr = R_OUT_SET;
           4       : reg_addr = R_OUT_CLR;
           5       : reg_addr = R_OUT_TGL;
           6       : reg_addr = R_IRQ_EN;
           7       : reg_addr = R_IRQ_RISE;
           8       : reg_addr = R_IRQ_FALL;
           9       : reg_addr = R_IRQ_HIGH;
           10      : reg_addr = R_IRQ_LOW;
           11      : reg_addr = R_IRQ_PEND;
           12      : reg_addr = R_INFO;
           13      : reg_addr = R_IN_EN;
           14      : reg_addr = R_WAKE_EN;
           15      : reg_addr = R_CFG;
           16      : reg_addr = R_IRQ_STAT;
           17      : reg_addr = R_OE_SET;
           18      : reg_addr = R_OE_CLR;
           19      : reg_addr = R_IRQ_EN_SET;
           20      : reg_addr = R_IRQ_EN_CLR;
           default : reg_addr = R_FIRST_UNMAP + 4*(n-21);
         endcase
      end
   endfunction

   // Alternate-function register at window offset 'off' present for this ALT_NR
   // (doc "Register map")
   function alt_reg_present;
      input [31:0] off;
      begin
         alt_reg_present = ((off == 32'h40) && (ALT_NR >= 1)) ||
                           ((off == 32'h44) && (ALT_NR >= 2)) ||
                           ((off == 32'h48) && (ALT_NR >= 3));
      end
   endfunction

   // Drive alternate function k's output values and enables (all four
   // functions exist on the ports whatever ALT_NR)
   task alt_drive;
      input integer k;
      input  [31:0] o;
      input  [31:0] oe;
      begin
         t_last_alt   = $realtime;
         tb_alt_o[k]  = o;
         tb_alt_oe[k] = oe;
      end
   endtask

   // A spread of interesting pins (lane boundaries, top pin), wrapped
   function integer pick_pin;
      input integer i;
      begin
         case (i)
           0:       pick_pin = 0;
           1:       pick_pin = 1;
           2:       pick_pin = 7;
           3:       pick_pin = 8;
           4:       pick_pin = 15;
           5:       pick_pin = 16;
           6:       pick_pin = 24;
           7:       pick_pin = 31;
           default: pick_pin = GPIO_NR-1;
         endcase
         pick_pin = pick_pin % GPIO_NR;
      end
   endfunction

   // Wait for the first reset release, then n cycles (time 0 passes first,
   // so tb_rst_done holds the value its initial block gives it)
   task wait_reset_done;
      input integer n;
      begin
         #1;
         wait (tb_rst_done === 1'b1);
         cycles(n);
      end
   endtask

   // Drive the pins #10 after the next rising free_clk edge (never on an edge)
   task pins_set;
      input [31:0] value;
      begin
         @(posedge free_clk);
         #10;
         gpio_ext = value;
      end
   endtask

   // Enable the inputs of 'mask' and wait past the flush (doc "Inputs",
   // Enabling a pin: stage depth, then one more cycle for edge detection)
   task inputs_on;
      input [31:0] mask;
      begin
         wr(R_IN_EN, mask);
         cycles(L_IN + 3);
      end
   endtask

   // Stop / restart the oscillator (both clocks) #10 after a rising edge:
   // the gate closes in the following low phase, so the last clock edge is
   // the one before the call returns.
   task osc_stop;
      begin
         @(posedge free_clk);
         #10;
         tb_osc_off = 1'b1;
         @(posedge free_clk);
         #1;
      end
   endtask

   task osc_start;
      begin
         @(posedge free_clk);
         #10;
         tb_osc_off = 1'b0;
      end
   endtask

   // Wait n rising free_clk edges, return #1 after the last one
   task cycles;
      input integer n;
      begin
         repeat (n) @(posedge free_clk);
         #1;
      end
   endtask

   // Mid-test reset: asserted #10 after a rising edge, held n cycles,
   // released #10 after a rising edge (synchronous de-assertion).
   task tb_reset_pulse;
      input integer n;
      begin
         @(posedge free_clk);
         #10;
         presetn = 1'b0;
         repeat (n) @(posedge free_clk);
         #10;
         presetn = 1'b1;
         apb_idle;
      end
   endtask

endmodule
