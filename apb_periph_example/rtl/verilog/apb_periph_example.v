//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    apb_periph_example
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : apb_periph_example.v
// Module Description : APB4 peripheral example containing:
//                        + 8x read-write registers
//                        + 8x read-only  registers
//                        + 1x MDELEG register to control the privilege
//                          levels allowed to access the registers (via the
//                          pprot[0] and psmode APB signals)
//----------------------------------------------------------------------------
`default_nettype none

module  apb_periph_example #(
    parameter               ADDRW        = 7,      // APB address width (window = 1<<ADDRW bytes)
    parameter               ASYNC_RST_EN = 1'b1,   // Reset style: 1=async active-low reset, 0=synchronous reset
    parameter         [8:0] MDELEG_RST   = 9'h10F  // MDELEG[8:0] reset value (default: M-mode only, PSLVERR)
) (

// APB CLOCK & RESET
    input  wire             pclk_i,             // module clock
    input  wire             presetn_i,          // active-low reset, style per ASYNC_RST_EN (sync de-assert required at IP boundary)
    output wire             pclk_en_o,          // clock request for an external ICG (combinational, keep unregistered)

// APB INTERFACE
    input  wire             psel_i,             // completer select
    input  wire             penable_i,          // ACCESS phase
    input  wire [ADDRW-1:0] paddr_i,            // byte address
    input  wire             pwrite_i,           // write
    input  wire      [31:0] pwdata_i,           // write data
    input  wire       [3:0] pstrb_i,            // write strobes (ignored on reads)
    input  wire       [2:0] pprot_i,            // protection ([0] privileged; [2:1] not used)
    input  wire             psmode_i,           // supervisor-mode sideband (with the timing of pprot)
    output wire      [31:0] prdata_o,           // read data
    output wire             pready_o,           // ready (no wait states)
    output wire             pslverr_o,          // error (MDELEG access-control violation)

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

// MDELEG sits at offset 0x40, so the window needs ADDRW >= 7: in a narrower
// one no address reaches MDELEG, and the gates are stuck at their reset value.
// pragma translate_off
generate
    if (ADDRW < 7) begin : CHECK_ADDRW
        initial $fatal(1, "apb_periph_example: ADDRW (%0d) must be >= 7 (MDELEG is at offset 0x40).", ADDRW);
    end
    if ((ASYNC_RST_EN != 0) && (ASYNC_RST_EN != 1)) begin : CHECK_ASYNC_RST_EN
        initial $fatal(1, "apb_periph_example: ASYNC_RST_EN (%0d) must be 0 or 1.", ASYNC_RST_EN);
    end
    // A reset value must be one a write could store: no reserved privilege
    // code (a write coerces it to 2'b11) and the reserved bits [7:4] zero.
    if ((MDELEG_RST[1:0] == 2'b10) || (MDELEG_RST[3:2] == 2'b10) || (MDELEG_RST[7:4] != 4'h0)) begin : CHECK_MDELEG_RST
        initial $fatal(1, "apb_periph_example: MDELEG_RST (9'h%03h) holds a reserved privilege code or a reserved bit.", MDELEG_RST);
    end
endgenerate
// pragma translate_on

localparam              ARST_EN            = (ASYNC_RST_EN != 0);

// Decoder bit width (defines how many bits are considered for address decoding)
localparam              DEC_WD             =  ADDRW-2;

// MDELEG register reset values, the fields of MDELEG_RST
localparam        [1:0] MDELEG_WR_PRIV_RST = MDELEG_RST[1:0];
localparam        [1:0] MDELEG_RD_PRIV_RST = MDELEG_RST[3:2];
localparam              MDELEG_RESP_RST    = MDELEG_RST[8];

// MDELEG priv-field reserved encoding (treated as "Machine-mode only")
localparam        [1:0] MDELEG_PRIV_RSVD   = 2'b10;

// Register word offsets (byte offset / 4)
localparam integer      REGOUT_00   = 'h00,
                        REGIN_08    = 'h08,
                        REGIN_15    = 'h0F,
                        MDELEG      = 'h10;

// Decoded register slots (REGOUT_00 .. MDELEG); the window above is unmapped
localparam              DEC_SZ      = MDELEG + 1;

// Bank sizes, derived from the offsets above: the register bank, the read mux
// and the decoder all follow them
localparam              REGOUT_NR   = REGIN_08 - REGOUT_00;
localparam              REGIN_NR    = REGIN_15 - REGIN_08 + 1;


//=============================================================================
// 2)  INTERNAL WIRES DECLARATION
//=============================================================================

wire                    acc_valid;            // APB ACCESS phase
wire                    acc_write;            // APB write ACCESS phase
wire                    acc_read;             // APB read ACCESS phase
wire       [DEC_WD-1:0] acc_addr;             // register word address
wire                    machine_mode;         // Machine mode detected
wire                    supervisor_mode;      // Supervisor mode detected
wire              [1:0] privilege_mode;       // Current privilege mode (11: Machine; 10: Reserved; 01: Supervisor; 00: User)
wire                    reg_wr_allowed;       // Detect when current write access is allowed
wire                    reg_rd_allowed;       // Detect when current read access is allowed

wire                    mdeleg_wr_error;      // Detect not allowed write access to MDELEG register
wire                    mdeleg_rd_error;      // Detect not allowed read access to MDELEG register
wire                    reg_wr_error;         // Detect not allowed write access to REGOUT/REGIN registers
wire                    reg_rd_error;         // Detect not allowed read access to REGOUT/REGIN registers


//=============================================================================
// 3)  APB ACCESS PHASE DETECTION
//=============================================================================

// APB holds the address, control and write data stable from SETUP to the end
// of ACCESS: the transfer is decoded straight from the bus, without data-phase
// registers. Writes take effect at the end of the ACCESS cycle.
assign acc_valid       =  psel_i & penable_i;
assign acc_write       =  acc_valid &  pwrite_i;
assign acc_read        =  acc_valid & ~pwrite_i;
assign acc_addr        =  paddr_i[ADDRW-1:2];

// Detect Machine, Supervisor and User modes
assign machine_mode    =  pprot_i[0] & ~psmode_i;
assign supervisor_mode =  pprot_i[0] &  psmode_i;
assign privilege_mode  =  machine_mode     ? 2'b11 :
                          supervisor_mode  ? 2'b01 :
                                             2'b00 ;

// Enable clock (for architectural clock-gating): registers change only in a
// selected transfer (the reset generator requests the clock during a
// synchronous reset).
assign pclk_en_o       =  psel_i;


//============================================================================
// 4)  REGISTER DECODER
//============================================================================

wire [DEC_SZ-1:0] reg_dec;

genvar gd;
generate
    for (gd = 0; gd < DEC_SZ; gd = gd + 1) begin : g_dec
        assign reg_dec[gd] = (acc_addr == gd);
    end
endgenerate

// Read/Write vectors
wire [DEC_SZ-1:0] reg_wr   = reg_dec & {DEC_SZ{acc_write}};
wire [DEC_SZ-1:0] reg_rd   = reg_dec & {DEC_SZ{acc_read}};

// The REGIN bank is read-only: its write strobes have no consumer.
wire reg_dec_unused = |reg_wr[REGIN_15:REGIN_08];

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
// RESP   : Selects module response to unallowed accesses
//          (0: ignore access; 1: PSLVERR)
//
wire [31:0] mdeleg;
wire  [1:0] mdeleg_wr_priv;
wire  [1:0] mdeleg_rd_priv;
wire        mdeleg_resp;

// This register can only be changed when in Machine-Mode
wire        mdeleg_priv_wr       = reg_wr[MDELEG] & pstrb_i[0] & machine_mode;
wire        mdeleg_resp_wr       = reg_wr[MDELEG] & pstrb_i[1] & machine_mode;

// Coerce the reserved 2'b10 encoding to Machine-mode only (2'b11) at write
// time, so the register never holds or reads back a reserved code.
wire  [1:0] mdeleg_wr_priv_wdata = (pwdata_i[1:0] == MDELEG_PRIV_RSVD) ? 2'b11 : pwdata_i[1:0];
wire  [1:0] mdeleg_rd_priv_wdata = (pwdata_i[3:2] == MDELEG_PRIV_RSVD) ? 2'b11 : pwdata_i[3:2];

arv_ipdff #(.WIDTH(2), .RST_VAL(MDELEG_WR_PRIV_RST), .ARST_EN(ARST_EN)) u_mdeleg_wr_priv (
                             .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(mdeleg_priv_wr), .d_i(mdeleg_wr_priv_wdata), .q_o(mdeleg_wr_priv));

arv_ipdff #(.WIDTH(2), .RST_VAL(MDELEG_RD_PRIV_RST), .ARST_EN(ARST_EN)) u_mdeleg_rd_priv (
                             .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(mdeleg_priv_wr), .d_i(mdeleg_rd_priv_wdata), .q_o(mdeleg_rd_priv));

arv_ipdff #(.WIDTH(1), .RST_VAL(MDELEG_RESP_RST), .ARST_EN(ARST_EN))    u_mdeleg_resp (
                             .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(mdeleg_resp_wr), .d_i(pwdata_i[8]),          .q_o(mdeleg_resp));

// Combine 32b value for read path
assign      mdeleg          = {23'h000000, mdeleg_resp, 4'h0, mdeleg_rd_priv, mdeleg_wr_priv};

// Access is only allowed if the current privilege level is equal or higher to the configuration register
assign      reg_wr_allowed  = (privilege_mode >= mdeleg_wr_priv);
assign      reg_rd_allowed  = (privilege_mode >= mdeleg_rd_priv);


//=============================================================================
// 6)  ERROR RESPONSE
//=============================================================================

// Detect not allowed access to MDELEG (both read-write only allowed in Machine-Mode)
assign      mdeleg_wr_error = reg_wr[MDELEG] & mdeleg_resp & ~machine_mode;
assign      mdeleg_rd_error = reg_rd[MDELEG] & mdeleg_resp & ~machine_mode;

// Detect not allowed access to the other registers
assign      reg_wr_error    = acc_write      & mdeleg_resp & ~reg_wr_allowed;
assign      reg_rd_error    = acc_read       & mdeleg_resp & ~reg_rd_allowed;

// Every transfer completes in its first ACCESS cycle
assign pready_o             = 1'b1;
assign pslverr_o            = mdeleg_wr_error |
                              mdeleg_rd_error |
                              reg_wr_error    |
                              reg_rd_error    ;


//=============================================================================
// 7)  READ/WRITE REGISTERS
//=============================================================================

// RW register bank (REGOUT_00 ..), one enable per byte lane.
wire [31:0] regout     [0:REGOUT_NR-1];

genvar g;
generate
    for (g = 0; g < REGOUT_NR; g = g + 1) begin : g_regout_bank
        // Per-iteration local carries the registered value, then drives the
        // shared array word (constant-index word-selects on array ports are a
        // common iverilog/DC limitation, so the local hop keeps it portable).
        wire [31:0] regout_q;
        wire  [3:0] regout_wr = {4{reg_wr[REGOUT_00 + g] & reg_wr_allowed}} & pstrb_i;

        arv_ipdff #(.WIDTH(8), .ARST_EN(ARST_EN)) u_regout_b0 (
                             .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(regout_wr[0]), .d_i(pwdata_i[ 7: 0]), .q_o(regout_q[ 7: 0]));
        arv_ipdff #(.WIDTH(8), .ARST_EN(ARST_EN)) u_regout_b1 (
                             .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(regout_wr[1]), .d_i(pwdata_i[15: 8]), .q_o(regout_q[15: 8]));
        arv_ipdff #(.WIDTH(8), .ARST_EN(ARST_EN)) u_regout_b2 (
                             .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(regout_wr[2]), .d_i(pwdata_i[23:16]), .q_o(regout_q[23:16]));
        arv_ipdff #(.WIDTH(8), .ARST_EN(ARST_EN)) u_regout_b3 (
                             .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(regout_wr[3]), .d_i(pwdata_i[31:24]), .q_o(regout_q[31:24]));

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
// AND the requester's privilege level is allowed), OR-ed into prdata_o in a
// chain that starts from the MDELEG read term.
wire [31:0] mdeleg_rd   = (mdeleg & {32{reg_rd[MDELEG] & machine_mode}});
wire [31:0] regin       [0:REGIN_NR-1];
wire [31:0] reg_rd_data [0:REGOUT_NR+REGIN_NR-1];
wire [31:0] reg_rd_or   [0:REGOUT_NR+REGIN_NR];

assign regin[0] = register_08_i;
assign regin[1] = register_09_i;
assign regin[2] = register_10_i;
assign regin[3] = register_11_i;
assign regin[4] = register_12_i;
assign regin[5] = register_13_i;
assign regin[6] = register_14_i;
assign regin[7] = register_15_i;

generate
    for (g = 0; g < REGOUT_NR; g = g + 1) begin : g_regout_rd
        assign reg_rd_data[g]             = regout[g] & {32{reg_rd[REGOUT_00 + g] & reg_rd_allowed}};
    end
    for (g = 0; g < REGIN_NR; g = g + 1) begin : g_regin_rd
        assign reg_rd_data[REGOUT_NR + g] = regin[g]  & {32{reg_rd[REGIN_08  + g] & reg_rd_allowed}};
    end
    assign reg_rd_or[0] = mdeleg_rd;
    for (g = 0; g < REGOUT_NR + REGIN_NR; g = g + 1) begin : g_rd_or
        assign reg_rd_or[g+1] = reg_rd_or[g] | reg_rd_data[g];
    end
endgenerate

assign prdata_o = reg_rd_or[REGOUT_NR + REGIN_NR];


//-------------------------------------------------
// Lint cleanup
//-------------------------------------------------
wire  [1:0] paddr_unused     = paddr_i[1:0];
wire  [1:0] pprot_unused     = pprot_i[2:1];


endmodule // apb_periph_example

`default_nettype wire
