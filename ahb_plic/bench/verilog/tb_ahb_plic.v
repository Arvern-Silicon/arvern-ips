//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tb_ahb_plic
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tb_ahb_plic.v
// Module Description : Block-level testbench for the ahb_plic PLIC IP.
//                      Parameter-driven DUT instantiation; defaults are
//                      NUM_SOURCES=31, NUM_HARTS=1, SU_MODE_EN=1,
//                      PRIO_BITS=3. The sim-sweep runner
//                      overrides them via -D flags (PLIC_NUM_SOURCES=N,
//                      PLIC_NUM_HARTS=N, PLIC_SU_MODE_EN=0/1,
//                      PLIC_PRIO_BITS=N). Drives the AHB master plus a
//                      per-source irq_src driver and per-hart MEXT/SEXT
//                      probes. The selected stimulus file is `included
//                      into the TB module body as stimulus.v (symlinked
//                      by runsim).
//----------------------------------------------------------------------------
`include "timescale.v"

// Parameter overrides from the sweep runner (or test) -- consumed at the
// `localparam` declarations below. Defaults match the "all features on,
// 1 hart, 31 sources, 3-bit priority" build that the default `./run`
// exercises.
`ifndef PLIC_NUM_SOURCES
   `define PLIC_NUM_SOURCES 31
`endif
`ifndef PLIC_NUM_HARTS
   `define PLIC_NUM_HARTS   1
`endif
`ifndef PLIC_SU_MODE_EN
   `define PLIC_SU_MODE_EN  1
`endif
`ifndef PLIC_PRIO_BITS
   `define PLIC_PRIO_BITS   3
`endif
`ifndef PLIC_PRIV_CHECK_EN
   `define PLIC_PRIV_CHECK_EN 1
`endif
`ifndef PLIC_ASYNC_RST_EN
   `define PLIC_ASYNC_RST_EN  1
`endif

module  tb_ahb_plic;

//
// DUT parameters (driven from the `defines above so the sweep runner can
// override each independently).
//------------------------------
localparam NUM_SOURCES         = `PLIC_NUM_SOURCES;
localparam NUM_HARTS           = `PLIC_NUM_HARTS;
localparam SU_MODE_EN          = `PLIC_SU_MODE_EN;
localparam PRIO_BITS           = `PLIC_PRIO_BITS;
localparam PRIV_CHECK_EN       = `PLIC_PRIV_CHECK_EN;
localparam ASYNC_RST_EN        = `PLIC_ASYNC_RST_EN;
localparam NUM_CONTEXTS        = SU_MODE_EN ? 2*NUM_HARTS : NUM_HARTS;


//
// Wire & Register definition
//------------------------------

// Clock / Reset
reg                          hresetn;
reg                          free_clk;
wire                         hclk;
wire                         hclk_en;       // From DUT (combinational hclk_en_o)

// AHB Subordinate Interface
reg                   [31:0] haddr;
wire                         hready;
reg                    [2:0] hsize;
reg                    [1:0] htrans;
reg                    [3:0] hprot;       // Driven by ahb_tasks per the `mode` argument
reg                          hsmode;      // Driven by ahb_tasks per the `mode` argument
reg                   [31:0] hwdata;
reg                          hwrite;
wire                  [31:0] hrdata;
wire                         hreadyout;
wire                         hresp;
wire                         hsel;

// PLIC Interface
reg     [NUM_SOURCES:0]      irq_src;
wire    [NUM_SOURCES:0]      irq_src_i;
wire    [NUM_HARTS-1:0]      irq_m_external;
wire    [NUM_HARTS-1:0]      irq_s_external;

assign irq_src_i = irq_src;

// Testbench variables
integer                      tb_idx;
integer                      tmp_seed;
integer                      error;
reg                          stimulus_done;


//
// Include files
//------------------------------

// Verilog tasks & stimulus
`include "ahb_tasks.v"
`include "stimulus.v"

// Always-on passive reference-model scoreboard + homegrown functional coverage.
`include "scoreboard.v"
`include "cover_monitor.v"


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

// SoC-side ICG model (latch-based, latches enable on the low phase of free_clk
// so glitches on hclk_en during the high phase don't corrupt the next edge).
// Matches the convention documented in arv_custom_csr and ahb_periph_example.
reg hclk_en_latch;
always @(free_clk or hclk_en or hresetn)
  if (~free_clk)
    hclk_en_latch <= hclk_en | ~hresetn;  // CRG holds the clock running during reset (sync-reset init contract)
assign hclk = (free_clk & hclk_en_latch);

// Reset generation
initial
  begin
     hresetn       = 1'b1;
     #93;
     hresetn       = 1'b0;
     #593;
     hresetn       = 1'b1;
  end

// Variables initialization
initial
  begin
     tmp_seed      = `SEED;
     tmp_seed      = $urandom(tmp_seed);
     error         = 0;
     stimulus_done = 0;

     haddr  = 32'h00000000;
     hsize  =  3'h0;
     htrans =  2'h0;
     hprot  =  4'h2;                       // Privileged (M-mode by default)
     hsmode =  1'b0;                       // 0 = machine when hprot[1]=1
     hwdata = 32'h00000000;
     hwrite =  1'h0;
     irq_src = {(NUM_SOURCES+1){1'b0}};
  end

assign hready = hreadyout;

// AHB slave decode: any access to the 4 MB window starting at 0x00400000
// is routed to the PLIC. The upper 10 bits of the 32-bit byte address
// select the slave; the low 22 bits are presented to the DUT's haddr_i.
assign hsel   = (haddr[31:22] == 10'h001);


//
// AHB PLIC INSTANCE
//----------------------------------
ahb_plic #(
    .NUM_SOURCES        ( NUM_SOURCES            ),
    .NUM_HARTS          ( NUM_HARTS              ),
    .SU_MODE_EN         ( SU_MODE_EN             ),
    .PRIO_BITS          ( PRIO_BITS              ),
    .PRIV_CHECK_EN      ( PRIV_CHECK_EN          ),
    .ASYNC_RST_EN       ( ASYNC_RST_EN           )
) dut (

// AHB CLOCK & RESET
    .hclk_i            ( hclk                   ),
    .hresetn_i         ( hresetn                ),

// AHB INTERFACE
    .hsel_i            ( hsel                   ),
    .haddr_i           ( haddr[21:0]            ),
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

// PLIC INTERFACE
    .irq_src_i         ( irq_src_i              ),
    .irq_m_external_o  ( irq_m_external         ),
    .irq_s_external_o  ( irq_s_external         ),
    .hclk_en_o         ( hclk_en                )
 );


//
// Generate Waveform
//----------------------------------------
initial
  begin
   `ifdef NODUMP
   `else
     `ifdef VPD_FILE
        $vcdplusfile("tb_ahb_plic.vpd");
        $vcdpluson();
     `else
       `ifdef TRN_FILE
          $recordfile ("tb_ahb_plic.trn");
          $recordvars;
       `else
          $dumpfile("tb_ahb_plic.vcd");
          $dumpvars(0, tb_ahb_plic);
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

   // Drive a single bit of the irq_src vector. Convenience helper for tests.
   task set_irq_src;
      input integer idx;
      input         val;
      begin
         if ((idx >= 0) && (idx <= NUM_SOURCES))
            irq_src[idx] = val;
      end
   endtask


endmodule
