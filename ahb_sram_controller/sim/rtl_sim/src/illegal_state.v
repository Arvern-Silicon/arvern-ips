//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    illegal_state
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : illegal_state.v
// Module Description : Illegal state-register encodings (3'b001, 3'b101, 3'b110,
//                      3'b111), deposited directly into the state flop right
//                      after reset and after a write: no SRAM command is
//                      issued and the controller returns to IDLE on the next
//                      edge, then serves traffic normally. Words 0 and 1 only.
//----------------------------------------------------------------------------

integer     ii;
reg   [2:0] bad;

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

task inject;
   input [2:0] enc;
   begin
      mon_armed = 1'b0;                          // the enable is high for one idle cycle
      ahb_sram_controller_inst0.u_state.q_o = enc;
      #1;
      chk(sram_cen === 1'b1 && sram_wen === 4'b1111, "illegal state issued an SRAM command");
      @(posedge free_clk); #1;
      chk(ahb_sram_controller_inst0.u_state.q_o === 3'b000, "illegal state did not return to IDLE");
      mon_armed = 1'b1;
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      #1;
      for (ii = 0; ii < 4; ii = ii + 1) begin
         bad = (ii == 0) ? 3'b001 : (ii == 1) ? 3'b101 : (ii == 2) ? 3'b110 : 3'b111;
         inject(bad);
      end
      repeat(3) @(posedge free_clk); #1;

      // After a write has loaded the lane buffer and the pause buffer.
      haddr = 32'h00400004; htrans = 2'b10; hwrite = 1'b1; hsize = 3'b010;
      @(posedge free_clk); #1;
      hwdata = 32'h600DF00D;
      haddr = 32'h00400000; hwrite = 1'b0;       // pauses the write into the buffer
      @(posedge free_clk); #1;
      haddr = 32'h0; htrans = 2'b00;             // restore
      @(posedge free_clk); #1;
      for (ii = 0; ii < 4; ii = ii + 1) begin
         bad = (ii == 0) ? 3'b001 : (ii == 1) ? 3'b101 : (ii == 2) ? 3'b110 : 3'b111;
         inject(bad);
      end
      chk(sram_inst.mem[0] === 32'h00000000 && sram_inst.mem[1] === 32'h600DF00D, "memory changed by an illegal state");

      // Traffic after recovery.
      haddr = 32'h00400000; htrans = 2'b10; hwrite = 1'b1; hsize = 3'b010;
      @(posedge free_clk); #1;
      hwdata = 32'h12121212;
      hwrite = 1'b0;
      @(posedge free_clk); #1;
      haddr = 32'h0; htrans = 2'b00;
      chk(hrdata === 32'h12121212, "read after recovery returned the wrong word");
      repeat(2) @(posedge free_clk); #1;

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
