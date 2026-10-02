//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    priv_contexts
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : priv_contexts
// Module Description : Privilege policy on every context's enable and threshold
//                      registers, in every build it runs in. M-mode: always allowed.
//                      S-mode: allowed only on an S-context (SU_MODE_EN=1, odd
//                      context), denied on an M-context -- so every context with
//                      SU_MODE_EN=0. U-mode: always denied. Denied writes change
//                      nothing.
//----------------------------------------------------------------------------

`define PLIC_BASE      32'h00400000
`define PRIO_BASE      32'h00000000
`define ENABLE_BASE    32'h00002000
`define ENABLE_STRIDE  32'h00000080
`define TARGET_BASE    32'h00200000
`define TARGET_STRIDE  32'h00001000

task chk;
   input        cond;
   input [8*80-1:0] msg;
   begin
      if (cond !== 1'b1) begin
         $display("ERROR: %0s %t ns", msg, $time);
         error = error + 1;
      end
   end
endtask

task bus_idle;
   begin
      haddr  = 32'h00000000;
      htrans = 2'b00;
      hwrite = 1'b0;
      hsize  = 3'b000;
      set_mode(USER);
   end
endtask

integer c;
reg     s_ok;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(6) @(posedge free_clk); #1;

      for (c = 0; c < NUM_CONTEXTS; c = c + 1) begin
         s_ok = (SU_MODE_EN != 0) && (c % 2 == 1);

         // Machine mode programs a known value.
         ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE + c*`ENABLE_STRIDE, 32'h0000_0006, 2, OK);
         ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + c*`TARGET_STRIDE, 32'd1, 2, OK);

         // Supervisor mode.
         ahb_read (1, SUPERVISOR, `PLIC_BASE + `ENABLE_BASE + c*`ENABLE_STRIDE, 32'h0000_0006, 2, s_ok, s_ok ? OK : ERROR);
         ahb_write(1, SUPERVISOR, `PLIC_BASE + `ENABLE_BASE + c*`ENABLE_STRIDE, 32'h0000_000A, 2,       s_ok ? OK : ERROR);
         ahb_read (1, SUPERVISOR, `PLIC_BASE + `TARGET_BASE + c*`TARGET_STRIDE, 32'd1, 2, s_ok, s_ok ? OK : ERROR);
         ahb_write(1, SUPERVISOR, `PLIC_BASE + `TARGET_BASE + c*`TARGET_STRIDE, 32'd2, 2,       s_ok ? OK : ERROR);

         // User mode: always denied.
         ahb_read (1, USER, `PLIC_BASE + `ENABLE_BASE + c*`ENABLE_STRIDE, 32'h0, 2, 0, ERROR);
         ahb_write(1, USER, `PLIC_BASE + `ENABLE_BASE + c*`ENABLE_STRIDE, 32'h0000_0000, 2, ERROR);
         ahb_write(1, USER, `PLIC_BASE + `TARGET_BASE + c*`TARGET_STRIDE, 32'd3, 2, ERROR);

         // Only the admitted S-mode writes took effect.
         ahb_read (1, MACHINE, `PLIC_BASE + `ENABLE_BASE + c*`ENABLE_STRIDE, s_ok ? 32'h0000_000A : 32'h0000_0006, 2, 1, OK);
         ahb_read (1, MACHINE, `PLIC_BASE + `TARGET_BASE + c*`TARGET_STRIDE, s_ok ? 32'd2 : 32'd1, 2, 1, OK);
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
