//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    apb_i2s
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : apb_i2s.v
// Module Description : APB4 serial-audio master (I2S, left- and right-
//                      justified, DSP / PCM), clock master of the link:
//                        + MCLK, BCLK and LRCK from pclk_i by integer division
//                          (apb_i2s_core), format chosen by software (FORMAT)
//                        + transmit and receive flip-flop FIFOs of 32-bit
//                          words: one stereo frame ({right, left}) or two
//                          mono samples per word
//                        + FIFO levels, software thresholds, sticky under-
//                          and overrun flags, one interrupt line
//                        + debugger-aware RXDATA reads (pmaster_i)
//                        + MDELEG privilege gate (minimum write and read
//                          privilege, PSLVERR or silent drop), reset value
//                          MDELEG_RST
//
// REGISTER MAP (word offsets of the 1<<ADDRW byte window):
//   0x00 INFO      RO     0x10 THRESH    RW     0x20 RXDATA    RO (pops)
//   0x04 CTRL      RW     0x14 IRQ_EN    RW     0x24 CMD       WO
//   0x08 CLKDIV    RW     0x18 IRQ_PEND  RO/W1C 0x28 FORMAT    RW
//   0x0C STATUS    RO     0x1C TXDATA    WO     0x40 MDELEG    RW (M-mode only)
//----------------------------------------------------------------------------
`default_nettype none

module  apb_i2s #(
    parameter                 TX_EN            = 1,       // transmit path present
    parameter                 RX_EN            = 1,       // receive path present
    parameter                 TX_FIFO_AW       = 5,       // transmit FIFO depth = 1 << TX_FIFO_AW words (1..8)
    parameter                 RX_FIFO_AW       = 5,       // receive FIFO depth = 1 << RX_FIFO_AW words (1..8)
    parameter                 ADDRW            = 7,       // APB address width (window = 1<<ADDRW bytes, 7..16)
    parameter           [8:0] MDELEG_RST       = 9'h10F,  // MDELEG[8:0] reset value (default: M-mode only, PSLVERR)
    parameter           [3:0] DBG_PMASTER_MASK = 4'b1000, // PMASTER bits identifying a debugger access
    parameter                 ASYNC_RST_EN     = 1        // Reset style: 1=async active-low reset, 0=synchronous reset
) (

// APB CLOCK & RESET
    input  wire               pclk_i,                    // bus clock and audio timebase (gated by pclk_en_o at the SoC-level ICG)
    input  wire               presetn_i,                 // active-low reset, style per ASYNC_RST_EN
    output wire               pclk_en_o,                 // clock request: a transfer, CTRL.EN or the engine running

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

// SERIAL AUDIO
    output wire               i2s_mclk_o,                // master clock
    output wire               i2s_bclk_o,                // bit clock
    output wire               i2s_lrck_o,                // word clock / frame sync
    output wire               i2s_sd_o,                  // serial data out
    input  wire               i2s_sd_i,                  // serial data in (synchronised inside)

// INTERRUPT
    output wire               irq_o                      // OR of IRQ_PEND & IRQ_EN
 );


//=============================================================================
// 1)  PARAMETER DECLARATION
//=============================================================================

// pragma translate_off
generate
    if ((TX_EN != 0) && (TX_EN != 1)) begin : CHECK_TX_EN
        initial $fatal(1, "apb_i2s: TX_EN (%0d) must be 0 or 1.", TX_EN);
    end
    if ((RX_EN != 0) && (RX_EN != 1)) begin : CHECK_RX_EN
        initial $fatal(1, "apb_i2s: RX_EN (%0d) must be 0 or 1.", RX_EN);
    end
    if ((TX_EN == 0) && (RX_EN == 0)) begin : CHECK_PATHS
        initial $fatal(1, "apb_i2s: TX_EN and RX_EN cannot both be 0.");
    end
    if ((TX_FIFO_AW < 1) || (TX_FIFO_AW > 8)) begin : CHECK_TX_FIFO_AW
        initial $fatal(1, "apb_i2s: TX_FIFO_AW (%0d) must be 1..8.", TX_FIFO_AW);
    end
    if ((RX_FIFO_AW < 1) || (RX_FIFO_AW > 8)) begin : CHECK_RX_FIFO_AW
        initial $fatal(1, "apb_i2s: RX_FIFO_AW (%0d) must be 1..8.", RX_FIFO_AW);
    end
    if ((ADDRW < 7) || (ADDRW > 16)) begin : CHECK_ADDRW
        initial $fatal(1, "apb_i2s: ADDRW (%0d) must be 7..16.", ADDRW);
    end
    if ((MDELEG_RST[1:0] == 2'b10) || (MDELEG_RST[3:2] == 2'b10) || (MDELEG_RST[7:4] != 4'h0)) begin : CHECK_MDELEG_RST
        initial $fatal(1, "apb_i2s: MDELEG_RST (9'h%03h) holds a reserved privilege code or a reserved bit.", MDELEG_RST);
    end
    if ((ASYNC_RST_EN != 0) && (ASYNC_RST_EN != 1)) begin : CHECK_ASYNC_RST_EN
        initial $fatal(1, "apb_i2s: ASYNC_RST_EN (%0d) must be 0 or 1.", ASYNC_RST_EN);
    end
endgenerate
// pragma translate_on

localparam              ARST_EN       =  (ASYNC_RST_EN != 0);
localparam              TX_USE        =  (TX_EN != 0);
localparam              RX_USE        =  (RX_EN != 0);

// Decoder bit width (word address within the window)
localparam              DEC_WD        =  ADDRW-2;

// INFO register: build parameters
localparam        [3:0] INFO_VERSION  =  4'h1;
localparam        [3:0] INFO_TX_AW    =  TX_USE ? TX_FIFO_AW[3:0] : 4'h0;
localparam        [3:0] INFO_RX_AW    =  RX_USE ? RX_FIFO_AW[3:0] : 4'h0;
localparam              INFO_DBG      =  (DBG_PMASTER_MASK != 4'h0);
localparam       [31:0] INFO_VAL      =  {INFO_VERSION, 17'h00000, INFO_DBG, RX_USE, TX_USE, INFO_RX_AW, INFO_TX_AW};

// MDELEG register reset values, the fields of MDELEG_RST
localparam        [1:0] MDELEG_WR_PRIV_RST = MDELEG_RST[1:0];
localparam        [1:0] MDELEG_RD_PRIV_RST = MDELEG_RST[3:2];
localparam              MDELEG_RESP_RST    = MDELEG_RST[8];

// MDELEG priv-field reserved encoding (treated as "Machine-mode only")
localparam        [1:0] MDELEG_PRIV_RSVD   = 2'b10;

// FORMAT reset value: I2S (DELAY = 1)
localparam        [5:0] FORMAT_RST    =  6'b000010;

// Register word offsets
localparam [DEC_WD-1:0] REG_INFO      = 'h00,
                        REG_CTRL      = 'h01,
                        REG_CLKDIV    = 'h02,
                        REG_STATUS    = 'h03,
                        REG_THRESH    = 'h04,
                        REG_IRQ_EN    = 'h05,
                        REG_IRQ_PEND  = 'h06,
                        REG_TXDATA    = 'h07,
                        REG_RXDATA    = 'h08,
                        REG_CMD       = 'h09,
                        REG_FORMAT    = 'h0A,
                        REG_MDELEG    = 'h10;


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

// Registers
wire                    ctrl_en;              // CTRL.EN
wire                    ctrl_tx_on;           // CTRL.TX_ON
wire                    ctrl_rx_on;           // CTRL.RX_ON
wire                    ctrl_mclk_en;         // CTRL.MCLK_EN
wire                    ctrl_tx_mono;         // CTRL.TX_MONO
wire                    ctrl_rx_mono;         // CTRL.RX_MONO
wire              [1:0] ctrl_rx_sel;          // CTRL.RX_MONO_SEL
wire                    ctrl_loop;            // CTRL.LOOPBACK
wire                    ctrl_dbg_pop;         // CTRL.DBG_POP
wire             [31:0] ctrl;                 // CTRL read value
wire              [7:0] clk_mdiv;             // CLKDIV.MDIV - 1
wire              [2:0] clk_ratio;            // CLKDIV.RATIO
wire              [3:0] clk_rx_dly;           // CLKDIV.RX_DLY
wire                    running;              // the engine runs (STATUS.RUNNING)
wire                    tx_active;            // STATUS.TX_ACTIVE
wire                    rx_active;            // STATUS.RX_ACTIVE
wire                    cfg_lock;             // CLKDIV / FORMAT / LOOPBACK writes ignored
wire                    xfer_q;               // a transfer ended on the last edge
wire              [5:0] fmt;                  // FORMAT: {SLOT16, FSYNC, LRCK_INV, RJUST, DELAY, BCLK_INV}
wire              [8:0] thr_tx;               // THRESH.TX_THR
wire              [8:0] thr_rx;               // THRESH.RX_THR
wire              [5:0] irq_en;               // IRQ_EN
wire              [3:0] irq_sticky;           // IRQ_PEND[5:2]: TX_UNDER, RX_OVER, TX_OVF, RX_UDF (bit 0 = TX_UNDER)
wire              [3:0] irq_sticky_nxt;
wire              [8:0] thr_tx_nxt;
wire              [8:0] thr_rx_nxt;
wire              [5:0] irq_pend;             // IRQ_PEND read value

// Transmit path
wire                    tx_valid;             // ... holds a word
wire              [8:0] tx_level;             // words in the transmit FIFO
wire             [31:0] tx_frame;             // {right, left} offered to the core
wire                    tx_take;              // the core takes tx_frame
wire                    tx_under;             // the core sent a frame of zeros while transmitting
wire                    tx_ovf;               // TXDATA write with the FIFO full
wire                    irq_tx_low;           // IRQ_PEND.TX_LOW: transmit level <= TX_THR

// Receive path
wire             [31:0] rx_head;              // receive FIFO head word
wire              [8:0] rx_level;             // words in the receive FIFO
wire                    rx_frame_v;           // the core delivers a frame
wire             [31:0] rx_frame;             // {right, left}
wire                    rx_over;              // ... dropped, FIFO full
wire                    rx_udf;               // RXDATA read with the FIFO empty
wire                    irq_rx_high;          // IRQ_PEND.RX_HIGH: receive level >= RX_THR > 0

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

wire                sel_info     = (acc_addr == REG_INFO    );
wire                sel_ctrl     = (acc_addr == REG_CTRL    );
wire                sel_clkdiv   = (acc_addr == REG_CLKDIV  );
wire                sel_status   = (acc_addr == REG_STATUS  );
wire                sel_thresh   = (acc_addr == REG_THRESH  );
wire                sel_irq_en   = (acc_addr == REG_IRQ_EN  );
wire                sel_irq_pend = (acc_addr == REG_IRQ_PEND);
wire                sel_txdata   = (acc_addr == REG_TXDATA  );
wire                sel_rxdata   = (acc_addr == REG_RXDATA  );
wire                sel_cmd      = (acc_addr == REG_CMD     );
wire                sel_format   = (acc_addr == REG_FORMAT  );
wire                sel_mdeleg   = (acc_addr == REG_MDELEG  );

// Byte-lane write enables of the RW registers
wire          [3:0] wr_lane      = pstrb_i & {4{reg_wr}};


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
// CTRL: EN[0], TX_ON[1], RX_ON[2], MCLK_EN[3], TX_MONO[5], RX_MONO[6],
// RX_MONO_SEL[9:8], LOOPBACK[12], DBG_POP[13]. CLKDIV, FORMAT and LOOPBACK change only
// while the engine is stopped (EN and RUNNING 0), TX_MONO only while TX_ON
// is 0, RX_MONO and RX_MONO_SEL only while RX_ON is 0 (the values before the
// write).

assign cfg_lock     =  ctrl_en | running;

wire                wr_ctrl0     = wr_lane[0] & sel_ctrl;
wire                wr_ctrl1     = wr_lane[1] & sel_ctrl;

arv_ipdff #(.WIDTH(3), .ARST_EN(ARST_EN)) u_ctrl_on (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(wr_ctrl0),
    .d_i({pwdata_i[2] & RX_USE, pwdata_i[1] & TX_USE, pwdata_i[0]}), .q_o({ctrl_rx_on, ctrl_tx_on, ctrl_en}));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_ctrl_mclk (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(wr_ctrl0), .d_i(pwdata_i[3]), .q_o(ctrl_mclk_en));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_ctrl_tx_mono (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(wr_ctrl0 & ~ctrl_tx_on), .d_i(pwdata_i[5] & TX_USE), .q_o(ctrl_tx_mono));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_ctrl_rx_mono (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(wr_ctrl0 & ~ctrl_rx_on), .d_i(pwdata_i[6] & RX_USE), .q_o(ctrl_rx_mono));

arv_ipdff #(.WIDTH(2), .ARST_EN(ARST_EN)) u_ctrl_rx_sel (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(wr_ctrl1 & ~ctrl_rx_on),
    .d_i((pwdata_i[9:8] == 2'b11) ? 2'b00 : (pwdata_i[9:8] & {2{RX_USE}})), .q_o(ctrl_rx_sel));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_ctrl_dbg_pop (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(wr_ctrl1), .d_i(pwdata_i[13] & RX_USE), .q_o(ctrl_dbg_pop));

arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_ctrl_loop (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(wr_ctrl1 & ~cfg_lock), .d_i(pwdata_i[12] & TX_USE & RX_USE), .q_o(ctrl_loop));

assign ctrl         =  {18'h00000, ctrl_dbg_pop, ctrl_loop, 2'b00, ctrl_rx_sel,
                        1'b0, ctrl_rx_mono, ctrl_tx_mono, 1'b0, ctrl_mclk_en, ctrl_rx_on, ctrl_tx_on, ctrl_en};

// CLKDIV: MDIV-1 [7:0], RATIO [10:8] (5..7 store 0), RX_DLY [15:12]
arv_ipdff #(.WIDTH(8), .ARST_EN(ARST_EN)) u_clk_mdiv (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(wr_lane[0] & sel_clkdiv & ~cfg_lock), .d_i(pwdata_i[7:0]), .q_o(clk_mdiv));

arv_ipdff #(.WIDTH(7), .ARST_EN(ARST_EN)) u_clk_ratio (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(wr_lane[1] & sel_clkdiv & ~cfg_lock),
    .d_i({pwdata_i[15:12] & {4{RX_USE}}, (pwdata_i[10:8] > 3'd4) ? 3'd0 : pwdata_i[10:8]}), .q_o({clk_rx_dly, clk_ratio}));

// FORMAT: BCLK_INV[0], DELAY[1], RJUST[2], LRCK_INV[3], FSYNC[4], SLOT16[5]
arv_ipdff #(.WIDTH(6), .RST_VAL(FORMAT_RST), .ARST_EN(ARST_EN)) u_fmt (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(wr_lane[0] & sel_format & ~cfg_lock), .d_i(pwdata_i[5:0]), .q_o(fmt));

// THRESH: TX_THR [8:0], RX_THR [24:16]
assign thr_tx_nxt   =  {wr_lane[1] ? pwdata_i[8]  : thr_tx[8], wr_lane[0] ? pwdata_i[7:0]   : thr_tx[7:0]} & {9{TX_USE}};
assign thr_rx_nxt   =  {wr_lane[3] ? pwdata_i[24] : thr_rx[8], wr_lane[2] ? pwdata_i[23:16] : thr_rx[7:0]} & {9{RX_USE}};

arv_ipdff #(.WIDTH(9), .ARST_EN(ARST_EN)) u_thr_tx (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(|wr_lane[1:0] & sel_thresh), .d_i(thr_tx_nxt), .q_o(thr_tx));

arv_ipdff #(.WIDTH(9), .ARST_EN(ARST_EN)) u_thr_rx (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(|wr_lane[3:2] & sel_thresh), .d_i(thr_rx_nxt), .q_o(thr_rx));

// IRQ_EN: one bit per IRQ_PEND bit
arv_ipdff #(.WIDTH(6), .ARST_EN(ARST_EN)) u_irq_en (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(wr_lane[0] & sel_irq_en),
    .d_i(pwdata_i[5:0] & {RX_USE, TX_USE, RX_USE, TX_USE, RX_USE, TX_USE}), .q_o(irq_en));

// Flushes (CMD, write 1)
wire                tx_flush     = wr_lane[0] & sel_cmd & pwdata_i[0];
wire                rx_flush     = wr_lane[0] & sel_cmd & pwdata_i[1];


//=============================================================================
// 8)  SHIFT ENGINE
//=============================================================================

apb_i2s_core #(.TX_EN(TX_USE), .RX_EN(RX_USE), .ASYNC_RST_EN(ASYNC_RST_EN)) u_core (
    .clk_i       ( pclk_i            ),
    .rst_n_i     ( presetn_i         ),
    .run_i       ( ctrl_en           ),
    .mclk_en_i   ( ctrl_mclk_en      ),
    .mdiv_i      ( clk_mdiv          ),
    .ratio_i     ( clk_ratio         ),
    .rx_dly_i    ( clk_rx_dly        ),
    .bclk_inv_i  ( fmt[0]            ),
    .delay_i     ( fmt[1]            ),
    .rjust_i     ( fmt[2]            ),
    .lrck_inv_i  ( fmt[3]            ),
    .fsync_i     ( fmt[4]            ),
    .slot16_i    ( fmt[5]            ),
    .loopback_i  ( ctrl_loop         ),
    .running_o   ( running           ),
    .tx_on_i     ( ctrl_tx_on        ),
    .tx_valid_i  ( tx_valid          ),
    .tx_data_i   ( tx_frame          ),
    .tx_take_o   ( tx_take           ),
    .tx_under_o  ( tx_under          ),
    .tx_active_o ( tx_active         ),
    .rx_on_i     ( ctrl_rx_on        ),
    .rx_valid_o  ( rx_frame_v        ),
    .rx_data_o   ( rx_frame          ),
    .rx_active_o ( rx_active         ),
    .i2s_mclk_o  ( i2s_mclk_o        ),
    .i2s_bclk_o  ( i2s_bclk_o        ),
    .i2s_lrck_o  ( i2s_lrck_o        ),
    .i2s_sd_o    ( i2s_sd_o          ),
    .i2s_sd_i    ( i2s_sd_i          )
);


//=============================================================================
// 9)  TRANSMIT PATH
//=============================================================================
// TXDATA takes whole words only (PSTRB = 4'hF; a sparse write pushes
// nothing). Stereo: each word is a frame. Mono: each half-word is a sample
// sent in both slots, the lower half first; the word is popped after its
// upper half. Clearing TX_ON discards a held upper half; a flush clears the
// FIFO and the half pointer (the frame in progress is still sent).

generate
    if (TX_USE) begin : g_tx

        wire [TX_FIFO_AW:0] level;
        wire         [31:0] tx_head;              // transmit FIFO head word
        wire                tx_full;
        wire                tx_push;              // TXDATA write, accepted
        wire                tx_pop;               // the core finished a word
        wire                tx_half;              // mono: the next sample is the word's upper half
        wire                tx_word_wr;           // whole-word TXDATA write
        wire                tx_drop;              // TX_ON cleared with an upper half held
        wire                tx_half_nxt;

        assign tx_word_wr = reg_wr & sel_txdata & (&pstrb_i);
        assign tx_push    = tx_word_wr & ~tx_full;
        assign tx_ovf     = tx_word_wr &  tx_full;
        assign tx_drop    = wr_ctrl0 & ~pwdata_i[1] & ctrl_tx_mono & (tx_half ^ tx_take);
        assign tx_pop     = (tx_take & (~ctrl_tx_mono | tx_half)) | tx_drop;

        apb_i2s_fifo #(.AW(TX_FIFO_AW), .ASYNC_RST_EN(ASYNC_RST_EN)) u_fifo (
            .clk_i   ( pclk_i    ),
            .rst_n_i ( presetn_i ),
            .clr_i   ( tx_flush  ),
            .push_i  ( tx_push   ),
            .din_i   ( pwdata_i  ),
            .pop_i   ( tx_pop    ),
            .head_o  ( tx_head   ),
            .valid_o ( tx_valid  ),
            .full_o  ( tx_full   ),
            .level_o ( level     )
        );

        assign tx_half_nxt = ~tx_flush & ~tx_drop & ~tx_half;

        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_half (
            .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(tx_flush | tx_drop | (tx_take & ctrl_tx_mono)),
            .d_i(tx_half_nxt), .q_o(tx_half));

        if (TX_FIFO_AW == 8) begin : g_lv_full
            assign tx_level = level;
        end else begin : g_lv_pad
            assign tx_level = {{(8-TX_FIFO_AW){1'b0}}, level};
        end
        assign irq_tx_low = (tx_level <= thr_tx);
        assign tx_frame = ~ctrl_tx_mono ? tx_head :
                          tx_half       ? {tx_head[31:16], tx_head[31:16]} :
                                          {tx_head[15:0],  tx_head[15:0]};

    end else begin : g_no_tx

        assign tx_ovf     = 1'b0;
        assign tx_valid   = 1'b0;
        assign tx_level   = 9'h000;
        assign irq_tx_low = 1'b0;
        wire   sel_txdata_unused = sel_txdata;
        assign tx_frame = 32'h0;
        wire   tx_flush_unused = tx_flush;
        wire   tx_take_unused  = tx_take;
        wire   tx_act_unused   = tx_active;
        wire   [31:0] pwdata_unused = pwdata_i;

    end
endgenerate


//=============================================================================
// 10) RECEIVE PATH
//=============================================================================
// Stereo: each frame is a word. Mono: the left sample, the right one or their
// average (arithmetic shift of the 17-bit sum) is kept, and two consecutive
// samples make a word, the first in the lower half. A flush, or the stream
// becoming inactive (RX_ON at 0 and no frame in progress), drops a held first
// sample. A read pops the head; a debugger read only peeks unless DBG_POP is
// set.

generate
    if (RX_USE) begin : g_rx

        wire [RX_FIFO_AW:0] level;
        wire                rx_valid;             // receive FIFO head holds a word
        wire                rx_full;
        wire         [15:0] rx_mono_smp;          // mono: the selected or averaged sample
        wire                rx_half;              // mono: the first sample of a word is held
        wire         [15:0] rx_hold;              // mono: the held first sample
        wire                rx_word_v;            // a word is ready for the receive FIFO
        wire         [31:0] rx_word;
        wire                rx_push;              // ... and the FIFO takes it
        wire                rx_pop;               // RXDATA read pops
        wire                rx_idle = ~ctrl_rx_on & ~rx_active;   // receive stream inactive
        wire         [16:0] hold_nxt;
        wire         [16:0] sum = {rx_frame[15], rx_frame[15:0]} + {rx_frame[31], rx_frame[31:16]};

        assign rx_mono_smp = (ctrl_rx_sel == 2'b01) ? rx_frame[31:16] :
                             (ctrl_rx_sel == 2'b10) ? sum[16:1]       :
                                                      rx_frame[15:0];
        wire         sum_lsb_unused = sum[0];

        assign hold_nxt = (rx_flush | rx_idle) ? 17'h0 : {~rx_half, rx_mono_smp};

        arv_ipdff #(.WIDTH(17), .ARST_EN(ARST_EN)) u_hold (
            .clk_i(pclk_i), .rst_n_i(presetn_i),
            .en_i(rx_flush | rx_idle | (rx_frame_v & ctrl_rx_mono)), .d_i(hold_nxt), .q_o({rx_half, rx_hold}));

        assign rx_word_v = rx_frame_v & (~ctrl_rx_mono | rx_half);
        assign rx_word   = ctrl_rx_mono ? {rx_mono_smp, rx_hold} : rx_frame;
        assign rx_push   = rx_word_v & ~rx_full;
        assign rx_over   = rx_word_v &  rx_full;
        assign rx_pop    = reg_rd & sel_rxdata & rx_valid & (~acc_dbg | ctrl_dbg_pop);
        assign rx_udf    = reg_rd & sel_rxdata & ~rx_valid & (~acc_dbg | ctrl_dbg_pop);

        apb_i2s_fifo #(.AW(RX_FIFO_AW), .ASYNC_RST_EN(ASYNC_RST_EN)) u_fifo (
            .clk_i   ( pclk_i    ),
            .rst_n_i ( presetn_i ),
            .clr_i   ( rx_flush  ),
            .push_i  ( rx_push   ),
            .din_i   ( rx_word   ),
            .pop_i   ( rx_pop    ),
            .head_o  ( rx_head   ),
            .valid_o ( rx_valid  ),
            .full_o  ( rx_full   ),
            .level_o ( level     )
        );

        if (RX_FIFO_AW == 8) begin : g_lv_full
            assign rx_level = level;
        end else begin : g_lv_pad
            assign rx_level = {{(8-RX_FIFO_AW){1'b0}}, level};
        end
        assign irq_rx_high = (rx_level >= thr_rx) & (thr_rx != 9'h000);

    end else begin : g_no_rx

        assign rx_over     = 1'b0;
        assign rx_udf      = 1'b0;
        assign rx_head     = 32'h0;
        assign rx_level    = 9'h000;
        assign irq_rx_high = 1'b0;
        wire        rx_flush_unused = rx_flush;
        wire        rx_v_unused     = rx_frame_v;
        wire [31:0] rx_frame_unused = rx_frame;
        wire        rx_dbg_unused   = acc_dbg;
        wire        rx_act_unused   = rx_active;
        wire        sd_i_unused     = i2s_sd_i;

    end
endgenerate


//=============================================================================
// 11) INTERRUPTS
//=============================================================================
// IRQ_PEND: TX_LOW[0] and RX_HIGH[1] are live levels; TX_UNDER[2], RX_OVER[3],
// TX_OVF[4] and RX_UDF[5] are sticky, cleared by writing 1 (an event in the
// same cycle wins).

wire          [3:0] irq_set      = {rx_udf, tx_ovf, rx_over, tx_under};
wire          [3:0] irq_w1c      = pwdata_i[5:2] & {4{wr_lane[0] & sel_irq_pend}};

assign irq_sticky_nxt = irq_set | (irq_sticky & ~irq_w1c);

arv_ipdff #(.WIDTH(4), .ARST_EN(ARST_EN)) u_irq_sticky (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(|irq_set | |irq_w1c), .d_i(irq_sticky_nxt), .q_o(irq_sticky));


assign irq_pend     =  {irq_sticky, irq_rx_high, irq_tx_low};
assign irq_o        =  |(irq_pend & irq_en);


//=============================================================================
// 12) READ MUX AND CLOCK REQUEST
//=============================================================================

assign rd_mux       =  ({32{sel_info    }} & INFO_VAL                                  ) |
                       ({32{sel_ctrl    }} & ctrl                                      ) |
                       ({32{sel_clkdiv  }} & {16'h0000, clk_rx_dly, 1'b0, clk_ratio, clk_mdiv}) |
                       ({32{sel_status  }} & {running, tx_active, rx_active, 4'h0, rx_level, 7'h00, tx_level}) |
                       ({32{sel_thresh  }} & {7'h00, thr_rx, 7'h00, thr_tx}            ) |
                       ({32{sel_irq_en  }} & {26'h0000000, irq_en}                     ) |
                       ({32{sel_irq_pend}} & {26'h0000000, irq_pend}                   ) |
                       ({32{sel_rxdata  }} & rx_head                                   ) |
                       ({32{sel_format  }} & {26'h0000000, fmt}                        ) |
                       ({32{sel_mdeleg  }} & mdeleg                                    );

assign prdata_o     =  rd_mux & {32{reg_rd}};

// The edge after a transfer lets idle outputs follow a FORMAT write; the
// engine keeps its clock until it has stopped
arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_xfer (
    .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(acc_valid), .q_o(xfer_q));

assign pclk_en_o    =  psel_i | ctrl_en | running | xfer_q;

wire          [1:0] pprot_unused = pprot_i[2:1];
wire          [1:0] paddr_unused = paddr_i[1:0];
wire          [3:0] pmaster_unused = pmaster_i & ~DBG_PMASTER_MASK;

endmodule // apb_i2s

`default_nettype wire
