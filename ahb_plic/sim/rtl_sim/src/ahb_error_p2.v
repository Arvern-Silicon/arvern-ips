//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_error_p2
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_error_p2
// Module Description : Cycle-accurate check of the two-cycle AHB ERROR protocol
//                      (ahb_plic.v:431-443). The BFM samples hresp once, so a
//                      regression to a 1-cycle error or wrong hreadyout shape
//                      would pass. A denied access (here a byte-size access,
//                      denied independent of privilege) must drive:
//                        P1 : hresp=1, hreadyout=0  (error, stall)
//                        P2 : hresp=1, hreadyout=1  (error, complete)
//                        next: hresp=0              (recovered)
//----------------------------------------------------------------------------

`define PLIC_BASE  32'h00400000
`define PRIO_BASE  32'h00000000

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(6) @(posedge free_clk);

      $display(" ===============================================");
      $display("|        PLIC : TWO-CYCLE ERROR (P1 + P2)       |");
      $display(" ===============================================");

      // Drive the address phase of a DENIED access: byte (size=0) access to a
      // valid register. Bad size is denied regardless of PRIV_CHECK_EN.
      haddr  = `PLIC_BASE + `PRIO_BASE + 4*1;
      htrans = 2'b10;          // NONSEQ
      hwrite = 1'b0;
      hprot  = 4'h2;           // MACHINE
      hsmode = 1'b0;
      hsize  = 3'b000;         // byte -> denied

      @(posedge free_clk);
      #1;
      haddr  = 32'h00000000;
      htrans = 2'b00;
      hsize  = 3'b000;

      // --- P1 ---
      if ((hresp === 1'b1) && (hreadyout === 1'b0)) begin
         $display("PASS:  P1 -- hresp=1, hreadyout=0 (error + stall) %t ns", $time);
      end else begin
         $display("ERROR: P1 -- expected hresp=1/hreadyout=0, got hresp=%b/hreadyout=%b %t ns",
                  hresp, hreadyout, $time);
         error = error + 1;
      end

      @(posedge free_clk);
      #1;
      // --- P2 ---
      if ((hresp === 1'b1) && (hreadyout === 1'b1)) begin
         $display("PASS:  P2 -- hresp=1, hreadyout=1 (error + complete) %t ns", $time);
      end else begin
         $display("ERROR: P2 -- expected hresp=1/hreadyout=1, got hresp=%b/hreadyout=%b %t ns",
                  hresp, hreadyout, $time);
         error = error + 1;
      end

      @(posedge free_clk);
      #1;
      // --- recovery ---
      if (hresp === 1'b0) begin
         $display("PASS:  post-error -- hresp returned to 0 %t ns", $time);
      end else begin
         $display("ERROR: post-error -- hresp still %b (error not exactly 2 cycles) %t ns", hresp, $time);
         error = error + 1;
      end

      // A legal word access right after must still succeed.
      ahb_read(1, MACHINE, `PLIC_BASE + `PRIO_BASE + 4*1, 32'd0, 2, 1, OK);

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
