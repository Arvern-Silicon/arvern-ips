//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    pclk_gating
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : pclk_gating.v
// Module Description : Clock request: no request while idle, with entries
//                      queued and EN clear, or with a select held across an
//                      empty FIFO; transactions complete with the bus clock
//                      gated by pclk_en_o alone (the always-on check compares
//                      pclk_en_o with its formula every cycle); an ABORT with
//                      a held select and an idle bus releases the select by
//                      itself and sets DONE.
//
// Doc "Clock request".
//----------------------------------------------------------------------------

integer i;

task no_request;
   input integer n;
   input [80*8-1:0] what;
   integer k;
   begin
      for (k = 0; k < n; k = k + 1)
        begin
           @(negedge free_clk);
           if (pclk_en !== 1'b0) begin
              $display("ERROR: clock requested: %0s %t ns", what, $time);
              error = error + 1;
              k = n;
           end
        end
   end
endtask

initial
   begin
      wait_reset_done(5);
      no_request(20, "idle after reset");
      clk_set(2, 0);
      cs_set(8'h00, 2, 2, 2);
      ctrl_wr(C_IDLE_HIGH);                    // EN clear
      ent_tx(8, 32'h5A, 1'b0);
      ent_tx(16, 32'h1234, 1'b0);
      no_request(20, "entries queued, EN clear");
      ctrl_wr(C_EN | C_IDLE_HIGH);
      wait_idle(10000);
      irq_chk(I_DONE, I_DONE);
      no_request(20, "idle after a transaction");
      // a held select across an empty FIFO requests nothing
      ent_tx(8, 32'hC3, 1'b1);
      wait_quiet(10000);
      chk(apb_spi_inst0.core_cs === 1'b1, "select held");
      no_request(50, "select held across an empty FIFO");
      ent_tx(8, 32'h3C, 1'b0);
      wait_idle(10000);
      // ABORT with a held select and nothing in progress: the release completes under the gated clock
      ent_tx(8, 32'hA5, 1'b1);
      wait_quiet(10000);
      wr(R_IRQ_PEND, 32'h7C);
      abort_ok = 1;
      wr(R_CMD, K_ABORT);
      for (i = 0; i < 200 && apb_spi_inst0.core_cs; i = i + 1) @(posedge free_clk);
      abort_ok = 0;
      chk(apb_spi_inst0.core_cs === 1'b0, "ABORT releases a held select by itself");
      wait_idle(10000);
      irq_chk(I_DONE, I_DONE);
      no_request(20, "idle after the abort");
      stimulus_done = 1;
   end
