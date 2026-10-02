//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    cells_contract
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : cells_contract.v
// Module Description : The six cells against the library contract, in every
//                      parameter arm: arv_ipdff / arv_ipdff_sinit in all four
//                      ARST_EN x CLK_NEGEDGE combinations (reset timing, enable
//                      hold, RST_VAL, and for _sinit the priority reset > sinit >
//                      enable), arv_synchronizer latency and its reset in both
//                      styles (a synchronous reset reaches sync_o on the second
//                      edge), arv_cgate (no pulse from an enable change while the
//                      clock is high; test_en forces the clock on), arv_and /
//                      arv_or.
//----------------------------------------------------------------------------
`include "timescale.v"

module cells_contract;

reg  clk, rst_n, en, sinit;
reg  [3:0] d;
integer error;

initial begin clk = 1'b0; forever #5 clk = ~clk; end

task chk;
   input        cond;
   input [8*56-1:0] msg;
   begin
      if (cond !== 1'b1) begin
         $display("ERROR: %0s  %0t ns", msg, $time);
         error = error + 1;
      end
   end
endtask

// ---- flops: [ARST_EN][CLK_NEGEDGE] --------------------------------------
wire [3:0] q_a_p, q_a_n, q_s_p, q_s_n;          // arv_ipdff
wire [3:0] i_a_p, i_a_n, i_s_p, i_s_n;          // arv_ipdff_sinit
arv_ipdff #(.WIDTH(4), .RST_VAL(4'hA), .ARST_EN(1'b1), .CLK_NEGEDGE(1'b0)) u_ap (.clk_i(clk), .rst_n_i(rst_n), .en_i(en), .d_i(d), .q_o(q_a_p));
arv_ipdff #(.WIDTH(4), .RST_VAL(4'hA), .ARST_EN(1'b1), .CLK_NEGEDGE(1'b1)) u_an (.clk_i(clk), .rst_n_i(rst_n), .en_i(en), .d_i(d), .q_o(q_a_n));
arv_ipdff #(.WIDTH(4), .RST_VAL(4'hA), .ARST_EN(1'b0), .CLK_NEGEDGE(1'b0)) u_sp (.clk_i(clk), .rst_n_i(rst_n), .en_i(en), .d_i(d), .q_o(q_s_p));
arv_ipdff #(.WIDTH(4), .RST_VAL(4'hA), .ARST_EN(1'b0), .CLK_NEGEDGE(1'b1)) u_sn (.clk_i(clk), .rst_n_i(rst_n), .en_i(en), .d_i(d), .q_o(q_s_n));
arv_ipdff_sinit #(.WIDTH(4), .RST_VAL(4'h5), .ARST_EN(1'b1), .CLK_NEGEDGE(1'b0)) v_ap (.clk_i(clk), .rst_n_i(rst_n), .sinit_i(sinit), .en_i(en), .d_i(d), .q_o(i_a_p));
arv_ipdff_sinit #(.WIDTH(4), .RST_VAL(4'h5), .ARST_EN(1'b1), .CLK_NEGEDGE(1'b1)) v_an (.clk_i(clk), .rst_n_i(rst_n), .sinit_i(sinit), .en_i(en), .d_i(d), .q_o(i_a_n));
arv_ipdff_sinit #(.WIDTH(4), .RST_VAL(4'h5), .ARST_EN(1'b0), .CLK_NEGEDGE(1'b0)) v_sp (.clk_i(clk), .rst_n_i(rst_n), .sinit_i(sinit), .en_i(en), .d_i(d), .q_o(i_s_p));
arv_ipdff_sinit #(.WIDTH(4), .RST_VAL(4'h5), .ARST_EN(1'b0), .CLK_NEGEDGE(1'b1)) v_sn (.clk_i(clk), .rst_n_i(rst_n), .sinit_i(sinit), .en_i(en), .d_i(d), .q_o(i_s_n));

// ---- synchronisers -------------------------------------------------------
reg  a;
wire s_a, s_s;
arv_synchronizer #(.W(1), .RST_VAL(1'b1), .ARST_EN(1'b1)) u_sync_a (.clk_i(clk), .rst_n_i(rst_n), .async_i(a), .sync_o(s_a));
arv_synchronizer #(.W(1), .RST_VAL(1'b1), .ARST_EN(1'b0)) u_sync_s (.clk_i(clk), .rst_n_i(rst_n), .async_i(a), .sync_o(s_s));

// ---- clock gate, gates ---------------------------------------------------
reg  cg_en, cg_te;
wire gclk;
arv_cgate u_cg (.clk_i(clk), .en_i(cg_en), .test_en_i(cg_te), .clk_o(gclk));
wire g_and, g_or;
arv_and #(.N(3)) u_and (.a_i(d[2:0]), .z_o(g_and));
arv_or  #(.N(3)) u_or  (.a_i(d[2:0]), .z_o(g_or));

integer gpulses;
initial gpulses = 0;
always @(posedge gclk) gpulses = gpulses + 1;

integer k;
initial begin
   error = 0; rst_n = 1'b1; en = 1'b0; sinit = 1'b0; d = 4'h0; a = 1'b0; cg_en = 1'b0; cg_te = 1'b0;

   // Asynchronous arms reset at once, synchronous arms on their next active edge.
   #12 rst_n = 1'b0; #1;
   chk(q_a_p === 4'hA && q_a_n === 4'hA && i_a_p === 4'h5 && i_a_n === 4'h5, "async arm did not reset at once");
   chk(s_a === 1'b1, "async synchroniser output not at RST_VAL at once");
   @(posedge clk); #1 chk(q_s_p === 4'hA && i_s_p === 4'h5, "sync posedge arm did not reset on the edge");
   @(negedge clk); #1 chk(q_s_n === 4'hA && i_s_n === 4'h5, "sync negedge arm did not reset on the edge");
   @(posedge clk); #1 chk(s_s === 1'b1, "sync synchroniser not at RST_VAL on the second edge");
   rst_n = 1'b1;

   // Enable loads on the active edge only; enable low holds.
   @(negedge clk); #1 en = 1'b1; d = 4'h3;
   @(posedge clk); #1 chk(q_a_p === 4'h3 && q_s_p === 4'h3 && q_a_n === 4'hA, "posedge arms did not load / negedge loaded early");
   @(negedge clk); #1 chk(q_a_n === 4'h3 && q_s_n === 4'h3, "negedge arms did not load");
   en = 1'b0; d = 4'hC;
   repeat (2) @(posedge clk); #1 chk(q_a_p === 4'h3 && q_s_n === 4'h3, "enable low did not hold");

   // _sinit: sinit re-inits on the edge even with enable high; reset beats sinit.
   en = 1'b1; d = 4'h9;
   @(posedge clk); #1 chk(i_a_p === 4'h9 && i_s_p === 4'h9, "_sinit posedge did not load");
   sinit = 1'b1;
   @(posedge clk); #1 chk(i_a_p === 4'h5 && i_s_p === 4'h5, "sinit did not win over enable");
   @(negedge clk); #1 chk(i_a_n === 4'h5 && i_s_n === 4'h5, "negedge sinit did not re-init");
   sinit = 1'b0; en = 1'b0;
   @(posedge clk); #1 chk(i_a_p === 4'h5, "_sinit did not hold after sinit");

   // Synchroniser latency: a change reaches sync_o on the second edge.
   @(negedge clk); a = 1'b1;
   repeat (3) @(posedge clk);
   @(negedge clk); a = 1'b0;
   @(posedge clk); #1 chk(s_a === 1'b1 && s_s === 1'b1, "synchroniser passed a change in one edge");
   @(posedge clk); #1 chk(s_a === 1'b0 && s_s === 1'b0, "synchroniser did not pass a change in two edges");

   // Clock gate: an enable change while the clock is high produces no pulse.
   @(negedge clk); gpulses = 0;
   repeat (3) @(posedge clk); #1 chk(gpulses == 0, "gated clock ran with en low");
   @(posedge clk); #2 cg_en = 1'b1;                   // clock high: must wait for the low phase
   #1 chk(gclk === 1'b0, "gated clock rose mid high-phase");
   repeat (3) @(posedge clk); #1 chk(gpulses == 3, "gated clock did not pass with en high");
   @(posedge clk); #2 cg_en = 1'b0; #1 chk(gclk === 1'b1, "gated clock truncated mid high-phase");
   @(negedge clk); gpulses = 0;
   cg_te = 1'b1;
   repeat (2) @(posedge clk); #1 chk(gpulses == 2, "test_en did not force the clock on");
   cg_te = 1'b0;

   // Gates.
   for (k = 0; k < 8; k = k + 1) begin
      d = k; #1;
      chk(g_and === &d[2:0] && g_or === |d[2:0], "arv_and / arv_or wrong");
   end

   #20;
   if (error == 0) $display("SIMULATION PASSED"); else $display("SIMULATION FAILED (%0d errors)", error);
   $finish;
end

endmodule
