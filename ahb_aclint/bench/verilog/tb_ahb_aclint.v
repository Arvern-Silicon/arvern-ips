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
`ifndef ACLINT_ASYNC_RST_EN
   `define ACLINT_ASYNC_RST_EN 1
`endif

module  tb_ahb_aclint;

// DUT parameters (driven from the `defines above so the sweep runner can
// override each independently).
parameter NUM_HARTS     = `ACLINT_NUM_HARTS;
parameter SU_MODE_EN    = `ACLINT_SU_MODE_EN;
parameter PRIV_CHECK_EN = `ACLINT_PRIV_CHECK_EN;
parameter ASYNC_RST_EN  = `ACLINT_ASYNC_RST_EN;

//
// Wire & Register definition
//------------------------------

// Clock / Reset (AHB / hclk domain)
reg                  hresetn;
reg                  free_clk;
wire                 hclk;
wire                 hclk_en;

// Clock / Reset (Low-frequency / always-on domain)
reg                  clk_lf;
reg                  resetn_lf;

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
wire [NUM_HARTS-1:0] mtimer_wake_lf;
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

// Free running clock - 20 MHz (period 50 ns = 2*25 ns)
initial
  begin
     free_clk  = 1'b0;
     forever
       begin
          #25;   // 20 MHz
          free_clk = ~free_clk;
       end
  end

// SoC-side ICG model
reg hclk_en_latch;
always @(free_clk or hclk_en or hresetn)
  if (~free_clk) hclk_en_latch <= hclk_en | ~hresetn;  // CRG holds the clock running during reset (sync-reset init contract)
assign hclk = (free_clk & hclk_en_latch);

// Reset generation (hclk domain)
initial
  begin
     hresetn       = 1'b1;
     #93;
     hresetn       = 1'b0;
     #593;
     hresetn       = 1'b1;
  end

// Low-frequency clock (5 MHz, period 200 ns = 2*100 ns). Phase-shift by
// a small offset relative to free_clk so the two clocks are demonstrably
// asynchronous.
initial
  begin
     clk_lf = 1'b0;
     #7;
     forever
       begin
          #100;
          clk_lf = ~clk_lf;
       end
  end

// Low-frequency reset. Pulse shape matches hresetn but is offset a few ns
// so the LF reset deasserts after clk_lf is already toggling.
initial
  begin
     resetn_lf = 1'b1;
     #117;
     resetn_lf = 1'b0;
     #617;
     resetn_lf = 1'b1;
  end

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

assign hready = hreadyout & ~tb_force_stall;
// 64KB-aligned base for hsel decode. Tests issue accesses at 0x0040_xxxx.
assign hsel   = (haddr[31:16] == 16'h0040);


//
// AHB ACLINT INSTANCE
//----------------------------------
ahb_aclint #(
    .SU_MODE_EN        ( SU_MODE_EN             ),
    .NUM_HARTS         ( NUM_HARTS              ),
    .PRIV_CHECK_EN     ( PRIV_CHECK_EN          ),
    .ASYNC_RST_EN      ( ASYNC_RST_EN           )
) dut (

// AHB CLOCK, RESET & WKUP (hclk_i gated by hclk_en_o, hclk_aon_i always-on)
    .hclk_i            ( hclk                   ),
    .hclk_aon_i        ( free_clk               ),
    .hresetn_i         ( hresetn                ),
    .hclk_en_o         ( hclk_en                ),
    .mtimer_wake_lf_o  ( mtimer_wake_lf         ),

// LOW-FREQUENCY CLOCK & RESET
    .clk_lf_i          ( clk_lf                 ),
    .resetn_lf_i       ( resetn_lf              ),

// AHB-LITE SLAVE INTERFACE
    .hsel_i            ( hsel                   ),
    .haddr_i           ( haddr[15:0]            ),
    .hwrite_i          ( hwrite                 ),
    .hsize_i           ( hsize                  ),
    .htrans_i          ( htrans                 ),
    .hprot_i           ( hprot                  ),
    .hsmode_i          ( hsmode                 ),
    .hready_i          ( hready                 ),
    .hwdata_i          ( hwdata                 ),
    .hrdata_o          ( hrdata                 ),
    .hreadyout_o       ( hreadyout              ),
    .hresp_o           ( hresp                  ),

// PER-HART INTERRUPTS
    .irq_m_software_o  ( irq_m_software         ),
    .irq_m_timer_o     ( irq_m_timer            ),
    .irq_s_software_o  ( irq_s_software         ),

// ZICNTR TIME INTERFACE
    .time_req_i        ( time_req               ),
    .time_gnt_o        ( time_gnt               ),
    .time_val_o        ( time_val               )
);


//
// SIM-ONLY MTIME SNAPSHOT MIRROR (testbench observability)
//----------------------------------
// Reconstructs the 64-bit AHB MTIME snapshot exactly as the design's atomic-read
// latch captures it: mtime_binary sampled on the cycle mtime_valid pulses while
// the read FSM is in its AHB-pending state -- the same strobe that loads the RTL's
// production u_mtime_shadow_ahb_hi register (FSM_AHB_PEND == 2'b01). Probed here
// from the testbench so no simulation-only flop has to live inside the synthesizable
// design. Tests read the full 64-bit value via tb_ahb_aclint.mtime_shadow_ahb_sim.
reg [63:0] mtime_shadow_ahb_sim;
always @(posedge hclk or negedge hresetn)
  if (~hresetn)
    mtime_shadow_ahb_sim <= 64'h0;
  else if (dut.u_mtimer.mtime_valid & (dut.u_mtimer.fsm_state == 2'b01))
    mtime_shadow_ahb_sim <= dut.u_mtimer.mtime_binary;


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
