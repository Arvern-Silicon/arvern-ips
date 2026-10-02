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

`ifndef MEM_SIZE
 `define MEM_SIZE 2048
`endif
parameter            MEM_SIZE     = `MEM_SIZE;          // Size of the memory instance (in Bytes); `-D MEM_SIZE=<n>`
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

// tb_hready_stall models another subordinate holding the shared bus: hready
// is low while this one has no data phase in flight (a test raises it only
// then).
reg tb_hready_stall;
initial tb_hready_stall = 1'b0;
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

ahb_sram_controller #(.MEM_SIZE(MEM_SIZE), .ASYNC_RST_EN(ASYNC_RST_EN)) ahb_sram_controller_inst0 (

// AHB CLOCK & RESET
    .hclk_i            ( hclk                 ),
    .hresetn_i         ( hresetn              ),
    .hclk_en_o         ( hclk_en              ),

// AHB INTERFACE
    .haddr_i           ( haddr_d[HADDRW-1:0]  ),
    .hready_i          ( hready_d             ),
    .hsize_i           ( hsize_d              ),
    .htrans_i          ( htrans_d             ),
    .hwdata_i          ( hwdata_d             ),
    .hwrite_i          ( hwrite_d             ),
    .hsel_i            ( hsel_d               ),
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
        if (sram_inst.mem[address] !== expected_value) begin
          $display("ERROR: Memory check   -- address: 0x%h -- read: 0x%h / expected: 0x%h %t ns", address, sram_inst.mem[address], expected_value, $time);
          error = error+1;
        end else begin
          $display("PASS:  Memory check   -- address: 0x%h -- value: 0x%h %t ns", address, sram_inst.mem[address], $time);
        end
      end
   endtask


//
// Bus monitor and shadow memory (sampled mid-cycle, where every signal is stable)
//------------------------------------------------------------------------------
// Every transfer is a zero-wait OKAY. A read data phase returns the full word
// the shadow memory holds (every earlier write applied in bus order, whatever
// the controller does with the SRAM port meanwhile); hrdata is 0 outside a
// read data phase (the SRAM model drives a poison word then); the clock enable
// is low on a cycle with neither an address nor a data phase. The shadow takes
// a word's initial value from the SRAM model on its first bus access.
reg  [31:0]          shadow     [0:(MEM_SIZE/4)-1];
reg  [(MEM_SIZE/4)-1:0] shadow_ok;
reg                  mon_armed;
reg                  mon_rd, mon_wr;
reg  [HADDRW-1:0]    mon_addr;
reg  [1:0]           mon_size;
reg                  mon_aph;
reg  [3:0]           mon_lanes;
reg  [MEM_ADDRW-1:0] mon_w;
reg  [31:0]          mon_word;
integer              mon_i;

initial begin
   mon_armed = 1'b0; mon_rd = 1'b0; mon_wr = 1'b0;
   shadow_ok = {(MEM_SIZE/4){1'b0}};
end
always @(posedge hresetn) mon_armed = 1'b1;
// A reset may drop or complete a write in flight; the shadow re-reads the SRAM
// model after it (tests that care check the word explicitly).
always @(negedge hresetn) shadow_ok = {(MEM_SIZE/4){1'b0}};

always @(negedge free_clk) begin
   if (!hresetn || !mon_armed) begin
      mon_rd = 1'b0; mon_wr = 1'b0;
   end else begin
      mon_aph = hsel & hready & htrans[1];
      if ((hreadyout !== 1'b1) || (hresp !== 1'b0)) begin
         $display("ERROR: MONITOR not a zero-wait OKAY (hreadyout=%b hresp=%b) %t ns", hreadyout, hresp, $time);
         error = error + 1;
      end
      if (mon_rd || mon_wr) begin
         mon_w = mon_addr[HADDRW-1:2];
         if (!shadow_ok[mon_w]) begin
            shadow[mon_w]    = sram_inst.mem[mon_w];
            shadow_ok[mon_w] = 1'b1;
         end
      end
      if (mon_rd) begin
         if (hrdata !== shadow[mon_w]) begin
            $display("ERROR: MONITOR read of word 0x%h returned %h, expected %h %t ns", mon_w, hrdata, shadow[mon_w], $time);
            error = error + 1;
         end
      end else if (hrdata !== 32'h0) begin
         $display("ERROR: MONITOR hrdata=%h outside a read data phase %t ns", hrdata, $time);
         error = error + 1;
      end
      if (mon_wr) begin
         mon_lanes = (mon_size == 2'b00) ? (4'b0001 << mon_addr[1:0]) :
                     (mon_size == 2'b01) ? (mon_addr[1] ? 4'b1100 : 4'b0011) :
                     (mon_size == 2'b10) ? 4'b1111 : 4'b0000;
         mon_word = shadow[mon_w];
         for (mon_i = 0; mon_i < 4; mon_i = mon_i + 1)
            if (mon_lanes[mon_i]) mon_word[8*mon_i +: 8] = hwdata[8*mon_i +: 8];
         shadow[mon_w] = mon_word;
      end
      if (!mon_aph && !mon_rd && !mon_wr && (hclk_en !== 1'b0)) begin
         $display("ERROR: MONITOR hclk_en high with no address or data phase %t ns", $time);
         error = error + 1;
      end
      mon_rd   = mon_aph & ~hwrite;
      mon_wr   = mon_aph &  hwrite;
      mon_addr = haddr[HADDRW-1:0];
      mon_size = hsize[1:0];
   end
end

endmodule
