//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dmi_reset_cross
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dmi_reset_cross
// Module Description : An ASYMMETRIC reset of the DMI-master CDC must not fabricate
//                      a transaction.
//
//   The req/ack handshake in arv_dtm_dmi_master carries a level TOGGLE across the
//   TCK<->hclk boundary, and each side edge-detects the OTHER side's level. The two
//   reset pins are both DEBUG-domain resets but independent: trst_n (TCK/TAP) and
//   dbgresetn (hclk; = the core DM's DMI-slave PRESETn). NB the bench reg driving the
//   DTM's dbgresetn_i port here is named `dbgresetn` -- it models dbgresetn, NOT the
//   hart's core reset (an ndmreset holds dbgresetn high, so it never reaches the DTM).
//   If only ONE of the two asserts (trst_n while dbgresetn stays high, or vice-versa),
//   the reset side's toggle level clears while the far side's shadow copy does not --
//   so the survivor would see a PHANTOM req edge and launch an unsolicited DMI
//   transaction (a replay of the last-latched request). The RTL resets both sides of
//   the handshake whenever either reset asserts, so no phantom edge can appear.
//
//   Part A -- pulse dbgresetn only (trst_n high): the last-latched WRITE must NOT be
//   replayed, and no DMI transaction may appear on the bus with no host op pending.
//   Part B -- pulse trst_n only (dbgresetn high): same, from the opposite domain.
//   In both, the bus (dmi_psel) must stay idle across the reset, and a fresh
//   transaction must round-trip cleanly afterwards.
//----------------------------------------------------------------------------

// A gated monitor rather than a fork/disable watcher. Verilator hits an internal fault
// on join_any + disable fork here, and arming a monitor around the window says the same
// thing -- without the original's side effect of aborting the reset pulse mid-way.
reg watch_psel;
reg phantom;

initial begin
   watch_psel = 1'b0;
   phantom    = 1'b0;
end

always @(posedge dmi_psel) if (watch_psel) phantom <= 1'b1;

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;

      @(posedge dbgresetn);
      @(posedge trst_n);
      repeat (4) @(posedge tck);

      tap_reset;
      shift_ir(IR_DMI);

      $display(" ===============================================");
      $display("|  Part A: asymmetric dbgresetn pulse (trst_n hi) |");
      $display(" ===============================================");

      // One write leaves a WRITE as the last-latched request (the replay candidate)
      // and settles the CDC handshake.
      dmi_write(7'h40, 32'hBAD0_BAD0, 8);
      // Backdoor the slave memory so a phantom replay of that write is observable.
      slave_mem[7'h40] = 32'h600D_600D;

      // Asymmetric reset: pulse dbgresetn only; trst_n stays high. With no host op
      // pending, the bus must stay idle -- a phantom req edge would drive PSEL for
      // the spurious transaction. Arm the watch BEFORE the pulse so a phantom that
      // fires *during* the reset window (not just after release) is still caught.
      phantom    = 1'b0;
      watch_psel = 1'b1;
      dbgresetn = 1'b0;
      repeat (3) @(posedge free_clk);
      dbgresetn = 1'b1;
      repeat (40) @(posedge free_clk);
      watch_psel = 1'b0;
      check_eq("A_no_phantom_xfer", phantom, 1'b0);

      // The seeded memory must be intact -- a replay would have rewritten 0xBAD0BAD0.
      shift_ir(IR_DMI);
      dmi_read(7'h40, 8, rd, st);
      check_eq("A_st",     st, OP_SUCCESS);
      check_eq("A_no_repl", rd, 32'h600D_600D);

      $display(" ===============================================");
      $display("|  Part B: asymmetric trst_n pulse (dbgresetn hi) |");
      $display(" ===============================================");

      // Settle the CDC again with a fresh write.
      shift_ir(IR_DMI);
      dmi_write(7'h41, 32'hFEED_FACE, 8);

      // Asymmetric reset from the other domain: pulse trst_n only; dbgresetn stays
      // high. Here hclk keeps running THROUGH the pulse and resyncs req_h to the
      // reset-cleared req_level, so the phantom edge fires *during* the low window
      // -- the watch must be armed before trst_n drops.
      phantom    = 1'b0;
      watch_psel = 1'b1;
      trst_n = 1'b0;
      repeat (3) @(posedge tck);
      trst_n = 1'b1;
      repeat (40) @(posedge free_clk);
      watch_psel = 1'b0;
      check_eq("B_no_phantom_xfer", phantom, 1'b0);

      // trst_n reset the TAP: re-init, then confirm a fresh transaction round-trips.
      tap_reset;
      shift_ir(IR_DMI);
      dmi_write(7'h42, 32'h1234_5678, 8);
      dmi_read (7'h42, 8, rd, st);
      check_eq("post_st", st, OP_SUCCESS);
      check_eq("post_rd", rd, 32'h1234_5678);

      $display(" ===============================================");
      $display("|  Part C: dbgresetn pulse with an op IN FLIGHT   |");
      $display(" ===============================================");

      // The combined reset now resets the master's TCK-side inflight/result regs on
      // a dbgresetn pulse, while the upstream arv_dtm_jtag (trst_n-only) keeps driving
      // launch_i / consuming inflight_o. Prove that seam does not wedge: reset the
      // master mid-flight, then confirm the sticky/inflight tracking recovers and a
      // fresh op round-trips (dm_inflight is a level, so a reset-cleared inflight just
      // re-enables launch -- same net effect as dtmhardreset).
      shift_ir(IR_DMI);
      slave_hold = 1'b1;
      dmi_scan(7'h43, 32'b0, OP_READ, rd, st);   // launch a read; stays in flight

      dbgresetn = 1'b0;                          // DM (dbgresetn) reset WHILE the op is stuck
      repeat (3) @(posedge free_clk);
      dbgresetn = 1'b1;

      slave_abort = 1'b1;                         // retire the now-orphaned slave xfer
      repeat (2) @(posedge free_clk);
      slave_abort = 1'b0;
      slave_hold  = 1'b0;

      // No stale inflight/busy: a NOP poll reports clean...
      shift_ir(IR_DMI);
      dmi_scan(7'h00, 32'b0, OP_NOP, rd, st);
      check_eq("C_poll_clean", st, OP_SUCCESS);

      // ...and a brand-new transaction round-trips.
      shift_ir(IR_DMI);
      dmi_write(7'h44, 32'hCAFE_F00D, 8);
      dmi_read (7'h44, 8, rd, st);
      check_eq("C_post_st", st, OP_SUCCESS);
      check_eq("C_post_rd", rd, 32'hCAFE_F00D);

      repeat (8) @(posedge tck);
      stimulus_done = 1'b1;
   end
