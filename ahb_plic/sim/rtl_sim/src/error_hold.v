//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    error_hold
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : error_hold
// Module Description : Transfers around a two-cycle ERROR. The next address phase
//                      held through the ERROR is taken in its second cycle and then
//                      completes normally; two denied transfers back to back give
//                      two full ERROR responses; a denied read returns 0 in both
//                      ERROR cycles; a denied claim read neither claims nor clears
//                      the pending source.
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

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      tb_ahb_plic.irq_src = {(NUM_SOURCES+1){1'b0}};
      repeat(6) @(posedge free_clk); #1;

      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*2, 32'd5, 2, OK);
      @(posedge free_clk); #1;

      // Denied U-mode write, then an M read held through the ERROR.
      haddr = `PLIC_BASE + `PRIO_BASE + 4*1; htrans = 2'b10; hwrite = 1'b1; hsize = 3'b010; set_mode(USER);
      @(posedge free_clk); #1;
      hwdata = 32'd7;
      haddr = `PLIC_BASE + `PRIO_BASE + 4*2; htrans = 2'b10; hwrite = 1'b0; set_mode(MACHINE);
      chk(hreadyout === 1'b0 && hresp === 1'b1, "ERROR cycle 1: expected hreadyout=0, hresp=1");
      @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b1, "ERROR cycle 2: expected hreadyout=1, hresp=1");
      @(posedge free_clk); #1;                             // held read taken at this edge
      bus_idle;
      chk(hreadyout === 1'b1 && hresp === 1'b0, "held read after ERROR: not OKAY");
      chk(hrdata === 32'd5, "held read after ERROR returned the wrong data");
      @(posedge free_clk); #1;
      ahb_read(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*1, 32'd0, 2, 1, OK);

      // Two denied reads back to back: read data 0 throughout.
      haddr = `PLIC_BASE + `PRIO_BASE + 4*2; htrans = 2'b10; hwrite = 1'b0; hsize = 3'b010; set_mode(USER);
      @(posedge free_clk); #1;
      haddr = `PLIC_BASE + `PRIO_BASE + 4*2; set_mode(USER);
      chk(hresp === 1'b1 && hreadyout === 1'b0 && hrdata === 32'h0, "1st denied read, cycle 1: ERROR with hrdata=0");
      @(posedge free_clk); #1;
      chk(hresp === 1'b1 && hreadyout === 1'b1 && hrdata === 32'h0, "1st denied read, cycle 2: ERROR with hrdata=0");
      @(posedge free_clk); #1;                             // second denied read taken
      bus_idle;
      chk(hresp === 1'b1 && hreadyout === 1'b0 && hrdata === 32'h0, "2nd denied read, cycle 1: ERROR with hrdata=0");
      @(posedge free_clk); #1;
      chk(hresp === 1'b1 && hreadyout === 1'b1 && hrdata === 32'h0, "2nd denied read, cycle 2: ERROR with hrdata=0");
      @(posedge free_clk); #1;
      chk(hresp === 1'b0 && hreadyout === 1'b1, "bus not back to OKAY after the second ERROR");

      // Denied claim read: source 2 pending and enabled for context 0.
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE, 32'h0000_0004, 2, OK);
      tb_ahb_plic.irq_src[2] = 1'b1;
      repeat(3) @(posedge free_clk); #1;
      chk(dut.pending_flat[2] === 1'b1, "setup: source 2 not pending");
      ahb_read(1, USER, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd0, 2, 0, ERROR);
      repeat(2) @(posedge free_clk); #1;
      chk(dut.pending_flat[2] === 1'b1 && dut.in_service_flat[2] === 1'b0,
          "denied claim read claimed the source");
      ahb_read(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd2, 2, 1, OK);
      tb_ahb_plic.irq_src[2] = 1'b0;
      ahb_write(1, MACHINE, `PLIC_BASE + `TARGET_BASE + 32'h4, 32'd2, 2, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
