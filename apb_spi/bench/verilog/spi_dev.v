//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          File:      spi_dev.v (included in tb_apb_spi)
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// The SPI side of the bench, written from the document (doc "Transfers",
// "Lanes and pads", "Chip selects", "Clocks and serial clock", "Receive
// timing", "Register map"):
//
//   - Register model: every admitted APB write is snooped into a mirror of
//     CTRL, CLKDIV, CSCFG, XFER, THRESH, IRQ_EN and MDELEG (byte lanes,
//     the _SET / _CLR aliases, the bits a build stores), from which the
//     expected PSLVERR (exp_resp_of) and every expected read are derived.
//   - Entry model: whole-word TXDATA writes are classified (legal, refused
//     with XFER_ERR, dropped with TX_OVF) against a level model of the
//     transmit FIFO; the legal ones form the queue of entries the monitor
//     expects on the wire, in order. A flush or an abort drops the entries
//     not yet taken (the IP's take strobe tells which ones started).
//   - Monitor: a transaction opens when the engine starts one and closes on
//     the select release. At each sampling edge it follows the entry queue
//     (entry, frame, clock), checks the select, the role of every lane
//     (driven, released, idle level) and collects the groups: a TX frame's
//     groups, assembled with the bench's own bit- and byte-order rules, must
//     equal its payload; a capturing frame's groups, read from the pads,
//     give the word the IP must push (a POLL frame only when it qualifies or
//     is the last one, then POLL_TO is expected).
//   - Clock and lane timing (ns): the first edge SETUP half-periods after
//     the start, every leading-to-trailing interval exactly HALF, every
//     trailing-to-leading interval at least HALF, the select released at
//     least HOLD half-periods after the last edge, the next start at least
//     INACT half-periods after a release; a lane driven by the IP stable at
//     least HALF before each sampling edge and changing no earlier than
//     HALF after one; no edge outside a transaction; idle levels per the
//     mirror between transactions.
//   - Device: dev_mode 0 is a scripted frame source: each capturing frame
//     takes the next word of the response queue (all ones when empty) and
//     launches it, in the order the IP assembles, on the lanes the frame
//     reads, dev_rt + dev_tco ns after each launch edge, with the lanes
//     unknown (X) from dev_rt + dev_tho ns; dev_mode 1 is the SD card
//     (sd_card.v), dev_mode 2 the quad flash (spi_flash.v).
//----------------------------------------------------------------------------

localparam QN = 16384;                        // queue storage

//----------------------------------------------------------------------------
// Register model
//----------------------------------------------------------------------------
localparam [10:0] CTRL_MASK_TB = (RX_EN != 0) ? 11'h7FF : 11'h4BF;
localparam  [6:0] IRQ_MASK_TB  = {POLL_USE[0], 1'b1, (RX_EN != 0), 1'b1, 1'b1, (RX_EN != 0), 1'b1};

reg  [10:0] m_ctrl;
reg  [15:0] m_clkdiv;                         // {RX_DLY, DIV}
reg  [19:0] m_cscfg;                          // {INACT-1, HOLD-1, SETUP-1, CSPOL}
reg  [15:0] m_xfer;
reg   [8:0] m_thresh_tx;
reg   [8:0] m_thresh_rx;
reg   [6:0] m_irq_en;
reg   [1:0] m_wr_priv;
reg   [1:0] m_rd_priv;
reg         m_resp;

wire        m_en       = m_ctrl[0];
wire        m_cpol     = m_ctrl[1];
wire  [1:0] m_tx_idle  = m_ctrl[5:4];
wire        m_io23_rel = m_ctrl[7];

function exp_resp_of;
   input        write;
   input  [1:0] mode;
   input [31:0] addr;
   reg    [1:0] priv;
   reg          allowed;
   reg          is_mdeleg;
   begin
      priv      = (mode == MACHINE) ? 2'b11 : (mode == SUPERVISOR) ? 2'b01 : 2'b00;
      is_mdeleg = (addr[ADDRW-1:2] == 'h18);
      allowed   = is_mdeleg ? (mode == MACHINE) : (priv >= (write ? m_wr_priv : m_rd_priv));
      exp_resp_of = (!allowed && m_resp) ? ERROR : OK;
   end
endfunction

function admitted;
   input       write;
   input [1:0] mode;
   input [ADDRW-1:0] a;
   reg   [1:0] priv;
   begin
      priv     = (mode == MACHINE) ? 2'b11 : (mode == SUPERVISOR) ? 2'b01 : 2'b00;
      admitted = (a[ADDRW-1:2] == 'h18) ? (mode == MACHINE) : (priv >= (write ? m_wr_priv : m_rd_priv));
   end
endfunction

// Is an XFER word legal for this build (doc "Refused entries")
function xfer_legal;
   input [15:0] x;
   begin
      xfer_legal = 1'b1;
      if (x[6:5] == 2'b11)                                 xfer_legal = 1'b0;
      if ((LANES_MAX == 1) && (x[6:5] != 2'b00))           xfer_legal = 1'b0;
      if ((LANES_MAX == 2) && (x[6:5] == 2'b10))           xfer_legal = 1'b0;
      if ((x[6:5] == 2'b01) && !x[0])                      xfer_legal = 1'b0;
      if ((x[6:5] == 2'b10) && (x[1:0] != 2'b11))          xfer_legal = 1'b0;
      if (!x[12] && (x[15:13] >= CS_NR))                   xfer_legal = 1'b0;
      if ((RX_EN == 0) && ((x[9:8] == 2'd1) || (x[9:8] == 2'd3) || x[10])) xfer_legal = 1'b0;
      if (!POLL_USE && (x[9:8] == 2'd3))                   xfer_legal = 1'b0;
   end
endfunction

// Entry queue (legal pushes), in order; [q_take, q_wr) are waiting in the FIFO
reg  [15:0] q_attr [0:QN-1];
reg  [31:0] q_data [0:QN-1];
reg  [31:0] q_pm   [0:QN-1];
reg  [31:0] q_pv   [0:QN-1];
integer     q_wr, q_take, q_mon;
integer     n_tx_ovf, n_xfer_err, n_rx_udf;  // events the model expects
integer     x_pushed;                         // words the IP pushed into its receive FIFO

// Expected receive words, in order; [x_rd, x_wr) not yet read; rx_got holds
// the words read (rx_pop_chk), at the same index
reg  [31:0] x_rx [0:QN-1];
reg  [31:0] rx_got [0:QN-1];
integer     x_wr, x_rd;
integer     n_poll_to;                        // POLL_TO events expected

wire  [1:0] snoop_mode = {pprot[0], psmode};
wire        snoop_wr   = psel && penable && pwrite && admitted(1'b1, snoop_mode, paddr);
wire [31:0] snoop_bits = {{8{pstrb[3]}}, {8{pstrb[2]}}, {8{pstrb[1]}}, {8{pstrb[0]}}};
localparam  DEC_W = ADDRW - 2;
wire [DEC_W-1:0] snoop_a = paddr[ADDRW-1:2];

task model_reset;
   begin
      m_ctrl      = 11'h010;
      m_clkdiv    = 16'h0;
      m_cscfg     = 20'h0;
      m_xfer      = 16'h0;
      m_thresh_tx = 9'h0;
      m_thresh_rx = 9'h0;
      m_irq_en    = 7'h0;
      m_wr_priv   = MDELEG_RST[1:0];
      m_rd_priv   = MDELEG_RST[3:2];
      m_resp      = MDELEG_RST[8];
      q_wr = 0; q_take = 0; q_mon = 0;
      x_wr = 0; x_rd = 0; x_pushed = 0;
      n_tx_ovf = 0; n_xfer_err = 0; n_rx_udf = 0; n_poll_to = 0;
   end
endtask

initial model_reset;

//----------------------------------------------------------------------------
// Transaction state seen by the monitor
//----------------------------------------------------------------------------
reg         mon_ev;                           // an entry is being clocked
integer     mon_e, mon_f, mon_c;              // its queue index, frame, clock
reg   [1:0] me_kind, me_lanes;
integer     me_L, me_N, me_nclk, me_frames;
reg         me_cap, me_hold, me_none;
reg   [2:0] me_sel;
reg  [31:0] me_data, me_pm, me_pv;
reg   [3:0] g_tx [0:31];                      // groups of the frame, arrival order
reg   [3:0] g_rx [0:31];
reg         abort_ok;                         // a test aborts: an entry may end early
reg   [3:0] t_rel_l;                          // lanes a dual / quad frame of the transaction released
integer     t_rxdly;                          // RX_DLY of the transaction

// Receive frames: the IP keeps the pad value RX_DLY clk_i edges after each
// sampling edge, so the monitor takes each group at that edge (pending
// samples), into the context of its frame; a frame is complete when all its
// groups are in, which for a POLL frame decides whether the entry ends
localparam  FC = 64;                          // frame contexts (ring)
localparam  PN = 512;                         // pending samples (ring)
reg   [3:0] fc_g    [0:FC*32-1];
integer     fc_need [0:FC-1];
integer     fc_got  [0:FC-1];
reg   [1:0] fc_kind [0:FC-1];
integer     fc_L    [0:FC-1];
integer     fc_e    [0:FC-1];
integer     fc_f    [0:FC-1];
reg         fc_lastf[0:FC-1];                 // the last frame the entry allows
reg   [7:0] fc_pm   [0:FC-1];
reg   [7:0] fc_pv   [0:FC-1];
reg         fc_lsb  [0:FC-1];
reg         fc_bsw  [0:FC-1];
integer     fc_wr, cur_fc;
integer     pd_due  [0:PN-1];
integer     pd_fc   [0:PN-1];
integer     pd_c    [0:PN-1];
reg   [2:0] pd_src  [0:PN-1];                 // 0 IO1, 1 IO0, 2 IO0 output (loopback), 3 dual, 4 quad
integer     pd_wr, pd_rd;
integer     mcyc;                             // free_clk rising edges
reg         poll_unres;                       // a POLL frame's decision is pending
reg         dev_wait;                         // the device waits for that decision
reg         dev_rel_now;                      // release at once (a decision of the bench, not a device edge)
initial begin fc_wr = 0; pd_wr = 0; pd_rd = 0; mcyc = 0; poll_unres = 0; dev_wait = 0; dev_rel_now = 0; end
initial begin mon_ev = 0; abort_ok = 0; t_rel_l = 0; end
reg         mon_txn;                          // a transaction is open
reg         t_cpol, t_cpha, t_lsb, t_bswap;
integer     t_H;                              // HALF of the transaction
integer     t_setup, t_hold, t_inact;         // in half-periods
reg   [7:0] t_cspol;
reg         t_none;
reg   [2:0] t_sel;
reg         t_rxio0, t_loop;
realtime    t_start, t_last_sck, t_rel, t_last_smp, t_lane_chg;
integer     t_nedge;                          // SCK edges of the transaction
reg         t_last_lead;
integer     t_prev_inact_ns;                  // INACT of the previous transaction, ns
integer     n_txn;                            // transactions seen
real        t_meas_hold;                      // last release, ns after the last edge
real        t_meas_inact;                     // last start, ns after the previous release
real        t_meas_setup;                     // last first edge, ns after the start
real        t_tl_gap;                         // last trailing-to-leading interval, ns
integer     n_poll_gap;                       // POLL frames resumed after the evaluation pause
real        t_poll_gap;                       // ... the last such SCK idle time, ns
integer     n_frames;                         // frames completed
reg         mon_on;                           // checks enabled
reg         rx_auto;                          // compare received words in rx_pop_chk

initial
  begin
     mon_txn = 0; mon_on = 1; rx_auto = 1; t_nedge = 0; t_prev_inact_ns = 0;
     n_txn = 0; n_frames = 0; t_rel = 0; t_last_smp = 0; t_lane_chg = 0;
     t_meas_hold = 0; t_meas_inact = 0; t_meas_setup = 0; t_tl_gap = 0; n_poll_gap = 0; t_poll_gap = 0;
  end

// The register model and the transaction start share one block, so a
// transaction latches the mirror as the IP does: every setting, the idle
// levels included, without a write on the same edge (doc "Divider changes")
reg  [10:0] pre_ctrl;
reg  [15:0] pre_clkdiv;
reg  [19:0] pre_cscfg;
wire        tb_start   = apb_spi_inst0.u_core.start;
wire        tb_release = (apb_spi_inst0.u_core.st != 3'd6) && (apb_spi_inst0.u_core.st_n == 3'd6);
wire        tb_take    = apb_spi_inst0.e_take;
wire        tb_tx_clr  = apb_spi_inst0.tx_clr;
wire        tb_rx_push = apb_spi_inst0.rx_valid;
wire        tb_rx_fl   = apb_spi_inst0.rx_flush;

always @(posedge pclk or negedge presetn)
  if (presetn !== 1'b1)
    begin
       model_reset;
       mon_txn = 0;
       mon_ev  = 0;
       t_nedge = 0;
       dev_oe  = 4'h0;
       ev_rd   = ev_wr;
       pd_rd   = pd_wr;
       poll_unres = 0;
       dev_wait = 0;
    end
  else
    begin : model_edge
       reg [31:0] w;
       reg [10:0] cm;
       reg [15:0] dm;
       reg [19:0] sm;
       reg  [6:0] im;
       integer    lv;
       integer    tk;
       // pushes and pops the IP performs on this edge
       if (tb_rx_push) x_pushed = x_pushed + 1;
       if (tb_rx_fl)   x_rd = x_pushed;
       tk = q_take;
       if (tb_take)    q_take = q_take + 1;
       pre_ctrl = m_ctrl; pre_clkdiv = m_clkdiv; pre_cscfg = m_cscfg;
       if (snoop_wr)
         begin
            w  = pwdata;
            cm = snoop_bits[10:0] & CTRL_MASK_TB;
            case (snoop_a)
              'h01: m_ctrl   = (m_ctrl & ~cm) | (w[10:0] & cm);
              'h02: m_ctrl   =  m_ctrl | (w[10:0] & cm);
              'h03: m_ctrl   =  m_ctrl & ~(w[10:0] & cm);
              'h04: begin
                       dm = {snoop_bits[19:16] & {4{RX_EN != 0}}, snoop_bits[11:0]};
                       m_clkdiv = (m_clkdiv & ~dm) | ({w[19:16], w[11:0]} & dm);
                    end
              'h05: begin
                       sm = snoop_bits[19:0];
                       m_cscfg = (m_cscfg & ~sm) | (w[19:0] & sm);
                    end
              'h06: m_xfer = (m_xfer & ~(snoop_bits[15:0] & 16'hFF7F)) | (w[15:0] & snoop_bits[15:0] & 16'hFF7F);
              'h08: begin
                       if (pstrb[0]) m_thresh_tx[7:0] = w[7:0];
                       if (pstrb[1]) m_thresh_tx[8]   = w[8];
                       if (pstrb[2] && (RX_EN != 0)) m_thresh_rx[7:0] = w[23:16];
                       if (pstrb[3] && (RX_EN != 0)) m_thresh_rx[8]   = w[24];
                    end
              'h09: begin im = {7{pstrb[0]}} & IRQ_MASK_TB; m_irq_en = (m_irq_en & ~im) | (w[6:0] & im); end
              'h0A: begin im = {7{pstrb[0]}} & IRQ_MASK_TB; m_irq_en =  m_irq_en | (w[6:0] & im); end
              'h0B: begin im = {7{pstrb[0]}} & IRQ_MASK_TB; m_irq_en =  m_irq_en & ~(w[6:0] & im); end
              'h0D: if (pstrb == 4'hF)
                      begin
                         lv = q_wr - q_take;
                         if (!xfer_legal(m_xfer))
                           n_xfer_err = n_xfer_err + 1;
                         else if (lv + (tb_take ? 1 : 0) >= TX_DEPTH)
                           n_tx_ovf = n_tx_ovf + 1;
                         else
                           begin
                              q_attr[q_wr] = m_xfer;
                              q_data[q_wr] = w;
                              q_pm[q_wr]   = {24'h0, w[31:24]};
                              q_pv[q_wr]   = {24'h0, w[23:16]};
                              q_wr = q_wr + 1;
                           end
                      end
              'h18: if (snoop_mode == MACHINE)
                      begin
                         if (pstrb[0])
                           begin
                              m_wr_priv = (w[1:0] == 2'b10) ? 2'b11 : w[1:0];
                              m_rd_priv = (w[3:2] == 2'b10) ? 2'b11 : w[3:2];
                           end
                         if (pstrb[1]) m_resp = w[8];
                      end
              default: ;
            endcase
         end
       if (psel && penable && !pwrite && admitted(1'b0, snoop_mode, paddr) && (snoop_a == 'h0E) && (RX_EN != 0) &&
           (!(|(pmaster & DBG_MASK)) || m_ctrl[9]) && (apb_spi_inst0.rx_level == 0))
         n_rx_udf = n_rx_udf + 1;
       if (tb_start)   txn_open(tk);              // after this edge's write, as the IP latches it
       if (tb_tx_clr)  q_wr = q_take;
       if (tb_release) txn_close;
    end

//----------------------------------------------------------------------------
// Monitor
//----------------------------------------------------------------------------

task txn_open;
   input integer tk;                          // the entry taken
   begin
      if (mon_txn) tb_error("monitor: a transaction starts while one is open");
      if (q_mon != tk) begin
         $display("ERROR: monitor: transaction starts at entry %0d, expected %0d %t ns", tk, q_mon, $time);
         error = error + 1;
      end
      mon_txn = 1;
      n_txn   = n_txn + 1;
      t_cpol  = pre_ctrl[1];
      t_cpha  = pre_ctrl[2];
      t_lsb   = pre_ctrl[3];
      t_bswap = pre_ctrl[10];
      t_H     = pre_clkdiv[11:0] + 1;
      t_setup = pre_cscfg[11:8] + 1;
      t_hold  = pre_cscfg[15:12] + 1;
      t_inact = pre_cscfg[19:16] + 1;
      t_cspol = pre_cscfg[7:0];
      t_none  = q_attr[tk][12];
      t_sel   = q_attr[tk][15:13];
      t_rxio0 = pre_ctrl[6];
      t_loop  = pre_ctrl[8];
      t_rxdly = (RX_EN != 0) ? pre_clkdiv[15:12] : 0;
      t_nedge = 0;
      t_rel_l = 4'h0;
      t_start = $realtime;
      t_meas_inact = t_start - t_rel;
      if (mon_on && (n_txn > 1) && (t_start - t_rel < t_prev_inact_ns - 0.01)) begin
         $display("ERROR: monitor: select asserted %0.1f ns after the release, INACT needs %0d ns %t ns",
                  t_start - t_rel, t_prev_inact_ns, $time);
         error = error + 1;
      end
      if (q_attr[tk][12] == 1'b0 && t_cspol[t_sel]) cv_cs_high = 1;
      if (q_attr[tk][12]) cv_cs_none = 1;
      if ((t_setup == 16) || (t_hold == 16) || (t_inact == 16)) cv_setup16 = 1;
      dev_start;
   end
endtask

task txn_close;
   begin
      mon_txn = 0;
      t_rel   = $realtime;
      t_meas_hold = t_rel - t_last_sck;
      if (abort_ok) q_mon = q_take;                 // entries an abort took before their first edge
      t_prev_inact_ns = t_inact * t_H * PCLK_P;
      if (mon_on && (t_nedge > 0) && (t_rel - t_last_sck < t_hold * t_H * PCLK_P - 0.01)) begin
         $display("ERROR: monitor: select released %0.1f ns after the last edge, HOLD needs %0.1f ns %t ns",
                  t_rel - t_last_sck, t_hold * t_H * PCLK_P, $time);
         error = error + 1;
      end
      if (mon_ev && !abort_ok) begin
         $display("ERROR: monitor: select released in entry %0d frame %0d clock %0d %t ns", mon_e, mon_f, mon_c, $time);
         error = error + 1;
      end
      mon_ev = 0;
      dev_release;
   end
endtask

// Decode the next entry of the queue
task ent_load;
   begin
      mon_e    = q_mon;
      q_mon    = q_mon + 1;
      me_kind  = q_attr[mon_e][9:8];
      me_lanes = q_attr[mon_e][6:5];
      me_L     = (me_lanes == 2'd2) ? 4 : (me_lanes == 2'd1) ? 2 : 1;
      me_N     = q_attr[mon_e][4:0] + 1;
      me_nclk  = (me_kind == 2'd2) ? 1 : me_N / me_L;
      me_frames= (me_kind == 2'd0) ? 1 : q_data[mon_e][15:0] + 1;
      me_cap   = (RX_EN != 0) && ((me_kind == 2'd1) || (me_kind == 2'd3) ||
                                  ((me_kind == 2'd0) && q_attr[mon_e][10] && (me_lanes == 2'd0)));
      me_hold  = q_attr[mon_e][11];
      me_none  = q_attr[mon_e][12];
      me_sel   = q_attr[mon_e][15:13];
      me_data  = q_data[mon_e];
      me_pm    = q_pm[mon_e];
      me_pv    = q_pv[mon_e];
      mon_f    = 0;
      mon_c    = 0;
      mon_ev   = 1;
      if (me_L > 1) t_rel_l = t_rel_l | ((me_L == 4) ? 4'hF : 4'h3);
   end
endtask

// Byte reversal of an n-bit frame (16, 24, 32), else unchanged
function [31:0] bswap_n;
   input [31:0] w;
   input integer n;
   begin
      case (n)
        16: bswap_n = {16'h0, w[7:0], w[15:8]};
        24: bswap_n = {8'h0, w[7:0], w[15:8], w[23:16]};
        32: bswap_n = {w[7:0], w[15:8], w[23:16], w[31:24]};
        default: bswap_n = w;
      endcase
   end
endfunction

function [31:0] mask_n;
   input integer n;
   begin
      mask_n = (n >= 32) ? 32'hFFFFFFFF : ((32'h1 << n) - 1);
   end
endfunction

// The frame value of nclk groups of L bits, in arrival order: MSB first, the
// groups from the most significant; LSB first, from the least; bit 0 of each
// group on IO0; then the byte order
reg  [31:0] asm_w;
task asm_frame;
   input       from_rx;
   input integer nclk;
   input integer L;
   reg  [31:0] w;
   reg   [3:0] g;
   integer     c;
   begin
      w = 0;
      for (c = 0; c < nclk; c = c + 1)
        begin
           g = from_rx ? g_rx[c] : g_tx[c];
           g = g & ((4'h1 << L) - 1);
           if (t_lsb) w = w | ({28'h0, g} << (c * L));
           else       w = (w << L) | {28'h0, g};
        end
      asm_w = t_bswap ? bswap_n(w, nclk * L) : w;
   end
endtask

// The group a frame of value v carries on clock c (the inverse of asm_frame)
function [3:0] ser_grp;
   input [31:0] v;
   input integer c;
   input integer L;
   input integer N;
   input        lsb;
   input        bsw;
   reg   [31:0] s;
   begin
      s = bsw ? bswap_n(v, N) : v;
      if (lsb) ser_grp = (s >> (c * L)) & ((32'h1 << L) - 1);
      else     ser_grp = (s >> (N - (c + 1) * L)) & ((32'h1 << L) - 1);
   end
endfunction

// Expected select output vector while the transaction holds select sel
function [7:0] cs_exp;
   input       on;
   input [2:0] sel;
   input [7:0] pol;
   integer     i;
   begin
      for (i = 0; i < 8; i = i + 1)
        cs_exp[i] = ~(((on && (sel == i)) ? 1'b1 : 1'b0) ^ pol[i]);
   end
endfunction

// Role checks of the lanes the IP drives at a sampling edge
task lane_check;
   reg   [3:0] data_l;                        // lanes carrying transmit data
   reg   [3:0] rel_l;                         // lanes released for the frame
   integer     k;
   begin
      data_l = (me_kind == 2'd0) ? ((me_L == 4) ? 4'hF : (me_L == 2) ? 4'h3 : 4'h1) : 4'h0;
      rel_l  = ((me_kind != 2'd0) && (me_L > 1)) ? ((me_L == 4) ? 4'hF : 4'h3) : 4'h0;
      for (k = 0; k < 4; k = k + 1)
        begin
           if (!data_l[k] && !rel_l[k] && t_rel_l[k])
             begin
                if (spi_io_oe[k] !== 1'b0) begin
                   $display("ERROR: monitor: lane %0d driven after a dual / quad frame released it (entry %0d) %t ns", k, mon_e, $time);
                   error = error + 1;
                end
             end
           else if (data_l[k] || rel_l[k])
             begin
                if (spi_io_oe[k] !== data_l[k]) begin
                   $display("ERROR: monitor: lane %0d oe %b, expected %b (entry %0d kind %0d L %0d) %t ns",
                            k, spi_io_oe[k], data_l[k], mon_e, me_kind, me_L, $time);
                   error = error + 1;
                end
             end
           else if (k == 0)
             begin
                if ((spi_io_oe[0] !== ~m_tx_idle[1]) || (!m_tx_idle[1] && (spi_io_o[0] !== m_tx_idle[0]))) begin
                   $display("ERROR: monitor: IO0 oe %b val %b, TX_IDLE %0d (entry %0d) %t ns", spi_io_oe[0], spi_io_o[0],
                            m_tx_idle, mon_e, $time);
                   error = error + 1;
                end
             end
           else if (k == 1)
             begin
                if (spi_io_oe[1] !== 1'b0) begin
                   $display("ERROR: monitor: IO1 driven outside a dual / quad transmit frame %t ns", $time);
                   error = error + 1;
                end
             end
           else
             begin
                if ((spi_io_oe[k] !== ~m_io23_rel) || (!m_io23_rel && (spi_io_o[k] !== 1'b1))) begin
                   $display("ERROR: monitor: IO%0d oe %b val %b, IO23_REL %b %t ns", k, spi_io_oe[k], spi_io_o[k], m_io23_rel, $time);
                   error = error + 1;
                end
             end
        end
      if (me_kind == 2'd0 && $realtime - t_lane_chg < t_H * PCLK_P - 0.01 && mon_on) begin
         $display("ERROR: monitor: transmit lanes changed %0.1f ns before the sampling edge, HALF is %0.1f ns %t ns",
                  $realtime - t_lane_chg, t_H * PCLK_P, $time);
         error = error + 1;
      end
   end
endtask

// Take the pending samples due on this edge (the pad values just before it)
task pd_take;
   reg [3:0] v;
   integer   id;
   begin
      while ((pd_rd < pd_wr) && (pd_due[pd_rd % PN] <= mcyc))
        begin
           case (pd_src[pd_rd % PN])
             3'd0: v = {3'h0, spi_pad[1]};
             3'd1: v = {3'h0, spi_pad[0]};
             3'd2: v = {3'h0, spi_io_o[0]};
             3'd3: v = {2'h0, spi_pad[1:0]};
             default: v = spi_pad;
           endcase
           id = pd_fc[pd_rd % PN];
           fc_g[id * 32 + pd_c[pd_rd % PN]] = v;
           fc_got[id] = fc_got[id] + 1;
           pd_rd = pd_rd + 1;
           if (fc_got[id] == fc_need[id]) fc_done(id);
        end
   end
endtask

// A receive frame complete: the word the IP must push
task fc_done;
   input integer id;
   reg  [31:0] w;
   reg   [3:0] g;
   integer     c, L, n;
   reg         q;
   begin
      w = 0; L = fc_L[id];
      for (c = 0; c < fc_need[id]; c = c + 1)
        begin
           g = fc_g[id * 32 + c] & ((4'h1 << L) - 1);
           if (fc_lsb[id]) w = w | ({28'h0, g} << (c * L));
           else            w = (w << L) | {28'h0, g};
        end
      n = fc_need[id] * L;
      if (fc_bsw[id]) w = bswap_n(w, n);
      if (fc_kind[id] == 2'd3)
        begin
           q = ((w[7:0] & fc_pm[id]) != fc_pv[id]);
           if (q || fc_lastf[id]) begin x_rx[x_wr] = w; x_wr = x_wr + 1; end
           if (!q && fc_lastf[id]) begin n_poll_to = n_poll_to + 1; cv_poll_to = 1; end
           if (q && fc_f[id] == 0) cv_poll_first = 1;
           if (q && fc_f[id] > 0 && !fc_lastf[id]) cv_poll_mid = 1;
           if (q && fc_lastf[id] && fc_f[id] > 0) cv_poll_last = 1;
           if (L == 4) cv_poll_quad = 1;
           if (q && mon_ev && (mon_e == fc_e[id])) mon_ev = 0;   // the entry ends
           poll_unres = 0;
           if (dev_wait) begin dev_wait = 0; if (dev_mode == 0 && !t_cpha) begin dev_rel_now = 1; dev_next; dev_rel_now = 0; end end
        end
      else
        begin
           x_rx[x_wr] = w; x_wr = x_wr + 1;
        end
   end
endtask

always @(posedge free_clk)
  begin
     mcyc = mcyc + 1;
     if (presetn === 1'b1) pd_take;
  end

// A sampling edge
task mon_sample;
   reg   [3:0] g;
   reg         q;
   reg         last;
   reg   [7:0] cse;
   integer     k;
   begin
      if (mon_ev && (me_kind == 2'd3) && (mon_c == 0) && (mon_f > 0) && !t_cpha) begin
         n_poll_gap = n_poll_gap + 1; t_poll_gap = t_tl_gap;
      end
      if (!mon_ev)
        begin
           if (q_mon >= q_take) begin
              $display("ERROR: monitor: sampling edge with no entry taken (%0d taken) %t ns", q_take, $time);
              error = error + 1;
           end
           ent_load;
           if (me_none != t_none || (!me_none && me_sel != t_sel)) begin
              $display("ERROR: monitor: entry %0d select %0d none %b in a transaction of select %0d none %b %t ns",
                       mon_e, me_sel, me_none, t_sel, t_none, $time);
              error = error + 1;
           end
           if (mon_e > 0 && t_nedge > 1) cv_hold_cont = 1;
        end
      cse = cs_exp(!t_none, t_sel, t_cspol);
      if (spi_cs !== cse[CS_NR-1:0]) begin
         $display("ERROR: monitor: chip selects %b, expected %b (entry %0d) %t ns", spi_cs, cse[CS_NR-1:0], mon_e, $time);
         error = error + 1;
      end
      lane_check;
      // transmit groups from the IP's outputs; receive groups from the pads at the IP's sampling point
      g = 4'h0;
      for (k = 0; k < me_L; k = k + 1) g[k] = spi_io_o[k];
      g_tx[mon_c] = g;
      if (me_cap)
        begin
           if (mon_c == 0)
             begin
                cur_fc = fc_wr % FC;
                fc_wr  = fc_wr + 1;
                fc_need[cur_fc] = me_nclk;  fc_got[cur_fc] = 0;
                fc_kind[cur_fc] = me_kind;  fc_L[cur_fc]   = me_L;
                fc_e[cur_fc]    = mon_e;    fc_f[cur_fc]   = mon_f;
                fc_lastf[cur_fc]= (mon_f == me_frames - 1);
                fc_pm[cur_fc]   = me_pm[7:0]; fc_pv[cur_fc] = me_pv[7:0];
                fc_lsb[cur_fc]  = t_lsb;    fc_bsw[cur_fc] = t_bswap;
             end
           pd_due[pd_wr % PN] = mcyc + t_rxdly;
           pd_fc[pd_wr % PN]  = cur_fc;
           pd_c[pd_wr % PN]   = mon_c;
           pd_src[pd_wr % PN] = (me_L == 4) ? 3'd4 : (me_L == 2) ? 3'd3 : t_loop ? 3'd2 : t_rxio0 ? 3'd1 : 3'd0;
           pd_wr = pd_wr + 1;
           if ((mon_c == me_nclk - 1) && (me_kind == 2'd3)) poll_unres = 1;
           if (t_rxdly == 0) pd_take;
        end
      // coverage
      cv_mode[{t_cpol, t_cpha}] = 1;
      case (me_L)
        1: cv_kind_l1[me_kind] = 1;
        2: cv_kind_l2[me_kind] = 1;
        default: cv_kind_l4[me_kind] = 1;
      endcase
      if (t_rxio0 && me_cap) cv_3wire = 1;
      if (m_io23_rel) cv_io23_rel = 1;
      if (t_loop && me_cap) cv_loopback = 1;
      mon_c = mon_c + 1;
      t_last_smp = $realtime;
      if (mon_c == me_nclk)
        begin
           n_frames = n_frames + 1;
           if (me_N == 1) cv_bits1 = 1;
           if (me_N == 32) cv_bits32 = 1;
           if (t_lsb) cv_lsb = 1;
           if (t_bswap && (me_N >= 16) && ((me_N % 8) == 0)) cv_bswap = 1;
           if (t_lsb && t_bswap && (me_N >= 16) && ((me_N % 8) == 0)) cv_lsb_bswap = 1;
           if (me_kind == 2'd0)
             begin
                asm_frame(1'b0, me_nclk, me_L);
                if (mon_on && (asm_w !== (me_data & mask_n(me_N)))) begin
                   $display("ERROR: monitor: entry %0d sent 0x%h, payload 0x%h (N %0d L %0d lsb %b bswap %b) %t ns",
                            mon_e, asm_w, me_data & mask_n(me_N), me_N, me_L, t_lsb, t_bswap, $time);
                   error = error + 1;
                end
             end
           mon_c = 0;
           mon_f = mon_f + 1;
           if (mon_f >= me_frames) mon_ev = 0;
        end
   end
endtask

// SCK edges: timing checks, the monitor at sampling edges, the device at launch edges
always @(spi_sck)
  if (tb_rst_done && (presetn === 1'b1))
    begin : sck_edge
       reg     lead;
       realtime now;
       now  = $realtime;
       if (!mon_txn)
         begin
            if (mon_on && (spi_sck !== m_cpol)) tb_error("monitor: SCK edge outside a transaction");
         end
       else
         begin
            lead = (spi_sck !== t_cpol);
            if (mon_on)
              begin
                 if (t_nedge == 0)
                   begin
                      t_meas_setup = now - t_start;
                      if (!lead) tb_error("monitor: first edge of a transaction is not a leading edge");
                      if ((now - t_start < t_setup * t_H * PCLK_P - 0.01) || (now - t_start > t_setup * t_H * PCLK_P + 0.01)) begin
                         $display("ERROR: monitor: first edge %0.1f ns after the start, SETUP is %0.1f ns %t ns",
                                  now - t_start, t_setup * t_H * PCLK_P, $time);
                         error = error + 1;
                      end
                   end
                 else if (lead)
                   begin
                      if (now - t_last_sck < t_H * PCLK_P - 0.01) begin
                         $display("ERROR: monitor: leading edge %0.1f ns after the trailing one, HALF is %0.1f ns %t ns",
                                  now - t_last_sck, t_H * PCLK_P, $time);
                         error = error + 1;
                      end
                      if (now - t_last_sck > t_H * PCLK_P + 0.01) cv_resume = 1;
                      t_tl_gap = now - t_last_sck;
                      if (mon_ev && (me_kind == 2'd3) && (mon_c == 0) && (mon_f > 0) && t_cpha) begin
                         n_poll_gap = n_poll_gap + 1; t_poll_gap = t_tl_gap;
                      end
                   end
                 else if ((now - t_last_sck < t_H * PCLK_P - 0.01) || (now - t_last_sck > t_H * PCLK_P + 0.01))
                   begin
                      $display("ERROR: monitor: trailing edge %0.1f ns after the leading one, HALF is %0.1f ns %t ns",
                               now - t_last_sck, t_H * PCLK_P, $time);
                      error = error + 1;
                   end
                 if (t_nedge > 0 && lead == t_last_lead) tb_error("monitor: two leading or two trailing edges in a row");
              end
            t_nedge     = t_nedge + 1;
            t_last_sck  = now;
            t_last_lead = lead;
            if (lead == !t_cpha)
              begin
                 mon_sample;
                 if (dev_mode == 1) sd_sample;
                 if (dev_mode == 2) fl_sample;
              end
            else
              dev_launch;
         end
    end

// Lane changes: never sooner than HALF after a sampling edge while a transaction is open
always @(spi_io_o or spi_io_oe)
  begin
     if (tb_rst_done && (presetn === 1'b1) && mon_txn && mon_on && (t_nedge > 0) &&
         ($realtime - t_last_smp < t_H * PCLK_P - 0.01) && ($realtime > t_last_smp))
       begin
          $display("ERROR: monitor: lanes changed %0.1f ns after a sampling edge, HALF is %0.1f ns (oe %b io %b) %t ns",
                   $realtime - t_last_smp, t_H * PCLK_P, spi_io_oe, spi_io_o, $time);
          error = error + 1;
       end
     t_lane_chg = $realtime;
  end

// Idle levels between transactions
always @(negedge free_clk)
  if (tb_rst_done && (presetn === 1'b1) && !mon_txn && mon_on)
    begin : idle_chk
       reg [7:0] cse;
       #1;                                   // after any change a task makes on this edge
       cse = cs_exp(1'b0, 3'd0, m_cscfg[7:0]);
       if (spi_sck !== m_cpol) begin
          $display("ERROR: idle SCK %b, CPOL %b %t ns", spi_sck, m_cpol, $time);
          error = error + 1;
       end
       if (spi_cs !== cse[CS_NR-1:0]) begin
          $display("ERROR: idle chip selects %b, expected %b %t ns", spi_cs, cse[CS_NR-1:0], $time);
          error = error + 1;
       end
       if ((spi_io_oe[0] !== ~m_tx_idle[1]) || (!m_tx_idle[1] && spi_io_o[0] !== m_tx_idle[0]) ||
           (spi_io_oe[1] !== 1'b0) ||
           (spi_io_oe[3:2] !== {2{~m_io23_rel}}) || (!m_io23_rel && spi_io_o[3:2] !== 2'b11)) begin
          $display("ERROR: idle lanes oe %b io %b (TX_IDLE %0d IO23_REL %b) %t ns", spi_io_oe, spi_io_o, m_tx_idle, m_io23_rel, $time);
          error = error + 1;
       end
    end

// Contention on a pad, beyond the device's round trip (the device lets go of a
// lane dev_rt after the launch edge on which the IP takes it back): each
// overlap is timed from its own start
reg         ov;                               // the IP and the device drive a lane together
reg         ov_rep;                           // ... reported
realtime    ov_t;                             // ... since
initial begin ov = 0; ov_rep = 0; ov_t = 0; end
always @(spi_io_oe or dev_oe)
  if (|(spi_io_oe & dev_oe))
    begin
       if (!ov) begin ov = 1; ov_rep = 0; ov_t = $realtime; end
    end
  else
    ov = 0;
always @(free_clk)
  if (tb_rst_done && (presetn === 1'b1) && ov && !ov_rep && ($realtime - ov_t > dev_rt + 0.5))
    begin
       $display("ERROR: pad contention: IP oe %b, device oe %b since %0.1f ns %t ns", spi_io_oe, dev_oe, ov_t, $time);
       error  = error + 1;
       ov_rep = 1;
    end

// Final checks at the end of a test
task mon_final;
   begin
      if (mon_txn && mon_on) tb_error("monitor: test ended with a transaction open");
      if (pd_rd != pd_wr) tb_error("monitor: test ended with receive samples pending");
   end
endtask

//----------------------------------------------------------------------------
// Scripted device (dev_mode 0)
//----------------------------------------------------------------------------
integer     dev_mode;                         // 0 scripted, 1 SD card, 2 flash
real        dev_rt, dev_tco, dev_tho;         // round trip, launch to valid, launch to invalid (ns)
reg  [31:0] rq [0:QN-1];                      // response frames
integer     rq_wr, rq_rd;
reg  [31:0] rq_dflt;                          // response when the queue is empty
integer     dv_e, dv_f;                       // frame the device is answering
reg  [31:0] dv;

task dev_defaults;
   begin
      dev_mode = 0;
      dev_rt   = 0.0;
      dev_tco  = 6.0;
      dev_tho  = 1.0;
      rq_wr    = 0;
      rq_rd    = 0;
      rq_dflt  = 32'hFFFFFFFF;
      dv_e     = -1;
      dv_f     = -1;
   end
endtask

initial
  begin
     dev_oe = 4'h0;
     dev_v  = 4'h0;
     dev_defaults;
  end

task rq_push;
   input [31:0] v;
   begin
      rq[rq_wr] = v;
      rq_wr = rq_wr + 1;
   end
endtask

// Drive the device lanes: lanes in oe take v after the round trip. The pad
// changes go through a time-ordered event queue (each launch schedules a
// release at rt, an unknown value at rt + t_ho and the new value at rt + t_co,
// and launches are further apart than t_co - t_ho), not through intra-
// assignment delays, which simulators keep differently once several are
// pending on one variable.
localparam  EQ = 256;
real        ev_t   [0:EQ-1];
reg   [3:0] ev_m   [0:EQ-1];                  // lanes the event changes
reg   [3:0] ev_oe  [0:EQ-1];
reg   [3:0] ev_v   [0:EQ-1];
reg         ev_x   [0:EQ-1];                  // the value is unknown
integer     ev_wr, ev_rd;
initial begin ev_wr = 0; ev_rd = 0; end

task ev_push;
   input real  t;
   input [3:0] m;
   input [3:0] oe;
   input [3:0] v;
   input       x;
   begin
      ev_t[ev_wr % EQ] = t; ev_m[ev_wr % EQ] = m; ev_oe[ev_wr % EQ] = oe; ev_v[ev_wr % EQ] = v; ev_x[ev_wr % EQ] = x;
      ev_wr = ev_wr + 1;
   end
endtask

always
  begin : ev_apply
     integer k, i;
     wait (ev_rd < ev_wr);
     i = ev_rd % EQ;
     if (ev_t[i] > $realtime) #(ev_t[i] - $realtime);
     if (ev_rd < ev_wr && i == ev_rd % EQ)
       begin
          for (k = 0; k < 4; k = k + 1)
            if (ev_m[i][k]) begin dev_oe[k] = ev_oe[i][k]; dev_v[k] = ev_x[i] ? 1'bx : ev_v[i][k]; end
          ev_rd = ev_rd + 1;
       end
  end

task dev_drive;
   input [3:0] oe;
   input [3:0] v;
   real        now;
   integer     k;
   begin
      now = $realtime;
      if ((dev_rt == 0.0) || dev_rel_now)
        begin
           for (k = 0; k < 4; k = k + 1) if (!oe[k]) dev_oe[k] = 1'b0;
        end
      else if (~oe != 4'h0)
        ev_push(now + dev_rt, ~oe, 4'h0, 4'h0, 1'b0);
      if (oe != 4'h0)
        begin
           if (dev_tco > dev_tho) ev_push(now + dev_rt + dev_tho, oe, oe, 4'h0, 1'b1);
           ev_push(now + dev_rt + dev_tco, oe, oe, v, 1'b0);
        end
   end
endtask

task dev_release;
   begin
      if (dev_mode == 0) dev_drive(4'h0, 4'h0);
      if (dev_mode == 1) sd_cs_release;
      if (dev_mode == 2) fl_cs_release;
   end
endtask

// The device presents the group of the next sampling edge
task dev_next;
   integer     e, f, c, L, N;
   reg   [1:0] kind, lanes;
   reg         cap;
   reg   [3:0] g;
   begin
      if (poll_unres && mon_ev) begin dev_wait = 1; e = -2; end
      else if (mon_ev) begin e = mon_e; f = mon_f; c = mon_c; end
      else if (q_mon < q_take) begin e = q_mon; f = 0; c = 0; end
      else e = -1;
      if (e >= 0)
        begin
           kind  = q_attr[e][9:8];
           lanes = q_attr[e][6:5];
           L     = (lanes == 2'd2) ? 4 : (lanes == 2'd1) ? 2 : 1;
           N     = q_attr[e][4:0] + 1;
           cap   = (RX_EN != 0) && ((kind == 2'd1) || (kind == 2'd3) || ((kind == 2'd0) && q_attr[e][10] && (lanes == 2'd0)));
           if (cap && !t_loop)
             begin
                if ((e != dv_e) || (f != dv_f))
                  begin
                     dv_e = e; dv_f = f;
                     if (rq_rd < rq_wr) begin dv = rq[rq_rd]; rq_rd = rq_rd + 1; end
                     else dv = rq_dflt;
                  end
                g = ser_grp(dv, c, L, N, t_lsb, t_bswap);
                if (L == 1) dev_drive(t_rxio0 ? 4'h1 : 4'h2, t_rxio0 ? {3'h0, g[0]} : {2'h0, g[0], 1'b0});
                else        dev_drive((L == 4) ? 4'hF : 4'h3, g);
             end
           else
             dev_drive(4'h0, 4'h0);
        end
      else if (e == -1)
        dev_drive(4'h0, 4'h0);
   end
endtask

task dev_launch;
   begin
      case (dev_mode)
        0: dev_next;
        1: sd_launch;
        2: fl_launch;
        default: ;
      endcase
   end
endtask

// At a transaction start a CPHA = 0 device presents its first bit
task dev_start;
   begin
      case (dev_mode)
        0: if (!t_cpha) dev_next;
        1: sd_cs_assert;
        2: fl_cs_assert;
        default: ;
      endcase
   end
endtask

// An entry taken while the device waits for one (CPHA = 0: its first bit
// must be on the lane before the leading edge)
always @(posedge pclk)
  if (tb_rst_done && (presetn === 1'b1) && tb_take && mon_txn && !t_cpha && !mon_ev && (dev_mode == 0))
    begin
       #0.01;
       dev_next;
    end


//----------------------------------------------------------------------------
// Configuration and entry tasks for the tests
//----------------------------------------------------------------------------

// XFER attribute word
function [15:0] xa;
   input [1:0] kind;                          // 0 TX, 1 RX, 2 DUMMY, 3 POLL
   input integer bits;                        // frame length 1..32
   input integer lanes;                       // 1, 2, 4
   input       capt;
   input       hold;
   input       none;
   input integer sel;
   begin
      xa = {sel[2:0], none, hold, capt, kind, 1'b0, (lanes == 4) ? 2'd2 : (lanes == 2) ? 2'd1 : 2'd0, bits[4:0] - 5'd1};
   end
endfunction

localparam [1:0] KTX = 2'd0, KRX = 2'd1, KDUMMY = 2'd2, KPOLL = 2'd3;

// Push one entry: waits for room, writes XFER when it changes, then TXDATA
reg ent_drain = 1'b1;                         // ent pops received words while it waits for room
task ent;
   input [15:0] attr;
   input [31:0] data;
   begin
      while (apb_spi_inst0.tx_level >= TX_DEPTH)
        begin
           if (ent_drain && (apb_spi_inst0.rx_level != 0) && (x_rd < x_wr)) rx_pop_chk(1);
           else @(posedge free_clk);
        end
      if ((attr & 16'hFF7F) != m_xfer) wr(R_XFER, {16'h0, attr});
      wr(R_TXDATA, data);
   end
endtask

// Shorthands on select sel, single lane
task ent_tx;   input integer bits; input [31:0] d; input hold; begin ent(xa(KTX, bits, 1, 1'b0, hold, 1'b0, 0), d); end endtask
task ent_txc;  input integer bits; input [31:0] d; input hold; begin ent(xa(KTX, bits, 1, 1'b1, hold, 1'b0, 0), d); end endtask
task ent_rx;   input integer bits; input integer n; input hold; begin ent(xa(KRX, bits, 1, 1'b0, hold, 1'b0, 0), n - 1); end endtask
task ent_dmy;  input integer n; input hold; begin ent(xa(KDUMMY, 8, 1, 1'b0, hold, 1'b0, 0), n - 1); end endtask
task ent_poll; input integer bits; input integer n; input hold; input [7:0] mask; input [7:0] val;
   begin ent(xa(KPOLL, bits, 1, 1'b0, hold, 1'b0, 0), {mask, val, n[15:0] - 16'd1}); end endtask

task ctrl_wr;
   input [31:0] v;
   begin
      wr(R_CTRL, v);
   end
endtask

// Divider (HALF = div + 1) and receive delay
task clk_set;
   input integer half;
   input integer rx_dly;
   begin
      wr(R_CLKDIV, {12'h0, rx_dly[3:0], 4'h0, half[11:0] - 12'd1});
   end
endtask

// Chip-select timing in half-periods (1..16) and polarity
task cs_set;
   input [7:0] pol;
   input integer setup;
   input integer hold;
   input integer inact;
   begin
      wr(R_CSCFG, {12'h0, inact[3:0] - 4'd1, hold[3:0] - 4'd1, setup[3:0] - 4'd1, pol});
   end
endtask


// Wait until the bus is idle (STATUS.IDLE), at most n pclk-free cycles
task wait_idle;
   input integer n;
   integer i;
   begin
      i = 0;
      while (!(apb_spi_inst0.idle_now === 1'b1) && (i < n))
        begin
           if (ent_drain && (apb_spi_inst0.rx_level != 0) && (x_rd < x_wr)) rx_pop_chk(1);
           else @(posedge free_clk);
           i = i + 1;
        end
      if (i >= n) tb_error("wait_idle: timeout");
      @(posedge free_clk); #1;
   end
endtask

// Wait until the engine is not busy and no entry waits (a select may be held)
task wait_quiet;
   input integer n;
   integer i;
   begin
      i = 0;
      while (((apb_spi_inst0.core_busy === 1'b1) || (apb_spi_inst0.e_valid_raw === 1'b1 && apb_spi_inst0.ctrl_en)) && (i < n))
        begin
           if (ent_drain && (apb_spi_inst0.rx_level != 0) && (x_rd < x_wr)) rx_pop_chk(1);
           else @(posedge free_clk);
           i = i + 1;
        end
      if (i >= n) tb_error("wait_quiet: timeout");
      @(posedge free_clk); #1;
   end
endtask

// Pop n received words and compare them with the monitor's expectation
task rx_pop_chk;
   input integer n;
   reg   [31:0] v;
   integer      i, t;
   begin
      for (i = 0; i < n; i = i + 1)
        begin
           t = 0;
           while ((apb_spi_inst0.rx_level == 0) && (t < 200000)) begin @(posedge free_clk); t = t + 1; end
           if (t >= 200000) tb_error("rx_pop_chk: receive FIFO stays empty");
           rdv(R_RXDATA, v);
           if (x_rd >= x_wr) begin
              $display("ERROR: rx_pop_chk: word 0x%h read, none expected %t ns", v, $time);
              error = error + 1;
           end else begin
              if (rx_auto && (v !== x_rx[x_rd])) begin
                 $display("ERROR: rx_pop_chk: word %0d read 0x%h, expected 0x%h %t ns", x_rd, v, x_rx[x_rd], $time);
                 error = error + 1;
              end
              rx_got[x_rd] = v;
              x_rd = x_rd + 1;
           end
        end
   end
endtask

// Pop everything the monitor expects
task rx_drain;
   begin
      rx_pop_chk(x_wr - x_rd);
   end
endtask

task chk;
   input            cond;
   input [80*8-1:0] what;
   begin
      if (!cond) tb_error(what);
   end
endtask

task chk32;
   input     [31:0] got;
   input     [31:0] exp;
   input [80*8-1:0] what;
   begin
      if (got !== exp) begin
         $display("ERROR: %0s: 0x%h, expected 0x%h %t ns", what, got, exp, $time);
         error = error + 1;
      end
   end
endtask

task wait_reset_done;
   input integer n;
   integer i;
   begin
      wait (tb_rst_done === 1'b1);
      for (i = 0; i < n; i = i + 1) @(posedge free_clk);
      #1;
   end
endtask

// Pulse the reset (asynchronous assertion, released on a free_clk edge)
task tb_reset_pulse;
   begin
      @(posedge free_clk); #3;
      presetn = 1'b0;
      repeat (3) @(posedge free_clk);
      #3;
      presetn = 1'b1;
      @(posedge free_clk);
      #1;
   end
endtask

// Check IRQ_PEND (the sticky part predicted by the model) and clear it
task irq_chk;
   input [31:0] exp_mask;                     // bits that must be set
   input [31:0] care;                         // bits compared
   reg   [31:0] v;
   begin
      rdv(R_IRQ_PEND, v);
      if ((v & care) !== (exp_mask & care)) begin
         $display("ERROR: IRQ_PEND 0x%h, expected 0x%h under 0x%h %t ns", v, exp_mask, care, $time);
         error = error + 1;
      end
      wr(R_IRQ_PEND, 32'h7C);
   end
endtask

// Standard set-up for a scripted single-device test: mode, divider, select timing, EN
task spi_setup;
   input [31:0] ctrl_bits;                    // CTRL without EN
   input integer half;
   input integer rx_dly;
   begin
      clk_set(half, rx_dly);
      cs_set(8'h00, 1, 1, 1);
      ctrl_wr(ctrl_bits | C_EN);
   end
endtask
