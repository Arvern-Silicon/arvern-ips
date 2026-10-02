//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    bus_stall_hsel
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : bus_stall_hsel.v
// Module Description : Another subordinate stalls the shared bus (hready low while
//                      this one has no data phase). An address phase presented
//                      during the stall is not taken; if the master withdraws it
//                      (hsel and htrans drop) nothing is written and no response is
//                      raised, denied accesses included; if it holds it, it is taken
//                      exactly once when the stall ends.
//----------------------------------------------------------------------------

localparam REGOUT_00 = 32'h00400000;
localparam REGOUT_01 = 32'h00400004;

task chk;
   input        cond;
   input [8*72-1:0] msg;
   begin
      if (cond !== 1'b1) begin
         $display("ERROR: %0s %t ns", msg, $time);
         error = error + 1;
      end
   end
endtask

// Bus back to idle, sampled on the next edge.
task bus_idle;
   begin
      haddr  = 32'h00000000;
      htrans = 2'b00;
      hwrite = 1'b0;
      hsize  = 3'b000;
      set_mode(USER);
   end
endtask

integer cyc;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(5) @(posedge free_clk); #1;

      ahb_write(1, MACHINE, REGOUT_00, 32'h11111111, 2, OK);
      ahb_write(1, MACHINE, REGOUT_01, 32'h00000000, 2, OK);
      @(posedge free_clk); #1;

      // 1. Admitted write presented during the stall, then withdrawn.
      tb_bus_stall = 1'b1;
      haddr = REGOUT_00; htrans = 2'b10; hwrite = 1'b1; hsize = 3'b010; set_mode(MACHINE);
      hwdata = 32'hDEADBEEF;
      for (cyc = 0; cyc < 3; cyc = cyc + 1) begin
         @(posedge free_clk); #1;
         chk(hreadyout === 1'b1 && hresp === 1'b0, "stalled bus: DUT responded to an untaken address phase");
      end
      bus_idle;                                      // hsel drops with htrans
      @(posedge free_clk); #1;
      tb_bus_stall = 1'b0;
      repeat(3) @(posedge free_clk); #1;
      chk(periph0_reg_00_out === 32'h11111111, "withdrawn address phase was written");

      // 2. Denied write presented during the stall, then withdrawn: no ERROR.
      tb_bus_stall = 1'b1;
      haddr = REGOUT_00; htrans = 2'b10; hwrite = 1'b1; hsize = 3'b010; set_mode(USER);
      for (cyc = 0; cyc < 3; cyc = cyc + 1) begin
         @(posedge free_clk); #1;
         chk(hresp === 1'b0, "stalled bus: ERROR raised for an untaken denied address phase");
      end
      bus_idle;
      @(posedge free_clk); #1;
      tb_bus_stall = 1'b0;
      repeat(3) @(posedge free_clk); #1;
      chk(hresp === 1'b0 && hreadyout === 1'b1, "late ERROR after a withdrawn denied address phase");

      // 3. Admitted write held through the stall: taken once when it ends.
      tb_bus_stall = 1'b1;
      haddr = REGOUT_01; htrans = 2'b10; hwrite = 1'b1; hsize = 3'b010; set_mode(MACHINE);
      repeat(3) @(posedge free_clk); #1;
      chk(periph0_reg_01_out === 32'h00000000, "held address phase taken during the stall");
      tb_bus_stall = 1'b0;
      @(posedge free_clk); #1;                       // address phase taken here
      bus_idle;
      hwdata = 32'h22222222;
      @(posedge free_clk); #1;                       // data phase commits here
      hwdata = 32'h33333333;
      repeat(3) @(posedge free_clk); #1;
      chk(periph0_reg_01_out === 32'h22222222, "held address phase not written exactly once with its data");
      chk(periph0_reg_00_out === 32'h11111111, "held address phase disturbed another register");

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
