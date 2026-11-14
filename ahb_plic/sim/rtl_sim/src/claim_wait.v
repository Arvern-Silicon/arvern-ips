//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    claim_wait
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : claim_wait
// Module Description : Cycle-accurate check of the claim read's wait state.
//                      (a) A claim read stalls one cycle ({hresp, hreadyout} =
//                          0,0), then returns the ID (0,1); pending is cleared
//                          by the edge completing the data phase, not before.
//                      (b) A claim with nothing pending stalls the same way,
//                          returns 0 and changes no state.
//                      (c) A higher-priority source that pends during the wait
//                          state is not the one claimed: the registered winner
//                          is returned, the new source stays pending and is
//                          returned by the next claim.
//                      (d) A completion and a threshold write and read stay
//                          zero-wait.
//----------------------------------------------------------------------------

`define PLIC_BASE      32'h00400000
`define PRIO_BASE      32'h00000000
`define PENDING_BASE   32'h00001000
`define ENABLE_BASE    32'h00002000
`define TARGET_BASE    32'h00200000

localparam CW_MAXP = (1 << PRIO_BITS) - 1;
localparam CW_HI   = 5;                             // high-priority source
localparam CW_LO   = 6;                             // low-priority source

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
      set_mode(MACHINE);
   end
endtask

task cw_aph;
   input        wr;
   input [31:0] addr;
   begin
      haddr  = addr;
      htrans = 2'b10;
      hwrite = wr;
      hsize  = 3'b010;
      set_mode(MACHINE);
   end
endtask

`define CLAIM0  (`PLIC_BASE + `TARGET_BASE + 32'h4)
`define THRESH0 (`PLIC_BASE + `TARGET_BASE)

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      tb_ahb_plic.irq_src = {(NUM_SOURCES+1){1'b0}};
      repeat(6) @(posedge free_clk); #1;

      // With PRIO_BITS=1 both sources share priority 1: the tie goes to the
      // lower ID, so CW_HI still wins.
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*CW_HI, CW_MAXP, 2, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*CW_LO, 32'd1, 2, OK);
      ahb_write(1, MACHINE, `PLIC_BASE + `ENABLE_BASE, (32'h1 << CW_HI) | (32'h1 << CW_LO), 2, OK);
      ahb_write(1, MACHINE, `THRESH0, 32'd0, 2, OK);

      $display(" ===============================================");
      $display("|  (a) CLAIM READ: STALL, THEN THE ID           |");
      $display(" ===============================================");

      irq_src[CW_HI] = 1'b1;
      repeat(3) @(posedge free_clk); #1;
      cw_aph(0, `CLAIM0);
      @(posedge free_clk); #1;
      bus_idle;
      chk(hreadyout === 1'b0 && hresp === 1'b0, "(a) first data-phase cycle is not a wait state");
      chk(dut.pending_flat[CW_HI] === 1'b1 && dut.in_service_flat[CW_HI] === 1'b0, "(a) source claimed before the data phase completes");
      @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b0 && hrdata === CW_HI, "(a) second cycle did not return the ID with OKAY");
      chk(dut.pending_flat[CW_HI] === 1'b1, "(a) pending cleared before the completing edge");
      @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hrdata === 32'h0, "(a) bus not released after the claim");
      chk(dut.pending_flat[CW_HI] === 1'b0 && dut.in_service_flat[CW_HI] === 1'b1, "(a) claim not applied on the completing edge");
      irq_src[CW_HI] = 1'b0;
      ahb_write(1, MACHINE, `CLAIM0, CW_HI, 2, OK);

      $display(" ===============================================");
      $display("|  (b) CLAIM WITH NOTHING PENDING               |");
      $display(" ===============================================");

      repeat(2) @(posedge free_clk); #1;
      cw_aph(0, `CLAIM0);
      @(posedge free_clk); #1;
      bus_idle;
      chk(hreadyout === 1'b0 && hresp === 1'b0, "(b) empty claim did not stall");
      @(posedge free_clk); #1;
      chk(hreadyout === 1'b1 && hresp === 1'b0 && hrdata === 32'h0, "(b) empty claim did not return 0");
      @(posedge free_clk); #1;
      chk(dut.in_service_flat[NUM_SOURCES:1] === {NUM_SOURCES{1'b0}} &&
          dut.pending_flat[NUM_SOURCES:1]    === {NUM_SOURCES{1'b0}}, "(b) empty claim changed state");

      $display(" ===============================================");
      $display("|  (c) A SOURCE PENDING DURING THE WAIT STATE   |");
      $display(" ===============================================");

      irq_src[CW_LO] = 1'b1;
      repeat(3) @(posedge free_clk); #1;
      cw_aph(0, `CLAIM0);
      @(posedge free_clk); #1;
      bus_idle;
      irq_src[CW_HI] = 1'b1;                            // sampled by the edge that ends the wait state
      chk(hreadyout === 1'b0, "(c) first data-phase cycle is not a wait state");
      @(posedge free_clk); #1;
      chk(dut.pending_flat[CW_HI] === 1'b1, "(c) new source not pending during the second cycle");
      chk(hreadyout === 1'b1 && hrdata === CW_LO, "(c) claim did not return the winner registered in the wait state");
      @(posedge free_clk); #1;
      chk(dut.in_service_flat[CW_LO] === 1'b1 && dut.in_service_flat[CW_HI] === 1'b0 &&
          dut.pending_flat[CW_HI]    === 1'b1, "(c) wrong source claimed, or the new one not left pending");
      ahb_read(1, MACHINE, `CLAIM0, CW_HI, 2, 1, OK);
      irq_src[CW_HI] = 1'b0;
      irq_src[CW_LO] = 1'b0;
      ahb_write(1, MACHINE, `CLAIM0, CW_LO, 2, OK);
      ahb_write(1, MACHINE, `CLAIM0, CW_HI, 2, OK);

      $display(" ===============================================");
      $display("|  (d) COMPLETE AND THRESHOLD STAY ZERO-WAIT    |");
      $display(" ===============================================");

      irq_src[CW_HI] = 1'b1;
      repeat(3) @(posedge free_clk); #1;
      ahb_read(1, MACHINE, `CLAIM0, CW_HI, 2, 1, OK);
      irq_src[CW_HI] = 1'b0;
      @(posedge free_clk); #1;
      cw_aph(1, `CLAIM0);
      @(posedge free_clk); #1;
      hwdata = CW_HI;
      cw_aph(1, `THRESH0);
      chk(hreadyout === 1'b1 && hresp === 1'b0, "(d) complete is not zero-wait");
      @(posedge free_clk); #1;
      hwdata = 32'd1;
      cw_aph(0, `THRESH0);
      chk(hreadyout === 1'b1 && hresp === 1'b0, "(d) threshold write is not zero-wait");
      @(posedge free_clk); #1;
      hwdata = 32'h0;
      bus_idle;
      chk(hreadyout === 1'b1 && hresp === 1'b0 && hrdata === 32'd1, "(d) threshold read is not zero-wait");
      @(posedge free_clk); #1;
      chk(dut.in_service_flat[CW_HI] === 1'b0, "(d) completion not applied");
      ahb_write(1, MACHINE, `THRESH0, 32'd0, 2, OK);

      repeat(10) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
