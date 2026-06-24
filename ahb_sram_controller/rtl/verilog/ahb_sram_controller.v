//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_sram_controller
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_sram_controller.v
// Module Description : Parameterizable AHB SRAM Controller.
//----------------------------------------------------------------------------
`default_nettype none

module  ahb_sram_controller (

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

// SRAM INTERFACE
    sram_dout_i,
    sram_addr_o,
    sram_cen_o,
    sram_clk_o,
    sram_din_o,
    sram_wen_o

 );

// PARAMETERs
//======================================
parameter                   MEM_SIZE     = 256;                // Size of the SRAM in Bytes
parameter                   ASYNC_RST_EN = 1'b1;               // Reset style: 1=asynchronous active-low, 0=synchronous

localparam                  MEM_ADDRW    = $clog2(MEM_SIZE)-2; // Address width of the SRAM (32b words)

// AHB CLOCK & RESET
//======================================
input  wire                 hclk_i;       // module clock (from the AHB clock domain)
input  wire                 hresetn_i;    // active-low async reset (sync-deassert required at IP boundary)
output wire                 hclk_en_o;    // clock-gate enable; must drive an external ICG cell

// AHB INTERFACE
//======================================
input  wire [MEM_ADDRW+1:0] haddr_i;      // AHB byte address
input  wire                 hready_i;     // bus ready in (from the interconnect)
input  wire           [2:0] hsize_i;      // transfer size (0=byte, 1=half-word, 2=word)
input  wire           [1:0] htrans_i;     // transfer type (NONSEQ/SEQ start an access; IDLE/BUSY skip)
input  wire          [31:0] hwdata_i;     // write data (DPH-aligned)
input  wire                 hwrite_i;     // write enable
input  wire                 hsel_i;       // slave select
output wire          [31:0] hrdata_o;     // read data (combinational, gated by per-byte read-cmd post-flop)
output wire                 hreadyout_o;  // bus ready out (constant 1)
output wire                 hresp_o;      // transfer response (constant 0)

// SRAM INTERFACE
//======================================
input  wire          [31:0] sram_dout_i;  // SRAM data out (one cycle after sram_cen + sram_addr)
output wire [MEM_ADDRW-1:0] sram_addr_o;  // SRAM word address
output wire                 sram_cen_o;   // SRAM chip-enable (active-low)
output wire                 sram_clk_o;   // SRAM clock (direct pass-through of hclk_i)
output wire          [31:0] sram_din_o;   // SRAM write data
output wire           [3:0] sram_wen_o;   // SRAM per-byte write enables (active-low)


//=============================================================================
// 1)  FSM ENCODING
//=============================================================================

localparam IDLE               = 3'b000;
localparam READ               = 3'b010;
localparam READ_PENDING_WRITE = 3'b011;
localparam WRITE              = 3'b100;

localparam RPW_BIT            = 0;  // Exclusive to READ_PENDING_WRITE (3'b011)
localparam READ_BIT           = 1;
localparam WRITE_BIT          = 2;

wire [2:0] state;
reg  [2:0] state_nxt;


//=============================================================================
// 2)  INTERNAL WIRES/REGISTERS/PARAMETERS DECLARATION
//=============================================================================

wire                 aph_valid;          // AHB address phase
wire                 aph_write;          // AHB write address phase
wire                 aph_read;           // AHB read  address phase

wire                 sram_rd_cmd;
wire           [3:0] sram_rd_cmd_post;
wire                 sram_wr_cmd_pre;
wire                 sram_wr_cmd;
wire                 sram_wr_pause;
wire                 sram_wr_restore;
wire                 sram_wr_active;

wire          [31:0] hwdata_pause;
wire                 sram_read_from_pause;
wire           [3:0] sram_read_from_pause_post;

wire [MEM_ADDRW-1:0] sram_wr_addr_buf;
wire           [3:0] sram_wr_en_buf;
wire           [3:0] sram_wr_en_nxt;


//=============================================================================
// 3)  STATE MACHINE
//=============================================================================

// Detect valid AHB transaction
assign     aph_valid  = hsel_i && hready_i && htrans_i[1];
assign     aph_write  = aph_valid &&  hwrite_i;
assign     aph_read   = aph_valid && ~hwrite_i;

// Compute next state of the FSM
always @* begin
    case (state)

        IDLE: begin
            if      (aph_write) begin state_nxt = WRITE; end
            else if (aph_read ) begin state_nxt = READ;  end
            else                begin state_nxt = IDLE;  end
        end

        READ: begin
            if      (aph_write) begin state_nxt = WRITE; end
            else if (aph_read ) begin state_nxt = READ;  end
            else                begin state_nxt = IDLE;  end
        end

        WRITE: begin
            if      (aph_read ) begin state_nxt = READ_PENDING_WRITE; end
            else if (aph_write) begin state_nxt = WRITE;              end
            else                begin state_nxt = IDLE;               end
        end

        READ_PENDING_WRITE: begin
            if      (aph_write) begin state_nxt = WRITE;              end
            else if (aph_read ) begin state_nxt = READ_PENDING_WRITE; end
            else                begin state_nxt = IDLE;               end
        end

        default: state_nxt = IDLE;
    endcase
end

// State register
arv_ipdff #(.WIDTH(3), .RST_VAL(IDLE), .ARST_EN(ASYNC_RST_EN)) u_state (
                                   .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(state_nxt), .q_o(state));

// Utility signals for read
assign sram_rd_cmd      = state_nxt[READ_BIT];

// Utility signals for write
assign sram_wr_cmd_pre  = state_nxt[WRITE_BIT];
assign sram_wr_cmd      = state[WRITE_BIT];
assign sram_wr_pause    = state[WRITE_BIT] &  aph_read;
assign sram_wr_restore  = state[RPW_BIT]   & ~aph_read;


//=============================================================================
// 4)  CONTROL SIGNALS
//=============================================================================

//-------------------------------------------------
// AHB response — no error response support
//-------------------------------------------------

// CPU raises misaligned exceptions before issuing AHB transactions,
// so this controller doesn't need to generate error responses (it would be redundant and degrade timing)
assign hreadyout_o    = 1'b1;
assign hresp_o        = 1'b0;

//-------------------------------------------------
// Control for write accesses
//-------------------------------------------------

// Compute the write strobes
assign sram_wr_en_nxt = {((hsize_i[1:0]==2'b00) && (haddr_i[1:0]==2'b11)) || ((hsize_i[1:0]==2'b01) && (haddr_i[1]==1'b1)) || (hsize_i[1:0]==2'b10),
                         ((hsize_i[1:0]==2'b00) && (haddr_i[1:0]==2'b10)) || ((hsize_i[1:0]==2'b01) && (haddr_i[1]==1'b1)) || (hsize_i[1:0]==2'b10),
                         ((hsize_i[1:0]==2'b00) && (haddr_i[1:0]==2'b01)) || ((hsize_i[1:0]==2'b01) && (haddr_i[1]==1'b0)) || (hsize_i[1:0]==2'b10),
                         ((hsize_i[1:0]==2'b00) && (haddr_i[1:0]==2'b00)) || ((hsize_i[1:0]==2'b01) && (haddr_i[1]==1'b0)) || (hsize_i[1:0]==2'b10)};

// Save address and write strobes for Write accesses
arv_ipdff #(.WIDTH(MEM_ADDRW), .ARST_EN(ASYNC_RST_EN)) u_sram_wr_addr_buf (
                                               .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(sram_wr_cmd_pre),
                                                                                    .d_i (haddr_i[MEM_ADDRW+1:2]),
                                                                                    .q_o (sram_wr_addr_buf));

arv_ipdff #(.WIDTH(4), .RST_VAL(4'b1111), .ARST_EN(ASYNC_RST_EN)) u_sram_wr_en_buf (
                                               .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(sram_wr_cmd_pre),
                                                                                    .d_i (sram_wr_en_nxt),
                                                                                    .q_o (sram_wr_en_buf));

// Save data in case of pause (in case of pipelined write/read back to back)
arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_hwdata_pause (
                                               .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(sram_wr_pause),
                                                                                    .d_i (hwdata_i),
                                                                                    .q_o (hwdata_pause));

// Active write access
assign sram_wr_active = (sram_wr_cmd & ~sram_wr_pause) | sram_wr_restore;

// Generate write strobes for Write accesses
assign sram_wen_o     = ~(sram_wr_en_buf & {4{sram_wr_active}});                   // Select byte to write depending on target address

// Assign SRAM data for Write accesses
assign sram_din_o     = (hwdata_i     & {32{sram_wr_cmd & ~sram_wr_pause}}) |      // Data from the AHB bus to the SRAM macro
                        (hwdata_pause & {32{sram_wr_restore             }}) ;      // Data from the pause buffer to the SRAM macro


//-------------------------------------------------
// Control for read accesses
//-------------------------------------------------

// Detect if we should read from the paused write data
assign sram_read_from_pause = sram_rd_cmd & state_nxt[RPW_BIT] & (sram_wr_addr_buf==haddr_i[MEM_ADDRW+1:2]);

wire [3:0] sram_read_from_pause_post_nxt = {4{sram_read_from_pause}} & sram_wr_en_buf;
wire [3:0] sram_rd_cmd_post_nxt          = {4{sram_rd_cmd}} & ~({4{sram_read_from_pause}} & sram_wr_en_buf);

arv_ipdff #(.WIDTH(4), .ARST_EN(ASYNC_RST_EN)) u_sram_read_from_pause_post (
                          .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(sram_read_from_pause_post_nxt), .q_o(sram_read_from_pause_post));

arv_ipdff #(.WIDTH(4), .ARST_EN(ASYNC_RST_EN)) u_sram_rd_cmd_post (
                          .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(sram_rd_cmd_post_nxt),          .q_o(sram_rd_cmd_post));

// Generate read data
// No need to mask bytes depending on the transfer size as mentioned in the AHB spec:
//     "For transfers that are narrower than the width of the bus, the Subordinate is only required to provide valid data on
//      the active byte lanes. The Manager selects the data from the correct byte lanes."
// Also select the bytes depending if they come from the SRAM or the pause buffer.
assign hrdata_o      = (sram_dout_i           & {{8{sram_rd_cmd_post[3]         }},
                                                 {8{sram_rd_cmd_post[2]         }},
                                                 {8{sram_rd_cmd_post[1]         }},
                                                 {8{sram_rd_cmd_post[0]         }}}) | // Read data from the SRAM

                       (hwdata_pause          & {{8{sram_read_from_pause_post[3]}},
                                                 {8{sram_read_from_pause_post[2]}},
                                                 {8{sram_read_from_pause_post[1]}},
                                                 {8{sram_read_from_pause_post[0]}}}) ; // Read data from the Pause buffer


//-------------------------------------------------
// Generic SRAM control signals
//-------------------------------------------------

assign sram_addr_o   = (haddr_i[MEM_ADDRW+1:2] & {MEM_ADDRW{sram_rd_cmd   }}) |
                       (sram_wr_addr_buf       & {MEM_ADDRW{sram_wr_active}}) ;

assign sram_cen_o    = ~(sram_rd_cmd | sram_wr_active);  // Enable SRAM during active states
assign sram_clk_o    =   hclk_i;


//-------------------------------------------------
// Enable clock (for architectural clock-gating)
//-------------------------------------------------
assign hclk_en_o     =  aph_valid | (state!=IDLE);


//-------------------------------------------------
// Lint cleanup
//-------------------------------------------------
wire   htrans0_unused;
assign htrans0_unused = htrans_i[0];

wire   hsize2_unused;
assign hsize2_unused  = hsize_i[2];


//=============================================================================
// 5)  Parameter range check
//=============================================================================
// Aborts elaboration if MEM_SIZE is not a power of 2 of at least 8 bytes.
// Lower bound: below 8 bytes, MEM_ADDRW (= $clog2(MEM_SIZE) - 2) becomes 0
// or negative and produces illegal port slices. Upper bound: none — any
// power-of-2 size up to the AHB address-space limit is valid; the practical
// cap is whatever depth the attached SRAM macro supports. A non-power-of-2
// value would leave gaps in the address space and alias unmapped accesses.
// pragma translate_off
generate
    if ((MEM_SIZE < 8) || ((MEM_SIZE & (MEM_SIZE - 1)) != 0)) begin : CHECK_MEM_SIZE
        initial $fatal(1, "ahb_sram_controller: MEM_SIZE (%0d) must be a power of 2 of at least 8 bytes.", MEM_SIZE);
    end
     if ((ASYNC_RST_EN != 0) && (ASYNC_RST_EN != 1)) begin : CHECK_ASYNC_RST_EN
        initial $fatal(1, "ahb_sram_controller: ASYNC_RST_EN (%0d) must be 0 or 1.", ASYNC_RST_EN);
    end
endgenerate
// pragma translate_on

endmodule // ahb_sram_controller

`default_nettype wire
