//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dmi_sync_reset_width
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dmi_sync_reset_width
// Module Description : A dbgresetn pulse of the documented minimum width never
//                      fabricates a DMI transaction.
//
//   doc/arv_dtm_jtag.md, Integration requirements: "dbgresetn_i is asserted
//   asynchronously and must be released synchronously to hclk_i ... At
//   ARST_EN = 0 hold it low for at least 3 hclk_i edges." Meaningful with
//   -sync_rst; in the default build it checks the same property at every width.
//   Runs over every transport (-dtm jtag|cjtag|uart|i2c).
//
//   A write leaves its request latched; the target location is then changed
//   behind the DTM's back. dbgresetn is pulsed for N = 1..6 clk edges. For
//   N >= 3 the bus must stay idle for 40 cycles (no replay of the latched write,
//   no read of 0x00) and a fresh transaction must round-trip. N = 1 and 2 are
//   below the contract: their outcome is only reported.
//----------------------------------------------------------------------------

reg     rw_watch;
integer rw_psel_cnt;

initial begin
   rw_watch    = 1'b0;
   rw_psel_cnt = 0;
end

always @(posedge dmi_psel) if (rw_watch) rw_psel_cnt = rw_psel_cnt + 1;

// Re-open the link after a dbgresetn pulse (the transport's own reset included).
task relink;
   begin
      repeat (4) @(posedge free_clk);
`ifdef DTM_UART
      uart_autobaud_sync;
`elsif DTM_I2C
`elsif DTM_CJTAG
      cjtag_active_done = 1'b0;
      tap_reset;
      shift_ir(IR_DMI);
`else
      repeat (4) @(posedge tck);
      tap_reset;
      shift_ir(IR_DMI);
`endif
   end
endtask

initial
   begin : test
      integer    n;
      integer    k;
      reg [31:0] rd;
      reg  [1:0] st;

      dtm_init;

      for (n = 1; n <= 6; n = n + 1) begin
         dtm_dmi_write(7'h10, 32'h0BAD_0010, st);        // request latched
         repeat (20) @(posedge free_clk);
         slave_mem[7'h10] = 32'h600D_0010;               // changed behind the DTM's back
         slave_mem[7'h00] = 32'h600D_0000;

         @(posedge free_clk);
         rw_psel_cnt = 0;
         rw_watch    = 1'b1;
         #1 dbgresetn = 1'b0;
         for (k = 0; k < n; k = k + 1) @(posedge free_clk);
         #1 dbgresetn = 1'b1;
         repeat (40) @(posedge free_clk);
         rw_watch = 1'b0;

         if (n >= 3) begin
            check_eq("no_phantom_psel", rw_psel_cnt, 0);
            check_eq("no_replay",       slave_mem[7'h10], 32'h600D_0010);
         end else begin
            $display("INFO:  %0d-edge pulse (below the 3-edge contract): %0d DMI transfer(s), mem[0x10] = 0x%0h",
                     n, rw_psel_cnt, slave_mem[7'h10]);
         end

         relink;
         dtm_dmi_read(7'h10, rd, st);
         check_eq("after_op",   st, OP_SUCCESS);
         check_eq("after_data", rd, slave_mem[7'h10]);
      end

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
