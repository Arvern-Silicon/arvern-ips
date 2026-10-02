//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tb_ahb_rom_controller
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tb_ahb_rom_controller.v
// Module Description : AHB ROM Controller testbench.
//----------------------------------------------------------------------------
`include "timescale.v"

module  tb_ahb_rom_controller;

//
// Wire & Register definition
//------------------------------

// ROM size in bytes. Overridable at compile time via `-D MEM_SIZE=<n>`.
`ifndef MEM_SIZE
  `define MEM_SIZE 2048
`endif
parameter            MEM_SIZE  = `MEM_SIZE;             // Size of the memory instance (in Bytes)
parameter            MEM_ADDRW = $clog2(MEM_SIZE)-2;    // Address width of the memory instance (32b words)
parameter            HADDRW    = $clog2(MEM_SIZE);      // Address width of the AHB interface (8b words)

// Reset architecture under test (1=async active-low [default], 0=synchronous).
// Overridable at compile time via `-D ASYNC_RST_EN=0` (see SIM_EXTRA_DEFINES).
`ifndef ASYNC_RST_EN
  `define ASYNC_RST_EN 1
`endif
parameter            ASYNC_RST_EN = `ASYNC_RST_EN;

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

// ROM Interface
wire [MEM_ADDRW-1:0] rom_addr;
wire                 rom_cen;
wire                 rom_clk;
wire          [31:0] rom_dout;


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
       rom_inst.mem[tb_idx] = 32'h00000000;
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
     hresetn        = 1'b1;
     #93;
     hresetn        = 1'b0;
     #593;
     hresetn        = 1'b1;
  end

// Variables initialization
initial
  begin
     tmp_seed           = `SEED;
     tmp_seed           = $urandom(tmp_seed);
     error              = 0;
     stimulus_done      = 0;

     haddr              = 32'h00000000;
     hsize              =  3'h0;
     htrans             =  2'h0;
     hwdata             = 32'h00000000;
     hwrite             =  1'h0;
     tb_hready_stall    =  1'b0;

  end

// tb_hready_stall models another subordinate holding the shared bus: hready
// is low while this one has no data phase in flight (a test raises it only
// then).
reg tb_hready_stall;
assign hready = hreadyout & ~tb_hready_stall;
assign hsel   = (haddr>=32'h00400000) & (haddr<(32'h00400000+MEM_SIZE));


//
// AHB FABRIC
//----------------------------------

// Bus inputs reach the DUT 1 ns after the tasks drive them: a task started on a clock
// edge would otherwise race the DUT's flops (the simulators order it differently).
// hready keeps the DUT's own hreadyout same-cycle; only the bench's stall is delayed.
wire             [31:0] haddr_d;
wire              [2:0] hsize_d;
wire              [1:0] htrans_d;
wire             [31:0] hwdata_d;
wire                    hwrite_d;
wire                    hsel_d;
wire                    tb_hready_stall_d;
wire                    hready_d;
assign #1 haddr_d           = haddr;
assign #1 hsize_d           = hsize;
assign #1 htrans_d          = htrans;
assign #1 hwdata_d          = hwdata;
assign #1 hwrite_d          = hwrite;
assign #1 hsel_d            = hsel;
assign #1 tb_hready_stall_d = tb_hready_stall;
assign    hready_d          = hreadyout & ~tb_hready_stall_d;

ahb_rom_controller #(.MEM_SIZE(MEM_SIZE), .ASYNC_RST_EN(ASYNC_RST_EN)) ahb_rom_controller_inst0 (

// AHB CLOCK & RESET
    .hclk_i               ( hclk                 ),
    .hresetn_i            ( hresetn              ),
    .hclk_en_o            ( hclk_en              ),

// AHB INTERFACE
    .haddr_i              ( haddr_d[HADDRW-1:0]  ),
    .hready_i             ( hready_d             ),
    .hsize_i              ( hsize_d              ),
    .htrans_i             ( htrans_d             ),
    .hwdata_i             ( hwdata_d             ),
    .hwrite_i             ( hwrite_d             ),
    .hsel_i               ( hsel_d               ),
    .hrdata_o             ( hrdata               ),
    .hreadyout_o          ( hreadyout            ),
    .hresp_o              ( hresp                ),

// ROM INTERFACE
    .rom_dout_i           ( rom_dout             ),
    .rom_addr_o           ( rom_addr             ),
    .rom_cen_o            ( rom_cen              ),
    .rom_clk_o            ( rom_clk              )
);


//
// Memory #0
//----------------------------------

rom #(MEM_ADDRW, MEM_SIZE) rom_inst (
    .rom_addr_i           ( rom_addr             ),   // Memory address
    .rom_cen_i            ( rom_cen              ),   // Memory chip enable (low active)
    .rom_clk_i            ( rom_clk              ),   // Memory clock
    .rom_dout_o           ( rom_dout             )    // Memory data output
);


//
// Generate Waveform
//----------------------------------------
initial
  begin
   `ifdef NODUMP
   `else
     `ifdef VPD_FILE
        $vcdplusfile("tb_ahb_rom_controller.vpd");
        $vcdpluson();
     `else
       `ifdef TRN_FILE
          $recordfile ("tb_ahb_rom_controller.trn");
          $recordvars;
       `else
          $dumpfile("tb_ahb_rom_controller.vcd");
          $dumpvars(0, tb_ahb_rom_controller);
       `endif
     `endif
   `endif
  end


`ifdef ARV_COV_RESET_ZERO
// Coverage counts start once reset is released: the Verilator coverage flow starts
// every flop at 1 so the asynchronous resets see an edge, and the reset driving them
// to 0 would otherwise count as a toggle of every bit.
initial begin
    wait (hresetn === 1'b0);
    @(posedge hresetn);
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
        if (rom_inst.mem[address] !== expected_value) begin
          $display("ERROR: Memory check   -- address: 0x%h -- read: 0x%h / expected: 0x%h %t ns", address, rom_inst.mem[address], expected_value, $time); 
          error = error+1;
        end else begin
          $display("PASS:  Memory check   -- address: 0x%h -- value: 0x%h %t ns", address, rom_inst.mem[address], $time);
        end
      end
   endtask


//
// Bus monitor (sampled mid-cycle, where every signal is stable)
//------------------------------------------------------------------
// Every data phase is checked against the AHB-Lite protocol this IP implements:
// a read data phase is a zero-wait OKAY; a write data phase is the two-cycle
// ERROR (hreadyout 0 then 1, hresp high in both); no ERROR without a write;
// hrdata is 0 outside a read data phase (the ROM model drives a poison word
// then); the clock enable is low on an idle cycle.
reg     mon_rd;       // this cycle is a read data phase
reg     mon_p1;       // this cycle is the first ERROR cycle of a write
reg     mon_p2;       // this cycle is the second ERROR cycle
reg     mon_aph;
reg     mon_armed;    // outputs are defined only once the first reset completes
initial begin mon_rd = 0; mon_p1 = 0; mon_p2 = 0; mon_armed = 0; end
always @(posedge hresetn) mon_armed = 1'b1;

always @(negedge free_clk) begin
   if (!hresetn || !mon_armed) begin
      mon_rd <= 1'b0; mon_p1 <= 1'b0; mon_p2 <= 1'b0;
   end else begin
      mon_aph = hsel & hready & htrans[1];
      if (mon_rd && !(hreadyout === 1'b1 && hresp === 1'b0)) begin
         $display("ERROR: MONITOR read data phase not a zero-wait OKAY (hreadyout=%b hresp=%b) %t ns", hreadyout, hresp, $time);
         error = error + 1;
      end
      if (mon_p1 && !(hreadyout === 1'b0 && hresp === 1'b1)) begin
         $display("ERROR: MONITOR write: expected ERROR cycle 1 (hreadyout=%b hresp=%b) %t ns", hreadyout, hresp, $time);
         error = error + 1;
      end
      if (mon_p2 && !(hreadyout === 1'b1 && hresp === 1'b1)) begin
         $display("ERROR: MONITOR write: expected ERROR cycle 2 (hreadyout=%b hresp=%b) %t ns", hreadyout, hresp, $time);
         error = error + 1;
      end
      if (!mon_p1 && !mon_p2 && (hresp !== 1'b0)) begin
         $display("ERROR: MONITOR hresp high outside a write ERROR %t ns", $time);
         error = error + 1;
      end
      if (!mon_rd && (hrdata !== 32'h0)) begin
         $display("ERROR: MONITOR hrdata=%h outside a read data phase %t ns", hrdata, $time);
         error = error + 1;
      end
      if (!mon_aph && !mon_rd && !mon_p1 && !mon_p2 && (hclk_en !== 1'b0)) begin
         $display("ERROR: MONITOR hclk_en high on an idle cycle %t ns", $time);
         error = error + 1;
      end
      mon_p2 <= mon_p1;
      mon_p1 <= mon_aph &  hwrite;
      mon_rd <= mon_aph & ~hwrite;
   end
end

endmodule
