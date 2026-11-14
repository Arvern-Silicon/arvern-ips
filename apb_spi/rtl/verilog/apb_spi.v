//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    apb_spi
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : apb_spi.v
// Module Description : APB4 SPI controller (single, dual and quad lanes):
//                        + SCK from pclk_i by an integer divider, all four
//                          clock modes, MSB / LSB first, byte swap
//                        + up to eight chip selects with setup, hold and
//                          inactive times
//                        + a transmit FIFO of entries (XFER attributes +
//                          payload): TX, RX, DUMMY clocks and POLL, so a
//                          whole SD-card or flash transaction is queued
//                          under one chip select (apb_spi_core)
//                        + a receive FIFO, thresholds, sticky flags, one
//                          interrupt line
//                        + debugger-aware RXDATA reads (pmaster_i)
//                        + MDELEG privilege gate (minimum write and read
//                          privilege, PSLVERR or silent drop), reset value
//                          MDELEG_RST
//
// REGISTER MAP (byte offsets of the 1<<ADDRW byte window):
//   0x00 CFG        RO     0x20 THRESH     RW     0x60 MDELEG     RW (M-mode only)
//   0x04 CTRL       RW     0x24 IRQ_EN     RW
//   0x08 CTRL_SET   WO     0x28 IRQ_EN_SET WO
//   0x0C CTRL_CLR   WO     0x2C IRQ_EN_CLR WO
//   0x10 CLKDIV     RW     0x30 IRQ_PEND   RO/W1C
//   0x14 CSCFG      RW     0x34 TXDATA     WO (pushes {XFER, PWDATA})
//   0x18 XFER       RW     0x38 RXDATA     RO (pops)
//   0x1C STATUS     RO     0x3C CMD        WO
//----------------------------------------------------------------------------
`default_nettype none

module  apb_spi #(
    parameter                 LANES_MAX        = 4,       // widest lane mode built: 1, 2 or 4
    parameter                 CS_NR            = 1,       // chip-select outputs (1..8)
    parameter                 RX_EN            = 1,       // receive path present
    parameter                 POLL_EN          = 1,       // POLL entries (needs RX_EN)
    parameter                 TX_FIFO_AW       = 4,       // transmit FIFO depth = 1 << TX_FIFO_AW entries (1..8)
    parameter                 RX_FIFO_AW       = 4,       // receive FIFO depth = 1 << RX_FIFO_AW words (1..8)
    parameter                 ADDRW            = 7,       // APB address width (window = 1<<ADDRW bytes, 7..16)
    parameter           [8:0] MDELEG_RST       = 9'h10F,  // MDELEG[8:0] reset value (default: M-mode only, PSLVERR)
    parameter           [3:0] DBG_PMASTER_MASK = 4'b1000, // PMASTER bits identifying a debugger access
    parameter                 ASYNC_RST_EN     = 1        // Reset style: 1=async active-low reset, 0=synchronous reset
) (

// APB CLOCK & RESET
    input  wire               pclk_i,                    // bus clock and SCK timebase (gated by pclk_en_o at the SoC-level ICG)
    input  wire               presetn_i,                 // active-low reset, style per ASYNC_RST_EN
    output wire               pclk_en_o,                 // clock request: a transfer, the engine busy, or an entry waiting

// APB INTERFACE
    input  wire               psel_i,                    // completer select
    input  wire               penable_i,                 // ACCESS phase
    input  wire   [ADDRW-1:0] paddr_i,                   // byte address
    input  wire               pwrite_i,                  // write
    input  wire        [31:0] pwdata_i,                  // write data
    input  wire         [3:0] pstrb_i,                   // write strobes (0 for reads)
    input  wire         [2:0] pprot_i,                   // protection ([0] privileged; [2:1] not used)
    input  wire               psmode_i,                  // aRVern S-mode sideband (with the timing of pprot)
    input  wire         [3:0] pmaster_i,                 // manager ID (with the timing of pprot); debugger per DBG_PMASTER_MASK
    output wire        [31:0] prdata_o,                  // read data
    output wire               pready_o,                  // ready (no wait states)
    output wire               pslverr_o,                 // error (access refused by MDELEG with RESP=1)

// SPI
    output wire               spi_sck_o,                 // serial clock
    output wire   [CS_NR-1:0] spi_cs_o,                  // chip selects (polarity per CSCFG.CSPOL)
    output wire         [3:0] spi_io_o,                  // lane outputs: [0] MOSI/IO0, [1] MISO/IO1, [2] WP#/IO2, [3] HOLD#/IO3
    output wire         [3:0] spi_io_oe_o,               // lane output enables
    input  wire         [3:0] spi_io_i,                  // lane inputs (synchronised inside)

// INTERRUPT
    output wire               irq_o                      // OR of IRQ_PEND & IRQ_EN
 );


//=============================================================================
// 1)  PARAMETER DECLARATION
//=============================================================================

// pragma translate_off
generate
    if ((LANES_MAX != 1) && (LANES_MAX != 2) && (LANES_MAX != 4)) begin : CHECK_LANES_MAX
        initial $fatal(1, "apb_spi: LANES_MAX (%0d) must be 1, 2 or 4.", LANES_MAX);
    end
    if ((CS_NR < 1) || (CS_NR > 8)) begin : CHECK_CS_NR
        initial $fatal(1, "apb_spi: CS_NR (%0d) must be 1..8.", CS_NR);
    end
    if ((RX_EN != 0) && (RX_EN != 1)) begin : CHECK_RX_EN
        initial $fatal(1, "apb_spi: RX_EN (%0d) must be 0 or 1.", RX_EN);
    end
    if ((POLL_EN != 0) && (POLL_EN != 1)) begin : CHECK_POLL_EN
        initial $fatal(1, "apb_spi: POLL_EN (%0d) must be 0 or 1.", POLL_EN);
    end
    if ((POLL_EN == 1) && (RX_EN == 0)) begin : CHECK_POLL_RX
        initial $fatal(1, "apb_spi: POLL_EN = 1 needs RX_EN = 1.");
    end
    if ((TX_FIFO_AW < 1) || (TX_FIFO_AW > 8)) begin : CHECK_TX_FIFO_AW
        initial $fatal(1, "apb_spi: TX_FIFO_AW (%0d) must be 1..8.", TX_FIFO_AW);
    end
    if ((RX_FIFO_AW < 1) || (RX_FIFO_AW > 8)) begin : CHECK_RX_FIFO_AW
        initial $fatal(1, "apb_spi: RX_FIFO_AW (%0d) must be 1..8.", RX_FIFO_AW);
    end
    if ((ADDRW < 7) || (ADDRW > 16)) begin : CHECK_ADDRW
        initial $fatal(1, "apb_spi: ADDRW (%0d) must be 7..16.", ADDRW);
    end
    if ((MDELEG_RST[1:0] == 2'b10) || (MDELEG_RST[3:2] == 2'b10) || (MDELEG_RST[7:4] != 4'h0)) begin : CHECK_MDELEG_RST
        initial $fatal(1, "apb_spi: MDELEG_RST (9'h%03h) holds a reserved privilege code or a reserved bit.", MDELEG_RST);
    end
    if ((ASYNC_RST_EN != 0) && (ASYNC_RST_EN != 1)) begin : CHECK_ASYNC_RST_EN
        initial $fatal(1, "apb_spi: ASYNC_RST_EN (%0d) must be 0 or 1.", ASYNC_RST_EN);
    end
endgenerate
// pragma translate_on

localparam              ARST_EN       =  (ASYNC_RST_EN != 0);
localparam              RX_USE        =  (RX_EN != 0);
localparam              POLL_USE      =  (POLL_EN != 0) && (RX_EN != 0);

// Decoder bit width (word address within the window)
localparam              DEC_WD        =  ADDRW-2;

// CFG register: build parameters
localparam        [3:0] CFG_VERSION   =  4'h1;
localparam        [3:0] CFG_TX_AW     =  TX_FIFO_AW[3:0];
localparam        [3:0] CFG_RX_AW     =  RX_USE ? RX_FIFO_AW[3:0] : 4'h0;
localparam        [2:0] CFG_CS        =  CS_NR[2:0] - 3'd1;
localparam        [1:0] CFG_LANES     =  (LANES_MAX == 4) ? 2'd2 : (LANES_MAX == 2) ? 2'd1 : 2'd0;
localparam              CFG_DBG       =  (DBG_PMASTER_MASK != 4'h0);
localparam       [31:0] CFG_VAL       =  {CFG_VERSION, 11'h000, CFG_DBG, POLL_USE, RX_USE, CFG_LANES, 1'b0, CFG_CS, CFG_RX_AW, CFG_TX_AW};

// Receive FIFO depth (in the 9-bit level domain)
localparam        [8:0] RX_DEPTH      =  9'd1 << RX_FIFO_AW;

// MDELEG register reset values, the fields of MDELEG_RST
localparam        [1:0] MDELEG_WR_PRIV_RST = MDELEG_RST[1:0];
localparam        [1:0] MDELEG_RD_PRIV_RST = MDELEG_RST[3:2];
localparam              MDELEG_RESP_RST    = MDELEG_RST[8];

// MDELEG priv-field reserved encoding (treated as "Machine-mode only")
localparam        [1:0] MDELEG_PRIV_RSVD   = 2'b10;

// CTRL: bits a build stores (RX_IO0, LOOPBACK, DBG_POP need the receive path)
localparam       [10:0] CTRL_MASK     =  RX_USE ? 11'h7FF : 11'h4BF;
localparam       [10:0] CTRL_RST      =  11'h010;

// IRQ_EN / IRQ_PEND: causes a build has (RX_HIGH, RX_UDF and POLL_TO need the receive path)
localparam        [6:0] IRQ_MASK      =  {POLL_USE, 1'b1, RX_USE, 1'b1, 1'b1, RX_USE, 1'b1};

// Register word offsets
localparam [DEC_WD-1:0] REG_CFG        = 'h00,
                        REG_CTRL       = 'h01,
                        REG_CTRL_SET   = 'h02,
                        REG_CTRL_CLR   = 'h03,
                        REG_CLKDIV     = 'h04,
                        REG_CSCFG      = 'h05,
                        REG_XFER       = 'h06,
                        REG_STATUS     = 'h07,
                        REG_THRESH     = 'h08,
                        REG_IRQ_EN     = 'h09,
                        REG_IRQ_EN_SET = 'h0A,
                        REG_IRQ_EN_CLR = 'h0B,
                        REG_IRQ_PEND   = 'h0C,
                        REG_TXDATA     = 'h0D,
                        REG_RXDATA     = 'h0E,
                        REG_CMD        = 'h0F,
                        REG_MDELEG     = 'h18;


//=============================================================================
// 2)  INTERNAL WIRES/REGISTERS/PARAMETERS DECLARATION
//=============================================================================

wire                    acc_valid;            // APB ACCESS phase
wire                    acc_write;            // APB write ACCESS phase
wire                    acc_read;             // APB read ACCESS phase
wire       [DEC_WD-1:0] acc_addr;             // register word address
wire                    acc_allowed;          // Access admitted by MDELEG
wire                    acc_dbg;              // Debugger access (PMASTER)
wire                    machine_mode;         // Machine mode detected
wire                    supervisor_mode;      // Supervisor mode detected
wire              [1:0] privilege_mode;       // Current privilege mode (11: Machine; 01: Supervisor; 00: User)
wire              [1:0] mdeleg_wr_priv;       // MDELEG.WR_PRIV
wire              [1:0] mdeleg_rd_priv;       // MDELEG.RD_PRIV
wire                    mdeleg_resp;          // MDELEG.RESP
wire             [31:0] mdeleg;               // MDELEG read value
wire                    reg_wr;               // Admitted write ACCESS phase
wire                    reg_rd;               // Admitted read ACCESS phase

// Registers (_n: the value after the current edge, which the engine sees)
wire             [10:0] ctrl;                 // CTRL
wire             [10:0] ctrl_n;
wire             [15:0] clkdiv;               // {RX_DLY, DIV}
wire             [15:0] clkdiv_n;
wire             [19:0] cscfg;                // {INACT, HOLD, SETUP, CSPOL}
wire             [19:0] cscfg_n;
wire             [15:0] xfer;                 // XFER ([7] stores 0)
wire              [8:0] thr_tx;               // THRESH.TX_THR
wire              [8:0] thr_rx;               // THRESH.RX_THR
wire              [6:0] irq_en;               // IRQ_EN
wire              [4:0] irq_sticky;           // IRQ_PEND[6:2]: DONE, TX_OVF, RX_UDF, XFER_ERR, POLL_TO (bit 0 = DONE)
wire              [6:0] irq_pend;             // IRQ_PEND read value

// Engine
wire                    e_valid;              // an entry is offered
wire                    e_valid_raw;          // the transmit FIFO holds an entry
wire             [47:0] e_head;               // {attributes, payload}
wire                    e_take;               // the engine takes it
wire                    core_busy;
wire                    core_cs;
wire                    core_stall;
wire                    core_quiet_n;         // after this edge: engine not busy, no select
wire                    poll_to;
wire                    rx_start;
wire                    rx_done;
wire                    rx_valid;
wire             [31:0] rx_word;
wire                    rx_room;              // a capturing frame may start

// Transmit path
wire              [8:0] tx_level;             // entries in the transmit FIFO
wire   [TX_FIFO_AW:0]   tx_lv;                // ... at the FIFO's width
wire                    tx_full;
wire                    tx_clr;               // flush or abort
wire                    tx_push;              // TXDATA write, accepted
wire                    tx_ovf;               // whole-word TXDATA write, FIFO full
wire                    xfer_err;             // whole-word TXDATA write, illegal XFER
wire                    irq_tx_low;           // IRQ_PEND.TX_LOW: transmit level <= TX_THR

// Receive path
wire             [31:0] rx_head;              // receive FIFO head word
wire              [8:0] rx_level;             // words in the receive FIFO
wire                    rx_udf;               // RXDATA read with the FIFO empty
wire                    irq_rx_high;          // IRQ_PEND.RX_HIGH: receive level >= RX_THR > 0

wire                    idle_now;             // STATUS.IDLE
wire                    idle_n;               // ... after this edge
wire             [31:0] rd_mux;               // read data before the ACCESS gating


//=============================================================================
// 3)  APB ACCESS PHASE DETECTION
//=============================================================================
// APB holds the address, control and write data stable from SETUP to the end
// of ACCESS: the transfer is decoded straight from the bus. Writes and FIFO
// pushes or pops take effect at the end of the ACCESS cycle.

assign acc_valid    =  psel_i & penable_i;
assign acc_write    =  acc_valid &  pwrite_i;
assign acc_read     =  acc_valid & ~pwrite_i;
assign acc_addr     =  paddr_i[ADDRW-1:2];
assign acc_dbg      =  |(pmaster_i & DBG_PMASTER_MASK);

assign reg_wr       =  acc_write & acc_allowed;
assign reg_rd       =  acc_read  & acc_allowed;

assign pready_o     =  1'b1;


//=============================================================================
// 4)  PRIVILEGE DECODE
//=============================================================================
// {pprot[0], psmode} = 1,0 -> Machine, 1,1 -> Supervisor, 0,x -> User.

assign machine_mode    =  pprot_i[0] & ~psmode_i;
assign supervisor_mode =  pprot_i[0] &  psmode_i;
assign privilege_mode  =  machine_mode     ? 2'b11 :
                          supervisor_mode  ? 2'b01 :
                                             2'b00 ;


//=============================================================================
// 5)  REGISTER DECODER
//=============================================================================
// The full word address is compared, so a window wider than the register map
// leaves every other offset unmapped (reads 0, writes ignored).

wire                sel_cfg      = (acc_addr == REG_CFG       );
wire                sel_ctrl     = (acc_addr == REG_CTRL      );
wire                sel_ctrl_set = (acc_addr == REG_CTRL_SET  );
wire                sel_ctrl_clr = (acc_addr == REG_CTRL_CLR  );
wire                sel_clkdiv   = (acc_addr == REG_CLKDIV    );
wire                sel_cscfg    = (acc_addr == REG_CSCFG     );
wire                sel_xfer     = (acc_addr == REG_XFER      );
wire                sel_status   = (acc_addr == REG_STATUS    );
wire                sel_thresh   = (acc_addr == REG_THRESH    );
wire                sel_irq_en   = (acc_addr == REG_IRQ_EN    );
wire                sel_irq_set  = (acc_addr == REG_IRQ_EN_SET);
wire                sel_irq_clr  = (acc_addr == REG_IRQ_EN_CLR);
wire                sel_irq_pend = (acc_addr == REG_IRQ_PEND  );
wire                sel_txdata   = (acc_addr == REG_TXDATA    );
wire                sel_rxdata   = (acc_addr == REG_RXDATA    );
wire                sel_cmd      = (acc_addr == REG_CMD       );
wire                sel_mdeleg   = (acc_addr == REG_MDELEG    );

// Byte-lane write enables of the RW registers, and their bit masks
wire          [3:0] wr_lane      = pstrb_i & {4{reg_wr}};
wire         [31:0] wr_bits      = {{8{wr_lane[3]}}, {8{wr_lane[2]}}, {8{wr_lane[1]}}, {8{wr_lane[0]}}};


//=============================================================================
// 6)  MDELEG REGISTER AND ERROR RESPONSE
//=============================================================================
// WR_PRIV[1:0] / RD_PRIV[3:2]: minimum privilege for writes / reads at any
// other offset; RESP[8]: 1 = PSLVERR on a refused access, 0 = silent drop.
// A reserved privilege code written stores Machine (2'b11). PSTRB[0] updates
// both privilege fields, PSTRB[1] updates RESP.
// MDELEG itself is Machine-mode only, whatever the gates say.

wire                mdeleg_priv_wr       = acc_write & sel_mdeleg & pstrb_i[0] & machine_mode;
wire                mdeleg_resp_wr       = acc_write & sel_mdeleg & pstrb_i[1] & machine_mode;

wire          [1:0] mdeleg_wr_priv_wdata = (pwdata_i[1:0] == MDELEG_PRIV_RSVD) ? 2'b11 : pwdata_i[1:0];
wire          [1:0] mdeleg_rd_priv_wdata = (pwdata_i[3:2] == MDELEG_PRIV_RSVD) ? 2'b11 : pwdata_i[3:2];

arv_ipdff #(.WIDTH(2), .RST_VAL(MDELEG_WR_PRIV_RST), .ARST_EN(ARST_EN)) u_mdeleg_wr_priv (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(mdeleg_priv_wr), .d_i(mdeleg_wr_priv_wdata), .q_o(mdeleg_wr_priv));

arv_ipdff #(.WIDTH(2), .RST_VAL(MDELEG_RD_PRIV_RST), .ARST_EN(ARST_EN)) u_mdeleg_rd_priv (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(mdeleg_priv_wr), .d_i(mdeleg_rd_priv_wdata), .q_o(mdeleg_rd_priv));

arv_ipdff #(.WIDTH(1), .RST_VAL(MDELEG_RESP_RST), .ARST_EN(ARST_EN)) u_mdeleg_resp (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(mdeleg_resp_wr), .d_i(pwdata_i[8]), .q_o(mdeleg_resp));

assign mdeleg       =  {23'h000000, mdeleg_resp, 4'h0, mdeleg_rd_priv, mdeleg_wr_priv};

wire                wr_allowed   = sel_mdeleg ? machine_mode : (privilege_mode >= mdeleg_wr_priv);
wire                rd_allowed   = sel_mdeleg ? machine_mode : (privilege_mode >= mdeleg_rd_priv);

assign acc_allowed  =  pwrite_i ? wr_allowed : rd_allowed;

assign pslverr_o    =  acc_valid & mdeleg_resp & ~acc_allowed;


//=============================================================================
// 7)  CONTROL REGISTERS
//=============================================================================
// Each register's next value is computed here. The engine takes the next
// value of the idle levels (CPOL, CSPOL, TX_IDLE, IO23_REL), so an idle output
// follows a write on the edge that ends its ACCESS cycle; everything it
// latches at a transaction or frame start it takes from the registers.

// CTRL: EN[0], CPOL[1], CPHA[2], LSB_FIRST[3], TX_IDLE[5:4], RX_IO0[6],
// IO23_REL[7], LOOPBACK[8], DBG_POP[9], BSWAP[10]; CTRL_SET / CTRL_CLR
// change the bits written 1
wire         [10:0] ctrl_wm      = wr_bits[10:0] & CTRL_MASK;
wire         [10:0] ctrl_wd      = pwdata_i[10:0];

assign ctrl_n       =  sel_ctrl     ? ((ctrl & ~ctrl_wm) | (ctrl_wd & ctrl_wm)) :
                       sel_ctrl_set ? (ctrl |  (ctrl_wd & ctrl_wm)) :
                       sel_ctrl_clr ? (ctrl & ~(ctrl_wd & ctrl_wm)) :
                                      ctrl;

arv_ipdff #(.WIDTH(11), .RST_VAL(CTRL_RST), .ARST_EN(ARST_EN)) u_ctrl (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(|wr_lane[1:0] & (sel_ctrl | sel_ctrl_set | sel_ctrl_clr)),
    .d_i(ctrl_n), .q_o(ctrl));

wire                ctrl_en      = ctrl[0];
wire                ctrl_dbg_pop = ctrl[9];

// CLKDIV: DIV [11:0], RX_DLY [19:16]
wire         [15:0] clkdiv_wm    = {wr_bits[19:16] & {4{RX_USE}}, wr_bits[11:0]} & {16{sel_clkdiv}};

assign clkdiv_n     =  (clkdiv & ~clkdiv_wm) | ({pwdata_i[19:16], pwdata_i[11:0]} & clkdiv_wm);

arv_ipdff #(.WIDTH(16), .ARST_EN(ARST_EN)) u_clkdiv (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(|wr_lane[2:0] & sel_clkdiv), .d_i(clkdiv_n), .q_o(clkdiv));

// CSCFG: CSPOL [7:0], SETUP-1 [11:8], HOLD-1 [15:12], INACT-1 [19:16]
wire         [19:0] cscfg_wm     = wr_bits[19:0] & {20{sel_cscfg}};

assign cscfg_n      =  (cscfg & ~cscfg_wm) | (pwdata_i[19:0] & cscfg_wm);

arv_ipdff #(.WIDTH(20), .ARST_EN(ARST_EN)) u_cscfg (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(|wr_lane[2:0] & sel_cscfg), .d_i(cscfg_n), .q_o(cscfg));

// XFER: attributes of the next pushed entry ([7] stores 0)
wire         [15:0] xfer_wm      = wr_bits[15:0] & 16'hFF7F & {16{sel_xfer}};
wire         [15:0] xfer_n       = (xfer & ~xfer_wm) | (pwdata_i[15:0] & xfer_wm);

arv_ipdff #(.WIDTH(16), .ARST_EN(ARST_EN)) u_xfer (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(|wr_lane[1:0] & sel_xfer), .d_i(xfer_n), .q_o(xfer));

// THRESH: TX_THR [8:0], RX_THR [24:16]
wire          [8:0] thr_tx_nxt   = {wr_lane[1] ? pwdata_i[8]  : thr_tx[8], wr_lane[0] ? pwdata_i[7:0]   : thr_tx[7:0]};
wire          [8:0] thr_rx_nxt   = {wr_lane[3] ? pwdata_i[24] : thr_rx[8], wr_lane[2] ? pwdata_i[23:16] : thr_rx[7:0]} & {9{RX_USE}};

arv_ipdff #(.WIDTH(9), .ARST_EN(ARST_EN)) u_thr_tx (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(|wr_lane[1:0] & sel_thresh), .d_i(thr_tx_nxt), .q_o(thr_tx));

arv_ipdff #(.WIDTH(9), .ARST_EN(ARST_EN)) u_thr_rx (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(|wr_lane[3:2] & sel_thresh), .d_i(thr_rx_nxt), .q_o(thr_rx));

// IRQ_EN: one bit per IRQ_PEND bit; IRQ_EN_SET / IRQ_EN_CLR change the bits written 1
wire          [6:0] irq_wm       = wr_bits[6:0] & IRQ_MASK;
wire          [6:0] irq_en_nxt   = sel_irq_en  ? ((irq_en & ~irq_wm) | (pwdata_i[6:0] & irq_wm)) :
                                   sel_irq_set ? (irq_en |  (pwdata_i[6:0] & irq_wm)) :
                                                 (irq_en & ~(pwdata_i[6:0] & irq_wm));

arv_ipdff #(.WIDTH(7), .ARST_EN(ARST_EN)) u_irq_en (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(wr_lane[0] & (sel_irq_en | sel_irq_set | sel_irq_clr)),
    .d_i(irq_en_nxt), .q_o(irq_en));

// Commands (CMD, write 1)
wire                tx_flush     = wr_lane[0] & sel_cmd & pwdata_i[0];
wire                rx_flush     = wr_lane[0] & sel_cmd & pwdata_i[1];
wire                abort        = wr_lane[0] & sel_cmd & pwdata_i[2];



//=============================================================================
// 8)  SHIFT ENGINE
//=============================================================================

apb_spi_core #(
    .LANES_MAX    ( LANES_MAX    ),
    .CS_NR        ( CS_NR        ),
    .RX_EN        ( RX_USE       ),
    .POLL_EN      ( POLL_USE     ),
    .ASYNC_RST_EN ( ASYNC_RST_EN )
) u_core (
    .clk_i        ( pclk_i               ),
    .rst_n_i      ( presetn_i            ),
    .div_i        ( clkdiv[11:0]         ),
    .rx_dly_i     ( clkdiv[15:12]        ),
    .cpol_i       ( ctrl_n[1]            ),
    .cpha_i       ( ctrl[2]              ),
    .lsb_first_i  ( ctrl[3]              ),
    .bswap_i      ( ctrl[10]             ),
    .cs_pol_i     ( cscfg_n[CS_NR-1:0]   ),
    .cs_setup_i   ( cscfg[11:8]          ),
    .cs_hold_i    ( cscfg[15:12]         ),
    .cs_inact_i   ( cscfg[19:16]         ),
    .tx_idle_i    ( ctrl_n[5:4]          ),
    .io23_rel_i   ( ctrl_n[7]            ),
    .rx_io0_i     ( ctrl[6]              ),
    .loopback_i   ( ctrl[8]              ),
    .e_valid_i    ( e_valid              ),
    .e_present_i  ( e_valid_raw          ),
    .e_attr_i     ( e_head[47:32]        ),
    .e_data_i     ( e_head[31:0]         ),
    .e_take_o     ( e_take               ),
    .e_abort_i    ( abort                ),
    .run_i        ( ctrl_en              ),
    .rx_room_i    ( rx_room              ),
    .busy_o       ( core_busy            ),
    .cs_active_o  ( core_cs              ),
    .stall_o      ( core_stall           ),
    .quiet_nxt_o  ( core_quiet_n         ),
    .poll_to_o    ( poll_to              ),
    .rx_start_o   ( rx_start             ),
    .rx_done_o    ( rx_done              ),
    .rx_valid_o   ( rx_valid             ),
    .rx_data_o    ( rx_word              ),
    .spi_sck_o    ( spi_sck_o            ),
    .spi_cs_o     ( spi_cs_o             ),
    .spi_io_o     ( spi_io_o             ),
    .spi_io_oe_o  ( spi_io_oe_o          ),
    .spi_io_i     ( spi_io_i             )
);


//=============================================================================
// 9)  TRANSMIT PATH
//=============================================================================
// TXDATA takes whole words only (PSTRB = 4'hF; a sparse write pushes nothing
// and sets no flag). An entry with an illegal XFER is refused (XFER_ERR); a
// legal one finding the FIFO full is dropped (TX_OVF).

// XFER legality: lane code 3 or beyond LANES_MAX; frame length not a multiple
// of the lane count; select beyond CS_NR; receiving kinds without RX_EN;
// POLL without POLL_EN
wire          [1:0] x_lanes      = xfer[6:5];
wire          [1:0] x_kind       = xfer[9:8];
wire          [2:0] x_sel        = xfer[15:13];
wire                x_bad        = (x_lanes == 2'b11) |
                                   ((LANES_MAX == 1) & (x_lanes != 2'b00)) |
                                   ((LANES_MAX == 2) & (x_lanes == 2'b10)) |
                                   ((x_lanes == 2'b01) & ~xfer[0]) |
                                   ((x_lanes == 2'b10) & (xfer[1:0] != 2'b11)) |
                                   (~xfer[12] & ({1'b0, x_sel} >= CS_NR[3:0])) |
                                   (~RX_USE & ((x_kind == 2'b01) | (x_kind == 2'b11) | xfer[10])) |
                                   (~POLL_USE & (x_kind == 2'b11));
wire          [1:0] x_kind_unused = x_kind;              // folded away in builds with both receive and POLL
wire          [2:0] x_sel_unused  = x_sel;               // folded away with CS_NR = 8
generate
    if (!POLL_USE) begin : g_no_poll_to
        wire poll_to_unused = poll_to;
    end
endgenerate

wire                tx_word_wr   = reg_wr & sel_txdata & (&pstrb_i);

assign tx_push      =  tx_word_wr & ~x_bad & ~tx_full;
assign tx_ovf       =  tx_word_wr & ~x_bad &  tx_full;
assign xfer_err     =  tx_word_wr &  x_bad;
assign tx_clr       =  tx_flush | abort;
assign e_valid      =  e_valid_raw & ~tx_clr;

apb_spi_fifo #(.AW(TX_FIFO_AW), .W(48), .ASYNC_RST_EN(ASYNC_RST_EN)) u_tx_fifo (
    .clk_i   ( pclk_i            ),
    .rst_n_i ( presetn_i         ),
    .clr_i   ( tx_clr            ),
    .push_i  ( tx_push           ),
    .din_i   ( {xfer, pwdata_i}  ),
    .pop_i   ( e_take            ),
    .head_o  ( e_head            ),
    .valid_o ( e_valid_raw       ),
    .full_o  ( tx_full           ),
    .level_o ( tx_lv             )
);

generate
    if (TX_FIFO_AW == 8) begin : g_tx_lv_full
        assign tx_level = tx_lv;
    end else begin : g_tx_lv_pad
        assign tx_level = {{(8-TX_FIFO_AW){1'b0}}, tx_lv};
    end
endgenerate

assign irq_tx_low   =  (tx_level <= thr_tx);


//=============================================================================
// 10) RECEIVE PATH
//=============================================================================
// The engine pushes only into room it has reserved: a capturing frame starts
// only while level + frames in flight < depth. A read pops the head; a
// debugger read only peeks unless DBG_POP is set.

generate
    if (RX_USE) begin : g_rx

        wire [RX_FIFO_AW:0] level;
        wire                rx_full;
        wire                rx_valid_h;           // receive FIFO head holds a word
        wire                rx_pop;               // RXDATA read pops
        wire                rx_push    = rx_valid & ~rx_full;
        wire          [8:0] inflight;             // capturing frames started, capture not completed
        wire          [8:0] inflight_n = inflight + {8'h00, rx_start} - {8'h00, rx_done};

        arv_ipdff #(.WIDTH(9), .ARST_EN(ARST_EN)) u_inflight (
            .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(rx_start | rx_done), .d_i(inflight_n), .q_o(inflight));

        assign rx_pop  = reg_rd & sel_rxdata &  rx_valid_h & (~acc_dbg | ctrl_dbg_pop);
        assign rx_udf  = reg_rd & sel_rxdata & ~rx_valid_h & (~acc_dbg | ctrl_dbg_pop);
        assign rx_room = ({1'b0, rx_level} + {1'b0, inflight}) < {1'b0, RX_DEPTH};

        apb_spi_fifo #(.AW(RX_FIFO_AW), .W(32), .ASYNC_RST_EN(ASYNC_RST_EN)) u_fifo (
            .clk_i   ( pclk_i               ),
            .rst_n_i ( presetn_i            ),
            .clr_i   ( rx_flush             ),
            .push_i  ( rx_push              ),
            .din_i   ( rx_word              ),
            .pop_i   ( rx_pop               ),
            .head_o  ( rx_head              ),
            .valid_o ( rx_valid_h           ),
            .full_o  ( rx_full              ),
            .level_o ( level                )
        );

        if (RX_FIFO_AW == 8) begin : g_lv_full
            assign rx_level = level;
        end else begin : g_lv_pad
            assign rx_level = {{(8-RX_FIFO_AW){1'b0}}, level};
        end
        assign irq_rx_high = (rx_level >= thr_rx) & (thr_rx != 9'h000);

    end else begin : g_no_rx

        assign rx_udf      = 1'b0;
        assign rx_head     = 32'h0;
        assign rx_level    = 9'h000;
        assign rx_room     = 1'b0;
        assign irq_rx_high = 1'b0;
        wire        rx_flush_unused = rx_flush;
        wire        rx_ev_unused    = rx_start | rx_done | rx_valid;
        wire [31:0] rx_word_unused  = rx_word;
        wire        rx_dbg_unused   = acc_dbg | ctrl_dbg_pop | sel_rxdata;
        wire        rx_ev2_unused   = core_stall | poll_to | rx_udf;

    end
endgenerate


//=============================================================================
// 11) STATUS AND INTERRUPTS
//=============================================================================
// IDLE: engine not busy, no select asserted, transmit FIFO empty. DONE is set
// on the edge on which IDLE rises.

wire                tx_empty_n   = tx_clr |
                                   ((tx_level == 9'h000) & ~tx_push) |
                                   ((tx_level == 9'h001) & e_take & ~tx_push);

assign idle_now     =  ~core_busy & ~core_cs & (tx_level == 9'h000);
assign idle_n       =  core_quiet_n & tx_empty_n;

// IRQ_PEND: TX_LOW[0] and RX_HIGH[1] are live levels; DONE[2], TX_OVF[3],
// RX_UDF[4], XFER_ERR[5] and POLL_TO[6] are sticky, cleared by writing 1 (an
// event in the same cycle wins).
wire          [4:0] irq_set      = {poll_to, xfer_err, rx_udf, tx_ovf, idle_n & ~idle_now} & IRQ_MASK[6:2];
wire          [4:0] irq_w1c      = pwdata_i[6:2] & {5{wr_lane[0] & sel_irq_pend}};
wire          [4:0] irq_sticky_n = irq_set | (irq_sticky & ~irq_w1c);

arv_ipdff #(.WIDTH(5), .ARST_EN(ARST_EN)) u_irq_sticky (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(|irq_set | |irq_w1c), .d_i(irq_sticky_n), .q_o(irq_sticky));

assign irq_pend     =  {irq_sticky, irq_rx_high, irq_tx_low};
assign irq_o        =  |(irq_pend & irq_en);


//=============================================================================
// 12) READ MUX AND CLOCK REQUEST
//=============================================================================

wire         [31:0] status       = {core_busy, idle_now, core_stall & RX_USE, core_cs, 3'h0, rx_level, 7'h00, tx_level};

assign rd_mux       =  ({32{sel_cfg     }} & CFG_VAL                                             ) |
                       ({32{sel_ctrl    }} & {21'h000000, ctrl}                                  ) |
                       ({32{sel_clkdiv  }} & {12'h000, clkdiv[15:12], 4'h0, clkdiv[11:0]}        ) |
                       ({32{sel_cscfg   }} & {12'h000, cscfg}                                    ) |
                       ({32{sel_xfer    }} & {16'h0000, xfer}                                    ) |
                       ({32{sel_status  }} & status                                              ) |
                       ({32{sel_thresh  }} & {7'h00, thr_rx, 7'h00, thr_tx}                      ) |
                       ({32{sel_irq_en  }} & {25'h0000000, irq_en}                               ) |
                       ({32{sel_irq_pend}} & {25'h0000000, irq_pend}                             ) |
                       ({32{sel_rxdata  }} & rx_head                                             ) |
                       ({32{sel_mdeleg  }} & mdeleg                                              );

assign prdata_o     =  rd_mux & {32{reg_rd}};

// The engine keeps its clock while it has work; an entry waiting at the head
// requests it too (receive room, inactive time)
assign pclk_en_o    =  psel_i | core_busy | (e_valid_raw & ctrl_en);

wire          [1:0] pprot_unused   = pprot_i[2:1];
wire          [1:0] paddr_unused   = paddr_i[1:0];
wire          [3:0] pmaster_unused = pmaster_i & ~DBG_PMASTER_MASK;
wire         [11:0] wr_bits_unused = wr_bits[31:20];

endmodule // apb_spi

`default_nettype wire
