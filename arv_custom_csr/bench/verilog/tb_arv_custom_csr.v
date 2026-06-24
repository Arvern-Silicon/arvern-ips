//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tb_arv_custom_csr
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tb_arv_custom_csr.v
// Module Description : Custom CSR peripheral testbench.
//----------------------------------------------------------------------------
`include "timescale.v"

module  tb_arv_custom_csr;

// PARAMETERs
//------------------------------
parameter            NR_USR_RW  = 4;         // Number of User-Mode Read-Write registers       (min: 1; max: 256)
parameter            NR_USR_RO  = 2;         // Number of User-Mode Read-Only  registers       (min: 1; max:  64)

parameter            NR_SUP_RW  = 4;         // Number of Supervisor-Mode Read-Write registers (min: 1; max: 128)
parameter            NR_SUP_RO  = 2;         // Number of Supervisor-Mode Read-Only  registers (min: 1; max:  64)

parameter            NR_MAC_RW  = 4;         // Number of Machine-Mode Read-Write registers    (min: 1; max: 128)
parameter            NR_MAC_RO  = 2;         // Number of Machine-Mode Read-Only  registers    (min: 1; max:  64)

`ifndef ASYNC_RST_EN
  `define ASYNC_RST_EN 1
`endif
parameter            ASYNC_RST_EN = `ASYNC_RST_EN;  // Reset architecture: 1=async active-low reset, 0=synchronous reset


//
// Wire & Register definition
//------------------------------

// Clock / Reset
reg                  hresetn;
reg                  free_clk;
wire                 hclk;
wire                 hclk_en;

// Custom-CSR Interface
reg           [10:0] ccsr_bank;
reg           [63:0] ccsr_reg_sel;
reg           [31:0] ccsr_wdata;
reg                  ccsr_wen;
wire          [31:0] ccsr_rdata;

// Custom-CSR values
wire          [31:0] ccsr_usr_rw3;
wire          [31:0] ccsr_usr_rw2;
wire          [31:0] ccsr_usr_rw1;
wire          [31:0] ccsr_usr_rw0;
wire          [31:0] ccsr_sup_rw3;
wire          [31:0] ccsr_sup_rw2;
wire          [31:0] ccsr_sup_rw1;
wire          [31:0] ccsr_sup_rw0;
wire          [31:0] ccsr_mac_rw3;
wire          [31:0] ccsr_mac_rw2;
wire          [31:0] ccsr_mac_rw1;
wire          [31:0] ccsr_mac_rw0;
reg           [31:0] ccsr_usr_ro1;
reg           [31:0] ccsr_usr_ro0;
reg           [31:0] ccsr_sup_ro1;
reg           [31:0] ccsr_sup_ro0;
reg           [31:0] ccsr_mac_ro1;
reg           [31:0] ccsr_mac_ro0;

// Testbench variables
integer              tb_idx;
integer              tmp_seed;
integer              error;
reg                  stimulus_done;


//
// Include files
//------------------------------

// Verilog tasks & stimulus
`include "csr_tasks.v"
`include "stimulus.v"


//
// Initialize Registers
//------------------------------
initial
  begin
    ccsr_usr_ro1 = 32'h00000000 ;
    ccsr_usr_ro0 = 32'h00000000 ;
    ccsr_sup_ro1 = 32'h00000000 ;
    ccsr_sup_ro0 = 32'h00000000 ;
    ccsr_mac_ro1 = 32'h00000000 ;
    ccsr_mac_ro0 = 32'h00000000 ;
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
//
// The CRG holds the clock running during reset: a real SoC reset controller
// forces the clock gate transparent while reset is asserted, which the
// synchronous-reset flops require to capture their reset value on a clock edge
// (async-reset flops are unaffected, so this is correct in both modes).
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

     ccsr_bank     = 11'h000;
     ccsr_reg_sel  = 64'h0000000000000000;
     ccsr_wdata    = 32'h00000000;
     ccsr_wen      =  1'b0;
  end


//
// CUSTOM CSR INSTANCE
//----------------------------------
arv_custom_csr #(.NR_USR_RW    ( NR_USR_RW    ),
                 .NR_USR_RO    ( NR_USR_RO    ),
                 .NR_SUP_RW    ( NR_SUP_RW    ),
                 .NR_SUP_RO    ( NR_SUP_RO    ),
                 .NR_MAC_RW    ( NR_MAC_RW    ),
                 .NR_MAC_RO    ( NR_MAC_RO    ),
                 .ASYNC_RST_EN ( ASYNC_RST_EN )) arv_custom_csr_inst (

// AHB CLOCK & RESET
    .hclk_i            ( hclk                                                     ),
    .hresetn_i         ( hresetn                                                  ),
    .hclk_en_o         ( hclk_en                                                  ),

// READ-ONLY VALUES FROM OUTSIDE WORLD
    .ccsr_usr_ro_i     ( {ccsr_usr_ro1, ccsr_usr_ro0}                             ),
    .ccsr_sup_ro_i     ( {ccsr_sup_ro1, ccsr_sup_ro0}                             ),
    .ccsr_mac_ro_i     ( {ccsr_mac_ro1, ccsr_mac_ro0}                             ),

// READ-WRITE VALUES TO OUTSIDE WORLD
    .ccsr_usr_rw_o     ( {ccsr_usr_rw3, ccsr_usr_rw2, ccsr_usr_rw1, ccsr_usr_rw0} ),
    .ccsr_sup_rw_o     ( {ccsr_sup_rw3, ccsr_sup_rw2, ccsr_sup_rw1, ccsr_sup_rw0} ),
    .ccsr_mac_rw_o     ( {ccsr_mac_rw3, ccsr_mac_rw2, ccsr_mac_rw1, ccsr_mac_rw0} ),

// INTERFACE TO CUSTOM CSR REGISTERS
    .ccsr_bank_i       ( ccsr_bank                                                ),
    .ccsr_reg_sel_i    ( ccsr_reg_sel                                             ),
    .ccsr_wdata_i      ( ccsr_wdata                                               ),
    .ccsr_wen_i        ( ccsr_wen                                                 ),
    .ccsr_rdata_o      ( ccsr_rdata                                               )
);


//
// Generate Waveform
//----------------------------------------
initial
  begin
   `ifdef NODUMP
   `else
     `ifdef VPD_FILE
        $vcdplusfile("tb_arv_custom_csr.vpd");
        $vcdpluson();
     `else
       `ifdef TRN_FILE
          $recordfile ("tb_arv_custom_csr.trn");
          $recordvars;
       `else
          $dumpfile("tb_arv_custom_csr.vcd");
          $dumpvars(0, tb_arv_custom_csr);
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

   task check_value;
      input integer reg_value;
      input integer expected_value;
        
      reg   [511:0] formatted_string;
      begin
        #1;
        if (reg_value !== expected_value) begin
          $display("ERROR: CCSR check   -- read: 0x%h / expected: 0x%h %t ns", reg_value, expected_value, $time); 
          error = error+1;
        end else begin
          $display("PASS:  CCSR check   -- value: 0x%h %t ns", reg_value, $time);
        end
      end
   endtask


endmodule
