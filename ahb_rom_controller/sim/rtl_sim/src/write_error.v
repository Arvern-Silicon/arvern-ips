//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    write_error
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : write_error.v
// Module Description : A WRITE TO ROM IS AN ERROR, NOT A SILENT NO-OP.
//
//                      Acknowledging a write with OKAY tells firmware its
//                      store succeeded. The controller answers the AHB-Lite
//                      two-cycle ERROR instead, which on an aRVern hart
//                      arrives as a resumable NMI -- the only notice a store
//                      to read-only memory ever gets.
//
//                      This drives the bus directly and checks the exact shape
//                      cycle by cycle (the bench's bus monitor checks it too,
//                      in every test):
//                        P1   : hresp=1, hreadyout=0  (error, stall)
//                        P2   : hresp=1, hreadyout=1  (error, complete)
//                        next : hresp=0               (recovered)
//                      then that the ROM is untouched and reads still work.
//----------------------------------------------------------------------------

integer        ii;
integer        jj;
reg     [31:0] exp_value;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      for (tb_idx=0; tb_idx < MEM_SIZE/4; tb_idx=tb_idx+1)
        rom_inst.mem[tb_idx] = $urandom;

      repeat(10) @(posedge free_clk);

      $display(" ===============================================");
      $display("|        ROM : A WRITE IS ANSWERED ERROR        |");
      $display(" ===============================================");

      exp_value = rom_inst.mem['h0A0];

      // Address phase of a write into the ROM window.
      haddr  = 32'h00400280;
      htrans = 2'b10;
      hwrite = 1'b1;
      hsize  = 3'b010;

      @(posedge free_clk);
      #1;
      haddr  = 32'h00000000;   // go idle so no further transfer starts
      htrans = 2'b00;
      hwrite = 1'b0;

      // --- P1: first error cycle (stall) ---
      if ((hresp === 1'b1) && (hreadyout === 1'b0)) begin
         $display("PASS:  P1 -- hresp=1, hreadyout=0 (error + stall) %t ns", $time);
      end else begin
         $display("ERROR: P1 -- expected hresp=1/hreadyout=0, got hresp=%b/hreadyout=%b %t ns",
                  hresp, hreadyout, $time);
         error = error + 1;
      end

      @(posedge free_clk);
      #1;
      // --- P2: second error cycle (complete) ---
      if ((hresp === 1'b1) && (hreadyout === 1'b1)) begin
         $display("PASS:  P2 -- hresp=1, hreadyout=1 (error + complete) %t ns", $time);
      end else begin
         $display("ERROR: P2 -- expected hresp=1/hreadyout=1, got hresp=%b/hreadyout=%b %t ns",
                  hresp, hreadyout, $time);
         error = error + 1;
      end

      @(posedge free_clk);
      #1;
      // --- Recovery ---
      if (hresp === 1'b0) begin
         $display("PASS:  post-error -- hresp returned to 0 %t ns", $time);
      end else begin
         $display("ERROR: post-error -- hresp still %b (error not exactly two cycles) %t ns",
                  hresp, $time);
         error = error + 1;
      end

      // The ROM must be untouched by the refused write.
      check_mem_value('h0A0, exp_value);

      // And the controller must still serve reads normally afterwards.
      repeat(4) @(posedge free_clk);
      ahb_read(1, 32'h00400280, exp_value, 2, 1);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
