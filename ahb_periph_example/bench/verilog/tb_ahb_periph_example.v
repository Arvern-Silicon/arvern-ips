//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tb_ahb_periph_example
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tb_ahb_periph_example.v
// Module Description : AHB Peripheral example testbench.
//----------------------------------------------------------------------------
`include "timescale.v"

// Reset architecture select (1=async [default], 0=sync). Build-time overridable
// via `-D ASYNC_RST_EN=0` to exercise the DUT's synchronous-reset path.
`ifndef ASYNC_RST_EN
 `define ASYNC_RST_EN 1
`endif

module  tb_ahb_periph_example;

//
// Wire & Register definition
//------------------------------

parameter            ASYNC_RST_EN = `ASYNC_RST_EN;  // Reset style: 1=asynchronous active-low, 0=synchronous

// Clock / Reset
reg                  hresetn;
reg                  free_clk;
wire                 hclk;
wire                 hclk_en;

// AHB Subordinate Interface
reg           [31:0] haddr;
reg            [3:0] hprot;
wire                 hready;
reg            [2:0] hsize;
reg                  hsmode;
reg            [1:0] htrans;
reg           [31:0] hwdata;
reg                  hwrite;
wire          [31:0] hrdata;
wire                 hreadyout;
wire                 hresp;
wire                 hsel;

// Peripheral Interface
wire          [31:0] periph0_reg_00_out;
wire          [31:0] periph0_reg_01_out;
wire          [31:0] periph0_reg_02_out;
wire          [31:0] periph0_reg_03_out;
wire          [31:0] periph0_reg_04_out;
wire          [31:0] periph0_reg_05_out;
wire          [31:0] periph0_reg_06_out;
wire          [31:0] periph0_reg_07_out;
reg           [31:0] periph0_reg_08_in;
reg           [31:0] periph0_reg_09_in;
reg           [31:0] periph0_reg_10_in;
reg           [31:0] periph0_reg_11_in;
reg           [31:0] periph0_reg_12_in;
reg           [31:0] periph0_reg_13_in;
reg           [31:0] periph0_reg_14_in;
reg           [31:0] periph0_reg_15_in;

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
// Initialize Registers
//------------------------------
initial
  begin
    periph0_reg_08_in = 32'h00000000 ;
    periph0_reg_09_in = 32'h00000000 ;
    periph0_reg_10_in = 32'h00000000 ;
    periph0_reg_11_in = 32'h00000000 ;
    periph0_reg_12_in = 32'h00000000 ;
    periph0_reg_13_in = 32'h00000000 ;
    periph0_reg_14_in = 32'h00000000 ;
    periph0_reg_15_in = 32'h00000000 ;
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
     hprot  =  4'h0;
     hsmode =  1'b0;
     hsize  =  3'h0;
     htrans =  2'h0;
     hwdata = 32'h00000000;
     hwrite =  1'h0;
  end

assign hready = hreadyout;
assign hsel   = (haddr>=32'h00400000) & (haddr<32'h00400080);


//
// AHB PERIPHERAL INSTANCE
//----------------------------------
ahb_periph_example #(.ASYNC_RST_EN(ASYNC_RST_EN)) ahb_periph_example_inst0 (

// AHB CLOCK & RESET
    .hclk_i            ( hclk                   ),
    .hresetn_i         ( hresetn                ),
    .hclk_en_o         ( hclk_en                ),

// AHB INTERFACE
    .haddr_i           ( haddr[6:0]             ),
    .hprot_i           ( hprot                  ),
    .hready_i          ( hready                 ),
    .hsmode_i          ( hsmode                 ),
    .hsize_i           ( hsize                  ),
    .htrans_i          ( htrans                 ),
    .hwdata_i          ( hwdata                 ),
    .hwrite_i          ( hwrite                 ),
    .hsel_i            ( hsel                   ),
    .hrdata_o          ( hrdata                 ),
    .hreadyout_o       ( hreadyout              ),
    .hresp_o           ( hresp                  ),

// REGISTERS
    .register_00_o     ( periph0_reg_00_out     ),
    .register_01_o     ( periph0_reg_01_out     ),
    .register_02_o     ( periph0_reg_02_out     ),
    .register_03_o     ( periph0_reg_03_out     ),
    .register_04_o     ( periph0_reg_04_out     ),
    .register_05_o     ( periph0_reg_05_out     ),
    .register_06_o     ( periph0_reg_06_out     ),
    .register_07_o     ( periph0_reg_07_out     ),

    .register_08_i     ( periph0_reg_08_in      ),
    .register_09_i     ( periph0_reg_09_in      ),
    .register_10_i     ( periph0_reg_10_in      ),
    .register_11_i     ( periph0_reg_11_in      ),
    .register_12_i     ( periph0_reg_12_in      ),
    .register_13_i     ( periph0_reg_13_in      ),
    .register_14_i     ( periph0_reg_14_in      ),
    .register_15_i     ( periph0_reg_15_in      )
 );


//
// Generate Waveform
//----------------------------------------
initial
  begin
   `ifdef NODUMP
   `else
     `ifdef VPD_FILE
        $vcdplusfile("tb_ahb_periph_example.vpd");
        $vcdpluson();
     `else
       `ifdef TRN_FILE
          $recordfile ("tb_ahb_periph_example.trn");
          $recordvars;
       `else
          $dumpfile("tb_ahb_periph_example.vcd");
          $dumpvars(0, tb_ahb_periph_example);
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

   task check_reg_value;
      input integer reg_number;
      input integer expected_value;
        
      reg [511:0] formatted_string;
      reg  [31:0] selected_reg;
      begin
        #1;
        case (reg_number)
           0: selected_reg = periph0_reg_00_out;
           1: selected_reg = periph0_reg_01_out;
           2: selected_reg = periph0_reg_02_out;
           3: selected_reg = periph0_reg_03_out;
           4: selected_reg = periph0_reg_04_out;
           5: selected_reg = periph0_reg_05_out;
           6: selected_reg = periph0_reg_06_out;
           7: selected_reg = periph0_reg_07_out;
           8: selected_reg = periph0_reg_08_in ;
           9: selected_reg = periph0_reg_09_in ;
          10: selected_reg = periph0_reg_10_in ;
          11: selected_reg = periph0_reg_11_in ;
          12: selected_reg = periph0_reg_12_in ;
          13: selected_reg = periph0_reg_13_in ;
          14: selected_reg = periph0_reg_14_in ;
          15: selected_reg = periph0_reg_15_in ; 
          default: begin
              selected_reg = 32'h00000000;
          end
        endcase

        if (selected_reg !== expected_value) begin
          $display("ERROR: Memory check   -- reg_number: %d -- read: 0x%h / expected: 0x%h %t ns", reg_number, selected_reg, expected_value, $time); 
          error = error+1;
        end else begin
          $display("PASS:  Memory check   -- reg_number: %d -- value: 0x%h %t ns", reg_number, selected_reg, $time);
        end
      end
   endtask

   task set_regin_value;
      input integer regin_number;
      input integer value;
        
      begin
        #1;
        case (regin_number)
           8: periph0_reg_08_in = value;
           9: periph0_reg_09_in = value;
          10: periph0_reg_10_in = value;
          11: periph0_reg_11_in = value;
          12: periph0_reg_12_in = value;
          13: periph0_reg_13_in = value;
          14: periph0_reg_14_in = value;
          15: periph0_reg_15_in = value; 
          default: begin
          end
        endcase
      end
   endtask


endmodule
