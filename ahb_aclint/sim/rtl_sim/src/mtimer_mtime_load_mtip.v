//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_mtime_load_mtip
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_mtime_load_mtip.v
// Module Description : MTIP FOLLOWS A COMPLETED MTIME LOAD, BOTH WAYS, WITH NO
//                      TRANSIENT.
//
//                      mtimer_mtime_write polls MTIP right after the store and
//                      so sees the forwarded pending value, not the load. Here
//                      each load is followed until it has actually landed on
//                      the counter (wr_pending high then low, and the counter
//                      itself, u_count_lf.mtime_lf, holding the written value
//                      plus accrued ticks), and MTIP is then watched for six
//                      more LF periods. Across the whole window -- from before
//                      the first store to the end of the watch -- MTIP must
//                      make exactly ONE transition: a drop at the hand-over
//                      from the forwarded value to the mirror would be a
//                      transient the firmware sees as a spurious or lost
//                      interrupt.
//
//                        ahb_aclint.md MTIMER: "MTIP is not sticky: loading past
//                        MTIMECMP raises it, loading back below clears it."
//                        ahb_aclint.md Wait states: "a MTIME write reaches the
//                        counter two to three LF periods later (a quiet tick, a
//                        launch tick, then the LF edge that consumes it), with
//                        reads served from the pending value meanwhile."
//                        ahb_aclint.md rule 3: "a back-to-back LO/HI pair
//                        reaches the counter as a single load -- there is no
//                        'write HI first' rule and no intermediate-match
//                        hazard."
//                        ACLINT 2.3: "pending whenever MTIME is greater than or
//                        equal to the value in the corresponding MTIMECMP
//                        register whereas ... cleared whenever MTIME is less
//                        than the value of the corresponding MTIMECMP register."
//
//                      Values are chosen so that a single transition is the
//                      only correct outcome under any per-half forwarding:
//                      C = {K, 0}; forward load {K, 0x100} written LO then HI;
//                      backward load {K-1, 0xFFFFF000} written LO then HI.
//                      Repeated twice with a different K, MTIMECMP reprogrammed
//                      with the three-store sequence while the monitor is off.
//----------------------------------------------------------------------------

localparam [31:0] LM_MTIME_LO = 32'h0040BFF8;
localparam [31:0] LM_MTIME_HI = 32'h0040BFFC;
localparam [31:0] LM_CMP_LO   = 32'h00404000;
localparam [31:0] LM_CMP_HI   = 32'h00404004;

reg         lm_watch;
reg         lm_prev;
integer     lm_edges;
integer     lm_iter;
integer     lm_dir;
integer     lm_guard;
reg  [31:0] lm_k;
reg  [63:0] lm_cmp;
reg  [63:0] lm_tgt;
reg  [63:0] lm_cnt;
reg  [63:0] lm_rb;
reg         lm_want;

// MTIP edge counter, sampled at the negedge (irq_m_timer_o is combinational).
initial begin
   lm_watch = 1'b0;
   lm_prev  = 1'b0;
   lm_edges = 0;
end

always @(negedge free_clk) begin
   if (lm_watch) begin
      if (irq_m_timer[0] !== lm_prev) begin
         lm_edges = lm_edges + 1;
         $display("INFO:  MTIP[0] -> %b %t ns", irq_m_timer[0], $time);
      end
   end
   lm_prev = irq_m_timer[0];
end

task lm_read_mtime;
   output [63:0] val;
   begin
      ahb_read(1, MACHINE, LM_MTIME_LO, 32'h00000000, 2, 0, OK);
      ahb_read(1, MACHINE, LM_MTIME_HI, 32'h00000000, 2, 0, OK);
      val = tb_ahb_aclint.mtime_shadow_ahb_sim;
   end
endtask

task lm_wait_landed;
   begin
      lm_guard = 0;
      while ((tb_ahb_aclint.dut.u_mtimer.wr_pending === 1'b0) && (lm_guard < `LF_CYCLES(2))) begin
         @(posedge free_clk);
         lm_guard = lm_guard + 1;
      end
      if (tb_ahb_aclint.dut.u_mtimer.wr_pending !== 1'b1) begin
         $display("ERROR: MTIME write never registered as pending %t ns", $time);
         error = error + 1;
      end
      lm_guard = 0;
      while ((tb_ahb_aclint.dut.u_mtimer.wr_pending === 1'b1) && (lm_guard < `LF_CYCLES(40))) begin
         @(posedge free_clk);
         lm_guard = lm_guard + 1;
      end
      if (tb_ahb_aclint.dut.u_mtimer.wr_pending !== 1'b0) begin
         $display("ERROR: MTIME write still pending after 40 LF periods %t ns", $time);
         error = error + 1;
      end
      repeat(`LF_CYCLES(3)) @(posedge free_clk);
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(`LF_CYCLES(5)) @(posedge free_clk);

      for (lm_iter = 0; lm_iter < 2; lm_iter = lm_iter + 1) begin
         lm_k   = 32'h00000010 + (lm_iter << 4);
         lm_cmp = {lm_k, 32'h00000000};

         // Three-store sequence (priv spec, RV32), monitor off.
         lm_watch = 1'b0;
         ahb_write(1, MACHINE, LM_CMP_LO, 32'hFFFFFFFF, 2, OK);
         ahb_write(1, MACHINE, LM_CMP_HI, lm_cmp[63:32], 2, OK);
         ahb_write(1, MACHINE, LM_CMP_LO, lm_cmp[31:0],  2, OK);
         repeat(`LF_CYCLES(2)) @(posedge free_clk);

         for (lm_dir = 0; lm_dir < 2; lm_dir = lm_dir + 1) begin
            lm_want = (lm_dir == 0);
            lm_tgt  = (lm_dir == 0) ? {lm_k, 32'h00000100} : {lm_k - 32'h1, 32'hFFFFF000};

            $display("");
            $display(" ===============================================");
            if (lm_dir == 0)
               $display("|   PASS %0d : LOAD PAST MTIMECMP RAISES MTIP    |", lm_iter);
            else
               $display("|   PASS %0d : LOAD BELOW MTIMECMP CLEARS MTIP   |", lm_iter);
            $display(" ===============================================");
            $display("INFO:  MTIMECMP 0x%h_%h, loading MTIME 0x%h_%h", lm_cmp[63:32], lm_cmp[31:0],
                     lm_tgt[63:32], lm_tgt[31:0]);

            @(negedge free_clk);
            if (irq_m_timer[0] !== ~lm_want) begin
               $display("ERROR: MTIP[0] = %b before the load, expected %b %t ns", irq_m_timer[0], ~lm_want, $time);
               error = error + 1;
            end

            lm_prev  = irq_m_timer[0];
            lm_edges = 0;
            lm_watch = 1'b1;
            ahb_write(1, MACHINE, LM_MTIME_LO, lm_tgt[31:0],  2, OK);
            ahb_write(1, MACHINE, LM_MTIME_HI, lm_tgt[63:32], 2, OK);
            lm_wait_landed;

            // The counter itself holds the load (written value + accrued ticks).
            lm_cnt = tb_ahb_aclint.dut.u_mtimer.u_count_lf.mtime_lf;
            if ((lm_cnt < lm_tgt) || ((lm_cnt - lm_tgt) > 64'd64)) begin
               $display("ERROR: counter holds 0x%h_%h, the load 0x%h_%h has not landed %t ns",
                        lm_cnt[63:32], lm_cnt[31:0], lm_tgt[63:32], lm_tgt[31:0], $time);
               error = error + 1;
            end
            lm_read_mtime(lm_rb);
            if ((lm_rb < lm_tgt) || ((lm_rb - lm_tgt) > 64'd64)) begin
               $display("ERROR: MTIME reads 0x%h_%h after the load of 0x%h_%h %t ns",
                        lm_rb[63:32], lm_rb[31:0], lm_tgt[63:32], lm_tgt[31:0], $time);
               error = error + 1;
            end

            @(negedge free_clk);
            if (irq_m_timer[0] !== lm_want) begin
               $display("ERROR: MTIP[0] = %b once the load has landed, expected %b %t ns",
                        irq_m_timer[0], lm_want, $time);
               error = error + 1;
            end else begin
               $display("PASS:  MTIP[0] = %b once the load has landed %t ns", lm_want, $time);
            end

            // Hold at the new level: no late transient.
            repeat(`LF_CYCLES(6)) @(posedge free_clk);
            @(negedge free_clk);
            lm_watch = 1'b0;
            if (irq_m_timer[0] !== lm_want) begin
               $display("ERROR: MTIP[0] = %b six LF periods after the load, expected %b %t ns",
                        irq_m_timer[0], lm_want, $time);
               error = error + 1;
            end
            if (lm_edges != 1) begin
               $display("ERROR: MTIP[0] made %0d transitions across the load, expected exactly 1 %t ns",
                        lm_edges, $time);
               error = error + 1;
            end else begin
               $display("PASS:  exactly one MTIP transition, no transient before or after the landing %t ns", $time);
            end
         end
      end

      ahb_write(1, MACHINE, LM_CMP_LO, 32'hFFFFFFFF, 2, OK);
      ahb_write(1, MACHINE, LM_CMP_HI, 32'hFFFFFFFF, 2, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
