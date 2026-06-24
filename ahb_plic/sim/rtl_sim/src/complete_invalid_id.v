//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Test:      complete_invalid_id
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// Description: PLIC 1.0.0 Chapter 9 -- "If the completion ID does not match
//              an interrupt source that is currently enabled for the target,
//              the completion is silently ignored."
//
//   Scenario:
//     enable[ctx0] = {1 for src 5, 0 for src 9}       (src 9 NOT enabled)
//     pri[5] = pri[9] = 7, threshold = 0
//     irq_src[5] = 1, irq_src[9] = 1
//
//     A. claim @ ctx0 -> returns 5 (src 5 enabled, src 9 not)
//        => in_service[5] becomes 1 (genuine in-service)
//        => in_service[9] stays  0 (never claimed)
//
//     B. write COMPLETE @ ctx0 with id=9 (NOT enabled for this target)
//        => spec: silently ignored. in_service[9] must stay 0.
//        => Equally important: in_service[5] (the genuine in-service)
//           must NOT be touched.
//
//     C. write COMPLETE @ ctx0 with id=0 (reserved)         -> silently ignored
//
//     D. write COMPLETE @ ctx0 with id=NUM_SOURCES+1 (out of range)
//        => silently ignored.
//
//     E. write COMPLETE @ ctx0 with id=5 (the real one)
//        => completes; in_service[5] returns to 0.
//
//   in_service flops are probed at tb_ahb_plic.dut.u_pending.in_service[*]
//   (a `[NUM_SOURCES:1]` reg array, declared inside plic_pending).
//----------------------------------------------------------------------------

`define PLIC_BASE        32'h00400000
`define PRIORITY_BASE    32'h00000000
`define ENABLE_BASE      32'h00002000
`define TARGET_BASE      32'h00200000

integer ii;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      tb_ahb_plic.irq_src = {(NUM_SOURCES+1){1'b0}};

      $display(" ===============================================");
      $display("|    SETUP: pri[5]=pri[9]=7, only src5 enabled  |");
      $display(" ===============================================");

      ahb_write(1, MACHINE, `PLIC_BASE + `PRIORITY_BASE + 32'h0014, 32'd7, 2, OK);  // pri[5]
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIORITY_BASE + 32'h0024, 32'd7, 2, OK);  // pri[9]

      // ctx 0 (hart 0 M-mode): enable bit 5 only. bit 9 stays 0.
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + 32'h0,
                32'h0000_0020, 2, OK);

      // Threshold 0 -- nothing masked.
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h0, 32'd0, 2, OK);

      // Drive both sources high.
      tb_ahb_plic.irq_src[5] = 1'b1;
      tb_ahb_plic.irq_src[9] = 1'b1;
      repeat(3) @(posedge free_clk);

      $display(" ===============================================");
      $display("|    A. CLAIM @ CTX0 -- expect src 5             |");
      $display(" ===============================================");

      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd5, 2, 1, OK);
      repeat(2) @(posedge free_clk);

      if (tb_ahb_plic.dut.u_pending.in_service[5] !== 1'b1) begin
         $display("ERROR: in_service[5] expected 1 after claim -- got %b %t ns",
                  tb_ahb_plic.dut.u_pending.in_service[5], $time);
         error = error + 1;
      end else
         $display("PASS:  in_service[5] == 1 after claim %t ns", $time);

      if (tb_ahb_plic.dut.u_pending.in_service[9] !== 1'b0) begin
         $display("ERROR: in_service[9] expected 0 (never claimed) -- got %b %t ns",
                  tb_ahb_plic.dut.u_pending.in_service[9], $time);
         error = error + 1;
      end else
         $display("PASS:  in_service[9] == 0 (never claimed) %t ns", $time);

      $display(" ===============================================");
      $display("|    B. COMPLETE id=9 (DISABLED) -- ignored     |");
      $display(" ===============================================");

      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd9, 2, OK);
      repeat(2) @(posedge free_clk);

      if (tb_ahb_plic.dut.u_pending.in_service[9] !== 1'b0) begin
         $display("ERROR: in_service[9] expected 0 after ignored complete -- got %b %t ns",
                  tb_ahb_plic.dut.u_pending.in_service[9], $time);
         error = error + 1;
      end else
         $display("PASS:  in_service[9] still 0 after complete id=9 silently ignored %t ns", $time);

      if (tb_ahb_plic.dut.u_pending.in_service[5] !== 1'b1) begin
         $display("ERROR: in_service[5] expected 1 (genuine claim not disturbed) -- got %b %t ns",
                  tb_ahb_plic.dut.u_pending.in_service[5], $time);
         error = error + 1;
      end else
         $display("PASS:  in_service[5] still 1 (genuine claim preserved) %t ns", $time);

      $display(" ===============================================");
      $display("|    C. COMPLETE id=0 (reserved) -- ignored     |");
      $display(" ===============================================");

      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd0, 2, OK);
      repeat(2) @(posedge free_clk);

      if (tb_ahb_plic.dut.u_pending.in_service[5] !== 1'b1) begin
         $display("ERROR: in_service[5] expected 1 after complete id=0 -- got %b %t ns",
                  tb_ahb_plic.dut.u_pending.in_service[5], $time);
         error = error + 1;
      end else
         $display("PASS:  in_service[5] still 1 after complete id=0 silently ignored %t ns", $time);

      $display(" ===============================================");
      $display("|    D. COMPLETE id=NUM_SOURCES+1 -- ignored    |");
      $display(" ===============================================");

      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, NUM_SOURCES + 1, 2, OK);
      repeat(2) @(posedge free_clk);

      if (tb_ahb_plic.dut.u_pending.in_service[5] !== 1'b1) begin
         $display("ERROR: in_service[5] expected 1 after complete OOR -- got %b %t ns",
                  tb_ahb_plic.dut.u_pending.in_service[5], $time);
         error = error + 1;
      end else
         $display("PASS:  in_service[5] still 1 after OOR complete silently ignored %t ns", $time);

      $display(" ===============================================");
      $display("|    E. COMPLETE id=5 (genuine) -- accepted     |");
      $display(" ===============================================");

      // Drop level first so the gateway doesn't immediately re-pend.
      tb_ahb_plic.irq_src[5] = 1'b0;
      tb_ahb_plic.irq_src[9] = 1'b0;

      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd5, 2, OK);
      repeat(2) @(posedge free_clk);

      if (tb_ahb_plic.dut.u_pending.in_service[5] !== 1'b0) begin
         $display("ERROR: in_service[5] expected 0 after genuine complete -- got %b %t ns",
                  tb_ahb_plic.dut.u_pending.in_service[5], $time);
         error = error + 1;
      end else
         $display("PASS:  in_service[5] == 0 after genuine complete %t ns", $time);

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
