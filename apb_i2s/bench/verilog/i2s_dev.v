//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          File:      i2s_dev.v (included in tb_apb_i2s)
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// The serial-audio device side of the bench and the shadows the checks need,
// all written from the document (doc "Clocks and sample rate", "Frame
// format", "Sample packing", "Transmit and receive"):
//
//   - Register shadows: MDELEG (exp_resp_of) and CTRL.EN (m_en), updated by
//     snooping admitted APB writes; the device configuration (d_mdiv,
//     d_ratio, d_fmt, d_mclk_en) set by i2s_setup().
//   - Clock checker, cycle-exact on pclk while CTRL.EN: MCLK toggles every
//     MDIV cycles (low with MCLK_EN = 0), BCLK every MDIV * K cycles,
//     K = RATIO / (2 * S); LRCK and SD change only at the start launch (the
//     cycle after EN is set) and at the launch edges of BCLK; every output
//     is idle the cycle after EN is cleared.
//   - Monitor: at each BCLK sampling edge, checks LRCK against the frame
//     position (counted from the start of the stream, which begins with a
//     left slot) and collects SD into frames {right, left} (mon_l / mon_r,
//     mon_n frames); the bits outside the sample field must be 0.
//   - Source: launches the bits of its frames (src_l / src_r, from frame
//     src_base on at each start) on i2s_sd_i, dev_rt ns after each launch
//     edge (the round trip of the pads, the board and the device).
//----------------------------------------------------------------------------

localparam MON_N = 8192;                     // monitor and source frame storage

//----------------------------------------------------------------------------
// Register shadows
//----------------------------------------------------------------------------
reg  [1:0] m_wr_priv;
reg  [1:0] m_rd_priv;
reg        m_resp;
reg        m_en;
reg [31:0] t_ctrl;                           // last CTRL value written by ctrl_wr()

function exp_resp_of;
   input        write;
   input  [1:0] mode;
   input [31:0] addr;
   reg    [1:0] priv;
   reg          allowed;
   reg          is_mdeleg;
   begin
      priv      = (mode == MACHINE) ? 2'b11 : (mode == SUPERVISOR) ? 2'b01 : 2'b00;
      is_mdeleg = (addr[ADDRW-1:2] == 'h10);
      allowed   = is_mdeleg ? (mode == MACHINE) : (priv >= (write ? m_wr_priv : m_rd_priv));
      exp_resp_of = (!allowed && m_resp) ? ERROR : OK;
   end
endfunction

wire [1:0] snoop_mode = {pprot[0], psmode};
always @(posedge free_clk or negedge presetn)
  if (presetn !== 1'b1)
    begin
       m_wr_priv = MDELEG_RST[1:0];
       m_rd_priv = MDELEG_RST[3:2];
       m_resp    = MDELEG_RST[8];
       m_en      = 1'b0;
    end
  else if (psel && penable && pwrite && (exp_resp_of(1'b1, snoop_mode, {{(32-ADDRW){1'b0}}, paddr}) == OK) &&
           ((snoop_mode == MACHINE) || (paddr[ADDRW-1:2] != 'h10)))
    begin
       // A refused access with RESP = 0 is also OK: re-check admission
       if (paddr[ADDRW-1:2] == 'h10)
         begin
            if (pstrb[0])
              begin
                 m_wr_priv = (pwdata[1:0] == 2'b10) ? 2'b11 : pwdata[1:0];
                 m_rd_priv = (pwdata[3:2] == 2'b10) ? 2'b11 : pwdata[3:2];
              end
            if (pstrb[1]) m_resp = pwdata[8];
         end
       else if ((paddr[ADDRW-1:2] == 'h01) && pstrb[0] && admitted(1'b1, snoop_mode))
         m_en = pwdata[0];
    end

function admitted;
   input       write;
   input [1:0] mode;
   reg   [1:0] priv;
   begin
      priv     = (mode == MACHINE) ? 2'b11 : (mode == SUPERVISOR) ? 2'b01 : 2'b00;
      admitted = (priv >= (write ? m_wr_priv : m_rd_priv));
   end
endfunction

//----------------------------------------------------------------------------
// Device configuration
//----------------------------------------------------------------------------
integer    d_mdiv;                           // MDIV (1..256)
integer    d_ratio;                          // 256, 384, 512, 768, 1024
reg  [5:0] d_fmt;                            // {SLOT16, FSYNC, LRCK_INV, RJUST, DELAY, BCLK_INV}
reg        d_mclk_en;
integer    dev_rt;                           // round trip, ns

initial
  begin
     d_mdiv    = 1;
     d_ratio   = 256;
     d_fmt     = F_I2S;
     d_mclk_en = 1'b0;
     dev_rt    = 10;
     t_ctrl    = 32'h0;
  end

function integer slot_w;  input [5:0] f; slot_w = f[5] ? 16 : 32; endfunction
function integer bk_of;   input [5:0] f; input integer ratio; bk_of = ratio / (2 * slot_w(f)); endfunction
function integer ratio_of; input [2:0] s;
   ratio_of = (s == 3'd1) ? 384 : (s == 3'd2) ? 512 : (s == 3'd3) ? 768 : (s == 3'd4) ? 1024 : 256;
endfunction

// Stream bit k (0 .. 2S-1) of frame {r, l}
function stream_bit;
   input [15:0] l;
   input [15:0] r;
   input integer k;
   input  [5:0] f;
   integer      s, j, b;
   reg   [15:0] smp;
   begin
      s   = slot_w(f);
      smp = (k >= s) ? r : l;
      j   = k % s;
      if (s == 16)       b = j;
      else if (f[2])     b = (j >= 16) ? (j - 16) : -1;
      else               b = (j < 16)  ? j        : -1;
      stream_bit = (b < 0) ? 1'b0 : smp[15 - b];
   end
endfunction

//----------------------------------------------------------------------------
// Clock checker (cycle-exact, one #1 after each rising pclk edge)
//----------------------------------------------------------------------------
// ck_run models the engine from the document: it starts on the edge after
// the write that sets CTRL.EN (cycle 0, the launch of position 0). A frame
// boundary (the launch of position 0) taken with EN clear arms the stop; the
// engine then stops at the launch edge of position D (D = 1 with DELAY = 1,
// except right-justified 32-bit slots; D = 0: at that boundary itself),
// outputs idle on that edge, and stays busy (STATUS.RUNNING, clock request)
// for one more BCLK half-period, during which a start waits. The EN value
// that decides an edge is the one before that edge (ck_en_prev).
integer    ck_cyc;
integer    ck_pos;                           // position launched last
reg        ck_run;
reg        ck_arm;                           // a boundary was taken with EN clear
integer    ck_tail;                          // busy cycles left after a stop
reg        ck_pend;                          // EN set: the start is on the next edge
reg        ck_en_prev;                       // CTRL.EN before the current edge
reg        ck_mclk_p, ck_bclk_p, ck_lrck_p, ck_sd_p;
integer    ck_k, ck_s, ck_d, ck_np;
reg        ck_launch, ck_mtog, ck_btog, ck_stop;
reg        ck_xfer_q;                        // a transfer ended on the last edge
integer    ck_mclk_age;                      // cycles since d_mclk_en last changed
reg        ck_mclk_en_p;
wire       ck_busy = ck_run | (ck_tail > 0); // STATUS.RUNNING / the engine's clock request

function lrck_idle_of; input [5:0] f; lrck_idle_of = f[4] ? f[3] : ~f[3]; endfunction
function dly_of;       input [5:0] f; dly_of = f[1] & ~(f[2] & ~f[5]); endfunction

initial begin ck_cyc = 0; ck_pos = 0; ck_run = 0; ck_arm = 0; ck_tail = 0; ck_pend = 0; ck_en_prev = 0;
              ck_xfer_q = 0; ck_mclk_age = 0; ck_mclk_en_p = 0; end

always @(posedge free_clk)
  begin
     #1;
     if (tb_rst_done && (presetn === 1'b1))
       begin
          ck_mclk_age  = (d_mclk_en !== ck_mclk_en_p) ? 0 : ck_mclk_age + 1;
          ck_mclk_en_p = d_mclk_en;
          ck_s = slot_w(d_fmt);
          ck_k = bk_of(d_fmt, d_ratio);
          ck_d = dly_of(d_fmt);
          if (ck_tail > 0) ck_tail = ck_tail - 1;
          if (ck_pend && !ck_run)
            begin
               // start: position 0 launched on this edge
               ck_run = 1; ck_cyc = 0; ck_pos = 0; ck_arm = 0;
            end
          else if (ck_run)
            begin
               ck_cyc  = ck_cyc + 1;
               ck_mtog = (ck_cyc % d_mdiv) == 0;
               ck_btog = (ck_cyc % (d_mdiv * ck_k)) == 0;
               ck_launch = ck_btog && (i2s_bclk === d_fmt[0]);
               ck_np   = (ck_pos + 1) % (2 * ck_s);
               ck_stop = ck_launch && !ck_en_prev && ((ck_d == 0) ? (ck_np == 0) : ((ck_np == 1) && ck_arm));
               if (ck_stop)
                 begin
                    // stop on this launch edge: every output idle, then the tail
                    ck_run  = 0;
                    ck_tail = d_mdiv * ck_k;
                    if ((i2s_mclk !== 1'b0) || (i2s_bclk !== d_fmt[0]) || (i2s_lrck !== lrck_idle_of(d_fmt)) || (i2s_sd_o !== 1'b0))
                      tb_error("CLK -- outputs not idle at the stop edge");
                 end
               else
                 begin
                    // MCLK changes only at its toggle instants; with MCLK_EN
                    // steady it toggles at every one (or stays low)
                    if ((i2s_mclk !== ck_mclk_p) && !ck_mtog)
                      begin $display("ERROR: CLK -- MCLK changed at cycle %0d (MDIV %0d) %t ns", ck_cyc, d_mdiv, $time); error = error + 1; end
                    if ((ck_mclk_age > 2 * d_mdiv) && (ck_cyc > d_mdiv) &&
                        (d_mclk_en ? (ck_mtog && (i2s_mclk === ck_mclk_p)) : (i2s_mclk !== 1'b0)))
                      begin $display("ERROR: CLK -- MCLK at cycle %0d (MDIV %0d, MCLK_EN %b) %t ns", ck_cyc, d_mdiv, d_mclk_en, $time); error = error + 1; end
                    if ((i2s_bclk !== ck_bclk_p) !== ck_btog)
                      begin $display("ERROR: CLK -- BCLK at cycle %0d (MDIV %0d, K %0d) %t ns", ck_cyc, d_mdiv, ck_k, $time); error = error + 1; end
                    if (ck_launch)
                      begin
                         ck_pos = ck_np;
                         if (ck_np == 0) ck_arm = !ck_en_prev;
                      end
                    else if ((i2s_lrck !== ck_lrck_p) || (i2s_sd_o !== ck_sd_p))
                      begin $display("ERROR: CLK -- LRCK / SD changed away from a launch edge, cycle %0d %t ns", ck_cyc, $time); error = error + 1; end
                 end
            end
          else if (!ck_xfer_q &&
                   ((i2s_mclk !== 1'b0) || (i2s_bclk !== d_fmt[0]) || (i2s_lrck !== lrck_idle_of(d_fmt)) || (i2s_sd_o !== 1'b0)))
            tb_error("CLK -- outputs not idle while stopped");
          ck_pend    = m_en && !ck_run && (ck_tail == 0);
          ck_en_prev = m_en;
          ck_mclk_p  = i2s_mclk;
          ck_bclk_p  = i2s_bclk;
          ck_lrck_p  = i2s_lrck;
          ck_sd_p    = i2s_sd_o;
       end
     else
       begin
          ck_run     = 1'b0;
          ck_pend    = 1'b0;
          ck_tail    = 0;
          ck_arm     = 1'b0;
          ck_en_prev = 1'b0;
       end
  end

// A transfer ended on the last edge (the idle levels follow a FORMAT write
// one edge later)
always @(posedge free_clk or negedge presetn)
  if (presetn !== 1'b1) ck_xfer_q <= 1'b0;
  else                  ck_xfer_q <= psel && penable;

//----------------------------------------------------------------------------
// Monitor: frames decoded from i2s_sd_o
//----------------------------------------------------------------------------
reg [15:0] mon_l [0:MON_N-1];
reg [15:0] mon_r [0:MON_N-1];
integer    mon_n;                            // frames decoded since mon_clear
integer    mon_cnt;                          // sampling edges since the start of the stream
integer    dev_frames;                       // frames started since the start of the stream
reg [63:0] mon_bits;                         // stream bits of the frame being decoded
reg        mon_en_d;
integer    mon_pos, mon_k, mon_s;
reg        mon_lr_exp;

initial begin mon_n = 0; mon_cnt = 0; dev_frames = 0; mon_bits = 64'h0; mon_en_d = 0; end

task mon_clear; begin mon_n = 0; end endtask

task mon_finalize;
   integer kk, ss, jj, bb;
   reg [15:0] l, r;
   reg        pad_err;
   begin
      ss = slot_w(d_fmt);
      l = 16'h0; r = 16'h0; pad_err = 1'b0;
      for (kk = 0; kk < 2 * ss; kk = kk + 1)
        begin
           jj = kk % ss;
           if (ss == 16)    bb = jj;
           else if (d_fmt[2]) bb = (jj >= 16) ? (jj - 16) : -1;
           else             bb = (jj < 16)  ? jj        : -1;
           if (bb < 0)
             begin
                if (mon_bits[kk]) pad_err = 1'b1;
             end
           else if (kk >= ss) r[15 - bb] = mon_bits[kk];
           else               l[15 - bb] = mon_bits[kk];
        end
      if (pad_err) tb_error("MON -- a bit outside the sample field is not 0");
      if (mon_n < MON_N) begin mon_l[mon_n] = l; mon_r[mon_n] = r; mon_n = mon_n + 1; end
      mon_bits = 64'h0;
   end
endtask

always @(i2s_bclk)
  if (tb_rst_done && (presetn === 1'b1) && ck_run && (i2s_bclk === ~d_fmt[0]))
    begin
       mon_s   = slot_w(d_fmt);
       mon_pos = mon_cnt % (2 * mon_s);
       if (mon_pos == 0) dev_frames = dev_frames + 1;
       mon_lr_exp = d_fmt[4] ? ((mon_pos == 0) ^ d_fmt[3]) : ((mon_pos >= mon_s) ^ d_fmt[3]);
       if (i2s_lrck !== mon_lr_exp)
         begin $display("ERROR: MON -- LRCK %b at position %0d, expected %b %t ns", i2s_lrck, mon_pos, mon_lr_exp, $time); error = error + 1; end
       mon_k = mon_pos - dly_of(d_fmt);
       if (mon_k < 0)
         begin
            if (mon_cnt == 0)
              begin
                 if (i2s_sd_o !== 1'b0) tb_error("MON -- SD not 0 before the first frame");
              end
            else
              begin
                 mon_bits[2 * mon_s - 1] = i2s_sd_o;
                 mon_finalize;
              end
         end
       else
         begin
            mon_bits[mon_k] = i2s_sd_o;
            if (mon_k == 2 * mon_s - 1) mon_finalize;
         end
       mon_cnt = mon_cnt + 1;
    end

always @(posedge free_clk)
  begin
     #2;
     if (ck_run && !mon_en_d) begin mon_cnt = 0; dev_frames = 0; mon_bits = 64'h0; end
     mon_en_d = ck_run;
  end

//----------------------------------------------------------------------------
// Source: frames launched on i2s_sd_i
//----------------------------------------------------------------------------
reg [15:0] src_l [0:MON_N-1];
reg [15:0] src_r [0:MON_N-1];
integer    src_base;                         // frame 0 of the current stream
integer    src_cnt;                          // launches since the start of the stream
integer    src_i;
reg        src_en_d;

initial
  begin
     for (src_i = 0; src_i < MON_N; src_i = src_i + 1)
       begin
          src_l[src_i] = $urandom;
          src_r[src_i] = $urandom;
       end
     src_base   = 0;
     src_cnt    = 0;
     src_en_d   = 0;
     i2s_sd_dev = 1'b0;
  end

task src_launch;
   integer ss, pos, k, fr;
   reg     b;
   begin
      ss  = slot_w(d_fmt);
      pos = src_cnt % (2 * ss);
      k   = pos - dly_of(d_fmt);
      if (k < 0)
        begin
           fr = (src_cnt / (2 * ss)) - 1;
           k  = 2 * ss - 1;
        end
      else
        fr = src_cnt / (2 * ss);
      b = (fr < 0) ? 1'b0 : stream_bit(src_l[(src_base + fr) % MON_N], src_r[(src_base + fr) % MON_N], k, d_fmt);
      i2s_sd_dev <= #(dev_rt) b;
      src_cnt = src_cnt + 1;
   end
endtask

// Index of the source frame launched as frame fr of the current stream
function integer src_idx; input integer fr; src_idx = (src_base + fr) % MON_N; endfunction

always @(posedge free_clk)
  begin
     #2;
     if (ck_run && !src_en_d)
       begin
          src_base = (src_base + 1000) % MON_N;
          src_cnt  = 0;
          src_launch;
       end
     src_en_d = ck_run;
  end

always @(i2s_bclk)
  if (tb_rst_done && (presetn === 1'b1) && ck_run && (i2s_bclk === d_fmt[0]))
    src_launch;

//----------------------------------------------------------------------------
// Helpers for the tests
//----------------------------------------------------------------------------

task ctrl_wr;
   input [31:0] v;
   begin
      wr(R_CTRL, v);
      t_ctrl = v;
   end
endtask

// Configure clocks and format (CTRL.EN must be 0); keeps the other CTRL bits
integer rx_dly;                              // CLKDIV.RX_DLY written by i2s_setup
initial rx_dly = 0;

task i2s_setup;
   input integer mdiv;          // 1..256
   input  [2:0]  rsel;          // 0..4
   input  [5:0]  fmt;
   input         mclk_en;
   begin
      if (m_en || ck_busy) tb_error("i2s_setup with the engine running");
      wr(R_CLKDIV, {16'h0, rx_dly[3:0], 1'b0, rsel, mdiv[7:0] - 8'd1});
      d_mdiv    = mdiv;
      d_ratio   = ratio_of(rsel);
      wr(R_FORMAT, {26'h0, fmt});
      d_fmt     = fmt;
      ctrl_wr((t_ctrl & ~C_MCLK_EN) | (mclk_en ? C_MCLK_EN : 32'h0));
      d_mclk_en = mclk_en;
   end
endtask

// pclk cycles of one frame with the current configuration
function integer frame_cycles; input dummy; frame_cycles = d_mdiv * d_ratio * 2; endfunction

// Wait for n more frame starts on the monitor (stream running)
task wait_frames;
   input integer n;
   integer target;
   begin
      target = dev_frames + n;
      while (dev_frames < target) @(posedge free_clk);
   end
endtask

// Bit k of a FIFO word, as a frame {right, left} for stereo, or the sample
// pair of a mono word
function [31:0] mono_frame;   // frame sent for mono sample index (0: low half, 1: high)
   input [31:0] w;
   input        hi;
   mono_frame = hi ? {w[31:16], w[31:16]} : {w[15:0], w[15:0]};
endfunction

// TX check: the monitor frames hold exp_tx[0 .. n-1] contiguously, after
// zero frames only
reg  [31:0] exp_tx [0:MON_N-1];
integer     exp_tx_n;

task tx_check;
   input integer n;
   integer i, j, first;
   begin
      first = -1;
      for (i = 0; (i < mon_n) && (first < 0); i = i + 1)
        if ({mon_r[i], mon_l[i]} == exp_tx[0]) first = i;
        else if ({mon_r[i], mon_l[i]} != 32'h0)
          begin
             $display("ERROR: TX -- frame %0d is 0x%h before the stream, expected silence %t ns", i, {mon_r[i], mon_l[i]}, $time);
             error = error + 1;
             i = mon_n;
          end
      if (first < 0)
        begin
           $display("ERROR: TX -- first frame 0x%h never seen (%0d frames decoded) %t ns", exp_tx[0], mon_n, $time); error = error + 1;
           for (i = 0; (i < mon_n) && (i < 12); i = i + 1) $display("       frame %0d: 0x%h", i, {mon_r[i], mon_l[i]});
           for (i = 0; (i < n) && (i < 4); i = i + 1) $display("       expected %0d: 0x%h", i, exp_tx[i]);
        end
      else
        for (j = 0; j < n; j = j + 1)
          if (first + j >= mon_n)
            begin $display("ERROR: TX -- only %0d of %0d frames decoded %t ns", j, n, $time); error = error + 1; j = n; end
          else if ({mon_r[first + j], mon_l[first + j]} !== exp_tx[j])
            begin
               $display("ERROR: TX -- frame %0d: 0x%h, expected 0x%h %t ns", j, {mon_r[first + j], mon_l[first + j]}, exp_tx[j], $time);
               error = error + 1;
               j = n;
            end
      if ((first >= 0) && (error == 0))
        $display("PASS:  TX -- %0d frames from frame %0d", n, first);
   end
endtask

// Expected RX word from the source frames of the current stream
function [15:0] mono_pick;
   input [15:0] l;
   input [15:0] r;
   input  [1:0] sel;
   reg   [16:0] sum;
   begin
      sum = {l[15], l} + {r[15], r};
      mono_pick = (sel == 2'd1) ? r : (sel == 2'd2) ? sum[16:1] : l;
   end
endfunction

function [31:0] rx_exp_word;
   input integer fr;            // first frame of the word, in the current stream
   input         mono;
   input   [1:0] sel;
   begin
      if (!mono) rx_exp_word = {src_r[src_idx(fr)], src_l[src_idx(fr)]};
      else       rx_exp_word = {mono_pick(src_l[src_idx(fr + 1)], src_r[src_idx(fr + 1)], sel),
                                mono_pick(src_l[src_idx(fr)],     src_r[src_idx(fr)],     sel)};
   end
endfunction

// RX check: words got[0 .. n-1] are consecutive received words of the
// current stream
reg  [31:0] got_rx [0:MON_N-1];

task rx_check;
   input integer n;
   input         mono;
   input   [1:0] sel;
   integer       f, i, first, step;
   begin
      step  = mono ? 2 : 1;
      first = -1;
      for (f = 0; (f < 4000) && (first < 0); f = f + 1)
        if (rx_exp_word(f, mono, sel) == got_rx[0]) first = f;
      if (first < 0)
        begin
           $display("ERROR: RX -- word 0x%h matches no source frame %t ns", got_rx[0], $time); error = error + 1;
           for (i = 0; (i < n) && (i < 4); i = i + 1) $display("       got %0d: 0x%h", i, got_rx[i]);
           for (f = 0; f < 6; f = f + 1)
             $display("       frame %0d: l=%h r=%h word=%h", f, src_l[src_idx(f)], src_r[src_idx(f)], rx_exp_word(f, mono, sel));
        end
      else
        begin
           for (i = 1; i < n; i = i + 1)
             if (got_rx[i] !== rx_exp_word(first + i * step, mono, sel))
               begin
                  $display("ERROR: RX -- word %0d: 0x%h, expected 0x%h %t ns", i, got_rx[i], rx_exp_word(first + i * step, mono, sel), $time);
                  error = error + 1;
                  i = n;
               end
           $display("PASS:  RX -- %0d words checked from stream frame %0d", n, first);
        end
   end
endtask

// Push n random words into TXDATA and the expected-frame list (stereo: one
// frame per word; mono: two)
task tx_push_random;
   input integer n;
   input         mono;
   integer       i;
   reg    [31:0] w;
   begin
      for (i = 0; i < n; i = i + 1)
        begin
           w = $urandom;
           if (w == 32'h0) w = 32'h1;
           if (w[15:0] == 16'h0) w[0] = 1'b1;
           wr(R_TXDATA, w);
           if (!mono) begin exp_tx[exp_tx_n] = w; exp_tx_n = exp_tx_n + 1; end
           else
             begin
                exp_tx[exp_tx_n]     = mono_frame(w, 1'b0);
                exp_tx[exp_tx_n + 1] = mono_frame(w, 1'b1);
                exp_tx_n = exp_tx_n + 2;
             end
        end
   end
endtask

// Read n words from RXDATA into got_rx
task rx_read;
   input integer n;
   integer       i;
   reg    [31:0] v;
   begin
      for (i = 0; i < n; i = i + 1)
        begin
           rdv(R_RXDATA, v);
           got_rx[i] = v;
        end
   end
endtask

// Wait until the receive FIFO holds at least n words
task rx_wait_level;
   input integer n;
   reg   [31:0]  s;
   integer       guard;
   begin
      guard = 0;
      rdv(R_STATUS, s);
      while ((s[24:16] < n) && (guard < 100000))
        begin
           repeat (20) @(posedge free_clk);
           rdv(R_STATUS, s);
           guard = guard + 1;
        end
      if (guard >= 100000) tb_error("RX -- receive FIFO level not reached");
   end
endtask

// Wait until the transmit FIFO is empty
task tx_wait_empty;
   reg   [31:0]  s;
   integer       guard;
   begin
      guard = 0;
      rdv(R_STATUS, s);
      while ((s[8:0] != 0) && (guard < 100000))
        begin
           repeat (20) @(posedge free_clk);
           rdv(R_STATUS, s);
           guard = guard + 1;
        end
      if (guard >= 100000) tb_error("TX -- transmit FIFO never empty");
   end
endtask

// Stop the stream: TX_ON / RX_ON off, wait two frames, EN off, wait until
// the engine has stopped
task i2s_stop;
   begin
      ctrl_wr(t_ctrl & ~(C_TX_ON | C_RX_ON));
      wait_frames(2);
      ctrl_wr(t_ctrl & ~C_EN);
      while (ck_busy) @(posedge free_clk);
      repeat (2) @(posedge free_clk);
   end
endtask

// Start the engine with the given extra CTRL bits
task i2s_start;
   input [31:0] bits;
   begin
      ctrl_wr(t_ctrl | C_EN | bits);
      while (!ck_run || !mon_en_d || !src_en_d) @(posedge free_clk);
      #3;
   end
endtask

//----------------------------------------------------------------------------
// Generic test helpers
//----------------------------------------------------------------------------

task chk;
   input            cond;
   input [80*8-1:0] msg;
   begin
      if (cond !== 1'b1) begin $display("ERROR: %0s %t ns", msg, $time); error = error + 1; end
   end
endtask

task chk32;
   input     [31:0] val;
   input     [31:0] exp;
   input [80*8-1:0] msg;
   begin
      if (val !== exp) begin $display("ERROR: %0s -- 0x%h, expected 0x%h %t ns", msg, val, exp, $time); error = error + 1; end
   end
endtask

// Wait for the end of the first reset, then n more edges
task wait_reset_done;
   input integer n;
   begin
      // the power-on reset pulse itself, so no variable's initial value matters
      wait (presetn === 1'b0);
      wait (presetn === 1'b1);
      wait (tb_rst_done === 1'b1);
      repeat (n) @(posedge free_clk);
      #1;
   end
endtask

// Device-side defaults (after a reset)
task dev_defaults;
   begin
      t_ctrl    = 32'h0;
      d_mdiv    = 1;
      d_ratio   = 256;
      d_fmt     = F_I2S;
      d_mclk_en = 1'b0;
      rx_dly    = 0;
      dev_rt    = 10;
      exp_tx_n  = 0;
      mon_n     = 0;
   end
endtask

// Pulse the reset (a few edges), then restore the bench defaults
task tb_reset_pulse;
   begin
      @(posedge free_clk); #3;
      presetn = 1'b0;
      repeat (3) @(posedge free_clk);
      #3;
      presetn = 1'b1;
      dev_defaults;
      repeat (2) @(posedge free_clk);
      #1;
   end
endtask

// STATUS fields
task rd_levels;
   output integer txl;
   output integer rxl;
   reg   [31:0]   s;
   begin
      rdv(R_STATUS, s);
      txl = s[8:0];
      rxl = s[24:16];
   end
endtask

// Fill the receive FIFO with n words from the source (RX_ON for long enough), then RX off
task rx_fill;
   input integer n;
   begin
      i2s_start(C_RX_ON);
      rx_wait_level(n);
      i2s_stop;
   end
endtask

initial exp_tx_n = 0;
