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
// Register counts come from `-D NR_*` defines so the bench runs at any
// configuration of sim/rtl_sim/bin/rtl_configs.py; the fallbacks are the
// configuration the fixed-address tests (simple_*, supervisor_rdwr,
// wen_zero) are written for.
`ifndef NR_USR_RW
  `define NR_USR_RW 4
`endif
`ifndef NR_USR_RO
  `define NR_USR_RO 2
`endif
`ifndef NR_SUP_RW
  `define NR_SUP_RW 4
`endif
`ifndef NR_SUP_RO
  `define NR_SUP_RO 2
`endif
`ifndef NR_MAC_RW
  `define NR_MAC_RW 4
`endif
`ifndef NR_MAC_RO
  `define NR_MAC_RO 2
`endif
parameter            NR_USR_RW  = `NR_USR_RW;   // Number of User-Mode Read-Write registers       (0..256)
parameter            NR_USR_RO  = `NR_USR_RO;   // Number of User-Mode Read-Only  registers       (0..64)
parameter            NR_SUP_RW  = `NR_SUP_RW;   // Number of Supervisor-Mode Read-Write registers (0..128)
parameter            NR_SUP_RO  = `NR_SUP_RO;   // Number of Supervisor-Mode Read-Only  registers (0..64)
parameter            NR_MAC_RW  = `NR_MAC_RW;   // Number of Machine-Mode Read-Write registers    (0..128)
parameter            NR_MAC_RO  = `NR_MAC_RO;   // Number of Machine-Mode Read-Only  registers    (0..60)

localparam           USR_RW_W   = (NR_USR_RW>0) ? (NR_USR_RW*32) : 1;
localparam           USR_RO_W   = (NR_USR_RO>0) ? (NR_USR_RO*32) : 1;
localparam           SUP_RW_W   = (NR_SUP_RW>0) ? (NR_SUP_RW*32) : 1;
localparam           SUP_RO_W   = (NR_SUP_RO>0) ? (NR_SUP_RO*32) : 1;
localparam           MAC_RW_W   = (NR_MAC_RW>0) ? (NR_MAC_RW*32) : 1;
localparam           MAC_RO_W   = (NR_MAC_RO>0) ? (NR_MAC_RO*32) : 1;
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

// Custom-CSR values. The *_pad vectors are sized for the architectural
// maximum (zero-extended / truncated to the DUT port) so that tests can index
// register i as <group>_pad[32*i+:32] at any configuration.
wire  [USR_RW_W-1:0] usr_rw_o;
wire  [SUP_RW_W-1:0] sup_rw_o;
wire  [MAC_RW_W-1:0] mac_rw_o;
wire    [256*32-1:0] usr_rw_pad = usr_rw_o;
wire    [128*32-1:0] sup_rw_pad = sup_rw_o;
wire    [128*32-1:0] mac_rw_pad = mac_rw_o;
reg      [64*32-1:0] usr_ro_pad;
reg      [64*32-1:0] sup_ro_pad;
reg      [64*32-1:0] mac_ro_pad;
wire          [31:0] ccsr_usr_rw0 = usr_rw_pad[0*32+:32];
wire          [31:0] ccsr_usr_rw1 = usr_rw_pad[1*32+:32];
wire          [31:0] ccsr_usr_rw2 = usr_rw_pad[2*32+:32];
wire          [31:0] ccsr_usr_rw3 = usr_rw_pad[3*32+:32];
wire          [31:0] ccsr_sup_rw0 = sup_rw_pad[0*32+:32];
wire          [31:0] ccsr_sup_rw1 = sup_rw_pad[1*32+:32];
wire          [31:0] ccsr_sup_rw2 = sup_rw_pad[2*32+:32];
wire          [31:0] ccsr_sup_rw3 = sup_rw_pad[3*32+:32];
wire          [31:0] ccsr_mac_rw0 = mac_rw_pad[0*32+:32];
wire          [31:0] ccsr_mac_rw1 = mac_rw_pad[1*32+:32];
wire          [31:0] ccsr_mac_rw2 = mac_rw_pad[2*32+:32];
wire          [31:0] ccsr_mac_rw3 = mac_rw_pad[3*32+:32];

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
    usr_ro_pad = {64*32{1'b0}};
    sup_ro_pad = {64*32{1'b0}};
    mac_ro_pad = {64*32{1'b0}};
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
    .ccsr_usr_ro_i     ( usr_ro_pad[USR_RO_W-1:0]                                 ),
    .ccsr_sup_ro_i     ( sup_ro_pad[SUP_RO_W-1:0]                                 ),
    .ccsr_mac_ro_i     ( mac_ro_pad[MAC_RO_W-1:0]                                 ),

// READ-WRITE VALUES TO OUTSIDE WORLD
    .ccsr_usr_rw_o     ( usr_rw_o                                                 ),
    .ccsr_sup_rw_o     ( sup_rw_o                                                 ),
    .ccsr_mac_rw_o     ( mac_rw_o                                                 ),

// INTERFACE TO CUSTOM CSR REGISTERS
    .ccsr_bank_i       ( ccsr_bank                                                ),
    .ccsr_reg_sel_i    ( ccsr_reg_sel                                             ),
    .ccsr_wdata_i      ( ccsr_wdata                                               ),
    .ccsr_wen_i        ( ccsr_wen                                                 ),
    .ccsr_rdata_o      ( ccsr_rdata                                               )
);


//
// Reference model and bus monitor
//----------------------------------------
// The model holds the RW registers and decodes the interface exactly as the
// document's address map states (register index -> bank, offset). Sampled at
// the falling edge, when the stimulus (driven 1 ns after the rising edge) has
// settled, it checks every cycle, whatever the test does:
//   - ccsr_rdata_o equals the selected register (0 for an offset >= NR_*, for
//     a disabled group and when nothing is selected);
//   - hclk_en_o is high exactly when a write selects an implemented RW
//     register;
//   - every RW output port equals the model.
// The model takes a write at the rising edge where the DUT would.
reg           [31:0] m_usr_rw [0:255];
reg           [31:0] m_sup_rw [0:127];
reg           [31:0] m_mac_rw [0:127];
reg                  mon_en;           // tests may clear it around deliberate illegal stimulus
reg                  mon_armed;        // set by the first reset release
integer              mon_i;
integer              mon_k;
integer              mon_cnt;          // checked cycles with a selection (coverage)
integer              mon_wr_cnt;       // model writes (coverage)

// One-hot index of the register select (-1 when none).
function integer sel_index;
   input [63:0] sel;
   integer      jj;
   begin
      sel_index = -1;
      for (jj = 0; jj < 64; jj = jj + 1)
         if (sel[jj]) sel_index = jj;
   end
endfunction

// Selected register: group (0 none, 1 usr rw, 2 usr ro, 3 sup rw, 4 sup ro,
// 5 mac rw, 6 mac ro) and index within the group.
reg            [2:0] m_grp;
integer              m_idx;
always @*
  begin
     mon_k = sel_index(ccsr_reg_sel);
     m_grp = 3'd0;
     m_idx = 0;
     if (mon_k >= 0) begin
        case (ccsr_bank)
          11'h001: begin m_grp = 3'd1; m_idx =       mon_k; end
          11'h002: begin m_grp = 3'd1; m_idx =  64 + mon_k; end
          11'h004: begin m_grp = 3'd1; m_idx = 128 + mon_k; end
          11'h008: begin m_grp = 3'd1; m_idx = 192 + mon_k; end
          11'h010: begin m_grp = 3'd2; m_idx =       mon_k; end
          11'h020: begin m_grp = 3'd3; m_idx =       mon_k; end
          11'h040: begin m_grp = 3'd3; m_idx =  64 + mon_k; end
          11'h080: begin m_grp = 3'd4; m_idx =       mon_k; end
          11'h100: begin m_grp = 3'd5; m_idx =       mon_k; end
          11'h200: begin m_grp = 3'd5; m_idx =  64 + mon_k; end
          11'h400: begin m_grp = 3'd6; m_idx =       mon_k; end
          default: m_grp = 3'd0;
        endcase
     end
  end

wire m_impl = ((m_grp == 3'd1) && (m_idx < NR_USR_RW)) ||
              ((m_grp == 3'd2) && (m_idx < NR_USR_RO)) ||
              ((m_grp == 3'd3) && (m_idx < NR_SUP_RW)) ||
              ((m_grp == 3'd4) && (m_idx < NR_SUP_RO)) ||
              ((m_grp == 3'd5) && (m_idx < NR_MAC_RW)) ||
              ((m_grp == 3'd6) && (m_idx < NR_MAC_RO));
wire m_rw   = (m_grp == 3'd1) || (m_grp == 3'd3) || (m_grp == 3'd5);

function [31:0] m_read;
   input [2:0] grp;
   input integer idx;
   begin
      case (grp)
        3'd1: m_read = m_usr_rw[idx];
        3'd2: m_read = usr_ro_pad[32*idx+:32];
        3'd3: m_read = m_sup_rw[idx];
        3'd4: m_read = sup_ro_pad[32*idx+:32];
        3'd5: m_read = m_mac_rw[idx];
        3'd6: m_read = mac_ro_pad[32*idx+:32];
        default: m_read = 32'h00000000;
      endcase
   end
endfunction

task model_reset;
   begin
      for (mon_i = 0; mon_i < 256; mon_i = mon_i + 1) m_usr_rw[mon_i] = 32'h00000000;
      for (mon_i = 0; mon_i < 128; mon_i = mon_i + 1) m_sup_rw[mon_i] = 32'h00000000;
      for (mon_i = 0; mon_i < 128; mon_i = mon_i + 1) m_mac_rw[mon_i] = 32'h00000000;
   end
endtask

initial
  begin
     mon_en     = 1'b1;
     mon_armed  = 1'b0;
     mon_cnt    = 0;
     mon_wr_cnt = 0;
     model_reset;
  end

always @(negedge hresetn) model_reset;
always @(posedge hresetn) mon_armed = 1'b1;

always @(posedge free_clk)
  if (hresetn === 1'b1 && ccsr_wen && m_rw && m_impl) begin
     case (m_grp)
       3'd1: m_usr_rw[m_idx] <= ccsr_wdata;
       3'd3: m_sup_rw[m_idx] <= ccsr_wdata;
       default: m_mac_rw[m_idx] <= ccsr_wdata;
     endcase
     mon_wr_cnt = mon_wr_cnt + 1;
  end

reg [31:0] m_exp;
always @(negedge free_clk)
  if (hresetn === 1'b1 && mon_armed && mon_en) begin
     m_exp = m_impl ? m_read(m_grp, m_idx) : 32'h00000000;
     if (ccsr_rdata !== m_exp) begin
        $display("ERROR: monitor -- rdata 0x%h, expected 0x%h (bank 0x%h, sel %0d) %t ns", ccsr_rdata, m_exp, ccsr_bank, mon_k, $time);
        error = error + 1;
     end
     if (hclk_en !== (ccsr_wen & m_rw & m_impl)) begin
        $display("ERROR: monitor -- hclk_en %b, expected %b (bank 0x%h, sel %0d, wen %b) %t ns", hclk_en, (ccsr_wen & m_rw & m_impl), ccsr_bank, mon_k, ccsr_wen, $time);
        error = error + 1;
     end
     for (mon_i = 0; mon_i < NR_USR_RW; mon_i = mon_i + 1)
        if (usr_rw_pad[32*mon_i+:32] !== m_usr_rw[mon_i]) begin
           $display("ERROR: monitor -- ccsr_usr_rw_o[%0d] 0x%h, expected 0x%h %t ns", mon_i, usr_rw_pad[32*mon_i+:32], m_usr_rw[mon_i], $time);
           error = error + 1;
        end
     for (mon_i = 0; mon_i < NR_SUP_RW; mon_i = mon_i + 1)
        if (sup_rw_pad[32*mon_i+:32] !== m_sup_rw[mon_i]) begin
           $display("ERROR: monitor -- ccsr_sup_rw_o[%0d] 0x%h, expected 0x%h %t ns", mon_i, sup_rw_pad[32*mon_i+:32], m_sup_rw[mon_i], $time);
           error = error + 1;
        end
     for (mon_i = 0; mon_i < NR_MAC_RW; mon_i = mon_i + 1)
        if (mac_rw_pad[32*mon_i+:32] !== m_mac_rw[mon_i]) begin
           $display("ERROR: monitor -- ccsr_mac_rw_o[%0d] 0x%h, expected 0x%h %t ns", mon_i, mac_rw_pad[32*mon_i+:32], m_mac_rw[mon_i], $time);
           error = error + 1;
        end
     if (m_grp != 3'd0) mon_cnt = mon_cnt + 1;
  end

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
