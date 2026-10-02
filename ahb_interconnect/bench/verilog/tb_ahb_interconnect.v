//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tb_ahb_interconnect
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tb_ahb_interconnect.v
// Module Description : Top-level testbench for the AHB interconnect.
//----------------------------------------------------------------------------

`include "timescale.v"

module  tb_ahb_interconnect;

//
// Wire & Register definition
//------------------------------

parameter            MEM_SIZE   = 2048;                  // Size of the memory instance (in Bytes)
parameter            MEM_ADDRW  = $clog2(MEM_SIZE)-2;    // Address width of the memory instance (32b words)
parameter            MEM_HADDRW = $clog2(MEM_SIZE);      // Address width of the AHB interface (8b words)
parameter            NR_M       = 3;                     // Number of AHB Managers
parameter            NR_S       = 4;                     // Number of AHB Subordinates
parameter            HAUSER_W   = 1;                     // Width of the HAUSER bus (min value is 1)

// Per-manager privilege sideband. These MUST differ between managers: the
// fabric only fans hauser/hprot out from the granted manager, so identical
// values make a mis-mux invisible -- which is what the whole suite used to do
// (every manager drove hauser=0 and hprot=4'h2).
//
// They differ ONLY in bits that do not change the access mode. hprot[1] stays
// 1 (privileged) and hauser[0] -- the aRVern hsmode bit -- stays 0 (M-mode) on
// every manager, because ahb_periph_example is a real privilege-filtering
// subordinate on s2/s3 (.hsmode_i(ws_s2_hauser[0])) and denies S- or U-mode
// under its M-only MDELEG default. Varying the MODE belongs in a dedicated
// test that opens MDELEG first; varying the ROUTING is what these do.
//   bit[0] opcode/data, bit[1] privileged, bit[2] bufferable, bit[3] cacheable
localparam     [3:0] MGR0_HPROT = 4'h2;   // 0010  privileged, data
localparam     [3:0] MGR1_HPROT = 4'h3;   // 0011  privileged, opcode
localparam     [3:0] MGR2_HPROT = 4'hA;   // 1010  privileged, data, cacheable

// Manager-supplied HMASTER bits. M1 is the tagged manager: bit 3 of its HMASTER
// follows haddr[2], so the tag toggles between consecutive word transfers and a
// fabric presenting a live tag instead of the cached one is caught. The other
// managers and M1's untagged bits drive ones, which the TAG mask must block.
// IDs stay at their defaults, so M1 presents 4'h1 or 4'h9.
localparam     [3:0] MGR1_HMASTER_TAG = 4'h8;
wire           [3:0] m0_hmaster_tag   = 4'hF;
wire           [3:0] m1_hmaster_tag;
wire           [3:0] m2_hmaster_tag   = 4'hF;

// Reset architecture (1=async active-low [default], 0=synchronous).  Build-time
// overridable via `-D ASYNC_RST_EN=0` so the block-level sim can exercise the
// interconnect variants' synchronous-reset configuration.
`ifndef ASYNC_RST_EN
  `define ASYNC_RST_EN 1
`endif
parameter            ASYNC_RST_EN = `ASYNC_RST_EN;

// Clock / Reset
reg                  hresetn;
reg                  free_clk;
wire                 dut_hclk;
wire                 dut_hclk_en;

// Arbiter Interface
wire      [NR_M-1:0] m_grant;
wire      [NR_M-1:0] m_request;

// Address Decoder Interface
wire      [NR_S-1:0] s_x_decoder_1hot;
wire          [31:0] s_x_decoder_addr;
wire      [NR_S-1:0] s_decoder_1hot;
wire          [31:0] s_decoder_addr;

// AHB Manager interfaces
reg           [31:0] m0_haddr;
reg   [HAUSER_W-1:0] m0_hauser;
reg            [2:0] m0_hburst;
reg                  m0_hmastlock;
reg            [3:0] m0_hprot;
reg            [2:0] m0_hsize;
reg            [1:0] m0_htrans;
reg           [31:0] m0_hwdata;
reg                  m0_hwrite;
wire          [31:0] m0_hrdata;
wire                 m0_hready;
wire                 m0_hresp;

reg           [31:0] m1_haddr;
reg   [HAUSER_W-1:0] m1_hauser;
reg            [2:0] m1_hburst;
reg                  m1_hmastlock;
reg            [3:0] m1_hprot;
reg            [2:0] m1_hsize;
reg            [1:0] m1_htrans;
reg           [31:0] m1_hwdata;
reg                  m1_hwrite;
wire          [31:0] m1_hrdata;
wire                 m1_hready;
wire                 m1_hresp;

reg           [31:0] m2_haddr;
reg   [HAUSER_W-1:0] m2_hauser;
reg            [2:0] m2_hburst;
reg                  m2_hmastlock;
reg            [3:0] m2_hprot;
reg            [2:0] m2_hsize;
reg            [1:0] m2_htrans;
reg           [31:0] m2_hwdata;
reg                  m2_hwrite;
wire          [31:0] m2_hrdata;
wire                 m2_hready;
wire                 m2_hresp;

// Managers reach the DUT through 1 ns delays in both directions. The tasks change
// inputs right after `@(posedge free_clk)` and sample hready on that same edge; with
// the delays the DUT always samples the old inputs and the tasks always see the old
// outputs at an edge, whatever the simulator's process order (Icarus and Verilator
// differ). The bench keeps using the undelayed names.
wire [31:0]          m0_haddr_d;
assign #1 m0_haddr_d = m0_haddr;
wire [HAUSER_W-1:0]  m0_hauser_d;
assign #1 m0_hauser_d = m0_hauser;
wire [2:0]           m0_hburst_d;
assign #1 m0_hburst_d = m0_hburst;
wire                 m0_hmastlock_d;
assign #1 m0_hmastlock_d = m0_hmastlock;
wire [3:0]           m0_hprot_d;
assign #1 m0_hprot_d = m0_hprot;
wire [2:0]           m0_hsize_d;
assign #1 m0_hsize_d = m0_hsize;
wire [1:0]           m0_htrans_d;
assign #1 m0_htrans_d = m0_htrans;
wire [31:0]          m0_hwdata_d;
assign #1 m0_hwdata_d = m0_hwdata;
wire                 m0_hwrite_d;
assign #1 m0_hwrite_d = m0_hwrite;
wire [3:0]           m0_hmaster_tag_d;
assign #1 m0_hmaster_tag_d = m0_hmaster_tag;
wire [31:0]          m0_hrdata_dut;
assign #1 m0_hrdata = m0_hrdata_dut;
wire                 m0_hready_dut;
assign #1 m0_hready = m0_hready_dut;
wire                 m0_hresp_dut;
assign #1 m0_hresp = m0_hresp_dut;
wire [31:0]          m1_haddr_d;
assign #1 m1_haddr_d = m1_haddr;
wire [HAUSER_W-1:0]  m1_hauser_d;
assign #1 m1_hauser_d = m1_hauser;
wire [2:0]           m1_hburst_d;
assign #1 m1_hburst_d = m1_hburst;
wire                 m1_hmastlock_d;
assign #1 m1_hmastlock_d = m1_hmastlock;
wire [3:0]           m1_hprot_d;
assign #1 m1_hprot_d = m1_hprot;
wire [2:0]           m1_hsize_d;
assign #1 m1_hsize_d = m1_hsize;
wire [1:0]           m1_htrans_d;
assign #1 m1_htrans_d = m1_htrans;
wire [31:0]          m1_hwdata_d;
assign #1 m1_hwdata_d = m1_hwdata;
wire                 m1_hwrite_d;
assign #1 m1_hwrite_d = m1_hwrite;
wire [3:0]           m1_hmaster_tag_d;
assign #1 m1_hmaster_tag_d = m1_hmaster_tag;
wire [31:0]          m1_hrdata_dut;
assign #1 m1_hrdata = m1_hrdata_dut;
wire                 m1_hready_dut;
assign #1 m1_hready = m1_hready_dut;
wire                 m1_hresp_dut;
assign #1 m1_hresp = m1_hresp_dut;
wire [31:0]          m2_haddr_d;
assign #1 m2_haddr_d = m2_haddr;
wire [HAUSER_W-1:0]  m2_hauser_d;
assign #1 m2_hauser_d = m2_hauser;
wire [2:0]           m2_hburst_d;
assign #1 m2_hburst_d = m2_hburst;
wire                 m2_hmastlock_d;
assign #1 m2_hmastlock_d = m2_hmastlock;
wire [3:0]           m2_hprot_d;
assign #1 m2_hprot_d = m2_hprot;
wire [2:0]           m2_hsize_d;
assign #1 m2_hsize_d = m2_hsize;
wire [1:0]           m2_htrans_d;
assign #1 m2_htrans_d = m2_htrans;
wire [31:0]          m2_hwdata_d;
assign #1 m2_hwdata_d = m2_hwdata;
wire                 m2_hwrite_d;
assign #1 m2_hwrite_d = m2_hwrite;
wire [3:0]           m2_hmaster_tag_d;
assign #1 m2_hmaster_tag_d = m2_hmaster_tag;
wire [31:0]          m2_hrdata_dut;
assign #1 m2_hrdata = m2_hrdata_dut;
wire                 m2_hready_dut;
assign #1 m2_hready = m2_hready_dut;
wire                 m2_hresp_dut;
assign #1 m2_hresp = m2_hresp_dut;

// AHB Subordinate Interfaces
wire          [31:0] s0_hrdata;
wire                 s0_hreadyout;
wire                 s0_hresp;
wire                 s0_hsel;
wire                 s0_hclk;
wire                 s0_hclk_en;

wire          [31:0] s0_haddr;
wire  [HAUSER_W-1:0] s0_hauser;
wire           [2:0] s0_hburst;
wire           [3:0] s0_hmaster;
wire                 s0_hmastlock;
wire           [3:0] s0_hprot;
wire                 s0_hready;
wire           [2:0] s0_hsize;
wire           [1:0] s0_htrans;
wire          [31:0] s0_hwdata;
wire                 s0_hwrite;

wire          [31:0] s1_hrdata;
wire                 s1_hreadyout;
wire                 s1_hresp;
wire                 s1_hsel;
wire                 s1_hclk;
wire                 s1_hclk_en;

wire          [31:0] s1_haddr;
wire  [HAUSER_W-1:0] s1_hauser;
wire           [2:0] s1_hburst;
wire           [3:0] s1_hmaster;
wire                 s1_hmastlock;
wire           [3:0] s1_hprot;
wire                 s1_hready;
wire           [2:0] s1_hsize;
wire           [1:0] s1_htrans;
wire          [31:0] s1_hwdata;
wire                 s1_hwrite;

wire          [31:0] s2_hrdata;
wire                 s2_hreadyout;
wire                 s2_hresp;
wire                 s2_hsel;
wire                 s2_hclk;
wire                 s2_hclk_en;

wire          [31:0] s2_haddr;
wire  [HAUSER_W-1:0] s2_hauser;
wire           [2:0] s2_hburst;
wire           [3:0] s2_hmaster;
wire                 s2_hmastlock;
wire           [3:0] s2_hprot;
wire                 s2_hready;
wire           [2:0] s2_hsize;
wire           [1:0] s2_htrans;
wire          [31:0] s2_hwdata;
wire                 s2_hwrite;

wire          [31:0] s3_hrdata;
wire                 s3_hreadyout;
wire                 s3_hresp;
wire                 s3_hsel;
wire                 s3_hclk;
wire                 s3_hclk_en;

wire          [31:0] s3_haddr;
wire  [HAUSER_W-1:0] s3_hauser;
wire           [2:0] s3_hburst;
wire           [3:0] s3_hmaster;
wire                 s3_hmastlock;
wire           [3:0] s3_hprot;
wire                 s3_hready;
wire           [2:0] s3_hsize;
wire           [1:0] s3_htrans;
wire          [31:0] s3_hwdata;
wire                 s3_hwrite;


// AHB Subordinate Interfaces with inserted wait states
integer              s0_number_wait_states;
reg                  s0_random_wait_states_en;
integer              s1_number_wait_states;
reg                  s1_random_wait_states_en;
integer              s2_number_wait_states;
reg                  s3_random_wait_states_en;
integer              s3_number_wait_states;
reg                  s2_random_wait_states_en;

wire          [31:0] ws_s0_hrdata;
wire                 ws_s0_hreadyout;
wire                 ws_s0_hresp;
wire                 ws_s0_hsel;
wire          [31:0] ws_s0_haddr;
wire  [HAUSER_W-1:0] ws_s0_hauser;
wire           [3:0] ws_s0_hprot;
wire                 ws_s0_hready;
wire           [2:0] ws_s0_hsize;
wire           [1:0] ws_s0_htrans;
wire          [31:0] ws_s0_hwdata;
wire                 ws_s0_hwrite;

wire          [31:0] ws_s1_hrdata;
wire                 ws_s1_hreadyout;
wire                 ws_s1_hresp;
wire                 ws_s1_hsel;
wire          [31:0] ws_s1_haddr;
wire  [HAUSER_W-1:0] ws_s1_hauser;
wire           [3:0] ws_s1_hprot;
wire                 ws_s1_hready;
wire           [2:0] ws_s1_hsize;
wire           [1:0] ws_s1_htrans;
wire          [31:0] ws_s1_hwdata;
wire                 ws_s1_hwrite;

wire          [31:0] ws_s2_hrdata;
wire                 ws_s2_hreadyout;
wire                 ws_s2_hresp;
wire                 ws_s2_hsel;
wire          [31:0] ws_s2_haddr;
wire  [HAUSER_W-1:0] ws_s2_hauser;
wire           [3:0] ws_s2_hprot;
wire                 ws_s2_hready;
wire           [2:0] ws_s2_hsize;
wire           [1:0] ws_s2_htrans;
wire          [31:0] ws_s2_hwdata;
wire                 ws_s2_hwrite;

wire          [31:0] ws_s3_hrdata;
wire                 ws_s3_hreadyout;
wire                 ws_s3_hresp;
wire                 ws_s3_hsel;
wire          [31:0] ws_s3_haddr;
wire  [HAUSER_W-1:0] ws_s3_hauser;
wire           [3:0] ws_s3_hprot;
wire                 ws_s3_hready;
wire           [2:0] ws_s3_hsize;
wire           [1:0] ws_s3_htrans;
wire          [31:0] ws_s3_hwdata;
wire                 ws_s3_hwrite;

// ROM Interface
wire          [31:0] rom0_dout;
wire [MEM_ADDRW-1:0] rom0_addr;
wire                 rom0_cen;
wire                 rom0_clk;

// SRAM Interface
wire          [31:0] sram0_dout;
wire [MEM_ADDRW-1:0] sram0_addr;
wire                 sram0_cen;
wire                 sram0_clk;
wire          [31:0] sram0_din;
wire           [3:0] sram0_wen;

// AHB Peripheral #0
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

// AHB Peripheral #1
wire          [31:0] periph1_reg_00_out;
wire          [31:0] periph1_reg_01_out;
wire          [31:0] periph1_reg_02_out;
wire          [31:0] periph1_reg_03_out;
wire          [31:0] periph1_reg_04_out;
wire          [31:0] periph1_reg_05_out;
wire          [31:0] periph1_reg_06_out;
wire          [31:0] periph1_reg_07_out;
reg           [31:0] periph1_reg_08_in;
reg           [31:0] periph1_reg_09_in;
reg           [31:0] periph1_reg_10_in;
reg           [31:0] periph1_reg_11_in;
reg           [31:0] periph1_reg_12_in;
reg           [31:0] periph1_reg_13_in;
reg           [31:0] periph1_reg_14_in;
reg           [31:0] periph1_reg_15_in;

// Testbench variables
integer              tb_idx;
integer              tmp_seed;
integer              error;
reg                  stimulus_done;


//
// Include files
//------------------------------

// Verilog stimulus
`include "ahb_tasks_m0.v"
`include "ahb_tasks_m1.v"
`include "ahb_tasks_m2.v"
`include "ahb_tasks.v"
`include "mem_strobes.v"
`include "stimulus.v"


//
// Initialize Memory & Peripherals
//---------------------------------
initial
  begin
     // Initialize memory instances
     for (tb_idx=0; tb_idx < MEM_SIZE/4; tb_idx=tb_idx+1)
       rom_inst0.mem[tb_idx]  = 32'h00000000;
       sram_inst0.mem[tb_idx] = 32'h00000000;

     // Initialize peripheral #0
     periph0_reg_08_in = 32'h00000000 ;
     periph0_reg_09_in = 32'h00000000 ;
     periph0_reg_10_in = 32'h00000000 ;
     periph0_reg_11_in = 32'h00000000 ;
     periph0_reg_12_in = 32'h00000000 ;
     periph0_reg_13_in = 32'h00000000 ;
     periph0_reg_14_in = 32'h00000000 ;
     periph0_reg_15_in = 32'h00000000 ;

     // Initialize peripheral #1
     periph1_reg_08_in = 32'h00000000 ;
     periph1_reg_09_in = 32'h00000000 ;
     periph1_reg_10_in = 32'h00000000 ;
     periph1_reg_11_in = 32'h00000000 ;
     periph1_reg_12_in = 32'h00000000 ;
     periph1_reg_13_in = 32'h00000000 ;
     periph1_reg_14_in = 32'h00000000 ;
     periph1_reg_15_in = 32'h00000000 ;

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
reg     dut_hclk_en_latch;
always @(free_clk or dut_hclk_en or hresetn)
  if (~free_clk)
    dut_hclk_en_latch <= dut_hclk_en | ~hresetn;  // CRG holds the clock running during reset (sync-reset init contract)
assign  dut_hclk  =  (free_clk & dut_hclk_en_latch);

reg     s0_hclk_en_latch;
always @(free_clk or s0_hclk_en)
  if (~free_clk)
    s0_hclk_en_latch <= s0_hclk_en;
assign  s0_hclk  =  (free_clk & s0_hclk_en_latch);

reg     s1_hclk_en_latch;
always @(free_clk or s1_hclk_en)
  if (~free_clk)
    s1_hclk_en_latch <= s1_hclk_en;
assign  s1_hclk  =  (free_clk & s1_hclk_en_latch);

reg     s2_hclk_en_latch;
always @(free_clk or s2_hclk_en)
  if (~free_clk)
    s2_hclk_en_latch <= s2_hclk_en;
assign  s2_hclk  =  (free_clk & s2_hclk_en_latch);

reg     s3_hclk_en_latch;
always @(free_clk or s3_hclk_en)
  if (~free_clk)
    s3_hclk_en_latch <= s3_hclk_en;
assign  s3_hclk  =  (free_clk & s3_hclk_en_latch);

// Checkers run once reset has been applied and released: before that the flops hold
// their power-on values (X in Icarus, arbitrary in Verilator) and mean nothing.
reg tb_rst_done;
initial begin
   tb_rst_done = 1'b0;
   wait (hresetn === 1'b0);
   @(posedge hresetn);
   tb_rst_done = 1'b1;
end

// Reset generation
initial
  begin
     hresetn               = 1'b1;
     #93;
     hresetn               = 1'b0;
     #593;
     hresetn               = 1'b1;
  end

// Variables initialization
initial
  begin
     tmp_seed                 = `SEED;
     tmp_seed                 = $urandom(tmp_seed);
     error                    = 0;
     stimulus_done            = 0;

`ifdef RANDOM_WS
     s0_number_wait_states    = 5;
     s1_number_wait_states    = 5;
     s2_number_wait_states    = 5;
     s3_number_wait_states    = 5;

     s0_random_wait_states_en = 1;
     s1_random_wait_states_en = 1;
     s2_random_wait_states_en = 1;
     s3_random_wait_states_en = 1;
`else
     s0_number_wait_states    = 0;
     s1_number_wait_states    = 0;
     s2_number_wait_states    = 0;
     s3_number_wait_states    = 0;

     s0_random_wait_states_en = 0;
     s1_random_wait_states_en = 0;
     s2_random_wait_states_en = 0;
     s3_random_wait_states_en = 0;
`endif

     m0_haddr                 = 32'h00000000;
     m0_hauser                = {HAUSER_W{1'h0}};
     m0_hburst                =  3'h0;
     m0_hmastlock             =  1'h0;
     m0_hprot                 =  MGR0_HPROT;
     m0_hsize                 =  3'h0;
     m0_htrans                =  2'h0;
     m0_hwdata                = 32'h00000000;
     m0_hwrite                =  1'h0;

     m1_haddr                 = 32'h00000000;
     m1_hauser                = {HAUSER_W{1'h0}};
     m1_hburst                =  3'h0;
     m1_hmastlock             =  1'h0;
     m1_hprot                 =  MGR1_HPROT;
     m1_hsize                 =  3'h0;
     m1_htrans                =  2'h0;
     m1_hwdata                = 32'h00000000;
     m1_hwrite                =  1'h0;

     m2_haddr                 = 32'h00000000;
     m2_hauser                = {HAUSER_W{1'h0}};
     m2_hburst                =  3'h0;
     m2_hmastlock             =  1'h0;
     m2_hprot                 =  MGR2_HPROT;
     m2_hsize                 =  3'h0;
     m2_htrans                =  2'h0;
     m2_hwdata                = 32'h00000000;
     m2_hwrite                =  1'h0;
  end


assign m1_hmaster_tag = {m1_haddr_d[2] & m1_hready, 3'b111};

//--------------------------------------------------------------------
// DUT: AHB FABRIC
//--------------------------------------------------------------------
`ifdef FUSED
        parameter  NR_S_X      = 2;  // Total executable subordinates (= 1 ROM + 1 SRAM)
        parameter  NR_S_X_ROM  = 1;
        parameter  NR_S_X_SRAM = 1;

        // Wide memory pin nets driven by the fused fabric (per-instance vectors).
        // The narrow rom0_*/sram0_* nets used by the bench memory models are
        // sliced from these in the ROM/SRAM blocks further down.
        wire [30*NR_S_X_ROM -1:0] dut_rom_addr;
        wire    [NR_S_X_ROM -1:0] dut_rom_cen;
        wire    [NR_S_X_ROM -1:0] dut_rom_clk;
        wire [30*NR_S_X_SRAM-1:0] dut_sram_addr;
        wire    [NR_S_X_SRAM-1:0] dut_sram_cen;
        wire    [NR_S_X_SRAM-1:0] dut_sram_clk;
        wire [32*NR_S_X_SRAM-1:0] dut_sram_din;
        wire  [4*NR_S_X_SRAM-1:0] dut_sram_wen;

        ahb_interconnect_fused #(
            .NR_M             ( NR_M-1                   ),
            .NR_S_X_ROM       ( NR_S_X_ROM               ),
            .NR_S_X_SRAM      ( NR_S_X_SRAM              ),
            .NR_S_NX          ( NR_S-NR_S_X              ),
            .HAUSER_W         ( HAUSER_W                 ),
            .M_NX_HMASTER_TAG ( {4'h0, MGR1_HMASTER_TAG} ),
            .ASYNC_RST_EN     ( ASYNC_RST_EN             ),
`ifdef FUSED_FIXED_B_PRIO
            .FIXED_B_PRIO     ( 1'b1                     )
`else
            .FIXED_B_PRIO     ( 1'b0                     )
`endif
        ) dut (

        // AHB CLOCK & RESET
            .hclk_i                ( dut_hclk                                                ),
            .hresetn_i             ( hresetn                                                 ),

            .hclk_en_o             ( dut_hclk_en                                             ),

        // EXECUTABLE AHB BUS MANAGER INTERFACE
            .m_x_haddr_i           ( m0_haddr_d & {32{m0_hready}}                              ),
            .m_x_hauser_i          ( m0_hauser_d                                               ),
            .m_x_hburst_i          ( m0_hburst_d                                               ),
            .m_x_hmastlock_i       ( m0_hmastlock_d                                            ),
            .m_x_hprot_i           ( m0_hprot_d                                                ),
            .m_x_hsize_i           ( m0_hsize_d                                                ),
            .m_x_htrans_i          ( m0_htrans_d                                               ),
            .m_x_hwdata_i          ( m0_hwdata_d                                               ),
            .m_x_hwrite_i          ( m0_hwrite_d                                               ),

            .m_x_hrdata_o          ( m0_hrdata_dut                                               ),
            .m_x_hready_o          ( m0_hready_dut                                               ),
            .m_x_hresp_o           ( m0_hresp_dut                                                ),

        // NON-EXECUTABLE AHB MANAGER INTERFACES
            .m_nx_haddr_i          ({m2_haddr_d & {32{m2_hready}}, m1_haddr_d & {32{m1_hready}} }),
            .m_nx_hauser_i         ({m2_hauser_d,                  m1_hauser_d                  }),
            .m_nx_hburst_i         ({m2_hburst_d,                  m1_hburst_d                  }),
            .m_nx_hmaster_i        ({m2_hmaster_tag_d,             m1_hmaster_tag_d             }),
            .m_nx_hmastlock_i      ({m2_hmastlock_d,               m1_hmastlock_d               }),
            .m_nx_hprot_i          ({m2_hprot_d,                   m1_hprot_d                   }),
            .m_nx_hsize_i          ({m2_hsize_d,                   m1_hsize_d                   }),
            .m_nx_htrans_i         ({m2_htrans_d,                  m1_htrans_d                  }),
            .m_nx_hwdata_i         ({m2_hwdata_d,                  m1_hwdata_d                  }),
            .m_nx_hwrite_i         ({m2_hwrite_d,                  m1_hwrite_d                  }),

            .m_nx_hrdata_o         ({m2_hrdata_dut,                  m1_hrdata_dut                  }),
            .m_nx_hready_o         ({m2_hready_dut,                  m1_hready_dut                  }),
            .m_nx_hresp_o          ({m2_hresp_dut,                   m1_hresp_dut                   }),

        // ARBITER INTERFACE for NON-EXECUTABLE MANAGERS
            .m_nx_grant_i          ( m_grant[NR_M-2:0]                                       ),
            .m_nx_request_o        ( m_request[NR_M-2:0]                                     ),

        // ADDRESS DECODER INTERFACES (FOR ALL SUBORDINATES)
            .s_decoder_1hot_i      ( s_decoder_1hot                                          ),
            .s_decoder_addr_o      ( s_decoder_addr                                          ),

        // ADDRESS DECODER INTERFACES (FOR EXECUTABLE SUBORDINATES ONLY)
            .s_x_decoder_1hot_i    ( s_x_decoder_1hot[NR_S_X-1:0]                            ),
            .s_x_decoder_addr_o    ( s_x_decoder_addr                                        ),

        // FUSED ROM CONTROLLER MEMORY INTERFACE  (slot 0 = low decoder bit)
            .rom_dout_i            ( rom0_dout                                               ),
            .rom_addr_o            ( dut_rom_addr                                            ),
            .rom_cen_o             ( dut_rom_cen                                             ),
            .rom_clk_o             ( dut_rom_clk                                             ),

        // FUSED SRAM CONTROLLER MEMORY INTERFACE (slot 1 = high decoder bit)
            .sram_dout_i           ( sram0_dout                                              ),
            .sram_addr_o           ( dut_sram_addr                                           ),
            .sram_cen_o            ( dut_sram_cen                                            ),
            .sram_clk_o            ( dut_sram_clk                                            ),
            .sram_din_o            ( dut_sram_din                                            ),
            .sram_wen_o            ( dut_sram_wen                                            ),

        // NON-EXECUTABLE AHB SUBORDINATE INTERFACES
            .s_nx_hrdata_i         ({s3_hrdata,    s2_hrdata                                }),
            .s_nx_hreadyout_i      ({s3_hreadyout, s2_hreadyout                             }),
            .s_nx_hresp_i          ({s3_hresp,     s2_hresp                                 }),

            .s_nx_haddr_o          ({s3_haddr,     s2_haddr                                 }),
            .s_nx_hauser_o         ({s3_hauser,    s2_hauser                                }),
            .s_nx_hburst_o         ({s3_hburst,    s2_hburst                                }),
            .s_nx_hmaster_o        ({s3_hmaster,   s2_hmaster                               }),
            .s_nx_hmastlock_o      ({s3_hmastlock, s2_hmastlock                             }),
            .s_nx_hprot_o          ({s3_hprot,     s2_hprot                                 }),
            .s_nx_hready_o         ({s3_hready,    s2_hready                                }),
            .s_nx_hsel_o           ({s3_hsel,      s2_hsel                                  }),
            .s_nx_hsize_o          ({s3_hsize,     s2_hsize                                 }),
            .s_nx_htrans_o         ({s3_htrans,    s2_htrans                                }),
            .s_nx_hwdata_o         ({s3_hwdata,    s2_hwdata                                }),
            .s_nx_hwrite_o         ({s3_hwrite,    s2_hwrite                                })
        );

        ahb_decoder ahb_decoder_x_inst (

            .decoder_addr_i        ( s_x_decoder_addr                                        ),
            .decoder_1hot_o        ( s_x_decoder_1hot                                        )
        );

        assign m_request[NR_M-1] = 1'b0;

        // The fused fabric drives memory clocks directly (sram_clk_o/rom_clk_o);
        // the bench's gated s0_hclk/s1_hclk are unused.  Tie the gating enables
        // to avoid x-prop on the dangling clock-gate cells.
        assign s0_hclk_en = 1'b0;
        assign s1_hclk_en = 1'b0;

`elsif HIPERF
        parameter  NR_S_X  = 2;  // Number of Executable AHB Subordinates

        ahb_interconnect_hiperf #(
            .NR_M             ( NR_M-1                   ),
            .NR_S_X           ( NR_S_X                   ),
            .NR_S_NX          ( NR_S-NR_S_X              ),
            .HAUSER_W         ( HAUSER_W                 ),
            .M_NX_HMASTER_TAG ( {4'h0, MGR1_HMASTER_TAG} ),
            .ASYNC_RST_EN     ( ASYNC_RST_EN             )
        ) dut (

        // AHB CLOCK & RESET
            .hclk_i                ( dut_hclk                                                ),
            .hresetn_i             ( hresetn                                                 ),

            .hclk_en_o             ( dut_hclk_en                                             ),

        // EXECUTABLE AHB BUS MANAGER INTERFACE
            .m_x_haddr_i           ( m0_haddr_d & {32{m0_hready}}                              ),
            .m_x_hauser_i          ( m0_hauser_d                                               ),
            .m_x_hburst_i          ( m0_hburst_d                                               ),
            .m_x_hmastlock_i       ( m0_hmastlock_d                                            ),
            .m_x_hprot_i           ( m0_hprot_d                                                ),
            .m_x_hsize_i           ( m0_hsize_d                                                ),
            .m_x_htrans_i          ( m0_htrans_d                                               ),
            .m_x_hwdata_i          ( m0_hwdata_d                                               ),
            .m_x_hwrite_i          ( m0_hwrite_d                                               ),

            .m_x_hrdata_o          ( m0_hrdata_dut                                               ),
            .m_x_hready_o          ( m0_hready_dut                                               ),
            .m_x_hresp_o           ( m0_hresp_dut                                                ),

        // NON-EXECUTABLE AHB MANAGER INTERFACES
            .m_nx_haddr_i          ({m2_haddr_d & {32{m2_hready}}, m1_haddr_d & {32{m1_hready}} }), // Mask the address with Hready to constrain a bit more the simulation (i.e. haddr only needs to be valid during the last cycle of the address phase)
            .m_nx_hauser_i         ({m2_hauser_d,                  m1_hauser_d                  }),
            .m_nx_hburst_i         ({m2_hburst_d,                  m1_hburst_d                  }),
            .m_nx_hmaster_i        ({m2_hmaster_tag_d,             m1_hmaster_tag_d             }),
            .m_nx_hmastlock_i      ({m2_hmastlock_d,               m1_hmastlock_d               }),
            .m_nx_hprot_i          ({m2_hprot_d,                   m1_hprot_d                   }),
            .m_nx_hsize_i          ({m2_hsize_d,                   m1_hsize_d                   }),
            .m_nx_htrans_i         ({m2_htrans_d,                  m1_htrans_d                  }),
            .m_nx_hwdata_i         ({m2_hwdata_d,                  m1_hwdata_d                  }),
            .m_nx_hwrite_i         ({m2_hwrite_d,                  m1_hwrite_d                  }),

            .m_nx_hrdata_o         ({m2_hrdata_dut,                  m1_hrdata_dut                  }),
            .m_nx_hready_o         ({m2_hready_dut,                  m1_hready_dut                  }),
            .m_nx_hresp_o          ({m2_hresp_dut,                   m1_hresp_dut                   }),

        // ARBITER INTERFACE for NON-EXECUTABLE MANAGERS
            .m_nx_grant_i          ( m_grant[NR_M-2:0]                                       ),
            .m_nx_request_o        ( m_request[NR_M-2:0]                                     ),

        // ADDRESS DECODER INTERFACES (FOR ALL SUBORDINATES)
            .s_decoder_1hot_i      ( s_decoder_1hot                                          ),
            .s_decoder_addr_o      ( s_decoder_addr                                          ),

        // ADDRESS DECODER INTERFACES (FOR EXECUTABLE SUBORDINATES ONLY)
            .s_x_decoder_1hot_i    ( s_x_decoder_1hot[NR_S_X-1:0]                            ),
            .s_x_decoder_addr_o    ( s_x_decoder_addr                                        ),

        // EXECUTABLE AHB SUBORDINATE INTERFACES
            .s_x_hrdata_i          ({s1_hrdata,    s0_hrdata                                }),
            .s_x_hreadyout_i       ({s1_hreadyout, s0_hreadyout                             }),
            .s_x_hresp_i           ({s1_hresp,     s0_hresp                                 }),

            .s_x_haddr_o           ({s1_haddr,     s0_haddr                                 }),
            .s_x_hauser_o          ({s1_hauser,    s0_hauser                                }),
            .s_x_hburst_o          ({s1_hburst,    s0_hburst                                }),
            .s_x_hmaster_o         ({s1_hmaster,   s0_hmaster                               }),
            .s_x_hmastlock_o       ({s1_hmastlock, s0_hmastlock                             }),
            .s_x_hprot_o           ({s1_hprot,     s0_hprot                                 }),
            .s_x_hready_o          ({s1_hready,    s0_hready                                }),
            .s_x_hsel_o            ({s1_hsel,      s0_hsel                                  }),
            .s_x_hsize_o           ({s1_hsize,     s0_hsize                                 }),
            .s_x_htrans_o          ({s1_htrans,    s0_htrans                                }),
            .s_x_hwdata_o          ({s1_hwdata,    s0_hwdata                                }),
            .s_x_hwrite_o          ({s1_hwrite,    s0_hwrite                                }),

        // NON-EXECUTABLE AHB SUBORDINATE INTERFACES
            .s_nx_hrdata_i         ({s3_hrdata,    s2_hrdata                                }),
            .s_nx_hreadyout_i      ({s3_hreadyout, s2_hreadyout                             }),
            .s_nx_hresp_i          ({s3_hresp,     s2_hresp                                 }),

            .s_nx_haddr_o          ({s3_haddr,     s2_haddr                                 }),
            .s_nx_hauser_o         ({s3_hauser,    s2_hauser                                }),
            .s_nx_hburst_o         ({s3_hburst,    s2_hburst                                }),
            .s_nx_hmaster_o        ({s3_hmaster,   s2_hmaster                               }),
            .s_nx_hmastlock_o      ({s3_hmastlock, s2_hmastlock                             }),
            .s_nx_hprot_o          ({s3_hprot,     s2_hprot                                 }),
            .s_nx_hready_o         ({s3_hready,    s2_hready                                }),
            .s_nx_hsel_o           ({s3_hsel,      s2_hsel                                  }),
            .s_nx_hsize_o          ({s3_hsize,     s2_hsize                                 }),
            .s_nx_htrans_o         ({s3_htrans,    s2_htrans                                }),
            .s_nx_hwdata_o         ({s3_hwdata,    s2_hwdata                                }),
            .s_nx_hwrite_o         ({s3_hwrite,    s2_hwrite                                })
        );

        ahb_decoder ahb_decoder_x_inst (

            .decoder_addr_i        ( s_x_decoder_addr                                        ),
            .decoder_1hot_o        ( s_x_decoder_1hot                                        )
        );

        assign m_request[NR_M-1] = 1'b0;
`else
        ahb_interconnect_generic #(
            .NR_M         ( NR_M                           ),
            .NR_S         ( NR_S                           ),
            .HAUSER_W     ( HAUSER_W                       ),
            .M_HMASTER_TAG( {4'h0, MGR1_HMASTER_TAG, 4'h0} ),
            .ASYNC_RST_EN ( ASYNC_RST_EN                   )
        ) dut (

        // AHB CLOCK & RESET
            .hclk_i                ( dut_hclk                                                ),
            .hresetn_i             ( hresetn                                                 ),

            .hclk_en_o             ( dut_hclk_en                                             ),

        // AHB MANAGER INTERFACES
            .m_haddr_i             ({m2_haddr_d & {32{m2_hready}}, m1_haddr_d & {32{m1_hready}}, m0_haddr_d & {32{m0_hready}}}), // Mask the address with Hready to constrain a bit more the simulation (i.e. haddr only needs to be valid during the last cycle of the address phase)
            .m_hauser_i            ({m2_hauser_d,                  m1_hauser_d,                  m0_hauser_d                 }),
            .m_hburst_i            ({m2_hburst_d,                  m1_hburst_d,                  m0_hburst_d                 }),
            .m_hmaster_i           ({m2_hmaster_tag_d,             m1_hmaster_tag_d,             m0_hmaster_tag_d            }),
            .m_hmastlock_i         ({m2_hmastlock_d,               m1_hmastlock_d,               m0_hmastlock_d              }),
            .m_hprot_i             ({m2_hprot_d,                   m1_hprot_d,                   m0_hprot_d                  }),
            .m_hsize_i             ({m2_hsize_d,                   m1_hsize_d,                   m0_hsize_d                  }),
            .m_htrans_i            ({m2_htrans_d,                  m1_htrans_d,                  m0_htrans_d                 }),
            .m_hwdata_i            ({m2_hwdata_d,                  m1_hwdata_d,                  m0_hwdata_d                 }),
            .m_hwrite_i            ({m2_hwrite_d,                  m1_hwrite_d,                  m0_hwrite_d                 }),

            .m_hrdata_o            ({m2_hrdata_dut,                  m1_hrdata_dut,                  m0_hrdata_dut                 }),
            .m_hready_o            ({m2_hready_dut,                  m1_hready_dut,                  m0_hready_dut                 }),
            .m_hresp_o             ({m2_hresp_dut,                   m1_hresp_dut,                   m0_hresp_dut                  }),

        // ARBITER INTERFACES
            .m_grant_i             ( m_grant                                                 ),
            .m_request_o           ( m_request                                               ),

        // ADDRESS DECODER INTERFACES
            .s_decoder_1hot_i      ( s_decoder_1hot                                          ),
            .s_decoder_addr_o      ( s_decoder_addr                                          ),

        // AHB SUBORDINATE INTERFACES
            .s_hrdata_i            ({s3_hrdata,    s2_hrdata,    s1_hrdata,    s0_hrdata    }),
            .s_hreadyout_i         ({s3_hreadyout, s2_hreadyout, s1_hreadyout, s0_hreadyout }),
            .s_hresp_i             ({s3_hresp,     s2_hresp,     s1_hresp,     s0_hresp     }),

            .s_haddr_o             ({s3_haddr,     s2_haddr,     s1_haddr,     s0_haddr     }),
            .s_hauser_o            ({s3_hauser,    s2_hauser,    s1_hauser,    s0_hauser    }),
            .s_hburst_o            ({s3_hburst,    s2_hburst,    s1_hburst,    s0_hburst    }),
            .s_hmaster_o           ({s3_hmaster,   s2_hmaster,   s1_hmaster,   s0_hmaster   }),
            .s_hmastlock_o         ({s3_hmastlock, s2_hmastlock, s1_hmastlock, s0_hmastlock }),
            .s_hprot_o             ({s3_hprot,     s2_hprot,     s1_hprot,     s0_hprot     }),
            .s_hready_o            ({s3_hready,    s2_hready,    s1_hready,    s0_hready    }),
            .s_hsel_o              ({s3_hsel,      s2_hsel,      s1_hsel,      s0_hsel      }),
            .s_hsize_o             ({s3_hsize,     s2_hsize,     s1_hsize,     s0_hsize     }),
            .s_htrans_o            ({s3_htrans,    s2_htrans,    s1_htrans,    s0_htrans    }),
            .s_hwdata_o            ({s3_hwdata,    s2_hwdata,    s1_hwdata,    s0_hwdata    }),
            .s_hwrite_o            ({s3_hwrite,    s2_hwrite,    s1_hwrite,    s0_hwrite    })
        );

`endif


//--------------------------------------------------------------------
// AHB ARBITER & ADDRESS DECODER
//--------------------------------------------------------------------

ahb_arbiter ahb_arbiter_inst (

    .hclk_i               ( dut_hclk                    ),
    .hresetn_i            ( hresetn                     ),
    .request_i            ( m_request                   ),
    .grant_o              ( m_grant                     )
);

ahb_decoder ahb_decoder_inst (

    .decoder_addr_i       ( s_decoder_addr              ),
    .decoder_1hot_o       ( s_decoder_1hot              )
);


//--------------------------------------------------------------------
// AHB Protocol Checkers (one per manager port, passive)
//
// Each instance asserts that the master holds HADDR / HTRANS / HSIZE /
// HWRITE / HBURST stable across wait states (i.e. while HREADY is low
// and HRESP is not an ERROR response).  No fabric output is driven.
//--------------------------------------------------------------------

reg                  protocol_checker_enable;  // set/cleared per test if needed
initial              protocol_checker_enable = 1'b1;

ahb_protocol_checker ahb_protocol_checker_m0 (
    .bus_name_i           ( {496'h0, "M0"}              ),
    .hclk_i               ( free_clk                    ),
    .hresetn_i            ( hresetn                     ),
    .haddr_i              ( m0_haddr_d                    ),
    .htrans_i             ( m0_htrans_d                   ),
    .hsize_i              ( m0_hsize_d                    ),
    .hwrite_i             ( m0_hwrite_d                   ),
    .hburst_i             ( m0_hburst_d                   ),
    .hready_i             ( m0_hready                   ),
    .hresp_i              ( m0_hresp                    ),
    .checker_enable_i     ( protocol_checker_enable     )
);

ahb_protocol_checker ahb_protocol_checker_m1 (
    .bus_name_i           ( {496'h0, "M1"}              ),
    .hclk_i               ( free_clk                    ),
    .hresetn_i            ( hresetn                     ),
    .haddr_i              ( m1_haddr_d                    ),
    .htrans_i             ( m1_htrans_d                   ),
    .hsize_i              ( m1_hsize_d                    ),
    .hwrite_i             ( m1_hwrite_d                   ),
    .hburst_i             ( m1_hburst_d                   ),
    .hready_i             ( m1_hready                   ),
    .hresp_i              ( m1_hresp                    ),
    .checker_enable_i     ( protocol_checker_enable     )
);

ahb_protocol_checker ahb_protocol_checker_m2 (
    .bus_name_i           ( {496'h0, "M2"}              ),
    .hclk_i               ( free_clk                    ),
    .hresetn_i            ( hresetn                     ),
    .haddr_i              ( m2_haddr_d                    ),
    .htrans_i             ( m2_htrans_d                   ),
    .hsize_i              ( m2_hsize_d                    ),
    .hwrite_i             ( m2_hwrite_d                   ),
    .hburst_i             ( m2_hburst_d                   ),
    .hready_i             ( m2_hready                   ),
    .hresp_i              ( m2_hresp                    ),
    .checker_enable_i     ( protocol_checker_enable     )
);


//--------------------------------------------------------------------
// HMASTER ID propagation monitor — passive
//
// On every APH-commit cycle (hsel & hready & htrans[1]) at any slave,
// the slave-side hmaster MUST equal the ID of the master that issued
// the APH. Expected value per variant:
//
//   GENERIC :  single 3-master arbiter; for any slave
//                m_grant[i]==1  =>  expected = i
//
//   In every variant M1's expectation also carries its tag bit, recomputed
//   from the checked slave's haddr[2] (see MGR1_HMASTER_TAG).
//
//   HIPERF  :  NX-side slaves (s2, s3): NX arbiter grants M1/M2 via
//                m_grant[1:0]   =>  expected = grant+1
//              X-side slaves (s0, s1): per-X-slave 2-master mux
//              (X vs NX). Use DUT's internal s_x_grant[2*i+:2]:
//                s_x_grant[2*i+0]==1  => expected = 0 (M_X)
//                s_x_grant[2*i+1]==1  => expected = grant+1 (NX side)
//
//   FUSED   :  X-side fused leaves drive memory pins directly; the
//              external s_x_hmaster ports are not connected so we
//              skip s0/s1. NX-side same as HIPERF.
//
// Counts cov_hmaster_checks / cov_hmaster_fails for confidence.
//--------------------------------------------------------------------

reg                  hmaster_checker_enable;
initial              hmaster_checker_enable = 1'b1;

integer              cov_hmaster_checks;
integer              cov_hmaster_fails;
initial begin
    cov_hmaster_checks = 0;
    cov_hmaster_fails  = 0;
end

reg            [3:0] exp_hm_nx;        // NX-side expected hmaster
reg            [3:0] exp_hm_generic;   // generic-variant expected hmaster
reg            [3:0] exp_hm_x_s0, exp_hm_x_s1;  // HIPERF X-slave expected

function [3:0] m1_tagged;
    input      [3:0] id;
    input            is_m1;
    input     [31:0] haddr;
    begin
        m1_tagged = id | ({4{is_m1 & haddr[2]}} & MGR1_HMASTER_TAG);
    end
endfunction

task check_hmaster;
    input  [8*8-1:0] slave_name;       // up to 8-char label
    input      [3:0] observed;
    input      [3:0] expected;
    begin
        cov_hmaster_checks = cov_hmaster_checks + 1;
        if (observed !== expected) begin
            $display("ERROR-VERILOG: [HMASTER mismatch] slave=%0s observed=0x%h expected=0x%h (t=%t)",
                     slave_name, observed, expected, $time);
            error              = error              + 1;
            cov_hmaster_fails  = cov_hmaster_fails  + 1;
        end
    end
endtask

// Loose check: hmaster must be a valid master ID (∈ {0, 1, 2}, or 9 for
// M1 with its tag set, in our 3-master TB).  Used for HIPERF X-side slaves where the two-level
// routing (NX manager_mux → per-X-slave manager_mux) with independent
// m_aph_pending at each level makes the exact expected-value formula
// too brittle for a passive monitor.
task check_hmaster_in_range;
    input  [8*8-1:0] slave_name;
    input      [3:0] observed;
    begin
        cov_hmaster_checks = cov_hmaster_checks + 1;
        if (!((observed == 4'h0) || (observed == 4'h1) || (observed == 4'h2) || (observed == 4'h9))) begin
            $display("ERROR-VERILOG: [HMASTER out of range] slave=%0s observed=0x%h (valid: 0..2, 9) (t=%t)",
                     slave_name, observed, $time);
            error              = error              + 1;
            cov_hmaster_fails  = cov_hmaster_fails  + 1;
        end
    end
endtask

always @(posedge free_clk) begin
    if (hresetn && tb_rst_done && hmaster_checker_enable) begin
`ifdef HIPERF
        // NX side: strict — top-level NX arbiter (m_grant[1:0]) determines hmaster
        exp_hm_nx = m_grant[0] ? 4'h1 : (m_grant[1] ? 4'h2 : 4'h0);
        if (s2_hsel & s2_hready & s2_htrans[1]) check_hmaster("s2", s2_hmaster, m1_tagged(exp_hm_nx, m_grant[0], s2_haddr));
        if (s3_hsel & s3_hready & s3_htrans[1]) check_hmaster("s3", s3_hmaster, m1_tagged(exp_hm_nx, m_grant[0], s3_haddr));
        // X side: loose (any valid master ID); two-level routing with caching
        // makes a strict prediction non-trivial.
        if (s0_hsel & s0_hready & s0_htrans[1]) check_hmaster_in_range("s0", s0_hmaster);
        if (s1_hsel & s1_hready & s1_htrans[1]) check_hmaster_in_range("s1", s1_hmaster);
`else `ifdef FUSED
        // FUSED: only NX-side hmaster is externally observable
        exp_hm_nx = m_grant[0] ? 4'h1 : (m_grant[1] ? 4'h2 : 4'h0);
        if (s2_hsel & s2_hready & s2_htrans[1]) check_hmaster("s2", s2_hmaster, m1_tagged(exp_hm_nx, m_grant[0], s2_haddr));
        if (s3_hsel & s3_hready & s3_htrans[1]) check_hmaster("s3", s3_hmaster, m1_tagged(exp_hm_nx, m_grant[0], s3_haddr));
`else
        // GENERIC: single 3-master arbiter, strict check on all slaves
        exp_hm_generic = m_grant[0] ? 4'h0 : (m_grant[1] ? 4'h1 : (m_grant[2] ? 4'h2 : 4'h0));
        if (s0_hsel & s0_hready & s0_htrans[1]) check_hmaster("s0", s0_hmaster, m1_tagged(exp_hm_generic, m_grant[1], s0_haddr));
        if (s1_hsel & s1_hready & s1_htrans[1]) check_hmaster("s1", s1_hmaster, m1_tagged(exp_hm_generic, m_grant[1], s1_haddr));
        if (s2_hsel & s2_hready & s2_htrans[1]) check_hmaster("s2", s2_hmaster, m1_tagged(exp_hm_generic, m_grant[1], s2_haddr));
        if (s3_hsel & s3_hready & s3_htrans[1]) check_hmaster("s3", s3_hmaster, m1_tagged(exp_hm_generic, m_grant[1], s3_haddr));
`endif
`endif
    end
end


//--------------------------------------------------------------------
// PRIVILEGE SIDEBAND CHECKER
//
// hauser carries the aRVern hsmode bit and hprot[1] the privileged bit, so
// together they are how every privilege-filtering IP downstream learns the
// access mode. The fabric must present the GRANTED manager's pair to the
// selected subordinate, unchanged, on every layer. Nothing else in this bench
// looks at them: without this check a fabric that dropped, crossed or stuck
// the sideband would pass the entire regression, and the filtering it feeds
// would silently police the wrong master.
//
// Checked at address-phase commit (hsel & hready & htrans[1]), the same
// instant the HMASTER checker uses. Expectations are per-variant for the same
// reason: the X side of HIPERF routes through two levels with caching, so it
// is checked loosely (must match SOME manager's pair) while the NX side is
// strict (must match the granted one).
//--------------------------------------------------------------------

reg                  sideband_checker_enable;
initial              sideband_checker_enable = 1'b1;

integer              cov_sideband_checks;
integer              cov_sideband_fails;
initial begin
    cov_sideband_checks = 0;
    cov_sideband_fails  = 0;
end

reg [HAUSER_W-1:0]   exp_hauser_nx;
reg            [3:0] exp_hprot_nx;

task check_sideband;
    input  [8*8-1:0] slave_name;
    input [HAUSER_W-1:0] obs_hauser;
    input      [3:0] obs_hprot;
    input [HAUSER_W-1:0] exp_hauser;
    input      [3:0] exp_hprot;
    begin
        cov_sideband_checks = cov_sideband_checks + 1;
        if ((obs_hauser !== exp_hauser) || (obs_hprot !== exp_hprot)) begin
            $display("ERROR: sideband mis-routed on %0s -- hauser %b/%b hprot %h/%h (obs/exp) %t ns",
                     slave_name, obs_hauser, exp_hauser, obs_hprot, exp_hprot, $time);
            error               = error               + 1;
            cov_sideband_fails  = cov_sideband_fails  + 1;
        end
    end
endtask

// Loose form: the pair must belong to SOME manager. Catches a dropped or stuck
// sideband, and any value the fabric invented, without predicting the routing.
task check_sideband_any;
    input  [8*8-1:0] slave_name;
    input [HAUSER_W-1:0] obs_hauser;
    input      [3:0] obs_hprot;
    begin
        cov_sideband_checks = cov_sideband_checks + 1;
        if (!(((obs_hauser === m0_hauser) && (obs_hprot === MGR0_HPROT)) ||
              ((obs_hauser === m1_hauser) && (obs_hprot === MGR1_HPROT)) ||
              ((obs_hauser === m2_hauser) && (obs_hprot === MGR2_HPROT)))) begin
            $display("ERROR: sideband on %0s matches no manager -- hauser=%b hprot=%h %t ns",
                     slave_name, obs_hauser, obs_hprot, $time);
            error               = error               + 1;
            cov_sideband_fails  = cov_sideband_fails  + 1;
        end
    end
endtask

always @(posedge free_clk) begin
    if (hresetn && tb_rst_done && sideband_checker_enable) begin
`ifdef HIPERF
        exp_hauser_nx = m_grant[0] ? m1_hauser  : (m_grant[1] ? m2_hauser  : m1_hauser);
        exp_hprot_nx  = m_grant[0] ? MGR1_HPROT : (m_grant[1] ? MGR2_HPROT : MGR1_HPROT);
        if (s2_hsel & s2_hready & s2_htrans[1]) check_sideband("s2", s2_hauser, s2_hprot, exp_hauser_nx, exp_hprot_nx);
        if (s3_hsel & s3_hready & s3_htrans[1]) check_sideband("s3", s3_hauser, s3_hprot, exp_hauser_nx, exp_hprot_nx);
        if (s0_hsel & s0_hready & s0_htrans[1]) check_sideband_any("s0", s0_hauser, s0_hprot);
        if (s1_hsel & s1_hready & s1_htrans[1]) check_sideband_any("s1", s1_hauser, s1_hprot);
`else `ifdef FUSED
        exp_hauser_nx = m_grant[0] ? m1_hauser  : (m_grant[1] ? m2_hauser  : m1_hauser);
        exp_hprot_nx  = m_grant[0] ? MGR1_HPROT : (m_grant[1] ? MGR2_HPROT : MGR1_HPROT);
        if (s2_hsel & s2_hready & s2_htrans[1]) check_sideband("s2", s2_hauser, s2_hprot, exp_hauser_nx, exp_hprot_nx);
        if (s3_hsel & s3_hready & s3_htrans[1]) check_sideband("s3", s3_hauser, s3_hprot, exp_hauser_nx, exp_hprot_nx);
`else
        exp_hauser_nx = m_grant[0] ? m0_hauser  : (m_grant[1] ? m1_hauser  : (m_grant[2] ? m2_hauser  : m0_hauser));
        exp_hprot_nx  = m_grant[0] ? MGR0_HPROT : (m_grant[1] ? MGR1_HPROT : (m_grant[2] ? MGR2_HPROT : MGR0_HPROT));
        if (s0_hsel & s0_hready & s0_htrans[1]) check_sideband("s0", s0_hauser, s0_hprot, exp_hauser_nx, exp_hprot_nx);
        if (s1_hsel & s1_hready & s1_htrans[1]) check_sideband("s1", s1_hauser, s1_hprot, exp_hauser_nx, exp_hprot_nx);
        if (s2_hsel & s2_hready & s2_htrans[1]) check_sideband("s2", s2_hauser, s2_hprot, exp_hauser_nx, exp_hprot_nx);
        if (s3_hsel & s3_hready & s3_htrans[1]) check_sideband("s3", s3_hauser, s3_hprot, exp_hauser_nx, exp_hprot_nx);
`endif
`endif
    end
end


//--------------------------------------------------------------------
// ROM Memory
//--------------------------------------------------------------------

`ifdef FUSED
   // Fused mode: the fused ROM controller (instantiated inside the DUT) drives
   // the rom memory pins directly.  Slice the wide fabric output down to the
   // bench memory's word index width.
   assign rom0_addr = dut_rom_addr[MEM_ADDRW-1:0];
   assign rom0_cen  = dut_rom_cen [0];
   assign rom0_clk  = dut_rom_clk [0];
`else
ahb_waitstate_inserter #(HAUSER_W) ahb_waitstate_inserter_rom_inst (

// AHB CLOCK & RESET
    .hclk_i                   ( free_clk                ),
    .hresetn_i                ( hresetn                 ),

    .number_wait_state        ( s0_number_wait_states   ),
    .random_wait_state_enable ( s0_random_wait_states_en),

// AHB INTERFACE (TO FABRIC OR DRIVER)
    .haddr_i                  ( s0_haddr                ),
    .hauser_i                 ( s0_hauser               ),
    .hprot_i                  ( s0_hprot                ),
    .hready_i                 ( s0_hready               ),
    .hsize_i                  ( s0_hsize                ),
    .htrans_i                 ( s0_htrans               ),
    .hwdata_i                 ( s0_hwdata               ),
    .hwrite_i                 ( s0_hwrite               ),
    .hsel_i                   ( s0_hsel                 ),
    .hrdata_o                 ( s0_hrdata               ),
    .hreadyout_o              ( s0_hreadyout            ),
    .hresp_o                  ( s0_hresp                ),

// AHB INTERFACE (TO AHB SUBORDINATE)
    .s_haddr_o                ( ws_s0_haddr             ),
    .s_hauser_o               ( ws_s0_hauser            ),
    .s_hprot_o                ( ws_s0_hprot             ),
    .s_hready_o               ( ws_s0_hready            ),
    .s_hsize_o                ( ws_s0_hsize             ),
    .s_htrans_o               ( ws_s0_htrans            ),
    .s_hwdata_o               ( ws_s0_hwdata            ),
    .s_hwrite_o               ( ws_s0_hwrite            ),
    .s_hsel_o                 ( ws_s0_hsel              ),
    .s_hrdata_i               ( ws_s0_hrdata            ),
    .s_hreadyout_i            ( ws_s0_hreadyout         ),
    .s_hresp_i                ( ws_s0_hresp             )
 );

ahb_rom_controller #(.MEM_SIZE(MEM_SIZE), .ASYNC_RST_EN(ASYNC_RST_EN)) ahb_rom_ctrl_inst0 (

// AHB CLOCK & RESET
    .hclk_i               ( s0_hclk                     ),
    .hresetn_i            ( hresetn                     ),
    .hclk_en_o            ( s0_hclk_en                  ),

// AHB INTERFACE
    .haddr_i              ( ws_s0_haddr[MEM_HADDRW-1:0] ),
    .hready_i             ( ws_s0_hready                ),
    .hsize_i              ( ws_s0_hsize                 ),
    .htrans_i             ( ws_s0_htrans                ),
    .hwdata_i             ( ws_s0_hwdata                ),
    .hwrite_i             ( ws_s0_hwrite                ),
    .hsel_i               ( ws_s0_hsel                  ),
    .hrdata_o             ( ws_s0_hrdata                ),
    .hreadyout_o          ( ws_s0_hreadyout             ),
    .hresp_o              ( ws_s0_hresp                 ),

// SRAM INTERFACE
    .rom_dout_i           ( rom0_dout                   ),
    .rom_addr_o           ( rom0_addr                   ),
    .rom_cen_o            ( rom0_cen                    ),
    .rom_clk_o            ( rom0_clk                    )
 );
`endif

rom #(MEM_ADDRW, MEM_SIZE) rom_inst0 (

// OUTPUTs
    .rom_dout_o           ( rom0_dout                   ),

// INPUTs
    .rom_addr_i           ( rom0_addr                   ),
    .rom_cen_i            ( rom0_cen                    ),
    .rom_clk_i            ( rom0_clk                    )
);


//--------------------------------------------------------------------
// SRAM Memory
//--------------------------------------------------------------------

`ifdef FUSED
   // Fused mode: the fused SRAM controller (inside the DUT) drives the sram
   // memory pins directly.  Slice the wide fabric output down to the bench
   // memory's word index width.
   assign sram0_addr = dut_sram_addr[MEM_ADDRW-1:0];
   assign sram0_cen  = dut_sram_cen [0];
   assign sram0_clk  = dut_sram_clk [0];
   assign sram0_din  = dut_sram_din;
   assign sram0_wen  = dut_sram_wen;
`else
ahb_waitstate_inserter #(HAUSER_W) ahb_waitstate_inserter_sram_inst (

// AHB CLOCK & RESET
    .hclk_i                   ( free_clk                ),
    .hresetn_i                ( hresetn                 ),

    .number_wait_state        ( s1_number_wait_states   ),
    .random_wait_state_enable ( s1_random_wait_states_en),

// AHB INTERFACE (TO FABRIC OR DRIVER)
    .haddr_i                  ( s1_haddr                ),
    .hauser_i                 ( s1_hauser               ),
    .hprot_i                  ( s1_hprot                ),
    .hready_i                 ( s1_hready               ),
    .hsize_i                  ( s1_hsize                ),
    .htrans_i                 ( s1_htrans               ),
    .hwdata_i                 ( s1_hwdata               ),
    .hwrite_i                 ( s1_hwrite               ),
    .hsel_i                   ( s1_hsel                 ),
    .hrdata_o                 ( s1_hrdata               ),
    .hreadyout_o              ( s1_hreadyout            ),
    .hresp_o                  ( s1_hresp                ),

// AHB INTERFACE (TO AHB SUBORDINATE)
    .s_haddr_o                ( ws_s1_haddr             ),
    .s_hauser_o               ( ws_s1_hauser            ),
    .s_hprot_o                ( ws_s1_hprot             ),
    .s_hready_o               ( ws_s1_hready            ),
    .s_hsize_o                ( ws_s1_hsize             ),
    .s_htrans_o               ( ws_s1_htrans            ),
    .s_hwdata_o               ( ws_s1_hwdata            ),
    .s_hwrite_o               ( ws_s1_hwrite            ),
    .s_hsel_o                 ( ws_s1_hsel              ),
    .s_hrdata_i               ( ws_s1_hrdata            ),
    .s_hreadyout_i            ( ws_s1_hreadyout         ),
    .s_hresp_i                ( ws_s1_hresp             )
 );

ahb_sram_controller #(.MEM_SIZE(MEM_SIZE), .ASYNC_RST_EN(ASYNC_RST_EN)) ahb_sram_ctrl_inst0 (

// AHB CLOCK & RESET
    .hclk_i               ( s1_hclk                     ),
    .hresetn_i            ( hresetn                     ),
    .hclk_en_o            ( s1_hclk_en                  ),

// AHB INTERFACE
    .haddr_i              ( ws_s1_haddr[MEM_HADDRW-1:0] ),
    .hready_i             ( ws_s1_hready                ),
    .hsize_i              ( ws_s1_hsize                 ),
    .htrans_i             ( ws_s1_htrans                ),
    .hwdata_i             ( ws_s1_hwdata                ),
    .hwrite_i             ( ws_s1_hwrite                ),
    .hsel_i               ( ws_s1_hsel                  ),
    .hrdata_o             ( ws_s1_hrdata                ),
    .hreadyout_o          ( ws_s1_hreadyout             ),
    .hresp_o              ( ws_s1_hresp                 ),

// SRAM INTERFACE
    .sram_dout_i          ( sram0_dout                  ),
    .sram_addr_o          ( sram0_addr                  ),
    .sram_cen_o           ( sram0_cen                   ),
    .sram_clk_o           ( sram0_clk                   ),
    .sram_din_o           ( sram0_din                   ),
    .sram_wen_o           ( sram0_wen                   )
 );
`endif

sram #(MEM_ADDRW, MEM_SIZE) sram_inst0 (

// OUTPUTs
    .sram_dout_o          ( sram0_dout                  ),

// INPUTs
    .sram_addr_i          ( sram0_addr                  ),
    .sram_cen_i           ( sram0_cen                   ),
    .sram_clk_i           ( sram0_clk                   ),
    .sram_din_i           ( sram0_din                   ),
    .sram_wen_i           ( sram0_wen                   )
);

//--------------------------------------------------------------------
// AHB Peripheral #0
//--------------------------------------------------------------------

ahb_waitstate_inserter #(HAUSER_W) ahb_waitstate_inserter_periph0_inst (

// AHB CLOCK & RESET
    .hclk_i                   ( free_clk                ),
    .hresetn_i                ( hresetn                 ),

    .number_wait_state        ( s2_number_wait_states   ),
    .random_wait_state_enable ( s2_random_wait_states_en),

// AHB INTERFACE (TO FABRIC OR DRIVER)
    .haddr_i                  ( s2_haddr                ),
    .hauser_i                 ( s2_hauser               ),
    .hprot_i                  ( s2_hprot                ),
    .hready_i                 ( s2_hready               ),
    .hsize_i                  ( s2_hsize                ),
    .htrans_i                 ( s2_htrans               ),
    .hwdata_i                 ( s2_hwdata               ),
    .hwrite_i                 ( s2_hwrite               ),
    .hsel_i                   ( s2_hsel                 ),
    .hrdata_o                 ( s2_hrdata               ),
    .hreadyout_o              ( s2_hreadyout            ),
    .hresp_o                  ( s2_hresp                ),

// AHB INTERFACE (TO AHB SUBORDINATE)
    .s_haddr_o                ( ws_s2_haddr             ),
    .s_hauser_o               ( ws_s2_hauser            ),
    .s_hprot_o                ( ws_s2_hprot             ),
    .s_hready_o               ( ws_s2_hready            ),
    .s_hsize_o                ( ws_s2_hsize             ),
    .s_htrans_o               ( ws_s2_htrans            ),
    .s_hwdata_o               ( ws_s2_hwdata            ),
    .s_hwrite_o               ( ws_s2_hwrite            ),
    .s_hsel_o                 ( ws_s2_hsel              ),
    .s_hrdata_i               ( ws_s2_hrdata            ),
    .s_hreadyout_i            ( ws_s2_hreadyout         ),
    .s_hresp_i                ( ws_s2_hresp             )
 );

ahb_periph_example #(.ASYNC_RST_EN(ASYNC_RST_EN)) ahb_periph_example_inst0 (

// AHB CLOCK & RESET
    .hclk_i               ( s2_hclk                     ),
    .hresetn_i            ( hresetn                     ),
    .hclk_en_o            ( s2_hclk_en                  ),

// AHB INTERFACE
    .haddr_i              ( ws_s2_haddr[6:0]            ),
    .hprot_i              ( ws_s2_hprot                 ),
    .hready_i             ( ws_s2_hready                ),
    .hsmode_i             ( ws_s2_hauser[0]             ),
    .hsize_i              ( ws_s2_hsize                 ),
    .htrans_i             ( ws_s2_htrans                ),
    .hwdata_i             ( ws_s2_hwdata                ),
    .hwrite_i             ( ws_s2_hwrite                ),
    .hsel_i               ( ws_s2_hsel                  ),
    .hrdata_o             ( ws_s2_hrdata                ),
    .hreadyout_o          ( ws_s2_hreadyout             ),
    .hresp_o              ( ws_s2_hresp                 ),

// REGISTERS (FOR PROBING)
    .register_00_o        ( periph0_reg_00_out          ),
    .register_01_o        ( periph0_reg_01_out          ),
    .register_02_o        ( periph0_reg_02_out          ),
    .register_03_o        ( periph0_reg_03_out          ),
    .register_04_o        ( periph0_reg_04_out          ),
    .register_05_o        ( periph0_reg_05_out          ),
    .register_06_o        ( periph0_reg_06_out          ),
    .register_07_o        ( periph0_reg_07_out          ),

    .register_08_i        ( periph0_reg_08_in           ),
    .register_09_i        ( periph0_reg_09_in           ),
    .register_10_i        ( periph0_reg_10_in           ),
    .register_11_i        ( periph0_reg_11_in           ),
    .register_12_i        ( periph0_reg_12_in           ),
    .register_13_i        ( periph0_reg_13_in           ),
    .register_14_i        ( periph0_reg_14_in           ),
    .register_15_i        ( periph0_reg_15_in           )
 );

//--------------------------------------------------------------------
// AHB Peripheral #1
//--------------------------------------------------------------------

ahb_waitstate_inserter #(HAUSER_W) ahb_waitstate_inserter_periph1_inst (

// AHB CLOCK & RESET
    .hclk_i                   ( free_clk                ),
    .hresetn_i                ( hresetn                 ),

    .number_wait_state        ( s3_number_wait_states   ),
    .random_wait_state_enable ( s3_random_wait_states_en),

// AHB INTERFACE (TO FABRIC OR DRIVER)
    .haddr_i                  ( s3_haddr                ),
    .hauser_i                 ( s3_hauser               ),
    .hprot_i                  ( s3_hprot                ),
    .hready_i                 ( s3_hready               ),
    .hsize_i                  ( s3_hsize                ),
    .htrans_i                 ( s3_htrans               ),
    .hwdata_i                 ( s3_hwdata               ),
    .hwrite_i                 ( s3_hwrite               ),
    .hsel_i                   ( s3_hsel                 ),
    .hrdata_o                 ( s3_hrdata               ),
    .hreadyout_o              ( s3_hreadyout            ),
    .hresp_o                  ( s3_hresp                ),

// AHB INTERFACE (TO AHB SUBORDINATE)
    .s_haddr_o                ( ws_s3_haddr             ),
    .s_hauser_o               ( ws_s3_hauser            ),
    .s_hprot_o                ( ws_s3_hprot             ),
    .s_hready_o               ( ws_s3_hready            ),
    .s_hsize_o                ( ws_s3_hsize             ),
    .s_htrans_o               ( ws_s3_htrans            ),
    .s_hwdata_o               ( ws_s3_hwdata            ),
    .s_hwrite_o               ( ws_s3_hwrite            ),
    .s_hsel_o                 ( ws_s3_hsel              ),
    .s_hrdata_i               ( ws_s3_hrdata            ),
    .s_hreadyout_i            ( ws_s3_hreadyout         ),
    .s_hresp_i                ( ws_s3_hresp             )
 );

ahb_periph_example #(.ASYNC_RST_EN(ASYNC_RST_EN)) ahb_periph_example_inst1 (

// AHB CLOCK & RESET
    .hclk_i               ( s3_hclk                     ),
    .hresetn_i            ( hresetn                     ),
    .hclk_en_o            ( s3_hclk_en                  ),

// AHB INTERFACE
    .haddr_i              ( ws_s3_haddr[6:0]            ),
    .hprot_i              ( ws_s3_hprot                 ),
    .hready_i             ( ws_s3_hready                ),
    .hsize_i              ( ws_s3_hsize                 ),
    .hsmode_i             ( ws_s3_hauser[0]             ),
    .htrans_i             ( ws_s3_htrans                ),
    .hwdata_i             ( ws_s3_hwdata                ),
    .hwrite_i             ( ws_s3_hwrite                ),
    .hsel_i               ( ws_s3_hsel                  ),
    .hrdata_o             ( ws_s3_hrdata                ),
    .hreadyout_o          ( ws_s3_hreadyout             ),
    .hresp_o              ( ws_s3_hresp                 ),

// REGISTERS (FOR PROBING)
    .register_00_o        ( periph1_reg_00_out          ),
    .register_01_o        ( periph1_reg_01_out          ),
    .register_02_o        ( periph1_reg_02_out          ),
    .register_03_o        ( periph1_reg_03_out          ),
    .register_04_o        ( periph1_reg_04_out          ),
    .register_05_o        ( periph1_reg_05_out          ),
    .register_06_o        ( periph1_reg_06_out          ),
    .register_07_o        ( periph1_reg_07_out          ),

    .register_08_i        ( periph1_reg_08_in           ),
    .register_09_i        ( periph1_reg_09_in           ),
    .register_10_i        ( periph1_reg_10_in           ),
    .register_11_i        ( periph1_reg_11_in           ),
    .register_12_i        ( periph1_reg_12_in           ),
    .register_13_i        ( periph1_reg_13_in           ),
    .register_14_i        ( periph1_reg_14_in           ),
    .register_15_i        ( periph1_reg_15_in           )
 );


//
// Generate Waveform
//----------------------------------------
initial
  begin
   `ifdef NODUMP
   `else
     `ifdef VPD_FILE
        $vcdplusfile("tb_ahb_interconnect.vpd");
        $vcdpluson();
     `else
       `ifdef TRN_FILE
          $recordfile ("tb_ahb_interconnect.trn");
          $recordvars;
       `else
          $dumpfile("tb_ahb_interconnect.vcd");
          $dumpvars(0, tb_ahb_interconnect);
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
     #50000000;
     `else
       #5000000;
     `endif
     `endif
       $display(" ===============================================");
       $display("|               SIMULATION FAILED               |");
       $display("|              (simulation Timeout)             |");
       $display(" ===============================================");
       $display("");
     `ifdef FUSED
       $display("FUSED DUT");
     `elsif HIPERF
       $display("HIPERF DUT");
     `else
       $display("GENERIC DUT");
     `endif
       $display("");
       tb_extra_report;
       $finish;
   `endif
  end

//--------------------------------------------------------------------
// Fabric invariant checker: at most one manager owns a data phase per
// bus (Architectural Constraint #2). Two m_dph_ongoing bits set at once
// means two masters share hwdata/hrdata/hresp -- silent corruption even
// if the data compare happens to pass.
//--------------------------------------------------------------------
integer dph_viol_cnt;
initial dph_viol_cnt = 0;

`ifdef FUSED
wire [1:0] dph_owners = { dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_dph_ongoing,
                          dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_dph_ongoing };
`elsif HIPERF
wire [1:0] dph_owners = { dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_dph_ongoing,
                          dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_dph_ongoing };
`else
wire [2:0] dph_owners = { dut.ahb_manager_mux_inst.AHB_MANAGER_IF[2].ahb_manager_if_inst.m_dph_ongoing,
                          dut.ahb_manager_mux_inst.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_dph_ongoing,
                          dut.ahb_manager_mux_inst.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_dph_ongoing };
`endif

always @(posedge dut_hclk)
   if (hresetn && tb_rst_done && (dph_owners & (dph_owners - 1)) != 0) begin      // more than one bit set
      dph_viol_cnt = dph_viol_cnt + 1;
      if (dph_viol_cnt <= 8)
         $display("ERROR: two managers own a data phase at once (m_dph_ongoing = %b) %t", dph_owners, $time);
   end

`ifdef HIPERF
// The same invariant on each executable subordinate's level-2 bus, where the
// executable manager and the non-executable sub-fabric contend.
wire [1:0] dph_owners_x0 = { dut.AHB_MANAGER_MUX_X[0].ahb_manager_mux_inst_x.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_dph_ongoing,
                             dut.AHB_MANAGER_MUX_X[0].ahb_manager_mux_inst_x.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_dph_ongoing };
wire [1:0] dph_owners_x1 = { dut.AHB_MANAGER_MUX_X[1].ahb_manager_mux_inst_x.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_dph_ongoing,
                             dut.AHB_MANAGER_MUX_X[1].ahb_manager_mux_inst_x.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_dph_ongoing };
always @(posedge dut_hclk)
   if (hresetn && tb_rst_done && (&dph_owners_x0 || &dph_owners_x1)) begin
      dph_viol_cnt = dph_viol_cnt + 1;
      if (dph_viol_cnt <= 8)
         $display("ERROR: two channels own a data phase on an executable subordinate (s0 %b, s1 %b) %t",
                  dph_owners_x0, dph_owners_x1, $time);
   end
`endif

// Subordinate-side HREADY protocol violations (see ahb_waitstate_inserter.v,
// "a stalling subordinate must see HREADY=0"). Counted inside the wait-state
// models; folded into `error` at the end of the test.
integer hready_viol_total;
task collect_hready_violations;
  begin
     hready_viol_total = 0;
`ifndef FUSED
     hready_viol_total = hready_viol_total + ahb_waitstate_inserter_rom_inst.hready_viol_cnt
                                          + ahb_waitstate_inserter_sram_inst.hready_viol_cnt;
`endif
     hready_viol_total = hready_viol_total + ahb_waitstate_inserter_periph0_inst.hready_viol_cnt
                                          + ahb_waitstate_inserter_periph1_inst.hready_viol_cnt;
     if (hready_viol_total != 0)
       begin
          $display("ERROR: %0d cycle(s) where a stalling subordinate was handed hready=1", hready_viol_total);
          error = error + hready_viol_total;
       end
     if (dph_viol_cnt != 0)
       begin
          $display("ERROR: %0d cycle(s) with more than one data-phase owner on a bus", dph_viol_cnt);
          error = error + dph_viol_cnt;
       end
  end
endtask

initial // Normal end of test
  begin
     #10;
     @(posedge stimulus_done);
     collect_hready_violations;

     $display(" ===============================================");
     if (error!=0)
       begin
          $display("|               SIMULATION FAILED               |");
          $display("|     (some verilog stimulus checks failed)     |");
          $display("|     (      %d errors           )     |", error);
       end
     else
       begin
          $display("|               SIMULATION PASSED               |");
       end
     $display(" ===============================================");
     $display("");
     `ifdef FUSED
       $display("FUSED DUT");
     `elsif HIPERF
       $display("HIPERF DUT");
     `else
       $display("GENERIC DUT");
     `endif
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
        if (sram_inst0.mem[address] !== expected_value) begin
          $display("ERROR: Memory check   -- address: 0x%h -- read: 0x%h / expected: 0x%h %t ns", address, sram_inst0.mem[address], expected_value, $time);
          error = error+1;
        end else begin
          $display("PASS:  Memory check   -- address: 0x%h -- value: 0x%h %t ns", address, sram_inst0.mem[address], $time);
        end
      end
   endtask

    task check_rom_value;
        input integer address;
        input integer expected_value;

        reg [511:0] formatted_string;
        integer i;
        begin
          #1;
          if (rom_inst0.mem[address] !== expected_value) begin
            $display("ERROR: ROM check   -- address: 0x%h -- read: 0x%h / expected: 0x%h %t ns", address, rom_inst0.mem[address], expected_value, $time);
            error = error+1;
          end else begin
            $display("PASS:  ROM check   -- address: 0x%h -- value: 0x%h %t ns", address, rom_inst0.mem[address], $time);
          end
        end
   endtask

   task check_periph_reg_value;
      input integer periph_number;
      input integer reg_number;
      input integer expected_value;

      reg [511:0] formatted_string;
      reg  [31:0] selected_reg;
      begin
        #1;
        if (periph_number == 0) begin
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
        end else if (periph_number == 1) begin
            case (reg_number)
               0: selected_reg = periph1_reg_00_out;
               1: selected_reg = periph1_reg_01_out;
               2: selected_reg = periph1_reg_02_out;
               3: selected_reg = periph1_reg_03_out;
               4: selected_reg = periph1_reg_04_out;
               5: selected_reg = periph1_reg_05_out;
               6: selected_reg = periph1_reg_06_out;
               7: selected_reg = periph1_reg_07_out;
               8: selected_reg = periph1_reg_08_in ;
               9: selected_reg = periph1_reg_09_in ;
              10: selected_reg = periph1_reg_10_in ;
              11: selected_reg = periph1_reg_11_in ;
              12: selected_reg = periph1_reg_12_in ;
              13: selected_reg = periph1_reg_13_in ;
              14: selected_reg = periph1_reg_14_in ;
              15: selected_reg = periph1_reg_15_in ;
              default: begin
                  selected_reg = 32'h00000000;
              end
            endcase
        end

        if (selected_reg !== expected_value) begin
          $display("ERROR: Periph check   -- periph: %d -- reg_number: %d -- read: 0x%h / expected: 0x%h %t ns", periph_number, reg_number, selected_reg, expected_value, $time);
          error = error+1;
        end else begin
          $display("PASS:  Periph check   -- periph: %d -- reg_number: %d -- value: 0x%h %t ns", periph_number, reg_number, selected_reg, $time);
        end
      end
   endtask

   task set_regin_value;
      input integer periph_number;
      input integer regin_number;
      input integer value;

      begin
        #1;
        if (periph_number == 0) begin
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
        end else if (periph_number == 1) begin
            case (regin_number)
               8: periph1_reg_08_in = value;
               9: periph1_reg_09_in = value;
              10: periph1_reg_10_in = value;
              11: periph1_reg_11_in = value;
              12: periph1_reg_12_in = value;
              13: periph1_reg_13_in = value;
              14: periph1_reg_14_in = value;
              15: periph1_reg_15_in = value;
              default: begin
              end
            endcase
        end
      end
   endtask

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

endmodule
