//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tb_apb_usb_host
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tb_apb_usb_host.v
// Module Description : Block-level testbench for the apb_usb_host IP.
//                      Parameter-driven DUT instantiation; the sweep runner
//                      overrides the parameters with -D USB_TB_<PARAM>=<v>
//                      (see bin/sim_configs.py). The selected stimulus file
//                      is `included into the module body as stimulus.v.
//
//  Clocking (doc "Clock request"): free_clk runs at CLK_HZ; pclk_i is
//  free_clk through an ICG latch enabled by pclk_en_o ONLY (plus
//  tb_pclk_force, 0 by default, and the USB_TB_FREE_CLK build that never
//  gates), and during reset, as the SoC reset generator requests every clock
//  then.
//
//  Port: resolved by the bench from both sides' drivers (submit.f defines
//  USB_LS_DEV_EXT_BUS, so the model drives nothing itself): while the IP
//  (usb_oe_o) and the device model (usb_ls_dev.v, instance dev) drive
//  together, their common value, X where they differ; else the driver's
//  value; undriven, the device's pull-up
//  (D- for low speed, D+ for the full-speed profile, while attached) against
//  the host's 15 kOhm pull-downs. The pad read-back is 1 only for a clean 1.
//
//  Always-on checks (after the first reset): pslverr_o low outside an ACCESS
//  cycle, prdata_o 0 outside a read ACCESS cycle, pready_o high, pclk_en_o
//  = psel_i | CTRL.EN | (STATE != OFF) | usb_oe_o | (an ACCESS cycle ended on
//  the last edge), no output X, the IP never driving while the device
//  drives (a two-state check, for Verilator; tb_coll_ok = 1 lifts it for a
//  test that provokes it on purpose), and the device model's host checkers: their
//  total count must stay 0 unless a test disables a checker (dev.chk_enable)
//  for a reason it states.
//----------------------------------------------------------------------------
`include "timescale.v"

`ifndef USB_TB_CLK_HZ
 `define USB_TB_CLK_HZ         48000000
`endif
`ifndef USB_TB_CTRL_EN
 `define USB_TB_CTRL_EN        0
`endif
`ifndef USB_TB_DIAG_EN
 `define USB_TB_DIAG_EN        0
`endif
`ifndef USB_TB_ADDRW
 `define USB_TB_ADDRW          8
`endif
`ifndef USB_TB_MDELEG_RST
 `define USB_TB_MDELEG_RST     271
`endif
`ifndef USB_TB_ASYNC_RST_EN
 `define USB_TB_ASYNC_RST_EN   1
`endif
`ifndef USB_TB_FREE_CLK
 `define USB_TB_FREE_CLK       0
`endif

module  tb_apb_usb_host;

//
// DUT parameters
//------------------------------
localparam            CLK_HZ        = `USB_TB_CLK_HZ;
localparam            CTRL_EN       = `USB_TB_CTRL_EN;
localparam            DIAG_EN       = `USB_TB_DIAG_EN;
localparam            ADDRW         = `USB_TB_ADDRW;
localparam      [8:0] MDELEG_RST    = `USB_TB_MDELEG_RST;
localparam            ASYNC_RST_EN  = `USB_TB_ASYNC_RST_EN;
localparam            FREE_CLK      = `USB_TB_FREE_CLK;

// Derived constants
localparam real       PCLK_P        = 1.0e9 / CLK_HZ;                        // pclk period, ns
localparam            CNT_CLK       = ((CLK_HZ % 1500000) == 0);             // jitter-free bit clock
localparam            GRID_NS       = CNT_CLK ? 0 : ((1000000000 + CLK_HZ - 1) / CLK_HZ);
localparam     [31:0] INFO_VALUE    = {4'h1, 25'h0, (DIAG_EN != 0), (CTRL_EN != 0), 1'b0};
localparam     [31:0] MDELEG_RST_WORD = {23'h0, MDELEG_RST[8], 4'h0, MDELEG_RST[3:0]};
localparam     [31:0] WIN_SIZE      = 32'h1 << ADDRW;

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
wire           [31:0] prdata;
wire                  pready;
wire                  pslverr;

// USB port
wire                  usb_dp;               // D+ bus
wire                  usb_dm;               // D- bus
wire                  usb_dp_o;
wire                  usb_dm_o;
wire                  usb_oe;
wire                  irq;

// Device model status
wire                  dev_attached;
wire                  dev_suspended;
wire            [6:0] dev_address;
wire                  dev_configured;
wire            [2:0] dev_state;
wire           [31:0] dev_err_count;

// Testbench variables
integer               tmp_seed;
integer               error = 0;
reg                   stimulus_done = 1'b0;
reg                   tb_rst_done = 1'b0;   // first reset completed
integer               free_cnt = 0;         // rising free_clk edges
reg                   tb_dev_chk_final = 1'b1;  // add the device checker total to the verdict
reg                   tb_coll_ok = 1'b0;    // test-controlled: the IP and the device may drive together
integer               tb_coll_n = 0;        // collisions seen (reported once each)
reg                   tb_coll_q = 1'b0;
real                  tb_act_t = 0.0;       // last change of a bus driver enable (IP or device)


//
// Include files
//------------------------------

// Verilog tasks & stimulus
`include "apb_tasks.v"
`include "usb_tasks.v"
`include "stimulus.v"


//
// Generate Clock & Reset
//------------------------------

// Free running clock at CLK_HZ
initial
  begin
     free_clk  = 1'b0;
     forever
       begin
          #(PCLK_P / 2.0);
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
     #(3.1 * PCLK_P);
     presetn       = 1'b0;
     #(20.3 * PCLK_P);
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
  end


//
// USB port: bus resolution, device
//----------------------------------
assign usb_dp = (usb_oe & dev.drv_en) ? ((usb_dp_o == dev.drv_dp) ? usb_dp_o : 1'bx) :
                usb_oe                 ? usb_dp_o :
                dev.drv_en             ? dev.drv_dp :
                                         (dev.pu_on & dev.pu_fs);
assign usb_dm = (usb_oe & dev.drv_en) ? ((usb_dm_o == dev.drv_dm) ? usb_dm_o : 1'bx) :
                usb_oe                 ? usb_dm_o :
                dev.drv_en             ? dev.drv_dm :
                                         (dev.pu_on & ~dev.pu_fs);

usb_ls_dev #(
    .NAME              ( "dev"                  ),
    .SEED              ( `SEED                  ),
    .VERBOSE           ( 1                      ),
    .RATE_GRID_NS      ( GRID_NS                )
) dev (
    .dp                ( usb_dp                 ),
    .dm                ( usb_dm                 ),
    .host_oe           ( usb_oe                 ),
    .attached          ( dev_attached           ),
    .suspended         ( dev_suspended          ),
    .address           ( dev_address            ),
    .configured        ( dev_configured         ),
    .dev_state         ( dev_state              ),
    .err_count         ( dev_err_count          )
);


//
// APB USB HOST INSTANCE
//----------------------------------
apb_usb_host #(
    .CLK_HZ            ( CLK_HZ                 ),
    .FS_EN             ( 0                      ),
    .CTRL_EN           ( CTRL_EN                ),
    .DIAG_EN           ( DIAG_EN                ),
    .ADDRW             ( ADDRW                  ),
    .MDELEG_RST        ( MDELEG_RST             ),
    .ASYNC_RST_EN      ( ASYNC_RST_EN           )
) dut (

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
    .prdata_o          ( prdata                 ),
    .pready_o          ( pready                 ),
    .pslverr_o         ( pslverr                ),

// USB PORT
    .usb_dp_i          ( usb_dp === 1'b1        ),
    .usb_dm_i          ( usb_dm === 1'b1        ),
    .usb_dp_o          ( usb_dp_o               ),
    .usb_dm_o          ( usb_dm_o               ),
    .usb_oe_o          ( usb_oe                 ),

// INTERRUPT
    .irq_o             ( irq                    )
);


//
// Always-on checks
//----------------------------------

// Bus activity: the last time the IP or the device started or stopped driving
// (edge-triggered: Verilator does not wake a level event control whose body
// reads no signal)
always @(posedge usb_oe or negedge usb_oe or posedge dev.drv_en or negedge dev.drv_en)
  tb_act_t = $realtime;

// The port state and CTRL.EN as the registers show them (doc "Clock request")
wire [3:0] tb_state  = dut.state;
wire       tb_ctrl_en = dut.ctrl_en;
reg        tb_acc_q  = 1'b0;                 // an ACCESS cycle ended on the last pclk edge
always @(posedge pclk or negedge presetn)
  if (presetn !== 1'b1) tb_acc_q <= 1'b0;
  else                  tb_acc_q <= psel & penable;

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
       if (pclk_en !== (psel | tb_ctrl_en | (tb_state != 4'd0) | usb_oe | tb_acc_q))
         begin
            $display("ERROR: pclk_en_o=%b, expected %b (PSEL %b, EN %b, STATE %0d, OE %b, ACC %b) %t ns", pclk_en,
                     psel | tb_ctrl_en | (tb_state != 4'd0) | usb_oe | tb_acc_q, psel, tb_ctrl_en, tb_state,
                     usb_oe, tb_acc_q, $time);
            error = error+1;
         end
       if (usb_oe && dev.drv_en && !tb_coll_q)
         begin
            tb_coll_n = tb_coll_n + 1;
            if (!tb_coll_ok)
              begin
                 $display("ERROR: the IP drives the bus while the device drives (host %b%b, device %b%b) %t ns",
                          usb_dp_o, usb_dm_o, dev.drv_dp, dev.drv_dm, $time);
                 error = error+1;
              end
         end
       tb_coll_q = usb_oe && dev.drv_en;
       if ((^{usb_dp_o, usb_dm_o, usb_oe, irq, pclk_en}) === 1'bx)
         begin
            $display("ERROR: X on a USB output, irq_o or pclk_en_o: dp %b dm %b oe %b irq %b pclk_en %b %t ns",
                     usb_dp_o, usb_dm_o, usb_oe, irq, pclk_en, $time);
            error = error+1;
         end
    end


//
// Functional coverage: one flag per bin, reported at the end
//----------------------------------
reg        cv_write = 0, cv_read = 0, cv_b2b = 0, cv_pslverr = 0, cv_strb_part = 0, cv_idle_noise = 0;
reg        cv_silent_drop = 0, cv_s_admitted = 0, cv_u_admitted = 0, cv_pclk_off = 0, cv_reset_busy = 0;
reg [10:0] cv_state = 0;                     // every STATE entered
reg  [9:0] cv_err = 0;                       // every STATUS.ERR value 1-9 reported
reg  [6:0] cv_irq = 0;                       // every IRQ_PEND cause set
reg  [6:0] cv_irq_out = 0;                   // every cause raised irq_o
reg  [5:0] cv_xres = 0;                      // every XFER.RESULT at XFER_DONE
reg  [2:0] cv_attempt = 0;                   // ATTEMPT values seen
reg        cv_w1c_race = 0, cv_report_swap_read = 0, cv_poll_ms = 0, cv_poll_bint = 0;
reg        cv_prev_access = 0;
reg  [3:0] cv_prev_state = 0;
reg        cv_xdone_q = 0;                   // XFER.RESULT is valid the cycle after XFER_DONE
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
          if (psel && penable && !dut.acc_allowed && !pslverr) cv_silent_drop = 1;
          if (psel && penable && dut.acc_allowed && pprot[0] && psmode) cv_s_admitted = 1;
          if (psel && penable && dut.acc_allowed && !pprot[0]) cv_u_admitted = 1;
          if (pclk_en === 1'b0) cv_pclk_off = 1;
          if ((tb_state != cv_prev_state) && (tb_state <= 4'd10)) cv_state[tb_state] = 1'b1;
          if ((dut.err != 4'd0) && (dut.err <= 4'd9)) cv_err[dut.err] = 1'b1;
          cv_irq     = cv_irq | dut.irq_set;
          cv_irq_out = cv_irq_out | (irq ? (dut.irq_pend & dut.irq_en) : 7'h00);
          cv_attempt[dut.attempt] = 1'b1;
          if (|(dut.irq_set & dut.irq_w1c)) cv_w1c_race = 1;
          if (cv_xdone_q && (dut.xres <= 3'd5)) cv_xres[dut.xres] = 1'b1;
          cv_xdone_q = dut.ev_xdone;
          if (dut.rpt_commit && psel && penable && !pwrite && (paddr[ADDRW-1:3] == 'h08)) cv_report_swap_read = 1;
          if (dut.run && (dut.ctrl_poll != 8'd0)) cv_poll_ms = 1;
          if (dut.run && (dut.ctrl_poll == 8'd0)) cv_poll_bint = 1;
          cv_prev_state = tb_state;
       end
     cv_prev_access = psel && penable;
  end
always @(negedge presetn) if (tb_rst_done && (psel || (tb_state !== 4'd0))) cv_reset_busy = 1;

task cover_report;
   integer k;
   begin
      if (cv_write)            $display("COVERAGE HIT: write");
      if (cv_read)             $display("COVERAGE HIT: read");
      if (cv_b2b)              $display("COVERAGE HIT: back_to_back");
      if (cv_pslverr)          $display("COVERAGE HIT: pslverr");
      if (cv_strb_part)        $display("COVERAGE HIT: partial_strobe");
      if (cv_idle_noise)       $display("COVERAGE HIT: penable_without_psel");
      if (cv_silent_drop)      $display("COVERAGE HIT: silent_drop");
      if (cv_s_admitted)       $display("COVERAGE HIT: smode_admitted");
      if (cv_u_admitted)       $display("COVERAGE HIT: umode_admitted");
      if (cv_pclk_off)         $display("COVERAGE HIT: pclk_gated");
      if (cv_reset_busy)       $display("COVERAGE HIT: reset_in_operation");
      for (k = 0; k <= 10; k = k + 1)
        if (cv_state[k])       $display("COVERAGE HIT: state_%0s", st_name(k));
      for (k = 1; k <= 9; k = k + 1)
        if (cv_err[k])         $display("COVERAGE HIT: err_%0d", k);
      for (k = 0; k < 7; k = k + 1)
        if (cv_irq[k])         $display("COVERAGE HIT: irq_%0s", irq_name(k));
      for (k = 0; k < 7; k = k + 1)
        if (cv_irq_out[k])     $display("COVERAGE HIT: irq_out_%0s", irq_name(k));
      for (k = 0; k <= 5; k = k + 1)
        if (cv_xres[k])        $display("COVERAGE HIT: xres_%0d", k);
      for (k = 0; k <= 2; k = k + 1)
        if (cv_attempt[k])     $display("COVERAGE HIT: attempt_%0d", k);
      if (cv_w1c_race)         $display("COVERAGE HIT: w1c_event_race");
      if (cv_report_swap_read) $display("COVERAGE HIT: report_swap_read");
      if (cv_poll_ms)          $display("COVERAGE HIT: poll_ms");
      if (cv_poll_bint)        $display("COVERAGE HIT: poll_binterval");
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
        $vcdplusfile("tb_apb_usb_host.vpd");
        $vcdpluson();
     `else
       `ifdef TRN_FILE
          $recordfile ("tb_apb_usb_host.trn");
          $recordvars;
       `else
          $dumpfile("tb_apb_usb_host.vcd");
          $dumpvars(0, tb_apb_usb_host);
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

initial // Timeout (simulated time: enumeration alone takes ~0.4 s)
  begin
   `ifdef NO_TIMEOUT
   `else
     `ifdef VERY_LONG_TIMEOUT
       #(60.0e9);
     `else
     `ifdef LONG_TIMEOUT
       #(20.0e9);
     `else
       #(5.0e9);
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
     if (tb_dev_chk_final && (dev_err_count != 0))
       begin
          $display("ERROR: the device model's host checkers counted %0d violation(s)", dev_err_count);
          error = error + 1;
       end
     dev.dump_summary;
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
         $display("CONFIG: CLK_HZ=%0d CTRL_EN=%0d DIAG_EN=%0d ADDRW=%0d MDELEG_RST=9'h%03h ASYNC_RST_EN=%0d FREE_CLK=%0d",
                  CLK_HZ, CTRL_EN, DIAG_EN, ADDRW, MDELEG_RST, ASYNC_RST_EN, FREE_CLK);
         $display("SIMULATION SEED: %d", `SEED);
         $display("");
      end
   endtask

endmodule
