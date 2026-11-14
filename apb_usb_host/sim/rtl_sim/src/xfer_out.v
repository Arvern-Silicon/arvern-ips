//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    xfer_out
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : xfer_out.v
// Module Description : Software control transfers with an OUT data stage
//                      and without a data stage, on an enumerated keyboard.
//                      OUT: XFER.PKT is set when the stage starts and the
//                      port sends nothing until CMD.XFER_NEXT; each packet
//                      software writes is sent and XFER_PKT rises when the
//                      device accepted it; a packet longer than the maximum
//                      (8) or than the remaining length is sent truncated;
//                      the status stage IN completes, RESULT OK, XFER_DONE,
//                      and the device holds the bytes (SET_REPORT 1 byte,
//                      12 bytes, 16 bytes). XFER_NEXT while PKT is clear is
//                      ignored. No data stage: SET_IDLE, and GET_STATUS with
//                      wLength 0 (direction ignored, status IN). GET_STATUS
//                      with wLength 2: one 2-byte IN packet.
//
// Doc "Control transfers", "Transactions", "Register map".
//----------------------------------------------------------------------------

reg [31:0] xo_v;
reg [31:0] xo_p;
reg        xo_watch = 1'b0;
integer    xo_ka    = 0;                   // host keep-alives while xo_watch (drive < 5 us)
integer    xo_pk    = 0;                   // host packets while xo_watch (longer drives)
real       xo_t_oe  = 0.0;
reg  [6:0] xo_len;
reg  [7:0] xo_seq;
reg [63:0] xo_d;

always @(posedge usb_oe)
  xo_t_oe = $realtime;

always @(negedge usb_oe)
  if (xo_watch)
    begin
       if (($realtime - xo_t_oe) < 5000.0) xo_ka = xo_ka + 1;
       else                                xo_pk = xo_pk + 1;
    end

// Wait until IRQ_PEND & mask is non-zero (irq_o with IRQ_EN = mask), at
// most ms; pend returns IRQ_PEND
task xo_wait;
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

// XFER.PKT set (polled every 100 us, at most ms)
task xo_wait_pkt;
   input real ms;
   real       t0;
   begin
      t0 = $realtime;
      rdv(R_XFER, xo_v);
      while ((xo_v[8] !== 1'b1) && (($realtime - t0) < ms * T_MS))
        begin
           #(100.0e3);
           rdv(R_XFER, xo_v);
        end
      if (xo_v[8] !== 1'b1)
        begin
           $display("ERROR: XFER.PKT not set within %0.1f ms (XFER 0x%h) %t ns", ms, xo_v, $time);
           error = error + 1;
        end
   end
endtask

// The port waits for software for ms: a keep-alive in every frame, no
// packet (no EP0 token, no poll), PKT held, no report committed
task xo_hold;
   input real ms;
   reg  [7:0] s0;
   begin
      rdv(R_REPORT_INFO, xo_v);
      s0       = xo_v[15:8];
      xo_ka    = 0;
      xo_pk    = 0;
      xo_watch = 1'b1;
      wait_ms(ms);
      xo_watch = 1'b0;
      chk(xo_pk == 0,                  "no packet while the port waits for XFER_NEXT");
      chk(xo_ka >= (ms - 1.0),         "a keep-alive in every frame while the port waits");
      rdv(R_REPORT_INFO, xo_v);
      chk(xo_v[15:8] == s0,            "no report committed during the transfer");
      rdv(R_STATUS, xo_v);
      chk(f_state(xo_v) == S_RUN && f_xbusy(xo_v), "RUN with XFER_BUSY while waiting");
      rdv(R_XFER, xo_v);
      chk(xo_v[8] == 1'b1,             "XFER.PKT held until XFER_NEXT");
   end
endtask

// The end of a transfer (XFER_DONE seen): XFER_BUSY low, RESULT OK, PKT
// clear, the port in RUN, the device saw the status stage complete
task xo_done_chk;
   input integer d0;
   begin
      // the model completes an IN status stage on decoding the host's ACK,
      // some 15 us after the host decides to send it
      #(20.0e3);
      rdv(R_STATUS, xo_v);
      chk(!f_xbusy(xo_v),              "XFER_BUSY falls at the end of the transfer");
      chk(f_state(xo_v) == S_RUN,      "RUN after the transfer");
      rdv(R_XFER, xo_v);
      chk32(xo_v & 32'hE00, {20'h0, X_OK, 9'h0}, "XFER.RESULT OK");
      chk((dev.st_xfer_done == d0 + 1) && (dev.ctl_stage == dev.CS_DONE), "the device saw the status stage complete");
      wr(R_IRQ_PEND, I_XFER_PKT | I_XFER_DONE);
   end
endtask

// A SET_REPORT (output report) of wl bytes to interface 0. Software writes
// packets of the lengths in lw (7 bits each, packet k in lw[7k +: 7]) with
// the next bytes of data; each is sent truncated to min(8, LEN, remaining).
// hold: the port is held 5 ms at the start of the stage with a report
// queued. dbl: a second XFER_NEXT right after the first of packet 0.
task xo_setrep;
   input integer  wl;
   input [127:0]  data;
   input [27:0]   lw;
   input          hold;
   input          dbl;
   integer        k, sent, n, c0, d0, x0;
   reg      [6:0] l;
   reg     [63:0] w;
   reg            done;
   begin : sr
      c0 = dev.srep_cnt;
      d0 = dev.st_xfer_done;
      x0 = dev.st_xfer_start;
      wr(R_IRQ_PEND, I_XFER_PKT | I_XFER_DONE);
      wr(R_SETUP0, 32'h0200_0921);
      wr(R_SETUP1, {wl[15:0], 16'h0000});
      wr(R_CMD, K_XFER_START);
      // The stage starts with the buffer free
      xo_wait_pkt(20.0);
      chk(dev.st_xfer_start == x0 + 1, "the SETUP was accepted");
      chk(dev.ctl_stage == dev.CS_DATA_OUT, "the device is in the OUT data stage");
      if (hold)
        begin
           dev.push_report(8, 64'h0000_2B00_0000_0001 + wl);
           xo_hold(5.0);
           chk(dev.ctl_out_cnt == 0,   "no OUT data sent before XFER_NEXT");
        end
      sent = 0;
      k    = 0;
      done = 1'b0;
      while ((sent < wl) && (k < 4))
        begin
           l = lw[7*k +: 7];
           w = data[8*sent +: 64];
           wr(R_XDATA0,     w[31:0]);
           wr(R_XDATA0 + 4, w[63:32]);
           wr(R_XFER, {25'h0, l});
           rdv(R_XFER, xo_v);
           chk32(xo_v & 32'h17F, {23'h0, 1'b1, 1'b0, l}, "XFER.LEN written by software, PKT set");
           wr(R_IRQ_PEND, I_XFER_PKT);
           wr(R_CMD, K_XFER_NEXT);
           if (dbl && (k == 0)) wr(R_CMD, K_XFER_NEXT);
           rdv(R_XFER, xo_v);
           chk(xo_v[8] == 1'b0,        "XFER_NEXT clears XFER.PKT");
           n = l;
           if (n > 8) n = 8;
           if (n > wl - sent) n = wl - sent;
           sent = sent + n;
           k    = k + 1;
           xo_wait(I_XFER_PKT | I_XFER_DONE, 20.0, xo_p);
           if (sent < wl)
             begin
                chk32(xo_p & (I_XFER_PKT | I_XFER_DONE), I_XFER_PKT, "XFER_PKT when the device accepted the packet");
                rdv(R_XFER, xo_v);
                chk(xo_v[8] == 1'b1,   "XFER.PKT set again: the buffer is free");
                chk(dev.ctl_out_cnt == sent, "the device received the packet, truncated");
                if (dbl && (k == 1))
                  begin
                     // The extra XFER_NEXT was ignored: the port waits
                     xo_hold(3.0);
                     chk(dev.ctl_out_cnt == sent, "no packet sent by the ignored XFER_NEXT");
                  end
             end
           else
             begin
                // Last packet: the stage has ended, the status stage follows
                // at once, without XFER_PKT (doc "Control transfers")
                if (!(xo_p & I_XFER_DONE)) xo_wait(I_XFER_DONE, 20.0, xo_p);
                chk((xo_p & I_XFER_PKT) == 0,  "no XFER_PKT after the packet that completes the stage");
                chk((xo_p & I_XFER_DONE) != 0, "XFER_DONE");
             end
        end
      xo_done_chk(d0);
      chk(dev.srep_cnt == c0 + 1,      "the device applied SET_REPORT");
      chk(dev.srep_len == wl,          "the device received wLength bytes");
      chk(dev.srep_wv == 16'h0200 && dev.srep_if == 0, "SET_REPORT wValue / interface");
      for (k = 0; k < wl; k = k + 1)
        if (dev.srep[k] !== data[8*k +: 8])
          begin
             $display("ERROR: SET_REPORT byte %0d = 0x%h, expected 0x%h %t ns", k, dev.srep[k], data[8*k +: 8], $time);
             error = error + 1;
          end
   end
endtask

// A request with no data stage: status stage IN, then XFER_DONE without
// any XFER_PKT
task xo_nodata;
   input [31:0] s0;
   input [31:0] s1;
   integer      d0;
   begin
      d0 = dev.st_xfer_done;
      wr(R_IRQ_PEND, I_XFER_PKT | I_XFER_DONE);
      wr(R_SETUP0, s0);
      wr(R_SETUP1, s1);
      wr(R_CMD, K_XFER_START);
      xo_wait(I_XFER_PKT | I_XFER_DONE, 20.0, xo_p);
      // the status stage IN may land in the same frame: settle a frame
      wait_ms(1.0);
      rdv(R_IRQ_PEND, xo_p);
      chk32(xo_p & (I_XFER_PKT | I_XFER_DONE), I_XFER_DONE, "no data stage: XFER_DONE, no XFER_PKT");
      chk(dev.ctl_in_dir == 1'b0,      "the device saw no data stage");
      xo_done_chk(d0);
   end
endtask

initial
   begin
      wait_reset_done(5);
      if (CTRL_EN == 0) tb_skip("CTRL_EN = 0: no software control transfers");

      enumerate(dev.P_KBD, C_EN | C_BOOT | C_IDLE0, 600.0);
      wait_ms(25.0);
      status_chk(S_RUN, E_NONE, 4'd0);
      wr(R_IRQ_PEND, I_ALL);

      // SET_REPORT, 1 byte (keyboard LEDs: Num Lock, Scroll Lock); polling
      // paused during the transfer and resumed after it
      read_report(xo_len, xo_seq, xo_d);
      xo_setrep(1, 128'h05, {21'h0, 7'd1}, 1'b1, 1'b0);
      expect_report(xo_seq, 8, 64'h0000_2B00_0000_0002, 30.0);

      // 12 bytes: packet 0 written with LEN 8, packet 1 with LEN 8 and 4
      // bytes remaining (sent as 4); an ignored second XFER_NEXT
      xo_setrep(12, 128'h0000_0000_1C1B_1A19_1817_1615_1413_1211, {14'h0, 7'd8, 7'd8}, 1'b0, 1'b1);

      // 16 bytes: packet 0 written with LEN 0x7F (longer than the maximum:
      // sent as 8), packet 1 with LEN 8
      xo_setrep(16, 128'h3837_3635_3433_3231_2827_2625_2423_2221, {14'h0, 7'd8, 7'd127}, 1'b0, 1'b0);

      // No data stage: SET_IDLE(duration 4, report 0) to interface 0
      xo_nodata(32'h0400_0A21, 32'h0000_0000);
      chk(dev.hid_idle[0] == 4,        "SET_IDLE applied by the device");
      xo_nodata(32'h0000_0A21, 32'h0000_0000);
      chk(dev.hid_idle[0] == 0,        "SET_IDLE(0) applied by the device");

      // GET_STATUS(device) with wLength 0: bmRequestType[7] is ignored, the
      // status stage is an IN
      xo_nodata(32'h0000_0080, 32'h0000_0000);

      // GET_STATUS(device), wLength 2: one 2-byte IN packet 00 00
      begin : gs
         integer d0;
         reg [31:0] w;
         d0 = dev.st_xfer_done;
         wr(R_IRQ_PEND, I_XFER_PKT | I_XFER_DONE);
         wr(R_SETUP0, 32'h0000_0080);
         wr(R_SETUP1, 32'h0002_0000);
         wr(R_CMD, K_XFER_START);
         xo_wait(I_XFER_PKT | I_XFER_DONE, 20.0, xo_p);
         chk32(xo_p & (I_XFER_PKT | I_XFER_DONE), I_XFER_PKT, "GET_STATUS: one data packet");
         rdv(R_XFER, xo_v);
         chk32(xo_v & 32'hF7F, 32'h102, "GET_STATUS: XFER.LEN 2, PKT");
         rdv(R_XDATA0, w);
         chk32(w & 32'hFFFF, 32'h0000, "GET_STATUS data 00 00");
         wr(R_IRQ_PEND, I_XFER_PKT);
         wr(R_CMD, K_XFER_NEXT);
         xo_wait(I_XFER_PKT | I_XFER_DONE, 20.0, xo_p);
         chk32(xo_p & (I_XFER_PKT | I_XFER_DONE), I_XFER_DONE, "GET_STATUS: XFER_DONE after the short packet");
         xo_done_chk(d0);
      end

      // Polling still runs
      read_report(xo_len, xo_seq, xo_d);
      dev.push_report(8, 64'h0000_2C00_0000_0001);
      expect_report(xo_seq, 8, 64'h0000_2C00_0000_0001, 30.0);
      status_chk(S_RUN, E_NONE, 4'd0);
      chk(!st_seen(S_BACKOFF),         "no failure");
      stimulus_done = 1;
   end
