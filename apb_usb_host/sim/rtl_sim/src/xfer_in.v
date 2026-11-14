//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    xfer_in
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : xfer_in.v
// Module Description : Software control transfers with an IN data stage on
//                      an enumerated keyboard. Every data packet lands in
//                      XDATA with XFER.LEN, XFER.PKT and IRQ_PEND.XFER_PKT,
//                      its bytes equal to the device's descriptor; the port
//                      then waits for CMD.XFER_NEXT with keep-alives in every
//                      frame, no token sent and polling paused (550 ms of
//                      waiting is no progress timeout); the stage ends on a
//                      short packet, a zero-length packet or wLength bytes;
//                      the status stage completes, XFER_BUSY falls, RESULT
//                      OK, XFER_DONE, and polling resumes (a report is
//                      delivered). Requests: GET_DESCRIPTOR of the device
//                      (wLength 18, 16, 24), string 2 (28 bytes), a 16-byte
//                      string (wLength 24: 8, 8, then a zero-length packet)
//                      and the HID report descriptor (63 bytes). XFER_NEXT
//                      while XFER.PKT is clear is ignored.
//
// Doc "Control transfers", "Transactions", "Register map", "States".
//----------------------------------------------------------------------------

reg [31:0] xi_v;
reg [31:0] xi_p;
reg [31:0] xi_w0;
reg [31:0] xi_w1;
reg        xi_watch = 1'b0;
integer    xi_ka    = 0;                   // host keep-alives while xi_watch (drive < 5 us)
integer    xi_pk    = 0;                   // host packets while xi_watch (longer drives)
real       xi_t_oe  = 0.0;
reg  [6:0] xi_len;
reg  [7:0] xi_seq;
reg [63:0] xi_d;
integer    xi_k;

always @(posedge usb_oe)
  xi_t_oe = $realtime;

always @(negedge usb_oe)
  if (xi_watch)
    begin
       if (($realtime - xi_t_oe) < 5000.0) xi_ka = xi_ka + 1;
       else                                xi_pk = xi_pk + 1;
    end

// Wait until IRQ_PEND & mask is non-zero (irq_o with IRQ_EN = mask), at
// most ms; pend returns IRQ_PEND
task xi_wait;
   input  [31:0] mask;
   input    real ms;
   output [31:0] pend;
   reg           to;
   integer       k;
   begin
      to = 1'b0;
      wr(R_IRQ_EN, mask);
      if (irq !== 1'b1)
        begin : w
           fork
              begin : w_ev
                 wait (irq === 1'b1);
                 disable w_to;
              end
              begin : w_to
                 for (k = 0; k < ms * 100.0; k = k + 1)
                   #(10.0e3);
                 to = 1'b1;
                 disable w_ev;
              end
           join
        end
      rdv(R_IRQ_PEND, pend);
      if (to)
        begin
           $display("ERROR: IRQ_PEND 0x%h: no bit of 0x%h within %0.1f ms %t ns", pend, mask, ms, $time);
           error = error + 1;
        end
   end
endtask

// The port waits for software for ms: a keep-alive in every frame, no
// packet (no EP0 token, no poll), PKT held, the transfer still running
task xi_hold;
   input real ms;
   integer    n0;
   reg  [7:0] s0;
   begin
      rdv(R_REPORT_INFO, xi_v);
      s0       = xi_v[15:8];
      n0       = dev.int_sent_cnt;
      xi_ka    = 0;
      xi_pk    = 0;
      xi_watch = 1'b1;
      wait_ms(ms);
      xi_watch = 1'b0;
      chk(xi_pk == 0,                  "no packet while the port waits for XFER_NEXT");
      chk(xi_ka >= (ms - 1.0),         "a keep-alive in every frame while the port waits");
      chk(dev_suspended === 1'b0,      "the device is kept awake");
      chk(dev.int_sent_cnt == n0,      "polling paused during the transfer");
      rdv(R_REPORT_INFO, xi_v);
      chk(xi_v[15:8] == s0,            "no report committed during the transfer");
      rdv(R_STATUS, xi_v);
      chk(f_state(xi_v) == S_RUN && f_xbusy(xi_v), "RUN with XFER_BUSY while waiting");
      chk(f_err(xi_v) == E_NONE,       "no progress timeout while waiting for software");
      rdv(R_XFER, xi_v);
      chk(xi_v[8] == 1'b1,             "XFER.PKT held until XFER_NEXT");
      rdv(R_IRQ_PEND, xi_v);
      chk((xi_v & (I_XFER_DONE | I_FAIL)) == 32'h0, "no XFER_DONE / FAIL while waiting");
   end
endtask

// One IN data packet: XFER_PKT pending (not XFER_DONE), XFER = {OK, PKT,
// len}, XDATA = bytes off .. off+len-1 of the device's region r
task xi_pkt;
   input integer len;
   input integer r;
   input integer off;
   integer       k;
   reg    [63:0] d;
   begin
      xi_wait(I_XFER_PKT | I_XFER_DONE, 20.0, xi_p);
      chk32(xi_p & (I_XFER_PKT | I_XFER_DONE), I_XFER_PKT, "IRQ_PEND after an IN data packet");
      rdv(R_XFER, xi_v);
      chk32(xi_v & 32'hF7F, 32'h100 | len, "XFER after an IN data packet (RESULT OK, PKT, LEN)");
      rdv(R_STATUS, xi_v);
      chk(f_xbusy(xi_v) && (f_state(xi_v) == S_RUN), "XFER_BUSY in RUN during the transfer");
      rdv(R_XDATA0,     xi_w0);
      rdv(R_XDATA0 + 4, xi_w1);
      d = {xi_w1, xi_w0};
      for (k = 0; k < len; k = k + 1)
        if (d[8*k +: 8] !== dev.dmem[r*256 + off + k])
          begin
             $display("ERROR: XDATA byte %0d = 0x%h, expected descriptor byte %0d = 0x%h %t ns", k, d[8*k +: 8],
                      off + k, dev.dmem[r*256 + off + k], $time);
             error = error + 1;
          end
      wr(R_IRQ_PEND, I_XFER_PKT);
   end
endtask

// The end of a transfer: XFER_DONE without a further packet, XFER_BUSY
// low, RESULT OK, PKT clear, the port in RUN
task xi_done;
   begin
      xi_wait(I_XFER_PKT | I_XFER_DONE, 20.0, xi_p);
      chk32(xi_p & (I_XFER_PKT | I_XFER_DONE), I_XFER_DONE, "XFER_DONE and no further data packet");
      rdv(R_STATUS, xi_v);
      chk(!f_xbusy(xi_v),              "XFER_BUSY falls at the end of the transfer");
      chk(f_state(xi_v) == S_RUN,      "RUN after the transfer");
      rdv(R_XFER, xi_v);
      chk32(xi_v & 32'hF00, {20'h0, X_OK, 9'h0}, "XFER.RESULT OK, PKT clear");
      wr(R_IRQ_PEND, I_XFER_DONE);
   end
endtask

// A whole IN transfer from region r of the device. The expected packets
// follow the stage rule: 8-byte packets, then a short one or, when the
// descriptor is a multiple of 8 and shorter than wLength, a zero-length
// one; none after wLength bytes. At packet hold_k the port is held for
// hold_ms (a report queued first, which must wait); dbl sends a second
// XFER_NEXT right after the first one of packet 0 (PKT clear: ignored).
task xi_in;
   input [31:0]  s0;
   input [31:0]  s1;
   input integer r;
   input integer hold_k;
   input real    hold_ms;
   input         dbl;
   integer       wl, dl, n, k, len, off, x0, d0;
   begin
      wl = s1[31:16];
      dl = (dev.rlen[r] < wl) ? dev.rlen[r] : wl;
      n  = (dl / 8) + ((((dl % 8) != 0) || (dl < wl)) ? 1 : 0);
      wr(R_IRQ_PEND, I_XFER_PKT | I_XFER_DONE);
      wr(R_SETUP0, s0);
      wr(R_SETUP1, s1);
      x0 = dev.st_xfer_start;
      d0 = dev.st_xfer_done;
      wr(R_CMD, K_XFER_START);
      off = 0;
      for (k = 0; k < n; k = k + 1)
        begin
           len = dl - off;
           if (len > 8) len = 8;
           xi_pkt(len, r, off);
           if (k == hold_k)
             begin
                dev.push_report(8, 64'h0000_1E00_0000_0002 + k);
                xi_hold(hold_ms);
             end
           wr(R_CMD, K_XFER_NEXT);
           if (dbl && (k == 0)) wr(R_CMD, K_XFER_NEXT);
           rdv(R_XFER, xi_v);
           chk(xi_v[8] == 1'b0,        "XFER_NEXT clears XFER.PKT");
           off = off + len;
        end
      xi_done;
      chk(dev.st_xfer_start == x0 + 1, "one SETUP for the transfer");
      chk((dev.st_xfer_done == d0 + 1) && (dev.ctl_stage == dev.CS_DONE), "the device saw the status stage complete");
   end
endtask

initial
   begin
      wait_reset_done(5);
      if (CTRL_EN == 0) tb_skip("CTRL_EN = 0: no software control transfers");

      // Keyboard, plus a 16-byte string descriptor 3 (a multiple of 8)
      dev.load_profile(dev.P_KBD);
      dev.desc_set(dev.R_STR3, 0, 16);
      dev.desc_set(dev.R_STR3, 1, 3);
      for (xi_k = 0; xi_k < 7; xi_k = xi_k + 1)
        begin
           dev.desc_set(dev.R_STR3, 2 + 2*xi_k, 8'h41 + xi_k);
           dev.desc_set(dev.R_STR3, 3 + 2*xi_k, 0);
        end
      enumerate(-1, C_EN | C_BOOT | C_IDLE0, 600.0);
      wait_ms(25.0);
      status_chk(S_RUN, E_NONE, 4'd0);
      wr(R_IRQ_PEND, I_ALL);

      // GET_DESCRIPTOR(DEVICE), wLength 18: 8, 8, 2. The port waits 550 ms
      // at the first packet: time waiting for software is not progress
      // (doc "Transactions", progress timeout 500 ms)
      read_report(xi_len, xi_seq, xi_d);
      xi_in(32'h0100_0680, 32'h0012_0000, dev.R_DEV, 0, 550.0, 1'b0);
      expect_report(xi_seq, 8, 64'h0000_1E00_0000_0002, 30.0);
      rdv(R_STATUS, xi_v);
      chk(f_attempt(xi_v) == 2'd0 && f_err(xi_v) == E_NONE, "no failure after the long wait");

      // String 2 (28 bytes) with wLength 255: 8, 8, 8, 4. A second
      // XFER_NEXT while PKT is clear is ignored: packet 1 still waits
      read_report(xi_len, xi_seq, xi_d);
      xi_in(32'h0302_0680, 32'h00FF_0409, dev.R_STR2, 1, 3.0, 1'b1);
      expect_report(xi_seq, 8, 64'h0000_1E00_0000_0003, 30.0);

      // HID report descriptor to interface 0, wLength 63: seven 8-byte
      // packets, then 7 bytes
      xi_in(32'h2200_0681, 32'h003F_0000, dev.R_REP0, -1, 0.0, 1'b0);

      // DEVICE, wLength 16: the stage ends after wLength bytes on a full
      // packet, no further IN (the model STALLs an IN beyond the data)
      xi_in(32'h0100_0680, 32'h0010_0000, dev.R_DEV, -1, 0.0, 1'b0);

      // DEVICE, wLength 24 (a multiple of 8, longer than the descriptor):
      // 8, 8, then a short packet of 2
      xi_in(32'h0100_0680, 32'h0018_0000, dev.R_DEV, -1, 0.0, 1'b0);

      // String 3 (16 bytes), wLength 24: 8, 8, then a zero-length packet,
      // which is a packet too (XFER.LEN 0, PKT, XFER_PKT)
      read_report(xi_len, xi_seq, xi_d);
      xi_in(32'h0303_0680, 32'h0018_0409, dev.R_STR3, 2, 3.0, 1'b0);
      expect_report(xi_seq, 8, 64'h0000_1E00_0000_0004, 30.0);

      // String 1 (14 bytes), wLength 255: 8, 6
      xi_in(32'h0301_0680, 32'h00FF_0409, dev.R_STR1, -1, 0.0, 1'b0);

      status_chk(S_RUN, E_NONE, 4'd0);
      rdv(R_STATUS, xi_v);
      chk(f_attempt(xi_v) == 2'd0,     "ATTEMPT 0");
      chk(!st_seen(S_BACKOFF),         "no failure");
      stimulus_done = 1;
   end
