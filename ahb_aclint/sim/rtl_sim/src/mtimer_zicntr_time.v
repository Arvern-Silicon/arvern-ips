//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_zicntr_time
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_zicntr_time.v
// Module Description : Exercise the Zicntr time_req_i / time_gnt_o / time_val_o
//                      side-band handshake -- the core-private path that
//                      services `csrr time` without an AHB transaction.
//
//                      This path was previously unverified (time_req tied 0,
//                      time_gnt/time_val dangling). It hid a clock-gate bug:
//                      mtimer_active_o omitted the time_gnt_r term, so on the
//                      grant cycle -- FSM back in IDLE, time_req already
//                      released -- the SoC clock gate could drop hclk_i before
//                      the grant flop cleared, stranding time_gnt_o high.
//
//                      The test issues time reads on a QUIESCENT bus (the only
//                      condition under which mtimer_active_o is the sole
//                      clock-keeper), models the core releasing time_req in
//                      response to the grant, and then checks:
//                        (a) the grant arrives (handshake completes),
//                        (b) time_gnt_o returns low      <- catches the bug,
//                        (c) time_val_o equals the internal Zicntr shadow,
//                        (d) the snapshot agrees with the AHB MTIME path and
//                            is monotonically non-decreasing across reads,
//                        (e) a SECOND read still completes after a fully-gated
//                            idle window (the "core can re-issue" symptom).
//----------------------------------------------------------------------------

reg [63:0] z0;
reg [63:0] z1;
reg [63:0] z0_shadow;
reg [63:0] z1_shadow;
reg [63:0] m_ahb;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(100) @(posedge free_clk);

      $display(" ===============================================");
      $display("|        ZICNTR : TIME REQ/GNT HANDSHAKE        |");
      $display(" ===============================================");

      //----------------------------------------------------------------
      // Read #1 on a quiescent bus. With AHB and SSWI idle, the request
      // alone must wake a gated hclk_i (mtimer_active_o.time_req term),
      // run the gray-sync roundtrip, and pulse time_gnt_o for one cycle.
      //----------------------------------------------------------------
      zicntr_time_read(z0, "read #1");
      z0_shadow = tb_ahb_aclint.dut.u_mtimer.mtime_shadow_zicntr;

      // (b) time_gnt_o must be a 1-cycle pulse, not a stuck level. This is
      //     the direct check for the clock-gate / time_gnt_r bug.
      zicntr_check_gnt_cleared("read #1");

      // (c) time_val_o is just the registered Zicntr shadow -- they must be
      //     bit-identical the cycle the grant lands.
      if (z0 !== z0_shadow) begin
         $display("ERROR: Zicntr read #1 -- time_val 0x%h_%h != mtime_shadow_zicntr 0x%h_%h %t ns",
                  z0[63:32], z0[31:0], z0_shadow[63:32], z0_shadow[31:0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  Zicntr read #1 -- time_val matches the internal Zicntr shadow %t ns", $time);
      end

      // Snapshot must be a real, advancing count (not stuck at the reset 0).
      if (z0 == 64'h0) begin
         $display("WARNING: Zicntr read #1 -- time_val still 0 (LF clock not advancing yet?) %t ns", $time);
      end

      //----------------------------------------------------------------
      // (d) Cross-check against the AHB MTIME read path. An AHB LO+HI pair
      //     sampled right after the Zicntr read must be >= the Zicntr
      //     snapshot (time only moves forward).
      //----------------------------------------------------------------
      ahb_read(1, MACHINE, 32'h00404008, 32'h00000000, 2, 0, OK);
      ahb_read(1, MACHINE, 32'h0040400C, 32'h00000000, 2, 0, OK);
      m_ahb = tb_ahb_aclint.mtime_shadow_ahb_sim;
      if (m_ahb < z0) begin
         $display("ERROR: Zicntr/AHB disagree -- AHB MTIME 0x%h_%h < earlier Zicntr 0x%h_%h %t ns",
                  m_ahb[63:32], m_ahb[31:0], z0[63:32], z0[31:0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  Zicntr snapshot consistent with the AHB MTIME path %t ns", $time);
      end

      //----------------------------------------------------------------
      // Let hclk_i gate OFF for a real idle window (no AHB, no time_req),
      // and let MTIME advance, before re-issuing. This proves the request
      // restarts a fully-stopped clock and that the handshake is re-usable
      // (the "core never re-issues" symptom of the bug shows up here too:
      // with time_gnt_o stranded high, read #2 would observe a stale grant).
      //----------------------------------------------------------------
      repeat(200) @(posedge free_clk);

      zicntr_time_read(z1, "read #2");
      z1_shadow = tb_ahb_aclint.dut.u_mtimer.mtime_shadow_zicntr;
      zicntr_check_gnt_cleared("read #2");

      if (z1 !== z1_shadow) begin
         $display("ERROR: Zicntr read #2 -- time_val 0x%h_%h != mtime_shadow_zicntr 0x%h_%h %t ns",
                  z1[63:32], z1[31:0], z1_shadow[63:32], z1_shadow[31:0], $time);
         error = error + 1;
      end else begin
         $display("PASS:  Zicntr read #2 -- time_val matches the internal Zicntr shadow %t ns", $time);
      end

      // (d) Monotonicity across the two Zicntr reads.
      if (z1 < z0) begin
         $display("ERROR: Zicntr time went backwards -- z0=0x%h_%h z1=0x%h_%h %t ns",
                  z0[63:32], z0[31:0], z1[63:32], z1[31:0], $time);
         error = error + 1;
      end else if (z1 == z0) begin
         $display("WARNING: Zicntr time did not advance between reads -- z0==z1==0x%h_%h (LF clock too slow?) %t ns",
                  z0[63:32], z0[31:0], $time);
      end else begin
         $display("PASS:  Zicntr time advanced -- z1 - z0 = 0x%h %t ns", (z1 - z0), $time);
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
