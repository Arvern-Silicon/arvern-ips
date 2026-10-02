//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_rom_controller
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_rom_controller.v
// Module Description : Parameterizable AHB ROM Controller.
//----------------------------------------------------------------------------
`default_nettype none

module  ahb_rom_controller (

// AHB CLOCK & RESET
    hclk_i,
    hresetn_i,
    hclk_en_o,

// AHB INTERFACE
    haddr_i,
    hready_i,
    hsize_i,
    htrans_i,
    hwdata_i,
    hwrite_i,
    hsel_i,
    hrdata_o,
    hreadyout_o,
    hresp_o,

// ROM INTERFACE
    rom_dout_i,
    rom_addr_o,
    rom_cen_o,
    rom_clk_o

 );

// PARAMETERs
//======================================
parameter                   MEM_SIZE     = 256;                // Size of the ROM in Bytes
parameter                   ASYNC_RST_EN = 1'b1;               // 1=async active-low reset, 0=synchronous reset

localparam                  MEM_ADDRW    = $clog2(MEM_SIZE)-2; // Address width of the ROM (32b words)


// AHB CLOCK & RESET
//======================================
input  wire                 hclk_i;       // module clock (from the AHB clock domain)
input  wire                 hresetn_i;    // active-low reset, style per ASYNC_RST_EN (sync de-assert required at IP boundary)
output wire                 hclk_en_o;    // clock-gate enable; must drive an external ICG cell

// AHB INTERFACE
//======================================
input  wire [MEM_ADDRW+1:0] haddr_i;      // AHB byte address
input  wire                 hready_i;     // bus ready in (from the interconnect)
input  wire           [2:0] hsize_i;      // transfer size (unused — ROM returns the full 32-bit word)
input  wire           [1:0] htrans_i;     // transfer type (NONSEQ/SEQ start an access; IDLE/BUSY skip)
input  wire          [31:0] hwdata_i;     // write data (ignored — ROM is read-only; the transfer is answered with ERROR)
input  wire                 hwrite_i;     // write enable; a write is answered with a two-cycle AHB ERROR and reaches no state
input  wire                 hsel_i;       // Subordinate select (HSELx)
output wire          [31:0] hrdata_o;     // read data (combinational, gated by `rd_active`)
output wire                 hreadyout_o;  // bus ready out; low for the first of the two ERROR cycles, high otherwise
output wire                 hresp_o;      // transfer response; high for both ERROR cycles, low otherwise

// ROM INTERFACE
//======================================
input  wire          [31:0] rom_dout_i;   // ROM data in (returned one cycle after rom_cen + rom_addr)
output wire [MEM_ADDRW-1:0] rom_addr_o;   // ROM word address (combinational from `haddr_i`)
output wire                 rom_cen_o;    // ROM chip-enable (active-low, asserted during read APH)
output wire                 rom_clk_o;    // ROM clock (direct pass-through of `hclk_i`)


//=============================================================================
// 1)  INTERNAL SIGNALS
//=============================================================================

wire  aph_valid;
wire  aph_read;
wire  rd_active;
wire  aph_write;
wire  wr_denied;
wire  err_state;
wire  err_state_nxt;
wire  in_err_p1;
wire  in_err_p2;


//=============================================================================
// 2)  AHB ADDRESS PHASE DECODE
//=============================================================================

assign aph_valid = hsel_i && hready_i && htrans_i[1];
assign aph_read  = aph_valid && ~hwrite_i;
assign aph_write = aph_valid &&  hwrite_i;


//=============================================================================
// 3)  STATE: read data phase, write ERROR (two cycles)
//=============================================================================

// rd_active: registered aph_read. Resets to 0; enabled every cycle (en_i=1).
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_rd_active (
                       .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                            .d_i (aph_read),
                                                            .q_o (rd_active));

// A write is answered with the AHB-Lite two-cycle ERROR
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_wr_denied (
                       .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                            .d_i (aph_write),
                                                            .q_o (wr_denied));

assign err_state_nxt = wr_denied & ~err_state;
arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_err_state (
                       .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                            .d_i (err_state_nxt),
                                                            .q_o (err_state));

assign in_err_p1   = wr_denied & ~err_state;
assign in_err_p2   =              err_state;


//=============================================================================
// 4)  OUTPUTS
//=============================================================================

assign hreadyout_o = ~in_err_p1;
assign hresp_o     =  in_err_p1 | in_err_p2;

// Read data: valid one cycle after the read APH (rd_active is the registered aph_read)
assign hrdata_o    = rom_dout_i & {32{rd_active}};

// ROM address: direct wire, zero gate levels on the critical path
assign rom_addr_o  = haddr_i[MEM_ADDRW+1:2];

// ROM chip-enable: ~aph_read — ~3 gate levels, no haddr/hsize dependency
assign rom_cen_o   = ~aph_read;

assign rom_clk_o   = hclk_i;

// Clock enable for architectural clock-gating
assign hclk_en_o   = aph_valid | rd_active | wr_denied | err_state;


//=============================================================================
// 5)  Lint cleanup
//=============================================================================

wire        htrans0_unused;
assign      htrans0_unused = htrans_i[0];

wire  [1:0] haddr10_unused;
assign      haddr10_unused = haddr_i[1:0];

wire [31:0] hwdata_unused;
assign      hwdata_unused  = hwdata_i;

wire  [2:0] hsize_unused;
assign      hsize_unused   = hsize_i;



//=============================================================================
// 6)  Parameter range check
//=============================================================================
// Aborts elaboration if MEM_SIZE is not a power of 2 of at least 8 bytes.
// Lower bound: below 8 bytes, MEM_ADDRW (= $clog2(MEM_SIZE) - 2) becomes 0
// or negative and produces illegal port slices. Upper bound: none — any
// power-of-2 size up to the AHB address-space limit is valid; the practical
// cap is whatever depth the attached ROM macro supports. A non-power-of-2
// value sizes the ports for the next power of 2 and forwards the address
// unchanged: reads between MEM_SIZE and that bound reach the macro out of
// range, as the IP checks no address.
// pragma translate_off
generate
    if ((MEM_SIZE < 8) || ((MEM_SIZE & (MEM_SIZE - 1)) != 0)) begin : CHECK_MEM_SIZE
        initial $fatal(1, "ahb_rom_controller: MEM_SIZE (%0d) must be a power of 2 of at least 8 bytes.", MEM_SIZE);
    end
     if ((ASYNC_RST_EN != 0) && (ASYNC_RST_EN != 1)) begin : CHECK_ASYNC_RST_EN
        initial $fatal(1, "ahb_rom_controller: ASYNC_RST_EN (%0d) must be 0 or 1.", ASYNC_RST_EN);
    end
endgenerate
// pragma translate_on

endmodule // ahb_rom_controller

`default_nettype wire
