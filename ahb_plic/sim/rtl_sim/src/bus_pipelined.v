//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    bus_pipelined
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bus_pipelined
// Module Description : AHB-Lite traffic the blocking BFM never issues. Pipelined
//                      back-to-back writes and reads (each address phase overlaps
//                      the previous data phase), a NONSEQ+SEQ word burst (accepted
//                      beat by beat: there is no burst check), IDLE and BUSY carrying
//                      a bad size or a U-mode privilege (zero-wait OKAY, no effect),
//                      and hsize 3'b011 / 3'b000 on a word address (ERROR).
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

integer k;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(6) @(posedge free_clk); #1;

      // Pipelined writes: priority[1..4] = 1..4, one address phase per cycle.
      set_mode(MACHINE); hwrite = 1'b1; hsize = 3'b010; htrans = 2'b10;
      for (k = 1; k <= 4; k = k + 1) begin
         haddr = `PLIC_BASE + `PRIO_BASE + 4*k;
         @(posedge free_clk); #1;
         hwdata = k;
         chk(hreadyout === 1'b1 && hresp === 1'b0, "pipelined write: data phase not zero-wait OKAY");
      end
      bus_idle;
      @(posedge free_clk); #1;

      // Pipelined reads, data checked in each data phase.
      set_mode(MACHINE); hwrite = 1'b0; hsize = 3'b010; htrans = 2'b10;
      haddr = `PLIC_BASE + `PRIO_BASE + 4*1;
      for (k = 1; k <= 4; k = k + 1) begin
         @(posedge free_clk); #1;
         if (k < 4) haddr = `PLIC_BASE + `PRIO_BASE + 4*(k+1); else bus_idle;
         chk(hreadyout === 1'b1 && hresp === 1'b0, "pipelined read: data phase not zero-wait OKAY");
         chk(hrdata === k, "pipelined read returned the wrong priority");
      end
      @(posedge free_clk); #1;

      // NONSEQ + SEQ word burst: both beats written.
      set_mode(MACHINE); hwrite = 1'b1; hsize = 3'b010;
      haddr = `PLIC_BASE + `PRIO_BASE + 4*5; htrans = 2'b10;
      @(posedge free_clk); #1;
      hwdata = 32'd5;
      haddr = `PLIC_BASE + `PRIO_BASE + 4*6; htrans = 2'b11;
      @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b0, "burst beat 1 not zero-wait OKAY");
      hwdata = 32'd6;
      bus_idle;
      @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b0, "burst beat 2 not zero-wait OKAY");
      ahb_read(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*5, 32'd5, 2, 1, OK);
      ahb_read(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*6, 32'd6, 2, 1, OK);

      // IDLE and BUSY with a bad size and from U-mode: not transfers.
      @(posedge free_clk); #1;
      haddr = `PLIC_BASE + `PRIO_BASE + 4*1; hwrite = 1'b1; hsize = 3'b000; set_mode(USER);
      htrans = 2'b00;                                    // IDLE
      @(posedge free_clk); #1;
      hwdata = 32'd7;
      htrans = 2'b01;                                    // BUSY
      chk(hreadyout === 1'b1 && hresp === 1'b0, "IDLE with bad size / U-mode not a zero-wait OKAY");
      @(posedge free_clk); #1;
      bus_idle;
      chk(hreadyout === 1'b1 && hresp === 1'b0, "BUSY with bad size / U-mode not a zero-wait OKAY");
      @(posedge free_clk); #1;
      chk(hresp === 1'b0, "late ERROR after IDLE / BUSY");
      ahb_read(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*1, 32'd1, 2, 1, OK);

      // hsize 3'b011 and 3'b000 on a word address: denied.
      set_mode(MACHINE); hwrite = 1'b1; hsize = 3'b011; htrans = 2'b10;
      haddr = `PLIC_BASE + `PRIO_BASE + 4*2;
      @(posedge free_clk); #1;
      hwdata = 32'd7;
      bus_idle;
      chk(hreadyout === 1'b0 && hresp === 1'b1, "hsize=3'b011: expected ERROR cycle 1");
      @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b1, "hsize=3'b011: expected ERROR cycle 2");
      @(posedge free_clk); #1;
      ahb_read (1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*2, 32'd2, 2, 1, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*2, 32'd7, 0, ERROR);
      ahb_read (1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*2, 32'd2, 2, 1, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
