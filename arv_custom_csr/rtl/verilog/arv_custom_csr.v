//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    arv_custom_csr
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : arv_custom_csr.v
// Module Description : Implementation of Custom CSR registers interfacing with
//                      the aRVern core.
//----------------------------------------------------------------------------
`default_nettype none

module  arv_custom_csr (

// AHB CLOCK & RESET
    hclk_i,
    hresetn_i,
    hclk_en_o,

// READ-ONLY VALUES FROM OUTSIDE WORLD
    ccsr_usr_ro_i,
    ccsr_sup_ro_i,
    ccsr_mac_ro_i,

// READ-WRITE VALUES TO OUTSIDE WORLD
    ccsr_usr_rw_o,
    ccsr_sup_rw_o,
    ccsr_mac_rw_o,

// INTERFACE TO CUSTOM CSR REGISTERS
    ccsr_bank_i,
    ccsr_reg_sel_i,
    ccsr_wdata_i,
    ccsr_wen_i,
    ccsr_rdata_o
);

// USER PARAMETERs
//======================================
parameter integer            NR_USR_RW    = 6;       // Number of User-Mode Read-Write registers       (min: 0; max: 256)
parameter integer            NR_USR_RO    = 2;       // Number of User-Mode Read-Only  registers       (min: 0; max:  64)

parameter integer            NR_SUP_RW    = 4;       // Number of Supervisor-Mode Read-Write registers (min: 0; max: 128)
parameter integer            NR_SUP_RO    = 2;       // Number of Supervisor-Mode Read-Only  registers (min: 0; max:  64)

parameter integer            NR_MAC_RW    = 2;       // Number of Machine-Mode Read-Write registers    (min: 0; max: 128)
parameter integer            NR_MAC_RO    = 1;       // Number of Machine-Mode Read-Only  registers    (min: 0; max:  64)

parameter                    ASYNC_RST_EN = 1'b1;    // Reset architecture: 1=async active-low reset, 0=synchronous reset

// LOCAL PARAMETERs
//======================================
localparam                   USR_RW_W     = (NR_USR_RW>0) ? (NR_USR_RW*32) : 1;
localparam                   USR_RO_W     = (NR_USR_RO>0) ? (NR_USR_RO*32) : 1;

localparam                   SUP_RW_W     = (NR_SUP_RW>0) ? (NR_SUP_RW*32) : 1;
localparam                   SUP_RO_W     = (NR_SUP_RO>0) ? (NR_SUP_RO*32) : 1;

localparam                   MAC_RW_W     = (NR_MAC_RW>0) ? (NR_MAC_RW*32) : 1;
localparam                   MAC_RO_W     = (NR_MAC_RO>0) ? (NR_MAC_RO*32) : 1;

// AHB CLOCK & RESET
//=====================================================
input  wire                  hclk_i;
input  wire                  hresetn_i;
output wire                  hclk_en_o;

// READ-ONLY VALUES FROM OUTSIDE WORLD
//=====================================================
input  wire   [USR_RO_W-1:0] ccsr_usr_ro_i;
input  wire   [SUP_RO_W-1:0] ccsr_sup_ro_i;
input  wire   [MAC_RO_W-1:0] ccsr_mac_ro_i;

// READ-WRITE VALUES TO OUTSIDE WORLD
//=====================================================
output wire   [USR_RW_W-1:0] ccsr_usr_rw_o;
output wire   [SUP_RW_W-1:0] ccsr_sup_rw_o;
output wire   [MAC_RW_W-1:0] ccsr_mac_rw_o;

// INTERFACE TO CUSTOM CSR REGISTERS
//=====================================================
input  wire           [10:0] ccsr_bank_i;
input  wire           [63:0] ccsr_reg_sel_i;
input  wire           [31:0] ccsr_wdata_i;
input  wire                  ccsr_wen_i;
output wire           [31:0] ccsr_rdata_o;


//////======================================================================================================================//////
//////======================================================================================================================//////
//////                                                                                                                      //////
//////                                             PRIV_LEVEL AND BANK_SELECT ENCODING                                      //////
//////                                                                                                                      //////
//////======================================================================================================================//////
//////======================================================================================================================//////
//////                                                                                                                      //////
//////                          + ccsr_bank_i[0]      -> 0x800-0x83F Custom Read-Write, User-Mode                           //////
//////                          + ccsr_bank_i[1]      -> 0x840-0x87F Custom Read-Write, User-Mode                           //////
//////                          + ccsr_bank_i[2]      -> 0x880-0x8BF Custom Read-Write, User-Mode                           //////
//////                          + ccsr_bank_i[3]      -> 0x8C0-0x8FF Custom Read-Write, User-Mode                           //////
//////                          + ccsr_bank_i[4]      -> 0xCC0-0xCFF Custom Read-Only,  User-Mode                           //////
//////                                                                                                                      //////
//////                          + ccsr_bank_i[5]      -> 0x5C0-0x5FF Custom Read-Write, Supervisor-Mode                     //////
//////                          + ccsr_bank_i[6]      -> 0x9C0-0x9FF Custom Read-Write, Supervisor-Mode                     //////
//////                          + ccsr_bank_i[7]      -> 0xDC0-0xDFF Custom Read-Only,  Supervisor-Mode                     //////
//////                                                                                                                      //////
//////                          + ccsr_bank_i[8]      -> 0x7C0-0x7FF Custom Read-Write, Machine-Mode                        //////
//////                          + ccsr_bank_i[9]      -> 0xBC0-0xBFF Custom Read-Write, Machine-Mode                        //////
//////                          + ccsr_bank_i[10]     -> 0xFC0-0xFFF Custom Read-Only,  Machine-Mode                        //////
//////                                                                                                                      //////
//////======================================================================================================================//////

// Wires for User-Mode CSRs.
// `ccsr_reg_en_*` are full-bank-width decode vectors; bits above NR_*_* are
// intentionally unused and explicitly tied to `*_unused` wires further down
// (see LINT CLEANUP section). The `_unused` postfix convention lets a single
// generic waiver file be written for any lint tool.
wire         hclk_usr_rdwr_en;
wire [256:0] ccsr_reg_en_usr_rdwr;
wire  [64:0] ccsr_reg_en_usr_rdonly;
wire  [31:0] ccsr_rdata_usr_rdwr;
wire  [31:0] ccsr_rdata_usr_rdonly;

// Wires for Supervisor-Mode CSRs
wire         hclk_sup_rdwr_en;
wire [128:0] ccsr_reg_en_sup_rdwr;
wire  [64:0] ccsr_reg_en_sup_rdonly;
wire  [31:0] ccsr_rdata_sup_rdwr;
wire  [31:0] ccsr_rdata_sup_rdonly;

// Wires for Machine-Mode CSRs
wire         hclk_mac_rdwr_en;
wire [128:0] ccsr_reg_en_mac_rdwr;
wire  [64:0] ccsr_reg_en_mac_rdonly;
wire  [31:0] ccsr_rdata_mac_rdwr;
wire  [31:0] ccsr_rdata_mac_rdonly;


//////======================================================================================================================//////
//////======================================================================================================================//////
//////                                                                                                                      //////
//////                                               USER-MODE CSR REGISTERS                                                //////
//////                                                                                                                      //////
//////======================================================================================================================//////
//////======================================================================================================================//////

// The `{1'b0, ...}` padding-bit at the MSB of each decoder vector exists so
// that the "unused" slice `[N : NR_*]` (see LINT CLEANUP section below) is
// at least 1 bit wide when NR_* equals the maximum bank width. Without the
// pad, NR_*_RW = 256/128 (or NR_*_RO = 64) would produce a reversed slice.
assign ccsr_reg_en_usr_rdonly =  {1'b0, ( ccsr_reg_sel_i & {64{ccsr_bank_i[4]}} )};
assign ccsr_reg_en_usr_rdwr   =  {1'b0, ( ccsr_reg_sel_i & {64{ccsr_bank_i[3]}} ),
                                        ( ccsr_reg_sel_i & {64{ccsr_bank_i[2]}} ),
                                        ( ccsr_reg_sel_i & {64{ccsr_bank_i[1]}} ),
                                        ( ccsr_reg_sel_i & {64{ccsr_bank_i[0]}} )};

generate
    if (NR_USR_RO>0) begin : WITH_USR_RO
        arv_ccsr_rdonly #(.NR_REG(NR_USR_RO)) arv_ccsr_user_rdonly_inst (

            .ccsr_reg_value_i                   ( ccsr_usr_ro_i                         ),
            .ccsr_reg_en_i                      ( ccsr_reg_en_usr_rdonly[NR_USR_RO-1:0] ),
            .ccsr_rdata_o                       ( ccsr_rdata_usr_rdonly                 )
        );
    end else begin         : WITHOUT_USR_RO
        wire   ccsr_usr_ro_unused;
        assign ccsr_rdata_usr_rdonly = 32'h00000000;
        assign ccsr_usr_ro_unused    = ccsr_usr_ro_i;
    end
endgenerate

generate
    if (NR_USR_RW>0) begin : WITH_USR_RW
        arv_ccsr_rdwr #(.NR_REG(NR_USR_RW), .ARST_EN(ASYNC_RST_EN)) arv_ccsr_user_rdwr_inst (
            .hclk_i                             ( hclk_i                                ),
            .hresetn_i                          ( hresetn_i                             ),
            .hclk_en_o                          ( hclk_usr_rdwr_en                      ),

            .ccsr_reg_value_o                   ( ccsr_usr_rw_o                         ),

            .ccsr_reg_en_i                      ( ccsr_reg_en_usr_rdwr[NR_USR_RW-1:0]   ),
            .ccsr_wdata_i                       ( ccsr_wdata_i                          ),
            .ccsr_wen_i                         ( ccsr_wen_i                            ),
            .ccsr_rdata_o                       ( ccsr_rdata_usr_rdwr                   )
        );
    end else begin         : WITHOUT_USR_RW
        assign hclk_usr_rdwr_en    =             1'b0;
        assign ccsr_usr_rw_o       = {USR_RW_W{  1'b0}};
        assign ccsr_rdata_usr_rdwr =            32'h00000000;
    end
endgenerate


//////======================================================================================================================//////
//////======================================================================================================================//////
//////                                                                                                                      //////
//////                                               SUPERVISOR-MODE CSR REGISTERS                                          //////
//////                                                                                                                      //////
//////======================================================================================================================//////
//////======================================================================================================================//////

assign ccsr_reg_en_sup_rdonly =  {1'b0, ( ccsr_reg_sel_i & {64{ccsr_bank_i[7]}} )};
assign ccsr_reg_en_sup_rdwr   =  {1'b0, ( ccsr_reg_sel_i & {64{ccsr_bank_i[6]}} ),
                                        ( ccsr_reg_sel_i & {64{ccsr_bank_i[5]}} )};

generate
    if (NR_SUP_RO>0) begin : WITH_SUP_RO
        arv_ccsr_rdonly #(.NR_REG(NR_SUP_RO)) arv_ccsr_supervisor_rdonly_inst (

            .ccsr_reg_value_i                   ( ccsr_sup_ro_i                         ),
            .ccsr_reg_en_i                      ( ccsr_reg_en_sup_rdonly[NR_SUP_RO-1:0] ),
            .ccsr_rdata_o                       ( ccsr_rdata_sup_rdonly                 )
        );
    end else begin         : WITHOUT_SUP_RO
        wire   ccsr_sup_ro_unused;
        assign ccsr_rdata_sup_rdonly = 32'h00000000;
        assign ccsr_sup_ro_unused    = ccsr_sup_ro_i;
    end
endgenerate

generate
    if (NR_SUP_RW>0) begin : WITH_SUP_RW
        arv_ccsr_rdwr #(.NR_REG(NR_SUP_RW), .ARST_EN(ASYNC_RST_EN)) arv_ccsr_supervisor_rdwr_inst (
            .hclk_i                             ( hclk_i                                ),
            .hresetn_i                          ( hresetn_i                             ),
            .hclk_en_o                          ( hclk_sup_rdwr_en                      ),

            .ccsr_reg_value_o                   ( ccsr_sup_rw_o                         ),

            .ccsr_reg_en_i                      ( ccsr_reg_en_sup_rdwr[NR_SUP_RW-1:0]   ),
            .ccsr_wdata_i                       ( ccsr_wdata_i                          ),
            .ccsr_wen_i                         ( ccsr_wen_i                            ),
            .ccsr_rdata_o                       ( ccsr_rdata_sup_rdwr                   )
        );
    end else begin         : WITHOUT_SUP_RW
        assign hclk_sup_rdwr_en    =             1'b0;
        assign ccsr_sup_rw_o       = {SUP_RW_W{  1'b0}};
        assign ccsr_rdata_sup_rdwr =            32'h00000000;
    end
endgenerate


//////======================================================================================================================//////
//////======================================================================================================================//////
//////                                                                                                                      //////
//////                                               MACHINE-MODE CSR REGISTERS                                             //////
//////                                                                                                                      //////
//////======================================================================================================================//////
//////======================================================================================================================//////

assign ccsr_reg_en_mac_rdonly =  {1'b0, ( ccsr_reg_sel_i & {64{ccsr_bank_i[10]}})};
assign ccsr_reg_en_mac_rdwr   =  {1'b0, ( ccsr_reg_sel_i & {64{ccsr_bank_i[9]}} ),
                                        ( ccsr_reg_sel_i & {64{ccsr_bank_i[8]}} )};

generate
    if (NR_MAC_RO>0) begin : WITH_MAC_RO
        arv_ccsr_rdonly #(.NR_REG(NR_MAC_RO)) arv_ccsr_machine_rdonly_inst (

            .ccsr_reg_value_i                   ( ccsr_mac_ro_i                         ),
            .ccsr_reg_en_i                      ( ccsr_reg_en_mac_rdonly[NR_MAC_RO-1:0] ),
            .ccsr_rdata_o                       ( ccsr_rdata_mac_rdonly                 )
        );
    end else begin         : WITHOUT_MAC_RO
        wire   ccsr_mac_ro_unused;
        assign ccsr_rdata_mac_rdonly = 32'h00000000;
        assign ccsr_mac_ro_unused    = ccsr_mac_ro_i;
    end
endgenerate

generate
    if (NR_MAC_RW>0) begin : WITH_MAC_RW
        arv_ccsr_rdwr #(.NR_REG(NR_MAC_RW), .ARST_EN(ASYNC_RST_EN)) arv_ccsr_machine_rdwr_inst (
            .hclk_i                             ( hclk_i                                ),
            .hresetn_i                          ( hresetn_i                             ),
            .hclk_en_o                          ( hclk_mac_rdwr_en                      ),

            .ccsr_reg_value_o                   ( ccsr_mac_rw_o                         ),

            .ccsr_reg_en_i                      ( ccsr_reg_en_mac_rdwr[NR_MAC_RW-1:0]   ),
            .ccsr_wdata_i                       ( ccsr_wdata_i                          ),
            .ccsr_wen_i                         ( ccsr_wen_i                            ),
            .ccsr_rdata_o                       ( ccsr_rdata_mac_rdwr                   )
        );
    end else begin         : WITHOUT_MAC_RW
        assign hclk_mac_rdwr_en    =             1'b0;
        assign ccsr_mac_rw_o       = {MAC_RW_W{  1'b0}};
        assign ccsr_rdata_mac_rdwr =            32'h00000000;
    end
endgenerate


//////======================================================================================================================//////
//////======================================================================================================================//////
//////                                                                                                                      //////
//////                                       COMBINE CLOCK-ENABLES AND READ-DATA                                            //////
//////                                                                                                                      //////
//////======================================================================================================================//////
//////======================================================================================================================//////
//
// CONTRACT: The OR-mux on ccsr_rdata_o and hclk_en_o relies on the caller
// driving ccsr_bank_i and ccsr_reg_sel_i as ONE-HOT (or all-zero) vectors,
// per the RISC-V CSR interface defined in doc/arv_custom_csr.md. A multi-hot
// input bit-wise ORs the data of every selected bank/register and asserts
// hclk_en_o for every selected RW bank simultaneously, which is not a valid
// architectural state. This module does NOT detect or recover from that.

assign       hclk_en_o    =  hclk_usr_rdwr_en      |
                             hclk_sup_rdwr_en      |
                             hclk_mac_rdwr_en      ;

assign       ccsr_rdata_o =  ccsr_rdata_usr_rdwr   |
                             ccsr_rdata_usr_rdonly |
                             ccsr_rdata_sup_rdwr   |
                             ccsr_rdata_sup_rdonly |
                             ccsr_rdata_mac_rdwr   |
                             ccsr_rdata_mac_rdonly ;


//////======================================================================================================================//////
//////======================================================================================================================//////
//////                                                                                                                      //////
//////                                        LINT CLEANUP & PARAMETER CHECK                                                //////
//////                                                                                                                      //////
//////======================================================================================================================//////
//////======================================================================================================================//////

// LINT CONVENTION: the bank decode vectors `ccsr_reg_en_*` are sized for the
// architectural maximum, but the sub-instances only consume the lower
// [NR_*-1:0] bits. The upper bits are intentionally unused. We tie them to
// `*_unused` sink wires so that *any* lint tool can waive them with a single
// rule on the `_unused` postfix (no tool-specific pragmas required). See
// doc/arv_custom_csr.md for the waiver-file recipe.

// Unused User signals
wire  [64-NR_USR_RO:0] ccsr_reg_en_usr_rdonly_unused;
wire [256-NR_USR_RW:0] ccsr_reg_en_usr_rdwr_unused;

assign  ccsr_reg_en_usr_rdonly_unused = ccsr_reg_en_usr_rdonly[64:NR_USR_RO];
assign  ccsr_reg_en_usr_rdwr_unused   = ccsr_reg_en_usr_rdwr[256:NR_USR_RW];

// Unused Supervisor signals
wire  [64-NR_SUP_RO:0] ccsr_reg_en_sup_rdonly_unused;
wire [128-NR_SUP_RW:0] ccsr_reg_en_sup_rdwr_unused;

assign  ccsr_reg_en_sup_rdonly_unused = ccsr_reg_en_sup_rdonly[64:NR_SUP_RO];
assign  ccsr_reg_en_sup_rdwr_unused   = ccsr_reg_en_sup_rdwr[128:NR_SUP_RW];

// Unused Machine signals
wire  [64-NR_MAC_RO:0] ccsr_reg_en_mac_rdonly_unused;
wire [128-NR_MAC_RW:0] ccsr_reg_en_mac_rdwr_unused;

assign  ccsr_reg_en_mac_rdonly_unused = ccsr_reg_en_mac_rdonly[64:NR_MAC_RO];
assign  ccsr_reg_en_mac_rdwr_unused   = ccsr_reg_en_mac_rdwr[128:NR_MAC_RW];

// Check parameter values: abort elaboration if any NR_*_* is out of range.
// Lower bound 0 is legal (sub-instance is generate-guarded); upper bounds
// follow the bank decoder layout: 4 banks*64 for User-RW, 2*64 for Sup/Mac-RW,
// 1*64 for any RO.
// pragma translate_off
generate
    if ((NR_USR_RW < 0) || (NR_USR_RW > 256)) begin : CHECK_NR_USR_RW
        initial $fatal(1, "arv_custom_csr: NR_USR_RW (%0d) must be 0..256.", NR_USR_RW);
    end
    if ((NR_USR_RO < 0) || (NR_USR_RO >  64)) begin : CHECK_NR_USR_RO
        initial $fatal(1, "arv_custom_csr: NR_USR_RO (%0d) must be 0..64.",  NR_USR_RO);
    end
    if ((NR_SUP_RW < 0) || (NR_SUP_RW > 128)) begin : CHECK_NR_SUP_RW
        initial $fatal(1, "arv_custom_csr: NR_SUP_RW (%0d) must be 0..128.", NR_SUP_RW);
    end
    if ((NR_SUP_RO < 0) || (NR_SUP_RO >  64)) begin : CHECK_NR_SUP_RO
        initial $fatal(1, "arv_custom_csr: NR_SUP_RO (%0d) must be 0..64.",  NR_SUP_RO);
    end
    if ((NR_MAC_RW < 0) || (NR_MAC_RW > 128)) begin : CHECK_NR_MAC_RW
        initial $fatal(1, "arv_custom_csr: NR_MAC_RW (%0d) must be 0..128.", NR_MAC_RW);
    end
    if ((NR_MAC_RO < 0) || (NR_MAC_RO >  64)) begin : CHECK_NR_MAC_RO
        initial $fatal(1, "arv_custom_csr: NR_MAC_RO (%0d) must be 0..64.",  NR_MAC_RO);
    end
     if ((ASYNC_RST_EN != 0) && (ASYNC_RST_EN != 1)) begin : CHECK_ASYNC_RST_EN
        initial $fatal(1, "arv_custom_csr: ASYNC_RST_EN (%0d) must be 0 or 1.", ASYNC_RST_EN);
    end
endgenerate
// pragma translate_on

endmodule // arv_custom_csr

`default_nettype wire
