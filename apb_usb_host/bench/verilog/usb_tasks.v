//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    usb_tasks
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : usb_tasks.v
// Module Description : Register map, constants and test helpers of the
//                      apb_usb_host testbench, from doc/apb_usb_host.md.
//
//   - MDELEG mirror: every admitted Machine-mode write to MDELEG updates it
//     (a reserved privilege code 2'b10 is stored as Machine, 2'b11), a reset
//     reloads MDELEG_RST; exp_resp_of(write, mode, addr) and
//     admitted(write, mode, addr) follow it.
//   - State history: every change of STATUS.STATE is logged with its time in
//     st_hist[] / st_time[] (st_n entries since the last st_hist_clear);
//     st_seen(s) and st_count(s) query it, st_dur_last(s) gives the length of
//     the last completed visit of a state in ns.
//   - Event controls: a test waits on a model event with an edge-triggered
//     control on one of its toggles (dev.ev_tgl, dev.setup_tgl, dev.ack_tgl),
//     on a state change with st_tgl, and reads bus activity from tb_act_t.
//     Never a level event control on a variable its body does not read: a
//     scheduler such as Verilator's runs that block on what its body reads,
//     not on its sensitivity list.
//   - Waits are in milliseconds of simulated time; a wait that times out is
//     an error and returns. A state wait returns 1 ns after the change, once
//     the state history has logged it.
//----------------------------------------------------------------------------

// Register map (doc "Register map")
localparam     [31:0] R_INFO        = 32'h00;
localparam     [31:0] R_CTRL        = 32'h04;
localparam     [31:0] R_CMD         = 32'h08;
localparam     [31:0] R_STATUS      = 32'h0C;
localparam     [31:0] R_IRQ_EN      = 32'h10;
localparam     [31:0] R_IRQ_PEND    = 32'h14;
localparam     [31:0] R_DEV_ID      = 32'h18;
localparam     [31:0] R_DEV_IF      = 32'h1C;
localparam     [31:0] R_DEV_EP      = 32'h20;
localparam     [31:0] R_REPORT_INFO = 32'h24;
localparam     [31:0] R_XFER        = 32'h28;
localparam     [31:0] R_SETUP0      = 32'h2C;
localparam     [31:0] R_SETUP1      = 32'h30;
localparam     [31:0] R_DIAG0       = 32'h34;
localparam     [31:0] R_DIAG1       = 32'h38;
localparam     [31:0] R_REPORT0     = 32'h40;     // REPORT[n] at 0x40 + 4n
localparam     [31:0] R_XDATA0      = 32'h80;     // XDATA[n]  at 0x80 + 4n
localparam     [31:0] R_MDELEG      = 32'hC0;

// CTRL fields
localparam     [31:0] C_EN          = 32'h001;
localparam     [31:0] C_BOOT        = 32'h002;
localparam     [31:0] C_IDLE0       = 32'h004;
localparam     [31:0] CTRL_RST      = 32'h006;

// CMD bits
localparam     [31:0] K_RESTART     = 32'h1;
localparam     [31:0] K_XFER_START  = 32'h2;
localparam     [31:0] K_XFER_NEXT   = 32'h4;
localparam     [31:0] K_XFER_ABORT  = 32'h8;

// IRQ_PEND bits
localparam     [31:0] I_REPORT      = 32'h01;
localparam     [31:0] I_READY       = 32'h02;
localparam     [31:0] I_DETACH      = 32'h04;
localparam     [31:0] I_FAIL        = 32'h08;
localparam     [31:0] I_XFER_PKT    = 32'h10;
localparam     [31:0] I_XFER_DONE   = 32'h20;
localparam     [31:0] I_STATE       = 32'h40;
localparam     [31:0] I_ALL         = 32'h7F;

// STATUS.STATE
localparam      [3:0] S_OFF         = 4'd0;
localparam      [3:0] S_DETACHED    = 4'd1;
localparam      [3:0] S_DEBOUNCE    = 4'd2;
localparam      [3:0] S_RESET       = 4'd3;
localparam      [3:0] S_RECOVERY    = 4'd4;
localparam      [3:0] S_ENUM        = 4'd5;
localparam      [3:0] S_RUN         = 4'd6;
localparam      [3:0] S_BACKOFF     = 4'd7;
localparam      [3:0] S_FAILED      = 4'd8;
localparam      [3:0] S_UNSUPPORTED = 4'd9;
localparam      [3:0] S_FS_DETECTED = 4'd10;

// STATUS.ERR
localparam      [3:0] E_NONE        = 4'd0;
localparam      [3:0] E_TIMEOUT     = 4'd1;
localparam      [3:0] E_CRC         = 4'd2;
localparam      [3:0] E_UNEXPECTED  = 4'd3;
localparam      [3:0] E_STALL       = 4'd4;
localparam      [3:0] E_PROGRESS    = 4'd5;
localparam      [3:0] E_MALFORMED   = 4'd6;
localparam      [3:0] E_HUB         = 4'd7;
localparam      [3:0] E_NO_HID      = 4'd8;
localparam      [3:0] E_MPS         = 4'd9;

// XFER.RESULT
localparam      [2:0] X_OK          = 3'd0;
localparam      [2:0] X_STALL       = 3'd1;
localparam      [2:0] X_ERROR       = 3'd2;
localparam      [2:0] X_ABORTED     = 3'd3;
localparam      [2:0] X_DETACHED    = 3'd4;
localparam      [2:0] X_REFUSED     = 3'd5;

// Timing of the port (doc "Bus timing"), ns: a duration of N ms lasts N to
// N+1 ms; T_LAT is the latency allowance of a measurement through STATUS
localparam real       T_MS          = 1.0e6;
localparam real       T_LAT         = 10.0e3;
localparam real       T_BIT         = 2000.0 / 3.0;
localparam real       T_DEBOUNCE    = 100.0e6;
localparam real       T_RESET       = 60.0e6;
localparam real       T_RECOVERY    = 10.0e6;
localparam real       T_BACKOFF     = 100.0e6;

//----------------------------------------------------------------------------
// MDELEG mirror and expected responses
//----------------------------------------------------------------------------
reg [1:0] m_wr_priv;
reg [1:0] m_rd_priv;
reg       m_resp;

initial
  begin
     m_wr_priv = MDELEG_RST[1:0];
     m_rd_priv = MDELEG_RST[3:2];
     m_resp    = MDELEG_RST[8];
  end

always @(negedge presetn)
  begin
     m_wr_priv = MDELEG_RST[1:0];
     m_rd_priv = MDELEG_RST[3:2];
     m_resp    = MDELEG_RST[8];
  end

// An admitted MDELEG write takes effect at the edge that ends its ACCESS cycle
always @(posedge free_clk)
  if ((presetn === 1'b1) && psel && penable && pwrite && pprot[0] && !psmode &&
      (paddr[ADDRW-1:2] == (R_MDELEG >> 2)))
    begin
       if (pstrb[0])
         begin
            m_wr_priv = (pwdata[1:0] == 2'b10) ? 2'b11 : pwdata[1:0];
            m_rd_priv = (pwdata[3:2] == 2'b10) ? 2'b11 : pwdata[3:2];
         end
       if (pstrb[1])
         m_resp = pwdata[8];
    end

function admitted;
   input        write;
   input  [1:0] mode;
   input [31:0] addr;
   reg    [1:0] priv;
   begin
      priv     = (mode == MACHINE) ? 2'b11 : (mode == SUPERVISOR) ? 2'b01 : 2'b00;
      admitted = (addr[ADDRW-1:2] == (R_MDELEG >> 2)) ? (mode == MACHINE)
                                                       : (priv >= (write ? m_wr_priv : m_rd_priv));
   end
endfunction

function exp_resp_of;
   input        write;
   input  [1:0] mode;
   input [31:0] addr;
   begin
      exp_resp_of = (!admitted(write, mode, addr) && m_resp) ? ERROR : OK;
   end
endfunction

//----------------------------------------------------------------------------
// Names
//----------------------------------------------------------------------------
function [8*11-1:0] st_name;
   input integer s;
   case (s)
     0:       st_name = "off";
     1:       st_name = "detached";
     2:       st_name = "debounce";
     3:       st_name = "reset";
     4:       st_name = "recovery";
     5:       st_name = "enum";
     6:       st_name = "run";
     7:       st_name = "backoff";
     8:       st_name = "failed";
     9:       st_name = "unsupported";
     10:      st_name = "fs_detected";
     default: st_name = "invalid";
   endcase
endfunction

function [8*9-1:0] irq_name;
   input integer k;
   case (k)
     0:       irq_name = "report";
     1:       irq_name = "ready";
     2:       irq_name = "detach";
     3:       irq_name = "fail";
     4:       irq_name = "xfer_pkt";
     5:       irq_name = "xfer_done";
     6:       irq_name = "state";
     default: irq_name = "invalid";
   endcase
endfunction

//----------------------------------------------------------------------------
// Checks
//----------------------------------------------------------------------------
task chk;
   input            cond;
   input [80*8-1:0] msg;
   begin
      if (cond !== 1'b1)
        begin
           $display("ERROR: %0s %t ns", msg, $time);
           error = error + 1;
        end
   end
endtask

task chk32;
   input     [31:0] got;
   input     [31:0] exp;
   input [80*8-1:0] msg;
   begin
      if (got !== exp)
        begin
           $display("ERROR: %0s: 0x%h, expected 0x%h %t ns", msg, got, exp, $time);
           error = error + 1;
        end
   end
endtask

// Real-time window check: lo <= t <= hi (ns)
task chk_range;
   input       real t;
   input       real lo;
   input       real hi;
   input [80*8-1:0] msg;
   begin
      if ((t < lo) || (t > hi))
        begin
           $display("ERROR: %0s: %0.1f ns, expected %0.1f to %0.1f ns %t ns", msg, t, lo, hi, $time);
           error = error + 1;
        end
   end
endtask

//----------------------------------------------------------------------------
// Waits
//----------------------------------------------------------------------------
task wait_reset_done;
   input integer n;
   begin
      wait (tb_rst_done === 1'b1);
      repeat (n) @(posedge free_clk);
      #1;
   end
endtask

task wait_ms;
   input real ms;
   #(ms * T_MS);
endtask

// Wait until STATUS.STATE == s, at most ms milliseconds
task wait_state;
   input  [3:0] s;
   input   real ms;
   reg          to;
   begin
      to = 1'b0;
      if (tb_state !== s)
        begin : w
           fork
              begin : w_ev
                 wait (tb_state === s);
                 disable w_to;
              end
              begin : w_to
                 #(ms * T_MS);
                 to = 1'b1;
                 disable w_ev;
              end
           join
        end
      if (to)
        begin
           $display("ERROR: STATE %0s not reached within %0.1f ms (STATE %0s) %t ns", st_name(s), ms,
                    st_name(tb_state), $time);
           error = error + 1;
        end
      #1;                                    // the state history has logged the change
   end
endtask

// Wait until STATUS.STATE leaves s, at most ms milliseconds
task wait_state_not;
   input  [3:0] s;
   input   real ms;
   reg          to;
   begin
      to = 1'b0;
      if (tb_state === s)
        begin : w
           fork
              begin : w_ev
                 wait (tb_state !== s);
                 disable w_to;
              end
              begin : w_to
                 #(ms * T_MS);
                 to = 1'b1;
                 disable w_ev;
              end
           join
        end
      if (to)
        begin
           $display("ERROR: STATE still %0s after %0.1f ms %t ns", st_name(s), ms, $time);
           error = error + 1;
        end
      #1;                                    // the state history has logged the change
   end
endtask

//----------------------------------------------------------------------------
// State history
//----------------------------------------------------------------------------
localparam            STH           = 1024;
reg             [3:0] st_hist [0:STH-1];
real                  st_time [0:STH-1];
integer               st_n          = 0;
reg                   st_verbose    = 1'b1;
reg                   st_tgl        = 1'b0;   // flips on every logged state change (edge-triggered waits)

task st_hist_clear;
   st_n = 0;
endtask

always @(tb_state)
  if (tb_rst_done === 1'b1)
    begin
       if (st_n < STH)
         begin
            st_hist[st_n] = tb_state;
            st_time[st_n] = $realtime;
         end
       st_n   = st_n + 1;
       st_tgl = ~st_tgl;
       if (st_verbose)
         $display("[%0t] STATE -> %0s", $time, st_name(tb_state));
    end

function st_seen;
   input [3:0] s;
   integer     k;
   begin
      st_seen = 1'b0;
      for (k = 0; (k < st_n) && (k < STH); k = k + 1)
        if (st_hist[k] == s) st_seen = 1'b1;
   end
endfunction

function integer st_count;
   input [3:0] s;
   integer     k;
   begin
      st_count = 0;
      for (k = 0; (k < st_n) && (k < STH); k = k + 1)
        if (st_hist[k] == s) st_count = st_count + 1;
   end
endfunction

// Length (ns) of the last completed visit of state s; -1 when none
function real st_dur_last;
   input [3:0] s;
   integer     k;
   begin
      st_dur_last = -1.0;
      for (k = 0; (k + 1 < st_n) && (k + 1 < STH); k = k + 1)
        if (st_hist[k] == s) st_dur_last = st_time[k + 1] - st_time[k];
   end
endfunction

//----------------------------------------------------------------------------
// Port helpers
//----------------------------------------------------------------------------

// STATUS fields
function [3:0] f_state;   input [31:0] v; f_state   = v[3:0];   endfunction
function [1:0] f_line;    input [31:0] v; f_line    = v[5:4];   endfunction
function       f_fs_dev;  input [31:0] v; f_fs_dev  = v[6];     endfunction
function       f_xbusy;   input [31:0] v; f_xbusy   = v[7];     endfunction
function [3:0] f_err;     input [31:0] v; f_err     = v[11:8];  endfunction
function [1:0] f_attempt; input [31:0] v; f_attempt = v[13:12]; endfunction
function [3:0] f_step;    input [31:0] v; f_step    = v[19:16]; endfunction

// Read STATUS and check STATE / ERR / STEP (pass 4'hF to skip a field)
task status_chk;
   input  [3:0] st;
   input  [3:0] er;
   input  [3:0] sp;
   reg   [31:0] v;
   begin
      rdv(R_STATUS, v);
      if ((st != 4'hF) && (f_state(v) != st))
        begin
           $display("ERROR: STATUS.STATE %0s, expected %0s (STATUS 0x%h) %t ns", st_name(f_state(v)), st_name(st), v, $time);
           error = error + 1;
        end
      if ((er != 4'hF) && (f_err(v) != er))
        begin
           $display("ERROR: STATUS.ERR %0d, expected %0d (STATUS 0x%h) %t ns", f_err(v), er, v, $time);
           error = error + 1;
        end
      if ((sp != 4'hF) && (f_step(v) != sp))
        begin
           $display("ERROR: STATUS.STEP %0d, expected %0d (STATUS 0x%h) %t ns", f_step(v), sp, v, $time);
           error = error + 1;
        end
   end
endtask

// Read IRQ_PEND, check (pend & mask) == (exp & mask), clear the mask bits
task irq_chk;
   input [31:0] exp;
   input [31:0] mask;
   reg   [31:0] v;
   begin
      rdv(R_IRQ_PEND, v);
      if ((v & mask) !== (exp & mask))
        begin
           $display("ERROR: IRQ_PEND 0x%h, expected 0x%h under mask 0x%h %t ns", v, exp, mask, $time);
           error = error + 1;
        end
      wr(R_IRQ_PEND, mask);
   end
endtask

// Enable the port with the given CTRL value (EN is forced on), attach the
// device with a profile (< 0: the descriptors already loaded) and wait for RUN
task enumerate;
   input integer profile;
   input  [31:0] ctrl;
   input    real ms;
   begin
      wr(R_CTRL, ctrl | C_EN);
      dev.attach(profile);
      wait_state(S_RUN, ms);
   end
endtask

// Report read with the SEQ retry (doc "Report buffer")
task read_report;
   output  [6:0] len;
   output  [7:0] seq;
   output [63:0] data;
   reg    [31:0] i0, i1, w0, w1;
   integer       n;
   begin
      n = 0;
      i1 = 32'hFFFF_FFFF;
      i0 = 32'h0;
      while ((n == 0) || (i0[15:8] != i1[15:8]))
        begin
           rdv(R_REPORT_INFO, i0);
           rdv(R_REPORT0,     w0);
           rdv(R_REPORT0 + 4, w1);
           rdv(R_REPORT_INFO, i1);
           n = n + 1;
        end
      len  = i0[6:0];
      seq  = i0[15:8];
      data = {w1, w0};
   end
endtask

// Wait for the report after SEQ seq0 (at most ms) and compare its first len bytes
task expect_report;
   input   [7:0] seq0;
   input integer len;
   input  [63:0] data;
   input    real ms;
   reg     [6:0] l;
   reg     [7:0] s;
   reg    [63:0] d;
   reg    [63:0] m;
   real          t0;
   begin : er
      t0 = $realtime;
      read_report(l, s, d);
      while ((s == seq0) && ($realtime - t0 < ms * T_MS))
        begin
           #(100.0 * 1000.0);
           read_report(l, s, d);
        end
      if (s == seq0)
        begin
           $display("ERROR: no report after SEQ %0d within %0.1f ms %t ns", seq0, ms, $time);
           error = error + 1;
           disable er;
        end
      if (s != seq0 + 8'd1)
        begin
           $display("ERROR: REPORT_INFO.SEQ %0d, expected %0d %t ns", s, seq0 + 8'd1, $time);
           error = error + 1;
        end
      if (l != len)
        begin
           $display("ERROR: REPORT_INFO.LEN %0d, expected %0d %t ns", l, len, $time);
           error = error + 1;
        end
      m = (len >= 8) ? {64{1'b1}} : ((64'h1 << (8 * len)) - 64'h1);
      if ((d & m) !== (data & m))
        begin
           $display("ERROR: REPORT %h, expected %h (%0d bytes) %t ns", d & m, data & m, len, $time);
           error = error + 1;
        end
   end
endtask
