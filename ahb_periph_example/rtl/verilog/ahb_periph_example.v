//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_periph_example
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_periph_example.v
// Module Description : AHB Peripheral example containing:
//                        + 8x read-write registers
//                        + 8x read-only  registers
//                        + 1x MDELEG register to control the privilege
//                          levels allowed to access the registers (via the
//                          hprot[1] and hsmode AHB signals)
//----------------------------------------------------------------------------
`default_nettype none

module  ahb_periph_example #(
    parameter               ADDRW        = 7,   // AHB address-width (window = 1<<ADDRW bytes)
    parameter               ASYNC_RST_EN = 1'b1 // Reset style: 1=async active-low reset, 0=synchronous reset
) (

// AHB CLOCK & RESET
    input  wire             hclk_i,             // module clock (from the AHB clock domain)
    input  wire             hresetn_i,          // active-low async reset (sync-deassert required at IP boundary)
    output wire             hclk_en_o,          // clock-gate enable; must drive an external ICG cell

// AHB INTERFACE
    input  wire [ADDRW-1:0] haddr_i,            // AHB byte address
    input  wire       [3:0] hprot_i,            // protection control (hprot[1] = privileged/non-privileged)
    input  wire             hready_i,           // bus ready in (from the interconnect)
    input  wire       [2:0] hsize_i,            // transfer size (0=byte, 1=half-word, 2=word)
    input  wire             hsmode_i,           // secure-mode bit (connect to HAUSER from the fabric)
    input  wire       [1:0] htrans_i,           // transfer type (NONSEQ/SEQ start an access; IDLE/BUSY skip)
    input  wire      [31:0] hwdata_i,           // write data (DPH-aligned)
    input  wire             hwrite_i,           // write enable
    input  wire             hsel_i,             // slave select
    output wire      [31:0] hrdata_o,           // read data
    output wire             hreadyout_o,        // bus ready out
    output wire             hresp_o,            // transfer response (asserted on MDELEG access-control violation)

// REGISTERS
    output wire      [31:0] register_00_o,
    output wire      [31:0] register_01_o,
    output wire      [31:0] register_02_o,
    output wire      [31:0] register_03_o,
    output wire      [31:0] register_04_o,
    output wire      [31:0] register_05_o,
    output wire      [31:0] register_06_o,
    output wire      [31:0] register_07_o,

    input  wire      [31:0] register_08_i,
    input  wire      [31:0] register_09_i,
    input  wire      [31:0] register_10_i,
    input  wire      [31:0] register_11_i,
    input  wire      [31:0] register_12_i,
    input  wire      [31:0] register_13_i,
    input  wire      [31:0] register_14_i,
    input  wire      [31:0] register_15_i
 );


//=============================================================================
// 1)  PARAMETER DECLARATION
//=============================================================================

// Decoder bit width (defines how many bits are considered for address decoding)
localparam              DEC_WD             =  ADDRW-2;

// AHB hsize encodings (only the natural sizes <= 32 bits are supported)
localparam        [1:0] HSIZE_BYTE         =  2'b00;
localparam        [1:0] HSIZE_HALF         =  2'b01;
localparam        [1:0] HSIZE_WORD         =  2'b10;

// MDELEG register reset values (M-mode-locked, ERROR on unauthorized access)
localparam        [1:0] MDELEG_WR_PRIV_RST = 2'b11;
localparam        [1:0] MDELEG_RD_PRIV_RST = 2'b11;
localparam              MDELEG_RESP_RST    = 1'b1;

// MDELEG priv-field reserved encoding (treated as "Machine-mode only")
localparam        [1:0] MDELEG_PRIV_RSVD   = 2'b10;

// Register addresses offset
localparam [DEC_WD-1:0] REGOUT_00   = 'h00,
                        REGOUT_01   = 'h01,
                        REGOUT_02   = 'h02,
                        REGOUT_03   = 'h03,
                        REGOUT_04   = 'h04,
                        REGOUT_05   = 'h05,
                        REGOUT_06   = 'h06,
                        REGOUT_07   = 'h07,
                        REGIN_08    = 'h08,
                        REGIN_09    = 'h09,
                        REGIN_10    = 'h0A,
                        REGIN_11    = 'h0B,
                        REGIN_12    = 'h0C,
                        REGIN_13    = 'h0D,
                        REGIN_14    = 'h0E,
                        REGIN_15    = 'h0F,
                        MDELEG      = 'h10;

// Register one-hot decoder utilities
localparam              DEC_SZ      = (1 << DEC_WD);
localparam [DEC_SZ-1:0] BASE_REG    = {{DEC_SZ-1{1'b0}}, 1'b1};

// Register one-hot decoder
localparam [DEC_SZ-1:0] REGOUT_00_D = (BASE_REG << REGOUT_00),
                        REGOUT_01_D = (BASE_REG << REGOUT_01),
                        REGOUT_02_D = (BASE_REG << REGOUT_02),
                        REGOUT_03_D = (BASE_REG << REGOUT_03),
                        REGOUT_04_D = (BASE_REG << REGOUT_04),
                        REGOUT_05_D = (BASE_REG << REGOUT_05),
                        REGOUT_06_D = (BASE_REG << REGOUT_06),
                        REGOUT_07_D = (BASE_REG << REGOUT_07),
                        REGIN_08_D  = (BASE_REG << REGIN_08 ),
                        REGIN_09_D  = (BASE_REG << REGIN_09 ),
                        REGIN_10_D  = (BASE_REG << REGIN_10 ),
                        REGIN_11_D  = (BASE_REG << REGIN_11 ),
                        REGIN_12_D  = (BASE_REG << REGIN_12 ),
                        REGIN_13_D  = (BASE_REG << REGIN_13 ),
                        REGIN_14_D  = (BASE_REG << REGIN_14 ),
                        REGIN_15_D  = (BASE_REG << REGIN_15 ),
                        MDELEG_D    = (BASE_REG << MDELEG   );


//=============================================================================
// 2)  INTERNAL WIRES/REGISTERS/PARAMETERS DECLARATION
//=============================================================================

wire                    aph_valid;            // AHB address phase
wire                    aph_write;            // AHB write address phase
wire              [3:0] aph_byte_mask;        // AHB byte mask address phase

wire                    dph_valid;            // AHB data phase
wire                    dph_write;            // AHB write data phase
wire                    dph_read;             // AHB read data phase
wire       [DEC_WD-1:0] dph_addr;             // AHB address data phase
wire                    dph_priv;             // AHB HPROT Priv
wire                    dph_smode;            // AHB Supervisor mode
wire              [3:0] dph_byte_mask;        // AHB byte mask
wire                    dph_machine_mode;     // Machine mode detected
wire                    dph_supervisor_mode;  // Supervisor mode detected
wire              [1:0] dph_privilege_mode;   // Current privilege mode (11: Machine; 10: Reserved; 01: Supervisor; 00: User)
wire                    reg_wr_allowed;       // Detect when current write access is allowed
wire                    reg_rd_allowed;       // Detect when current read access is allowed

wire                    mdeleg_wr_error;      // Detect not allowed write access to MDELEG register
wire                    mdeleg_rd_error;      // Detect not allowed read access to MDELEG register
wire                    reg_wr_error;         // Detect not allowed write access to REGOUT/REGIN registers
wire                    reg_rd_error;         // Detect not allowed read access to REGOUT/REGIN registers
wire                    error_resp;           // Error response detection
wire                    error_resp_done;      // Error response detection (2nd cycle)
wire                    error_resp_done_nxt;  // Error response detection next-state


//=============================================================================
// 3)  AHB ADDRESS/DATA PHASE DETECTION
//=============================================================================

// Detect valid AHB transaction (address Phase)
assign   aph_valid     = hsel_i & hready_i & htrans_i[1];
assign   aph_write     = aph_valid & hwrite_i;

// Compute byte mask based on the address LSB and size of the transfer
assign   aph_byte_mask = {((hsize_i[1:0]==HSIZE_BYTE) & (haddr_i[1:0]==2'b11)) | ((hsize_i[1:0]==HSIZE_HALF) & (haddr_i[1]==1'b1)) | (hsize_i[1:0]==HSIZE_WORD),
                          ((hsize_i[1:0]==HSIZE_BYTE) & (haddr_i[1:0]==2'b10)) | ((hsize_i[1:0]==HSIZE_HALF) & (haddr_i[1]==1'b1)) | (hsize_i[1:0]==HSIZE_WORD),
                          ((hsize_i[1:0]==HSIZE_BYTE) & (haddr_i[1:0]==2'b01)) | ((hsize_i[1:0]==HSIZE_HALF) & (haddr_i[1]==1'b0)) | (hsize_i[1:0]==HSIZE_WORD),
                          ((hsize_i[1:0]==HSIZE_BYTE) & (haddr_i[1:0]==2'b00)) | ((hsize_i[1:0]==HSIZE_HALF) & (haddr_i[1]==1'b0)) | (hsize_i[1:0]==HSIZE_WORD)};

// Data Phase registers
//
// The original always block had three branches: load on aph_valid, active
// CLEAR-to-zero on (else-if) hready_i, and hold otherwise. Faithfully mapped
// to arv_ipdff: enable when (aph_valid | hready_i), with a per-register d_i
// hold-mux that selects the captured value when aph_valid and zero otherwise.
wire                    dph_en        =  aph_valid | hready_i;

wire                    dph_valid_nxt     =  aph_valid;
wire                    dph_write_nxt     =  aph_valid ? aph_write          : 1'b0;
wire       [DEC_WD-1:0] dph_addr_nxt      =  aph_valid ? haddr_i[ADDRW-1:2] : {DEC_WD{1'b0}};
wire                    dph_priv_nxt      =  aph_valid ? hprot_i[1]          : 1'b0;
wire                    dph_smode_nxt     =  aph_valid ? hsmode_i            : 1'b0;
wire              [3:0] dph_byte_mask_nxt =  aph_valid ? aph_byte_mask       : 4'b0000;

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN))      u_dph_valid (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dph_en), .d_i(dph_valid_nxt),     .q_o(dph_valid));

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN))      u_dph_write (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dph_en), .d_i(dph_write_nxt),     .q_o(dph_write));

arv_ipdff #(.WIDTH(DEC_WD), .ARST_EN(ASYNC_RST_EN)) u_dph_addr (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dph_en), .d_i(dph_addr_nxt),      .q_o(dph_addr));

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN))      u_dph_priv (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dph_en), .d_i(dph_priv_nxt),      .q_o(dph_priv));

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN))      u_dph_smode (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dph_en), .d_i(dph_smode_nxt),     .q_o(dph_smode));

arv_ipdff #(.WIDTH(4), .ARST_EN(ASYNC_RST_EN))      u_dph_byte_mask (
                           .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(dph_en), .d_i(dph_byte_mask_nxt), .q_o(dph_byte_mask));

assign dph_read            =  dph_valid & ~dph_write;

// Detect Machine, Supervisor and User modes
assign dph_machine_mode    =  dph_priv & ~dph_smode;
assign dph_supervisor_mode =  dph_priv &  dph_smode;
assign dph_privilege_mode  =  dph_machine_mode     ? 2'b11 :
                              dph_supervisor_mode  ? 2'b01 :
                                                     2'b00 ;

// Enable clock (for architectural clock-gating)
assign hclk_en_o           =  aph_valid | dph_valid;


//============================================================================
// 4)  REGISTER DECODER
//============================================================================

wire [DEC_SZ-1:0] reg_dec  =  (REGOUT_00_D   &  {DEC_SZ{dph_addr==REGOUT_00}})  |
                              (REGOUT_01_D   &  {DEC_SZ{dph_addr==REGOUT_01}})  |
                              (REGOUT_02_D   &  {DEC_SZ{dph_addr==REGOUT_02}})  |
                              (REGOUT_03_D   &  {DEC_SZ{dph_addr==REGOUT_03}})  |
                              (REGOUT_04_D   &  {DEC_SZ{dph_addr==REGOUT_04}})  |
                              (REGOUT_05_D   &  {DEC_SZ{dph_addr==REGOUT_05}})  |
                              (REGOUT_06_D   &  {DEC_SZ{dph_addr==REGOUT_06}})  |
                              (REGOUT_07_D   &  {DEC_SZ{dph_addr==REGOUT_07}})  |
                              (REGIN_08_D    &  {DEC_SZ{dph_addr==REGIN_08 }})  |
                              (REGIN_09_D    &  {DEC_SZ{dph_addr==REGIN_09 }})  |
                              (REGIN_10_D    &  {DEC_SZ{dph_addr==REGIN_10 }})  |
                              (REGIN_11_D    &  {DEC_SZ{dph_addr==REGIN_11 }})  |
                              (REGIN_12_D    &  {DEC_SZ{dph_addr==REGIN_12 }})  |
                              (REGIN_13_D    &  {DEC_SZ{dph_addr==REGIN_13 }})  |
                              (REGIN_14_D    &  {DEC_SZ{dph_addr==REGIN_14 }})  |
                              (REGIN_15_D    &  {DEC_SZ{dph_addr==REGIN_15 }})  |
                              (MDELEG_D      &  {DEC_SZ{dph_addr==MDELEG   }})  ;

// Read/Write vectors
wire [DEC_SZ-1:0] reg_wr   = reg_dec & {DEC_SZ{dph_write}};
wire [DEC_SZ-1:0] reg_rd   = reg_dec & {DEC_SZ{dph_read}};

//=============================================================================
// 5)  MDELEG REGISTER
//=============================================================================
//
//      31                9     8    7         4    3    2    1    0
//     +--------------------+------+-------------+---------+----------+
//     |      reserved      | RESP |   reserved  | RD_PRIV | WR_PRIV  |
//     +--------------------+------+-------------+---------+----------+
//
// WR_PRIV: Selects minimum privilege level allowed to write to the REGOUT/REGIN registers
//          (0: User-Mode; 1: Supervisor-Mode; 2: reserved; 3: Machine-Mode)
//
// RD_PRIV: Selects minimum privilege level allowed to read from the REGOUT/REGIN registers
//          (0: User-Mode; 1: Supervisor-Mode; 2: reserved; 3: Machine-Mode)
//
// RESP   : Selects module respons to unallowed accesses
//          (0: ignore access; 1: AHB error-response)
//
wire [31:0] mdeleg;
wire  [1:0] mdeleg_wr_priv;
wire  [1:0] mdeleg_wr_priv_nxt;
wire  [1:0] mdeleg_rd_priv;
wire  [1:0] mdeleg_rd_priv_nxt;
wire        mdeleg_resp;
wire        mdeleg_resp_nxt;

// This register can only be changed when in Machine-Mode
wire        mdeleg_priv_wr     = reg_wr[MDELEG] & dph_byte_mask[0] & dph_machine_mode;
wire        mdeleg_resp_wr     = reg_wr[MDELEG] & dph_byte_mask[1] & dph_machine_mode;

// Coerce the reserved 2'b10 encoding to the most restrictive level (M-mode
// only) at write time so a firmware bug that confuses Supervisor (2'b01)
// with the reserved code cannot silently weaken access control.
wire  [1:0] mdeleg_wr_priv_wdata = (hwdata_i[1:0] == MDELEG_PRIV_RSVD) ? 2'b11 : hwdata_i[1:0];
wire  [1:0] mdeleg_rd_priv_wdata = (hwdata_i[3:2] == MDELEG_PRIV_RSVD) ? 2'b11 : hwdata_i[3:2];

assign      mdeleg_wr_priv_nxt = mdeleg_priv_wr ? mdeleg_wr_priv_wdata : mdeleg_wr_priv;
assign      mdeleg_rd_priv_nxt = mdeleg_priv_wr ? mdeleg_rd_priv_wdata : mdeleg_rd_priv;
assign      mdeleg_resp_nxt    = mdeleg_resp_wr ? hwdata_i[8]          : mdeleg_resp;

arv_ipdff #(.WIDTH(2), .RST_VAL(MDELEG_WR_PRIV_RST), .ARST_EN(ASYNC_RST_EN)) u_mdeleg_wr_priv (
                                                          .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                                                               .d_i (mdeleg_wr_priv_nxt),
                                                                                               .q_o (mdeleg_wr_priv));

arv_ipdff #(.WIDTH(2), .RST_VAL(MDELEG_RD_PRIV_RST), .ARST_EN(ASYNC_RST_EN)) u_mdeleg_rd_priv (
                                                          .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                                                               .d_i (mdeleg_rd_priv_nxt),
                                                                                               .q_o (mdeleg_rd_priv));

arv_ipdff #(.WIDTH(1), .RST_VAL(MDELEG_RESP_RST), .ARST_EN(ASYNC_RST_EN))    u_mdeleg_resp (
                                                          .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1),
                                                                                               .d_i (mdeleg_resp_nxt),
                                                                                               .q_o (mdeleg_resp));

// Combine 32b value for read path
assign      mdeleg          = {23'h000000, mdeleg_resp, 4'h0, mdeleg_rd_priv, mdeleg_wr_priv};

// Access is only allowed if the current privilege level is equal or higher to the configuration register
assign      reg_wr_allowed  = (dph_privilege_mode >= mdeleg_wr_priv);
assign      reg_rd_allowed  = (dph_privilege_mode >= mdeleg_rd_priv);


//=============================================================================
// 6)  ERROR RESPONSE
//=============================================================================

// Detect not allowed access to MDELEG (both read-write only allowed in Machine-Mode)
assign      mdeleg_wr_error = reg_wr[MDELEG]  & mdeleg_resp & ~dph_machine_mode;
assign      mdeleg_rd_error = reg_rd[MDELEG]  & mdeleg_resp & ~dph_machine_mode;

// Detect not allowed access to the other registers
assign      reg_wr_error    = dph_write       & mdeleg_resp & ~reg_wr_allowed;
assign      reg_rd_error    = dph_read        & mdeleg_resp & ~reg_rd_allowed;

// Error response generation
assign      error_resp      = mdeleg_wr_error |
                              mdeleg_rd_error |
                              reg_wr_error    |
                              reg_rd_error    ;

assign      error_resp_done_nxt = error_resp & ~error_resp_done;

arv_ipdff #(.WIDTH(1), .ARST_EN(ASYNC_RST_EN)) u_error_resp_done (
                             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(error_resp_done_nxt), .q_o(error_resp_done));


// No Error response and no wait state
assign hreadyout_o          = ~(error_resp & ~error_resp_done);
assign hresp_o              =   error_resp;


//=============================================================================
// 7)  READ/WRITE REGISTERS
//=============================================================================

// 8x parameterised RW register bank (REGOUT_00 .. REGOUT_07).
// Each register is updated on per-byte enables derived from `aph_byte_mask`,
// `reg_wr_allowed`, and the one-hot decoder bit `reg_wr[REGOUT_00 + g]`.
wire [31:0] regout     [0:7];
wire [31:0] regout_nxt [0:7];
wire  [3:0] regout_wr  [0:7];

genvar g;
generate
    for (g = 0; g < 8; g = g + 1) begin : g_regout_bank
        // Per-iteration local carries the registered value, then drives the
        // shared array word (constant-index word-selects on array ports are a
        // common iverilog/DC limitation, so the local hop keeps it portable).
        wire [31:0] regout_q;

        assign regout_wr[g]         = {4{reg_wr[REGOUT_00 + g] & reg_wr_allowed}} & dph_byte_mask;

        assign regout_nxt[g][ 7: 0] = regout_wr[g][0] ? hwdata_i[ 7: 0] : regout[g][ 7: 0];
        assign regout_nxt[g][15: 8] = regout_wr[g][1] ? hwdata_i[15: 8] : regout[g][15: 8];
        assign regout_nxt[g][23:16] = regout_wr[g][2] ? hwdata_i[23:16] : regout[g][23:16];
        assign regout_nxt[g][31:24] = regout_wr[g][3] ? hwdata_i[31:24] : regout[g][31:24];

        arv_ipdff #(.WIDTH(32), .ARST_EN(ASYNC_RST_EN)) u_regout (
                             .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(regout_nxt[g]), .q_o(regout_q));

        assign regout[g] = regout_q;
    end
endgenerate

assign register_00_o = regout[0];
assign register_01_o = regout[1];
assign register_02_o = regout[2];
assign register_03_o = regout[3];
assign register_04_o = regout[4];
assign register_05_o = regout[5];
assign register_06_o = regout[6];
assign register_07_o = regout[7];


//=============================================================================
// 8)  READ MUX
//=============================================================================

// Per-register read contributions (zero unless this register is being read
// AND the master's privilege level is allowed).
wire [31:0] regout_rd [0:7];
generate
    for (g = 0; g < 8; g = g + 1) begin : g_regout_rd
        assign regout_rd[g] = regout[g] & {32{reg_rd[REGOUT_00 + g] & reg_rd_allowed}};
    end
endgenerate

wire [31:0] regin_08_rd   = (register_08_i  & {32{reg_rd[REGIN_08 ] & reg_rd_allowed  }});
wire [31:0] regin_09_rd   = (register_09_i  & {32{reg_rd[REGIN_09 ] & reg_rd_allowed  }});
wire [31:0] regin_10_rd   = (register_10_i  & {32{reg_rd[REGIN_10 ] & reg_rd_allowed  }});
wire [31:0] regin_11_rd   = (register_11_i  & {32{reg_rd[REGIN_11 ] & reg_rd_allowed  }});
wire [31:0] regin_12_rd   = (register_12_i  & {32{reg_rd[REGIN_12 ] & reg_rd_allowed  }});
wire [31:0] regin_13_rd   = (register_13_i  & {32{reg_rd[REGIN_13 ] & reg_rd_allowed  }});
wire [31:0] regin_14_rd   = (register_14_i  & {32{reg_rd[REGIN_14 ] & reg_rd_allowed  }});
wire [31:0] regin_15_rd   = (register_15_i  & {32{reg_rd[REGIN_15 ] & reg_rd_allowed  }});
wire [31:0] mdeleg_rd     = (mdeleg         & {32{reg_rd[MDELEG   ] & dph_machine_mode}});

assign hrdata_o = regout_rd[0] |
                  regout_rd[1] |
                  regout_rd[2] |
                  regout_rd[3] |
                  regout_rd[4] |
                  regout_rd[5] |
                  regout_rd[6] |
                  regout_rd[7] |
                  regin_08_rd  |
                  regin_09_rd  |
                  regin_10_rd  |
                  regin_11_rd  |
                  regin_12_rd  |
                  regin_13_rd  |
                  regin_14_rd  |
                  regin_15_rd  |
                  mdeleg_rd    ;


//-------------------------------------------------
// Lint cleanup
//-------------------------------------------------
wire        htrans0_unused;
assign      htrans0_unused   = htrans_i[0];

wire        hsize2_unused;
assign      hsize2_unused    = hsize_i[2];

wire  [1:0] hprot3_2_unused;
assign      hprot3_2_unused  = hprot_i[3:2];

wire        hprot0_unused;
assign      hprot0_unused    = hprot_i[0];


endmodule // ahb_periph_example

`default_nettype wire
