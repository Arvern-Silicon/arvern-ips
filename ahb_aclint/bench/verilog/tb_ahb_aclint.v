//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tb_ahb_aclint
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tb_ahb_aclint.v
// Module Description : AHB ACLINT block-level testbench. Parameter-driven
//                      DUT instantiation; defaults are SU_MODE_EN=1,
//                      NUM_HARTS=1. The sim-sweep runner overrides them
//                      via -D flags (ACLINT_NUM_HARTS=N, ACLINT_SU_MODE_EN=0/1).
//                      Drives the AHB master, generates the async LF clock +
//                      reset, and `includes the selected stimulus file
//                      (symlinked as stimulus.v by the runner).
//----------------------------------------------------------------------------
`include "timescale.v"

// Parameter overrides from the sweep runner (or test) -- consumed at the
// `parameter` declarations below. Defaults match the "all features on,
// single hart" build that the default `./run` exercises.
`ifndef ACLINT_NUM_HARTS
   `define ACLINT_NUM_HARTS  1
`endif
`ifndef ACLINT_SU_MODE_EN
   `define ACLINT_SU_MODE_EN 1
`endif
`ifndef ACLINT_PRIV_CHECK_EN
   `define ACLINT_PRIV_CHECK_EN 1
`endif
`ifndef ACLINT_LF_HALF_PERIOD
   `define ACLINT_LF_HALF_PERIOD 250
`endif

// Ratio helpers
`define LF_RATIO         (`ACLINT_LF_HALF_PERIOD / 25)
`define LF_CYCLES(n)     ((n) * `LF_RATIO)

// LF_SYNC_EN: 0 = clk_lf is a real independent oscillator (default);
// 1 = synchronous mode: clk_lf is still the timebase source, but the IP samples
// it as data and clocks every flop from hclk_aon instead.
`ifndef ACLINT_LF_SYNC_EN
   `define ACLINT_LF_SYNC_EN 0
`endif

`ifndef ACLINT_ASYNC_RST_EN
   `define ACLINT_ASYNC_RST_EN 1
`endif

module  tb_ahb_aclint;

// DUT parameters (driven from the `defines above so the sweep runner can
// override each independently).
parameter NUM_HARTS     = `ACLINT_NUM_HARTS;
parameter SU_MODE_EN    = `ACLINT_SU_MODE_EN;
parameter PRIV_CHECK_EN = `ACLINT_PRIV_CHECK_EN;
parameter LF_SYNC_EN    = `ACLINT_LF_SYNC_EN;
parameter ASYNC_RST_EN  = `ACLINT_ASYNC_RST_EN;

//
// Wire & Register definition
//------------------------------

// Clock / Reset (AHB / hclk domain)
reg                  hresetn;
wire                 free_clk;
wire                 hclk_aon_en;   // oscillator's own enable view -> DUT hclk_aon_en_i   // driven by u_aon_osc (the always-on oscillator)
wire                 hclk;
wire                 hclk_aon;
wire                 hclk_en;

// Clock / Reset (Low-frequency / always-on domain)
reg                  clk_lf;
integer              lf_high_period;   // high-phase width in ns; defaults to a 50% duty cycle
reg                  resetn_lf;
reg                  scan_mode = 1'b0;   // DUT scan_mode_i; only scan-mode tests set it

// AHB Subordinate Interface (master-side regs)
reg           [31:0] haddr;
reg            [3:0] hprot;   // Wired to the DUT for PRIV_CHECK_EN; BFM tasks drive {priv,0,0,0}=0x2 for MACHINE.
wire                 hready;
reg            [2:0] hsize;
reg                  hsmode;  // Wired to the DUT for PRIV_CHECK_EN; BFM tasks drive 0 for MACHINE, 1 for SUPERVISOR.
reg            [1:0] htrans;
reg           [31:0] hwdata;
reg                  hwrite;
wire          [31:0] hrdata;
wire                 hreadyout;
wire                 hresp;
wire                 hsel;

// DUT IRQ outputs (sized by NUM_HARTS)
wire [NUM_HARTS-1:0] irq_m_software;
wire [NUM_HARTS-1:0] irq_m_timer;
wire                 mtimer_wake_lf;   // single bit: any hart (OR of the per-hart LF comparators)
wire [NUM_HARTS-1:0] irq_s_software;

// Zicntr time-port (driven by the zicntr BFM; observed by the scoreboard)
reg                  time_req;
wire                 time_gnt;
wire          [63:0] time_val;

// Fabric-side wait-state injection: when high, holds hready_i low to model an
// AHB interconnect stall. Default 0 -> hready follows hreadyout exactly, so
// existing tests are byte-identical. Driven by the ahb_wait_states test.
reg                  tb_force_stall;

// Testbench variables
integer              tb_idx;
integer              tmp_seed;
integer              error;
reg                  stimulus_done;


//
// Include files
//------------------------------

// Verilog tasks & stimulus
`include "ahb_tasks.v"
`include "stimulus.v"

// Always-on passive output scoreboard + homegrown functional coverage.
`include "scoreboard.v"
`include "cover_monitor.v"


//
// Generate Clock & Reset
//------------------------------

// THE ALWAYS-ON OSCILLATOR.
reg  allow_deep_sleep;
initial allow_deep_sleep = 1'b0;

wire osc_enable = hclk_en | ~allow_deep_sleep;

// The oscillator and its controller, wired as a SoC would: the model only
// toggles, and arv_osc_ctrl -- the same synthesizable block an integrator uses --
// owns the stop sequence, so hclk_aon_en falls exactly one edge before the clock
// does.
wire osc_run;

// ACLINT_OSC_ZERO_EDGE models an oscillator controller that violates the
// hclk_aon_en_i contract: the oscillator stops on the announce itself, so no edge
// is delivered with hclk_aon_en low (see mtimer_deep_sleep_zero_edge).
`ifdef ACLINT_OSC_ZERO_EDGE
wire osc_en_model = osc_run & hclk_aon_en;
`else
wire osc_en_model = osc_run;
`endif

osc #(.HALF_PERIOD(25)) u_aon_osc (      // 20 MHz
    .en_i      ( osc_en_model   ),
    .clk_o     ( free_clk       )
);

arv_osc_ctrl u_aon_osc_ctrl (
    .osc_clk_i ( free_clk       ),
    .osc_en_o  ( osc_run        ),
    .resetn_i  ( hresetn        ),
    .scan_mode_i ( 1'b0         ),
    .wake_i    ( mtimer_wake_lf ),
    .enable_i  ( osc_enable     ),
    .clk_en_o  ( hclk_aon_en    )
);

// hclk_aon_i IS the oscillator -- not a gated copy of it.
assign hclk_aon = free_clk;

// SoC-side ICG model.
reg hclk_en_latch;
reg icg_ignore_reset;
initial icg_ignore_reset = 1'b0;

always @(free_clk or hclk_en or hresetn or icg_ignore_reset)
  if (~free_clk) hclk_en_latch <= icg_ignore_reset ? hclk_en              // integrator omitted it
                                                  : (hclk_en | ~hresetn); // CRG holds the clock running during reset
assign hclk = (hclk_aon & hclk_en_latch);

// Reset width. An ASYNC_RST_EN=0 build reaches its reset values only on clock
// edges, so each reset has to span at least two edges of the clock that samples
// it -- the IP states that for the LF side as a hard integration constraint. The
// fixed 593 ns floor covers it at a short LF period, but not at a realistic
// crystal ratio where one clk_lf period is longer than the whole pulse, so the
// width is the larger of 593 ns and two LF periods.
localparam integer LF_PERIOD = 2 * `ACLINT_LF_HALF_PERIOD;
localparam integer RST_WIDTH = (593 > 2*LF_PERIOD) ? 593 : 2*LF_PERIOD;

// Reset generation (hclk domain)
initial
  begin
     hresetn       = 1'b1;
     #93;
     hresetn       = 1'b0;
     #(RST_WIDTH);
     hresetn       = 1'b1;
  end

// Low-frequency clock. Half-period is `ACLINT_LF_HALF_PERIOD ns (default 250,
// i.e. 2 MHz / 500 ns against the 20 MHz free_clk -- a 10:1 ratio). Phase-shift
// by a small offset relative to free_clk so the two clocks are demonstrably
// asynchronous.
// The HIGH phase is separately controllable so a test can distort the duty
// cycle. That matters because clk_lf is sampled AS DATA: what has to survive two
// hclk_aon edges is each PHASE, not the period, so a 50% duty cycle is the
// easy case and a lopsided one is where the tick detector actually breaks.
initial
  begin
     clk_lf         = 1'b0;
     lf_high_period = `ACLINT_LF_HALF_PERIOD;
     #7;
     forever
       begin
          #(2 * `ACLINT_LF_HALF_PERIOD - lf_high_period);
          clk_lf = 1'b1;
          #(lf_high_period);
          clk_lf = 1'b0;
       end
  end

// clk_lf is driven identically in BOTH modes: it is the timebase source either
// way, and under LF_SYNC_EN the IP simply samples it instead of clocking flops
// with it. Only resetn_lf changes -- it has no consumer in synchronous mode, so
// tie it high there to prove the RTL really does not use it.
wire resetn_lf_dut = (LF_SYNC_EN != 0) ? 1'b1 : resetn_lf;

// Low-frequency reset. Pulse shape matches hresetn but is offset a few ns
// so the LF reset deasserts after clk_lf is already toggling.
initial
  begin
     resetn_lf = 1'b1;
     #117;
     resetn_lf = 1'b0;
     #(RST_WIDTH + 24);
     resetn_lf = 1'b1;
  end

`ifdef ARV_COV_RESET_ZERO
// Coverage counts start once both power-on resets are released: the Verilator coverage
// flow starts every flop at 1 so the asynchronous resets see an edge, and the reset
// driving them to 0 would otherwise count as a toggle of every bit.
initial begin
    fork
        begin @(negedge hresetn);   @(posedge hresetn);   end
        begin @(negedge resetn_lf); @(posedge resetn_lf); end
    join
    $c("Verilated::threadContextp()->coveragep()->zero();");
end
`endif

// Variables initialization
initial
  begin
     tmp_seed      = `SEED;
     tmp_seed      = $urandom(tmp_seed);
     error         = 0;
     stimulus_done = 0;

     haddr         = 32'h00000000;
     hprot         =  4'h0;
     hsmode        =  1'b0;
     hsize         =  3'h0;
     htrans        =  2'h0;
     hwdata        = 32'h00000000;
     hwrite        =  1'h0;

     time_req      =  1'b0;
     tb_force_stall = 1'b0;
  end

// Every input the bench drives reaches the DUT 1 ns after the bench sets it. Tests
// assign inputs right after `@(posedge free_clk)`, in the same time step as the edge
// the DUT samples on; without the delay which value the DUT sees depends on the
// simulator's process order (Icarus and Verilator differ). hready stays combinational:
// AHB requires it in the same cycle as hreadyout.
wire          [31:0] haddr_d;
wire           [1:0] htrans_d;
wire                 hwrite_d;
wire           [2:0] hsize_d;
wire           [3:0] hprot_d;
wire                 hsmode_d;
wire          [31:0] hwdata_d;
wire                 time_req_d;
wire                 scan_mode_d;
wire                 hresetn_d;
wire                 resetn_lf_dut_d;
wire                 tb_force_stall_d;
assign #1 haddr_d          = haddr;
assign #1 htrans_d         = htrans;
assign #1 hwrite_d         = hwrite;
assign #1 hsize_d          = hsize;
assign #1 hprot_d          = hprot;
assign #1 hsmode_d         = hsmode;
assign #1 hwdata_d         = hwdata;
assign #1 time_req_d       = time_req;
assign #1 scan_mode_d      = scan_mode;
assign #1 hresetn_d        = hresetn;
assign #1 resetn_lf_dut_d  = resetn_lf_dut;
assign #1 tb_force_stall_d = tb_force_stall;

assign hready = hreadyout & ~tb_force_stall_d;
// 64KB-aligned base for hsel decode. Tests issue accesses at 0x0040_xxxx.
assign hsel   = (haddr_d[31:16] == 16'h0040);


//
// AHB ACLINT INSTANCE
//----------------------------------
ahb_aclint #(
    .SU_MODE_EN        ( SU_MODE_EN             ),
    .NUM_HARTS         ( NUM_HARTS              ),
    .PRIV_CHECK_EN     ( PRIV_CHECK_EN          ),
    .LF_SYNC_EN        ( LF_SYNC_EN             ),
    .ASYNC_RST_EN      ( ASYNC_RST_EN           )
) dut (

// AHB CLOCK, RESET & WKUP (hclk_i gated by hclk_en_o, hclk_aon_i always-on)
    .hclk_i            ( hclk                   ),
    .hclk_aon_i        ( hclk_aon               ),
    .hresetn_i         ( hresetn_d              ),
    .hclk_en_o         ( hclk_en                ),
    .mtimer_wake_lf_o  ( mtimer_wake_lf         ),

// LOW-FREQUENCY CLOCK & RESET
    .clk_lf_i          ( clk_lf                 ),
    .resetn_lf_i       ( resetn_lf_dut_d        ),
    .hclk_aon_en_i     ( hclk_aon_en            ),
    .scan_mode_i       ( scan_mode_d            ),   // functional mode unless a test sets it

// AHB-LITE SLAVE INTERFACE
    .hsel_i            ( hsel                   ),
    .haddr_i           ( haddr_d[15:0]          ),
    .hwrite_i          ( hwrite_d               ),
    .hsize_i           ( hsize_d                ),
    .htrans_i          ( htrans_d               ),
    .hprot_i           ( hprot_d                ),
    .hsmode_i          ( hsmode_d               ),
    .hready_i          ( hready                 ),
    .hwdata_i          ( hwdata_d               ),
    .hrdata_o          ( hrdata                 ),
    .hreadyout_o       ( hreadyout              ),
    .hresp_o           ( hresp                  ),

// PER-HART INTERRUPTS
    .irq_m_software_o  ( irq_m_software         ),
    .irq_m_timer_o     ( irq_m_timer            ),
    .irq_s_software_o  ( irq_s_software         ),

// ZICNTR TIME INTERFACE
    .time_req_i        ( time_req_d             ),
    .time_gnt_o        ( time_gnt               ),
    .time_val_o        ( time_val               )
);


//
// SIM-ONLY MTIME SNAPSHOT MIRROR (testbench observability)
//----------------------------------
// Reconstructs the 64-bit AHB MTIME snapshot exactly as the design's atomic-read
// latch captures it: mtime_rd_src sampled on an AHB MTIME_LO read while the
// mirror is valid -- the same strobe that loads the RTL's production
// u_mtime_shadow_ahb_hi register. The read source is mtime_rd_src, which is the
// mirror normally and the pending write value while an MTIME load is still
// outstanding, so this tracks read-after-write exactly as the design does.
// Probed here from the testbench so no simulation-only flop has to live inside
// the synthesizable design. Tests read the full 64-bit value via
// tb_ahb_aclint.mtime_shadow_ahb_sim.
reg [63:0] mtime_shadow_ahb_sim;
always @(posedge hclk or negedge hresetn)
  if (~hresetn)
    mtime_shadow_ahb_sim <= 64'h0;
  else if (dut.u_mtimer.ahb_mtime_lo_read & dut.u_mtimer.mirror_valid)
    mtime_shadow_ahb_sim <= dut.u_mtimer.mtime_rd_src;


//
// Generate Waveform
//----------------------------------------
initial
  begin
   `ifdef NODUMP
   `else
     `ifdef VPD_FILE
        $vcdplusfile("tb_ahb_aclint.vpd");
        $vcdpluson();
     `else
       `ifdef TRN_FILE
          $recordfile ("tb_ahb_aclint.trn");
          $recordvars;
       `else
          $dumpfile("tb_ahb_aclint.vcd");
          $dumpvars(0, tb_ahb_aclint);
       `endif
     `endif
   `endif
  end


//
// End of simulation
//----------------------------------------

initial // Timeout
  begin
   `ifdef NO_TIMEOUT
   `else
     // Scaled by the clk_lf ratio
     `ifdef VERY_LONG_TIMEOUT
       #(500000000 * `LF_RATIO / 4);
     `else
     `ifdef LONG_TIMEOUT
       #(5000000   * `LF_RATIO / 4);
     `else
       #(500000    * `LF_RATIO / 4);
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
     $finish;
  end


//
// Tasks Definition
//------------------------------

   task tb_error;
      input [65*8:0] error_string;
      begin
         $display("ERROR: %s %t", error_string, $time);
         error = error+1;
      end
   endtask

   task tb_extra_report;
      begin
         $display("");
         scoreboard_report;
         cover_report;
         $display("");
         $display("SIMULATION SEED: %d", `SEED);
         $display("");
      end
   endtask

   task tb_skip_finish;
      input [65*8-1:0] skip_string;
      begin
         $display(" ===============================================");
         $display("|               SIMULATION SKIPPED              |");
         $display("%s", skip_string);
         $display(" ===============================================");
         $display("");
         tb_extra_report;
         $finish;
      end
   endtask


endmodule
