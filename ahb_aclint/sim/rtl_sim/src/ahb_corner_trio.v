//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_corner_trio
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_corner_trio.v
// Module Description : THREE AHB CORNERS THE BFM CANNOT REACH.
//
//                      (a) hprot[1]=0 with hsmode=1. The BFM's USER mode leaves
//                          hsmode at its previous value (0); this drives 1, and
//                          also sets the hprot bits the IP ignores.
//                            ahb_aclint.md privilege encoding: "hprot_i[1]=0,
//                            hsmode_i=x -> U-mode"; ports: "hprot_i ... Bit [1]
//                            = privileged. Other bits ignored"; "U | DENY | DENY
//                            | DENY | RAZ/WI".
//                            "A denied access gets the AHB-Lite two-cycle ERROR
//                            (hreadyout_o=0 then 1, hresp_o=1 for both). The
//                            addressed bank's select is gated throughout, so
//                            writes never land and reads return 0."
//                            "With SU_MODE_EN=0 the SSWI column reads RAZ/WI for
//                            every privilege"; "PRIV_CHECK_EN=0 accepts
//                            everything and holds hresp_o low".
//                      (b) Two back-to-back (pipelined, non-blocking) SETSSIP[0]
//                          writes of 1: irq_s_software_o[0] is ONE contiguous
//                          pulse, two hclk cycles long (one per write), no
//                          other hart's bit moves, and SETSSIP reads 0.
//                          SU_MODE_EN=1 only.
//                            ahb_aclint.md SSWI: "Writing 1 emits a one-cycle
//                            pulse on irq_s_software_o[hart] (back-to-back
//                            writes to the same hart merge into one longer
//                            pulse ...); writing 0 does nothing; reads return 0."
//                            ACLINT 4.2: "The least significant bit of a SETSSIP
//                            register always reads 0."
//                      (c) Right after a warm hresetn_i, a denied access with
//                          an MTIME_LO read presented in its second ERROR cycle
//                          (the AHB-Lite point where the next address phase may
//                          start). The denied access gets the two-cycle ERROR
//                          and reads 0; the MTIME_LO read that follows is not
//                          contaminated: hresp_o=0 on every one of its cycles
//                          including the stall, at most 2R wait states, and it
//                          returns MTIME.
//                            ahb_aclint.md Wait states: "MTIME_LO read while the
//                            mirror is untrustworthy | <= 2R"; "The mirror is
//                            untrustworthy only out of reset".
//                            ahb_aclint.md Resets: hresetn_i alone -> MTIME
//                            "survives" (LF_SYNC_EN=0); "with LF_SYNC_EN=1 ...
//                            MTIME restarts from zero on a warm reset".
//                          PRIV_CHECK_EN=1 only (nothing is denied otherwise).
//----------------------------------------------------------------------------

localparam [31:0] CT_MSIP     = 32'h00400000;
localparam [31:0] CT_CMP_LO   = 32'h00404000;
localparam [31:0] CT_CMP_HI   = 32'h00404004;
localparam [31:0] CT_MTIME_LO = 32'h0040BFF8;
localparam [31:0] CT_MTIME_HI = 32'h0040BFFC;
localparam [31:0] CT_SETSSIP  = 32'h0040C000;
localparam [31:0] CT_RSVD     = 32'h0040D000;
localparam integer CT_LF_NS   = 2 * `ACLINT_LF_HALF_PERIOD;

reg         ct_r1;
reg         ct_r2;
reg  [31:0] ct_rd;
reg  [31:0] ct_lo;
reg  [31:0] ct_hi;
integer     ct_w;
integer     ct_guard;
integer     ct_drift;
integer     ct_stall;
reg         ct_exp_err;
reg  [63:0] ct_before;
reg  [63:0] ct_v;
time        ct_t0;

// SSIP pulse monitor (negedge sampling).
reg         ct_ss_watch;
reg         ct_ss_prev;
integer     ct_ss_rises;
integer     ct_ss_width;
integer     ct_ss_other;

initial begin
   ct_ss_watch = 1'b0;
   ct_ss_prev  = 1'b0;
   ct_ss_rises = 0;
   ct_ss_width = 0;
   ct_ss_other = 0;
end

always @(negedge free_clk) begin
   if (ct_ss_watch) begin
      if ((irq_s_software[0] === 1'b1) && (ct_ss_prev !== 1'b1)) ct_ss_rises = ct_ss_rises + 1;
      if (irq_s_software[0] === 1'b1)                            ct_ss_width = ct_ss_width + 1;
      if ((irq_s_software >> 1) != 0)                            ct_ss_other = ct_ss_other + 1;
   end
   ct_ss_prev = irq_s_software[0];
end

task ct_xfer;
   input         wr;
   input  [31:0] addr;
   input  [31:0] wdata;
   input   [3:0] prot;
   input         smode;
   output        resp_p1;
   output        resp_end;
   output [31:0] rdata;
   output integer waits;
   begin
      haddr  = addr;
      htrans = 2'b10;
      hwrite = wr;
      hsize  = 3'b010;
      hprot  = prot;
      hsmode = smode;
      @(posedge free_clk);
      #1;
      haddr  = 32'h00000000;
      htrans = 2'b00;
      hwrite = 1'b0;
      hprot  = 4'h0;
      hsmode = 1'b0;
      hsize  = 3'b000;
      hwdata = wdata;
      waits  = 0;
      @(negedge free_clk);
      resp_p1 = hresp;
      while ((hreadyout !== 1'b1) && (waits < `LF_CYCLES(4) + 16)) begin
         @(negedge free_clk);
         waits = waits + 1;
      end
      resp_end = hresp;
      rdata    = hrdata;
      @(posedge free_clk);
      #1;
   end
endtask

// Check a raw transfer's response against OK (0 waits) or ERROR (two-cycle).
task ct_check_resp;
   input          exp_err;
   input [40*8:0] tag;
   begin
      if (exp_err) begin
         if ((ct_r1 !== 1'b1) || (ct_w != 1) || (ct_r2 !== 1'b1)) begin
            $display("ERROR: %0s -- expected two-cycle ERROR, got P1 hresp=%b, %0d wait(s), final hresp=%b %t ns",
                     tag, ct_r1, ct_w, ct_r2, $time);
            error = error + 1;
         end else begin
            $display("PASS:  %0s -- two-cycle ERROR %t ns", tag, $time);
         end
      end else begin
         if ((ct_r2 !== 1'b0) || (ct_w != 0)) begin
            $display("ERROR: %0s -- expected OK with 0 waits, got %0d wait(s), hresp=%b %t ns",
                     tag, ct_w, ct_r2, $time);
            error = error + 1;
         end else begin
            $display("PASS:  %0s -- OK, 0 wait states %t ns", tag, $time);
         end
      end
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(`LF_CYCLES(5)) @(posedge free_clk);

      $display(" ===============================================");
      $display("|   (a) hprot[1]=0 WITH hsmode=1 IS U-MODE      |");
      $display(" ===============================================");

      ct_exp_err = (PRIV_CHECK_EN != 0);

      // Denied read of MTIMECMP_LO[0] (reset all-ones): must read 0 when denied.
      ct_xfer(0, CT_CMP_LO, 32'h0, 4'h0, 1'b1, ct_r1, ct_r2, ct_rd, ct_w);
      ct_check_resp(ct_exp_err, "(a) U(hsmode=1) read MTIMECMP");
      if (ct_rd !== (ct_exp_err ? 32'h00000000 : 32'hFFFFFFFF)) begin
         $display("ERROR: (a) U(hsmode=1) read of MTIMECMP_LO returned 0x%h, expected 0x%h %t ns",
                  ct_rd, (ct_exp_err ? 32'h00000000 : 32'hFFFFFFFF), $time);
         error = error + 1;
      end

      // Same with the ignored hprot bits set (hprot = 4'b1101: bit 1 still 0).
      ct_xfer(0, CT_CMP_LO, 32'h0, 4'hD, 1'b1, ct_r1, ct_r2, ct_rd, ct_w);
      ct_check_resp(ct_exp_err, "(a) U(hprot=0xD, hsmode=1) read MTIMECMP");

      // Denied write of MSIP[0]: must not land (or lands when PRIV_CHECK_EN=0).
      ct_xfer(1, CT_MSIP, 32'h00000001, 4'h0, 1'b1, ct_r1, ct_r2, ct_rd, ct_w);
      ct_check_resp(ct_exp_err, "(a) U(hsmode=1) write MSIP");
      repeat(2) @(negedge free_clk);
      if (irq_m_software[0] !== ~ct_exp_err) begin
         $display("ERROR: (a) irq_m_software_o[0] = %b after the U(hsmode=1) MSIP write, expected %b %t ns",
                  irq_m_software[0], ~ct_exp_err, $time);
         error = error + 1;
      end
      ahb_read (1, MACHINE, CT_MSIP, {31'h0, ~ct_exp_err}, 2, 1, OK);
      ahb_write(1, MACHINE, CT_MSIP, 32'h00000000, 2, OK);

      // SSWI: denied for U with SU_MODE_EN=1, a RAZ/WI hole with SU_MODE_EN=0.
      ct_xfer(0, CT_SETSSIP, 32'h0, 4'h0, 1'b1, ct_r1, ct_r2, ct_rd, ct_w);
      ct_check_resp(ct_exp_err && (SU_MODE_EN != 0), "(a) U(hsmode=1) read SSWI");
      if (ct_rd !== 32'h0) begin
         $display("ERROR: (a) U(hsmode=1) read of SETSSIP returned 0x%h %t ns", ct_rd, $time);
         error = error + 1;
      end

      // Outside every window: RAZ/WI at any privilege.
      ct_xfer(1, CT_RSVD, 32'hFFFFFFFF, 4'h0, 1'b1, ct_r1, ct_r2, ct_rd, ct_w);
      ct_check_resp(1'b0, "(a) U(hsmode=1) write reserved");
      ct_xfer(0, CT_RSVD, 32'h0, 4'h0, 1'b1, ct_r1, ct_r2, ct_rd, ct_w);
      ct_check_resp(1'b0, "(a) U(hsmode=1) read reserved");
      if (ct_rd !== 32'h0) begin
         $display("ERROR: (a) reserved offset read 0x%h, expected RAZ %t ns", ct_rd, $time);
         error = error + 1;
      end

      $display("");
      $display(" ===============================================");
      $display("|   (b) BACK-TO-BACK SETSSIP WRITES             |");
      $display(" ===============================================");

      if (SU_MODE_EN == 0) begin
         $display("SKIP:  SU_MODE_EN=0 -- no SSWI bank %t ns", $time);
      end else begin
         ct_ss_rises = 0;
         ct_ss_width = 0;
         ct_ss_other = 0;
         @(negedge free_clk);
         ct_ss_watch = 1'b1;
         ahb_write(0, MACHINE, CT_SETSSIP, 32'h00000001, 2, OK);
         ahb_write(0, MACHINE, CT_SETSSIP, 32'h00000001, 2, OK);
         repeat(8) @(negedge free_clk);
         ct_ss_watch = 1'b0;

         if ((ct_ss_rises == 1) && (ct_ss_width == 2) && (ct_ss_other == 0)) begin
            $display("PASS:  (b) two back-to-back SETSSIP writes -> one merged 2-cycle pulse %t ns", $time);
         end else begin
            $display("ERROR: (b) back-to-back SETSSIP: %0d rising edge(s), %0d cycle(s) high, %0d cycle(s) with another hart's bit -- expected 1 / 2 / 0 %t ns",
                     ct_ss_rises, ct_ss_width, ct_ss_other, $time);
            error = error + 1;
         end
         ahb_read(1, MACHINE, CT_SETSSIP, 32'h00000000, 2, 1, OK);
         @(negedge free_clk);
         if (irq_s_software !== {NUM_HARTS{1'b0}}) begin
            $display("ERROR: (b) irq_s_software_o = %b after the pulse, expected 0 (no level) %t ns",
                     irq_s_software, $time);
            error = error + 1;
         end
      end

      $display("");
      $display(" ===============================================");
      $display("|   (c) DENIED ACCESS, THEN MTIME_LO OUT OF     |");
      $display("|       RESET                                   |");
      $display(" ===============================================");

      if (PRIV_CHECK_EN == 0) begin
         $display("SKIP:  PRIV_CHECK_EN=0 -- nothing is denied %t ns", $time);
      end else begin
         // Distinctive MTIME, landed before the reset.
         ahb_write(1, MACHINE, CT_MTIME_LO, 32'h00002000, 2, OK);
         ahb_write(1, MACHINE, CT_MTIME_HI, 32'h00000033, 2, OK);
         ct_guard = 0;
         while ((tb_ahb_aclint.dut.u_mtimer.wr_pending === 1'b1) && (ct_guard < `LF_CYCLES(40))) begin
            @(posedge free_clk);
            ct_guard = ct_guard + 1;
         end
         repeat(`LF_CYCLES(3)) @(posedge free_clk);
         ct_xfer(0, CT_MTIME_LO, 32'h0, 4'h2, 1'b0, ct_r1, ct_r2, ct_lo, ct_w);
         ct_xfer(0, CT_MTIME_HI, 32'h0, 4'h2, 1'b0, ct_r1, ct_r2, ct_hi, ct_w);
         ct_before = {ct_hi, ct_lo};
         ct_t0     = $time;
         if (ct_hi !== 32'h00000033) begin
            $display("ERROR: (c) MTIME setup did not land (HI 0x%h) %t ns", ct_hi, $time);
            error = error + 1;
         end

         @(negedge free_clk);
         hresetn = 1'b0;
         repeat(8) @(negedge free_clk);
         hresetn = 1'b1;

         // Denied S-mode read of MSIP[0], first cycle after the release.
         haddr  = CT_MSIP;
         htrans = 2'b10;
         hwrite = 1'b0;
         hsize  = 3'b010;
         hprot  = 4'h2;
         hsmode = 1'b1;
         @(posedge free_clk);
         #1;
         haddr  = 32'h00000000;
         htrans = 2'b00;
         hprot  = 4'h0;
         hsmode = 1'b0;
         @(negedge free_clk);
         if ((hresp !== 1'b1) || (hreadyout !== 1'b0)) begin
            $display("ERROR: (c) denied access P1: hresp=%b hreadyout=%b, expected 1/0 %t ns", hresp, hreadyout, $time);
            error = error + 1;
         end
         @(posedge free_clk);
         #1;
         // P2: present the MTIME_LO read here.
         haddr  = CT_MTIME_LO;
         htrans = 2'b10;
         hwrite = 1'b0;
         hsize  = 3'b010;
         hprot  = 4'h2;
         hsmode = 1'b0;
         @(negedge free_clk);
         if ((hresp !== 1'b1) || (hreadyout !== 1'b1) || (hrdata !== 32'h0)) begin
            $display("ERROR: (c) denied access P2: hresp=%b hreadyout=%b hrdata=0x%h, expected 1/1/0 %t ns",
                     hresp, hreadyout, hrdata, $time);
            error = error + 1;
         end else begin
            $display("PASS:  (c) denied access right after reset: two-cycle ERROR, reads 0 %t ns", $time);
         end
         if (tb_ahb_aclint.dut.u_mtimer.mirror_valid !== 1'b0)
            $display("INFO:  (c) mirror_valid already %b when the MTIME_LO read is issued %t ns",
                     tb_ahb_aclint.dut.u_mtimer.mirror_valid, $time);
         @(posedge free_clk);
         #1;
         haddr  = 32'h00000000;
         htrans = 2'b00;
         hprot  = 4'h0;

         // MTIME_LO data phase: hresp low on every cycle, bounded stall.
         ct_stall = 0;
         @(negedge free_clk);
         while ((hreadyout !== 1'b1) && (ct_stall < `LF_CYCLES(4) + 16)) begin
            if (hresp !== 1'b0) begin
               $display("ERROR: (c) hresp=1 during the MTIME_LO stall -- the previous ERROR leaked %t ns", $time);
               error = error + 1;
            end
            @(negedge free_clk);
            ct_stall = ct_stall + 1;
         end
         if (hresp !== 1'b0) begin
            $display("ERROR: (c) MTIME_LO read completed with hresp=1 %t ns", $time);
            error = error + 1;
         end
         ct_lo = hrdata;
         @(posedge free_clk);
         #1;

         if (ct_stall > `LF_CYCLES(2)) begin
            $display("ERROR: (c) MTIME_LO stalled %0d cycles, bound 2R = %0d %t ns", ct_stall, `LF_CYCLES(2), $time);
            error = error + 1;
         end else if ((ct_stall == 0) && (LF_SYNC_EN == 0)) begin
            $display("ERROR: (c) MTIME_LO read out of reset did not stall (mirror untrustworthy out of reset) %t ns", $time);
            error = error + 1;
         end else begin
            $display("INFO:  (c) MTIME_LO stalled %0d cycle(s) (bound %0d) %t ns", ct_stall, `LF_CYCLES(2), $time);
         end

         ct_xfer(0, CT_MTIME_HI, 32'h0, 4'h2, 1'b0, ct_r1, ct_r2, ct_hi, ct_w);
         ct_v     = {ct_hi, ct_lo};
         ct_drift = (($time - ct_t0) / CT_LF_NS) + 2;
         if (LF_SYNC_EN == 0) begin
            if ((ct_v < ct_before) || ((ct_v - ct_before) > ct_drift)) begin
               $display("ERROR: (c) MTIME 0x%h_%h, expected 0x%h_%h + [0..%0d] %t ns",
                        ct_hi, ct_lo, ct_before[63:32], ct_before[31:0], ct_drift, $time);
               error = error + 1;
            end else begin
               $display("PASS:  (c) MTIME_LO read after the ERROR returns MTIME 0x%h_%h %t ns", ct_hi, ct_lo, $time);
            end
         end else begin
            if (ct_v > ct_drift) begin
               $display("ERROR: (c) LF_SYNC_EN=1: MTIME 0x%h_%h, expected a count restarted from 0 %t ns",
                        ct_hi, ct_lo, $time);
               error = error + 1;
            end else begin
               $display("PASS:  (c) LF_SYNC_EN=1: MTIME_LO read after the ERROR returns the restarted count 0x%h %t ns",
                        ct_lo, $time);
            end
         end

         ahb_read(1, MACHINE, CT_MSIP, 32'h00000000, 2, 1, OK);
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
