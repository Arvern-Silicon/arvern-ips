//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_apb_bridge
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_apb_bridge.v
// Module Description : AHB-Lite subordinate to APB4 bridge with SLV_NR APB
//                      completers. Each completer owns an aligned power-of-two
//                      window of the bridge's 2^ADDRW-byte space (SLV_BASE,
//                      SLV_AW). An AHB transfer becomes one APB transfer: the
//                      SETUP phase in the AHB data phase's first cycle, then
//                      ACCESS until PREADY. The AHB response comes from flops
//                      only (HREADYOUT, HRESP, HRDATA): the completers' PREADY,
//                      PRDATA and PSLVERR never reach the AHB return path in
//                      the same cycle. Writes are not posted: a PSLVERR, an
//                      address no completer decodes, a transfer wider than a
//                      word or a misaligned one ends in the two-cycle AHB ERROR
//                      response, with HRDATA at 0.
//
//                      PCLK is HCLK. PPROT = {instruction, 0 (Secure: the
//                      fabric carries no HNONSEC), privileged}; the bridge
//                      filters no privilege level. The aRVern supervisor-mode sideband
//                      (hsmode_i, from the fabric's HAUSER) is carried to the
//                      completers on psmode_o, and the manager ID (hmaster_i,
//                      which tags debugger accesses) on pmaster_o, both with
//                      the timing of PPROT.
//----------------------------------------------------------------------------
`default_nettype none

module  ahb_apb_bridge #(
    parameter                    SLV_NR       = 2,                   // APB completers (1-16)
    parameter                    ADDRW        = 12,                  // bridge window = 2^ADDRW bytes (4-31)
    parameter [SLV_NR*ADDRW-1:0] SLV_BASE     = {12'h100, 12'h000},  // completer k's window base in [k*ADDRW +: ADDRW]
    parameter     [SLV_NR*5-1:0] SLV_AW       = {5'd8, 5'd8},        // completer k's window = 2^SLV_AW bytes in [k*5 +: 5] (2-ADDRW)
    parameter                    ASYNC_RST_EN = 1'b1                 // Reset style: 1=async active-low reset, 0=synchronous reset
) (

// AHB CLOCK & RESET
    input  wire                  hclk_i,              // bridge and APB clock (PCLK = HCLK)
    input  wire                  hresetn_i,           // active-low reset, style per ASYNC_RST_EN
    output wire                  hclk_en_o,           // clock-gate enable for an external ICG (busy)

// AHB-LITE SUBORDINATE
    input  wire      [ADDRW-1:0] haddr_i,             // byte address in the bridge window
    input  wire            [3:0] hmaster_i,           // manager ID (tags debugger accesses)
    input  wire            [3:0] hprot_i,             // protection: [0] data (else instruction), [1] privileged
    input  wire                  hready_i,            // bus ready in
    input  wire            [2:0] hsize_i,             // transfer size (0 byte, 1 half-word, 2 word)
    input  wire                  hsmode_i,            // aRVern supervisor-mode sideband (HAUSER)
    input  wire            [1:0] htrans_i,            // transfer type (NONSEQ/SEQ start a transfer)
    input  wire           [31:0] hwdata_i,            // write data (data phase)
    input  wire                  hwrite_i,            // write
    input  wire                  hsel_i,              // subordinate select
    output wire           [31:0] hrdata_o,            // read data
    output wire                  hreadyout_o,         // ready out
    output wire                  hresp_o,             // response (1 = ERROR)

// APB4 REQUESTER
    output wire     [SLV_NR-1:0] psel_o,              // completer select, one-hot
    output wire      [ADDRW-1:0] paddr_o,             // byte address in the bridge window
    output wire                  penable_o,           // ACCESS phase
    output wire                  pwrite_o,            // write
    output wire           [31:0] pwdata_o,            // write data
    output wire            [3:0] pstrb_o,             // write byte strobes (0 for reads)
    output wire            [2:0] pprot_o,             // {instruction, 0 (Secure), privileged}
    output wire                  psmode_o,            // aRVern supervisor-mode sideband, with PPROT
    output wire            [3:0] pmaster_o,           // manager ID (HMASTER), with PPROT
    input  wire  [SLV_NR*32-1:0] prdata_i,            // completer k's read data in [k*32 +: 32]
    input  wire     [SLV_NR-1:0] pready_i,            // completer ready
    input  wire     [SLV_NR-1:0] pslverr_i            // completer error (valid with PREADY)
);


//=============================================================================
// 1)  PARAMETER CHECKS AND DECLARATIONS
//=============================================================================

// pragma translate_off
genvar gc, gd;
generate
    if ((SLV_NR < 1) || (SLV_NR > 16)) begin : CHECK_SLV_NR
        initial $fatal(1, "ahb_apb_bridge: SLV_NR (%0d) must be 1-16.", SLV_NR);
    end
    if ((ADDRW < 4) || (ADDRW > 31)) begin : CHECK_ADDRW
        initial $fatal(1, "ahb_apb_bridge: ADDRW (%0d) must be 4-31.", ADDRW);
    end
    if ((ASYNC_RST_EN != 0) && (ASYNC_RST_EN != 1)) begin : CHECK_ASYNC_RST_EN
        initial $fatal(1, "ahb_apb_bridge: ASYNC_RST_EN (%0d) must be 0 or 1.", ASYNC_RST_EN);
    end
    for (gc = 0; gc < SLV_NR; gc = gc + 1) begin : CHECK_WIN
        localparam integer     CAW  = {27'd0, SLV_AW[gc*5 +: 5]};
        localparam [ADDRW-1:0] LOWM = ({ADDRW{1'b1}}) >> (ADDRW - CAW);       // offsets inside the window
        if ((CAW < 2) || (CAW > ADDRW)) begin : AW
            initial $fatal(1, "ahb_apb_bridge: SLV_AW of completer %0d (%0d) must be 2-ADDRW.", gc, CAW);
        end
        if ((SLV_BASE[gc*ADDRW +: ADDRW] & LOWM) != {ADDRW{1'b0}}) begin : ALIGN
            initial $fatal(1, "ahb_apb_bridge: completer %0d's base is not aligned to its window.", gc);
        end
        // Two aligned power-of-two windows overlap when they agree above the
        // larger one's size
        for (gd = gc + 1; gd < SLV_NR; gd = gd + 1) begin : OVL
            localparam integer     DAW  = {27'd0, SLV_AW[gd*5 +: 5]};
            localparam integer     MAW  = (CAW > DAW) ? CAW : DAW;
            localparam [ADDRW-1:0] HIM  = ~(({ADDRW{1'b1}}) >> (ADDRW - MAW));
            if ((SLV_BASE[gc*ADDRW +: ADDRW] & HIM) == (SLV_BASE[gd*ADDRW +: ADDRW] & HIM)) begin : HIT
                initial $fatal(1, "ahb_apb_bridge: the windows of completers %0d and %0d overlap.", gc, gd);
            end
        end
    end
endgenerate
// pragma translate_on

localparam              ARST_EN  = (ASYNC_RST_EN != 0);

// AHB hsize encodings (the natural sizes up to a word)
localparam        [1:0] HSIZE_BYTE = 2'b00;
localparam        [1:0] HSIZE_HALF = 2'b01;
localparam        [1:0] HSIZE_WORD = 2'b10;

// States
localparam        [2:0] S_IDLE   = 3'd0,          // ready, no transfer
                        S_SETUP  = 3'd1,          // APB SETUP (AHB data phase, first cycle)
                        S_ACCESS = 3'd2,          // APB ACCESS until PREADY
                        S_DONE   = 3'd3,          // AHB OKAY response
                        S_ERR1   = 3'd4,          // AHB ERROR, first cycle (HREADYOUT low)
                        S_ERR2   = 3'd5;          // AHB ERROR, second cycle (HREADYOUT high)

wire                    aph_valid;                // AHB address phase accepted
wire              [3:0] aph_byte_mask;
wire       [SLV_NR-1:0] aph_sel;                  // completer decoded
wire                    aph_misal;                // half-word or word not aligned to its size
wire                    aph_bad;                  // no completer, wider than a word, or misaligned
wire              [2:0] state;
wire              [2:0] state_nxt;
wire                    st_idle;
wire                    st_setup;
wire                    st_access;
wire                    st_done;
wire                    st_err1;
wire                    st_err2;
wire                    st_open;                  // HREADYOUT high: a new address phase is taken
wire       [SLV_NR-1:0] sel;                      // completer of the transfer
wire        [ADDRW-1:0] addr;
wire                    write;
wire              [3:0] strb;
wire              [2:0] prot;
wire                    smode;
wire              [3:0] master;
wire                    rsp_en;                   // the completer finished (ACCESS and PREADY)
wire                    rsp_err;                  // the completer's PSLVERR (used with rsp_en only)
wire                    rd_ok;                    // a read completed without error: HRDATA takes PRDATA
wire                    err_go;                   // an ERROR response starts: HRDATA reads 0
wire             [31:0] rd_mux;
wire             [31:0] rdata;


//=============================================================================
// 2)  ADDRESS PHASE
//=============================================================================

assign aph_valid     = hsel_i & hready_i & htrans_i[1];

assign aph_byte_mask = {((hsize_i[1:0]==HSIZE_BYTE) & (haddr_i[1:0]==2'b11)) | ((hsize_i[1:0]==HSIZE_HALF) & haddr_i[1]) | (hsize_i[1:0]==HSIZE_WORD),
                        ((hsize_i[1:0]==HSIZE_BYTE) & (haddr_i[1:0]==2'b10)) | ((hsize_i[1:0]==HSIZE_HALF) & haddr_i[1]) | (hsize_i[1:0]==HSIZE_WORD),
                        ((hsize_i[1:0]==HSIZE_BYTE) & (haddr_i[1:0]==2'b01)) | ((hsize_i[1:0]==HSIZE_HALF) & ~haddr_i[1]) | (hsize_i[1:0]==HSIZE_WORD),
                        ((hsize_i[1:0]==HSIZE_BYTE) & (haddr_i[1:0]==2'b00)) | ((hsize_i[1:0]==HSIZE_HALF) & ~haddr_i[1]) | (hsize_i[1:0]==HSIZE_WORD)};

// Window decode: the address bits above each completer's window match its base
genvar gs;
generate
    for (gs = 0; gs < SLV_NR; gs = gs + 1) begin : g_dec
        localparam integer     WAW  = {27'd0, SLV_AW[gs*5 +: 5]};
        localparam [ADDRW-1:0] MASK = ~(({ADDRW{1'b1}}) >> (ADDRW - WAW));
        assign aph_sel[gs] = ((haddr_i & MASK) == (SLV_BASE[gs*ADDRW +: ADDRW] & MASK));
    end
endgenerate

assign aph_misal = ((hsize_i[1:0] == HSIZE_HALF) & haddr_i[0]) | ((hsize_i[1:0] == HSIZE_WORD) & (|haddr_i[1:0]));

assign aph_bad   = ~(|aph_sel) | hsize_i[2] | (hsize_i[1:0] == 2'b11) | aph_misal;


//=============================================================================
// 3)  STATE MACHINE
//=============================================================================
// IDLE, DONE and ERR2 are the cycles where HREADYOUT is high (st_open): a new
// address phase is taken there

assign st_idle   = (state == S_IDLE);
assign st_setup  = (state == S_SETUP);
assign st_access = (state == S_ACCESS);
assign st_done   = (state == S_DONE);
assign st_err1   = (state == S_ERR1);
assign st_err2   = (state == S_ERR2);
assign st_open   = st_idle | st_done | st_err2;

assign rsp_en    = st_access & (|(sel & pready_i));
assign rsp_err   = |(sel & pslverr_i);

assign state_nxt = (st_open & aph_valid)  ? (aph_bad ? S_ERR1 : S_SETUP) :
                   st_open                ? S_IDLE   :
                   st_setup               ? S_ACCESS :
                   (st_access & rsp_en)   ? (rsp_err ? S_ERR1 : S_DONE) :
                   st_access              ? S_ACCESS :
                   st_err1                ? S_ERR2   :
                                            S_IDLE;     // unused encodings

arv_ipdff #(.WIDTH(3), .ARST_EN(ARST_EN)) u_state (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(1'b1), .d_i(state_nxt), .q_o(state));

// Transfer attributes, taken with the address phase and held to the end
wire                    attr_en = aph_valid & st_open;

arv_ipdff #(.WIDTH(SLV_NR+ADDRW+1+4+3+1+4), .ARST_EN(ARST_EN)) u_attr (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(attr_en),
    .d_i({aph_bad ? {SLV_NR{1'b0}} : aph_sel, haddr_i, hwrite_i, hwrite_i ? aph_byte_mask : 4'b0000,
          ~hprot_i[0], 1'b0, hprot_i[1], hsmode_i, hmaster_i}),
    .q_o({sel, addr, write, strb, prot, smode, master}));

// Read data, taken when a read completes without error and cleared when an
// ERROR response starts, so HRDATA is 0 in both ERROR cycles
generate
    if (SLV_NR == 1) begin : g_rd_one
        assign rd_mux = prdata_i[31:0];
    end else begin : g_rd_mux
        reg  [31:0] mux;
        integer     k;
        always @(*) begin
            mux = 32'd0;
            for (k = 0; k < SLV_NR; k = k + 1)
                mux = mux | ({32{sel[k]}} & prdata_i[k*32 +: 32]);
        end
        assign rd_mux = mux;
    end
endgenerate

assign rd_ok  = rsp_en & ~rsp_err & ~write;
assign err_go = (attr_en & aph_bad) | (rsp_en & rsp_err);

arv_ipdff #(.WIDTH(32), .ARST_EN(ARST_EN)) u_rdata (
    .clk_i(hclk_i), .rst_n_i(hresetn_i), .en_i(rd_ok | err_go), .d_i({32{rd_ok}} & rd_mux), .q_o(rdata));


//=============================================================================
// 4)  OUTPUTS
//=============================================================================

assign hreadyout_o = st_open;
assign hresp_o     = st_err1 | st_err2;
assign hrdata_o    = rdata;

assign psel_o      = sel & {SLV_NR{st_setup | st_access}};
assign penable_o   = st_access;
assign paddr_o     = addr;
assign pwrite_o    = write;
assign pwdata_o    = hwdata_i;
assign pstrb_o     = strb;
assign pprot_o     = prot;
assign psmode_o    = smode;
assign pmaster_o   = master;

// Clock request: a transfer in flight or arriving (the reset generator
// requests the clock during a synchronous reset)
assign hclk_en_o   = ~st_idle | aph_valid;

wire   [1:0] hprot_unused  = hprot_i[3:2];
wire         htrans_unused = htrans_i[0];

endmodule // ahb_apb_bridge

`default_nettype wire
