//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tb_ahb_sram_controller
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tb_ahb_sram_controller.v
// Module Description : AHB SRAM Controller testbench.
//----------------------------------------------------------------------------
`include "timescale.v"

// Reset architecture select (1=async [default], 0=sync). Build-time overridable
// via `-D ASYNC_RST_EN=0` to exercise the DUT's synchronous-reset path.
`ifndef ASYNC_RST_EN
 `define ASYNC_RST_EN 1
`endif

module  tb_ahb_sram_controller;

//
// Wire & Register definition
//------------------------------

parameter            MEM_SIZE     = 2048;               // Size of the memory instance (in Bytes)
parameter            MEM_ADDRW    = $clog2(MEM_SIZE)-2; // Address width of the memory instance (32b words)
parameter            HADDRW       = $clog2(MEM_SIZE);   // Address width of the AHB interface (8b words)
parameter            ASYNC_RST_EN = `ASYNC_RST_EN;      // Reset style: 1=asynchronous active-low, 0=synchronous

// Clock / Reset
reg                  hresetn;
reg                  free_clk;
wire                 hclk;
wire                 hclk_en;

// AHB Subordinate Interface
reg           [31:0] haddr;
wire                 hready;
reg            [2:0] hsize;
reg            [1:0] htrans;
reg           [31:0] hwdata;
reg                  hwrite;
wire          [31:0] hrdata;
wire                 hreadyout;
wire                 hresp;
wire                 hsel;

// SRAM Interface
wire [MEM_ADDRW-1:0] sram_addr;
wire                 sram_cen;
wire                 sram_clk;
wire          [31:0] sram_din;
wire           [3:0] sram_wen;
wire          [31:0] sram_dout;

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


//
// Initialize Memory
//------------------------------
initial
  begin
     // Initialize memory instances
     for (tb_idx=0; tb_idx < MEM_SIZE/4; tb_idx=tb_idx+1)
       sram_inst.mem[tb_idx] = 32'h00000000;
  end


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

// Gated Clock for the Fabric
reg hclk_en_latch;
always @(free_clk or hclk_en or hresetn)
  if (~free_clk)
    hclk_en_latch <= hclk_en | ~hresetn;  // CRG holds the clock running during reset (sync-reset init contract)
assign  hclk  =  (free_clk & hclk_en_latch);

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
     hwdata = 32'h00000000;
     hwrite =  1'h0;
  end

assign hready = hreadyout;
assign hsel   = (haddr>=32'h00400000) & (haddr<(32'h00400000+MEM_SIZE));


//
// AHB FABRIC
//----------------------------------

ahb_sram_controller #(.MEM_SIZE(MEM_SIZE), .ASYNC_RST_EN(ASYNC_RST_EN)) ahb_sram_controller_inst0 (

// AHB CLOCK & RESET
    .hclk_i            ( hclk                 ),
    .hresetn_i         ( hresetn              ),
    .hclk_en_o         ( hclk_en              ),

// AHB INTERFACE
    .haddr_i           ( haddr[HADDRW-1:0]    ),
    .hready_i          ( hready               ),
    .hsize_i           ( hsize                ),
    .htrans_i          ( htrans               ),
    .hwdata_i          ( hwdata               ),
    .hwrite_i          ( hwrite               ),
    .hsel_i            ( hsel                 ),
    .hrdata_o          ( hrdata               ),
    .hreadyout_o       ( hreadyout            ),
    .hresp_o           ( hresp                ),

// SRAM INTERFACE
    .sram_dout_i       ( sram_dout            ),
    .sram_addr_o       ( sram_addr            ),
    .sram_cen_o        ( sram_cen             ),
    .sram_clk_o        ( sram_clk             ),
    .sram_din_o        ( sram_din             ),
    .sram_wen_o        ( sram_wen             )

);


//
// Memory #0
//----------------------------------

sram #(MEM_ADDRW, MEM_SIZE) sram_inst (
    .sram_addr_i       ( sram_addr            ),   // Memory address
    .sram_cen_i        ( sram_cen             ),   // Memory chip enable (low active)
    .sram_clk_i        ( sram_clk             ),   // Memory clock
    .sram_din_i        ( sram_din             ),   // Memory data input
    .sram_wen_i        ( sram_wen             ),   // Memory write enable (low active)
    .sram_dout_o       ( sram_dout            )    // Memory data output
);


//
// Generate Waveform
//----------------------------------------
initial
  begin
   `ifdef NODUMP
   `else
     `ifdef VPD_FILE
        $vcdplusfile("tb_ahb_sram_controller.vpd");
        $vcdpluson();
     `else
       `ifdef TRN_FILE
          $recordfile ("tb_ahb_sram_controller.trn");
          $recordvars;
       `else
          $dumpfile("tb_ahb_sram_controller.vcd");
          $dumpvars(0, tb_ahb_sram_controller);
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

   task check_mem_value;
      input integer address;
      input integer expected_value;

      reg [511:0] formatted_string;
      integer i;
      begin
        #1;
        if (sram_inst.mem[address] !== expected_value) begin
          $display("ERROR: Memory check   -- address: 0x%h -- read: 0x%h / expected: 0x%h %t ns", address, sram_inst.mem[address], expected_value, $time);
          error = error+1;
        end else begin
          $display("PASS:  Memory check   -- address: 0x%h -- value: 0x%h %t ns", address, sram_inst.mem[address], $time);
        end
      end
   endtask


endmodule
