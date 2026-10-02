//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mtimer_cmp_torn_write
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mtimer_cmp_torn_write.v
// Module Description : MTIMECMP IS A PAIR OF 32-BIT REGISTERS, NOT A 64-BIT ONE.
//
//                      An RV32 manager can only store 32 bits at a time, and the
//                      two halves of MTIMECMP are separate registers read
//                      straight by the comparator. Between the two stores the
//                      comparand is {new HI, old LO} -- a value firmware never
//                      intended -- and the interrupt is generated from it.
//
//                      This is not a defect and there is nothing to fix in the
//                      hardware: it is why the privileged spec gives a THREE
//                      store sequence for RV32 (store -1 to LO, then HI, then
//                      LO), which keeps every intermediate no smaller than the
//                      lesser of the old and new comparands.
//
//                      Two things are asserted here:
//                        1. the read-back exposes the intermediate, so the
//                           non-atomicity is observable rather than theoretical;
//                        2. the spec's sequence produces NO MTIP transient.
//                      The two-store hazard itself is reported but not asserted
//                      -- it is a property of a 32-bit bus, not a requirement on
//                      this IP, and a design that merged the pair would still be
//                      correct.
//----------------------------------------------------------------------------

integer    guard;
integer    glitches;
reg        watch_glitch;
reg        mtip_d;
reg [63:0] mt_now;
reg [31:0] far_hi;
reg [31:0] tgt_lo;

`define MTIME_LO_ADDR    32'h0040BFF8
`define MTIME_HI_ADDR    32'h0040BFFC
`define MTIMECMP_LO_ADDR 32'h00404000
`define MTIMECMP_HI_ADDR 32'h00404004

// Count rising edges of MTIP while armed.
initial
   begin
      glitches     = 0;
      watch_glitch = 1'b0;
      mtip_d       = 1'b0;
      forever begin
         // Mid-cycle sample: MTIP is combinational off registers clocked on the
         // free_clk rising edge, so a rising-edge sample can land between their updates.
         @(negedge free_clk);
         if (watch_glitch && (tb_ahb_aclint.dut.irq_m_timer_o[0] === 1'b1) && (mtip_d === 1'b0))
            glitches = glitches + 1;
         mtip_d = tb_ahb_aclint.dut.irq_m_timer_o[0];
      end
   end

task read_mtime;
   output [63:0] val;
   begin
      ahb_read(1, MACHINE, `MTIME_LO_ADDR, 32'h00000000, 2, 0, OK);
      ahb_read(1, MACHINE, `MTIME_HI_ADDR, 32'h00000000, 2, 0, OK);
      val = tb_ahb_aclint.mtime_shadow_ahb_sim;
   end
endtask

// Park MTIMECMP far beyond MTIME so MTIP is low and nothing legitimate can fire.
task arm_far;
   begin
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, far_hi,          2, OK);
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, 32'h00000000,    2, OK);
      guard = 0;
      while ((tb_ahb_aclint.dut.irq_m_timer_o[0] !== 1'b0) && (guard < `LF_CYCLES(20))) begin
         @(posedge free_clk);
         guard = guard + 1;
      end
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      @(posedge resetn_lf);
      repeat(20) @(posedge free_clk);

      // MTIME must have advanced past zero: the intermediate comparand below is
      // {MTIME_HI, 0}, which only sits below MTIME once its low half is non-zero.
      guard = 0;
      read_mtime(mt_now);
      while ((mt_now[31:0] < 32'd4) && (guard < `LF_CYCLES(20))) begin
         repeat(`LF_CYCLES(1)) @(posedge free_clk);
         read_mtime(mt_now);
         guard = guard + 1;
      end

      far_hi = mt_now[63:32] + 32'd2;                  // far future, a different HI
      tgt_lo = mt_now[31:0]  + 32'h00100000;           // future, the SAME HI as MTIME

      $display(" ===============================================");
      $display("|  MTIMECMP : THE PAIR IS NOT ATOMIC           |");
      $display(" ===============================================");
      $display("INFO:  MTIME = 0x%h_%h, parking MTIMECMP at 0x%h_00000000 %t ns",
               mt_now[63:32], mt_now[31:0], far_hi, $time);

      arm_far;
      if (tb_ahb_aclint.dut.irq_m_timer_o[0] !== 1'b0) begin
         $display("ERROR: MTIP still set with the deadline parked far ahead %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIP low with the deadline parked far ahead %t ns", $time);
      end

      // First store of a naive HI,LO pair. The comparand is now {new HI, old LO}.
      watch_glitch = 1'b1;
      mtip_d       = tb_ahb_aclint.dut.irq_m_timer_o[0];
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, mt_now[63:32], 2, OK);

      // The read-back is the proof that the halves are independent: HI carries
      // the new value while LO still carries the old one.
      ahb_read(1, MACHINE, `MTIMECMP_HI_ADDR, mt_now[63:32], 2, 1, OK);
      ahb_read(1, MACHINE, `MTIMECMP_LO_ADDR, 32'h00000000,  2, 1, OK);
      $display("PASS:  read-back shows the torn comparand 0x%h_00000000 %t ns",
               mt_now[63:32], $time);

      // That intermediate is below MTIME, so the interrupt follows it. Reported,
      // not asserted -- see the header.
      repeat(4) @(posedge free_clk);
      if (tb_ahb_aclint.dut.irq_m_timer_o[0] === 1'b1)
         $display("INFO:  MTIP asserted on the intermediate value -- this is the spurious interrupt the three-store sequence exists to avoid %t ns", $time);
      else
         $display("INFO:  MTIP did not follow the intermediate value %t ns", $time);

      // Finish the pair; the real deadline is far ahead, so MTIP must drop.
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, tgt_lo, 2, OK);
      guard = 0;
      while ((tb_ahb_aclint.dut.irq_m_timer_o[0] !== 1'b0) && (guard < `LF_CYCLES(20))) begin
         @(posedge free_clk);
         guard = guard + 1;
      end
      watch_glitch = 1'b0;
      if (tb_ahb_aclint.dut.irq_m_timer_o[0] !== 1'b0) begin
         $display("ERROR: MTIP never cleared after the pair was completed %t ns", $time);
         error = error + 1;
      end else begin
         $display("PASS:  MTIP cleared once the second half landed %t ns", $time);
      end

      $display("");
      $display(" ===============================================");
      $display("|  MTIMECMP : THE SPEC SEQUENCE IS GLITCH-FREE |");
      $display(" ===============================================");

      // Same start state, same destination, the privileged spec's RV32 order.
      arm_far;
      if (tb_ahb_aclint.dut.irq_m_timer_o[0] !== 1'b0) begin
         $display("ERROR: could not re-park the deadline before the second pass %t ns", $time);
         error = error + 1;
      end

      glitches     = 0;
      watch_glitch = 1'b1;
      mtip_d       = tb_ahb_aclint.dut.irq_m_timer_o[0];

      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, 32'hFFFFFFFF,    2, OK);  // no smaller than the old
      ahb_write(1, MACHINE, `MTIMECMP_HI_ADDR, mt_now[63:32],   2, OK);  // no smaller than the new
      ahb_write(1, MACHINE, `MTIMECMP_LO_ADDR, tgt_lo,          2, OK);  // new value

      // Long enough for the write to cross into the LF domain and for any
      // transient to show, far short of the programmed deadline.
      repeat(`LF_CYCLES(12)) @(posedge free_clk);
      watch_glitch = 1'b0;

      if (glitches != 0) begin
         $display("ERROR: MTIP transient %0d time(s) during the three-store sequence %t ns",
                  glitches, $time);
         error = error + 1;
      end else begin
         $display("PASS:  no MTIP transient across the three-store sequence %t ns", $time);
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
