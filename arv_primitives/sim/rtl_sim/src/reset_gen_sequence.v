//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    reset_gen_sequence
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : reset_gen_sequence.v
// Module Description : arv_reset_gen release sequencing, in either LF_GATE_EN
//                      setting (-D LF_GATE=0|1): POR with no clock running, a dead and
//                      a late LF clock, warm pulses (also with the LF clock stopped), POR
//                      re-asserted mid-sequence, a warm reset held across the LF release,
//                      and scan mode. Monitors: no X after the first POR, releases only
//                      on an edge of the output's own clock, warm never reaches the LF or
//                      debug reset, hresetn_o never released during a warm reset or (LF
//                      gate on) before resetn_lf_o.
//----------------------------------------------------------------------------
`include "timescale.v"

`ifndef LF_GATE
  `define LF_GATE 1
`endif

module reset_gen_sequence;

reg  porn, warm, scan, hclk, clk_lf, hclk_run, lf_run;
wire resetn_lf, dbgresetn, hresetn;
integer error;

arv_reset_gen #(.LF_GATE_EN(`LF_GATE)) dut (
    .porn_async_i ( porn     ), .warm_reset_i ( warm      ), .scan_mode_i ( scan    ),
    .clk_lf_i     ( clk_lf   ), .hclk_i       ( hclk      ),
    .resetn_lf_o  ( resetn_lf), .dbgresetn_o  ( dbgresetn ), .hresetn_o   ( hresetn )
);

// Gateable clocks: hclk 10 ns, clk_lf 290 ns (asynchronous, ~29x slower).
initial begin hclk   = 1'b0; forever begin #5;   if (hclk_run) hclk   = ~hclk;   else hclk   = 1'b0; end end
initial begin clk_lf = 1'b0; #37; forever begin #145; if (lf_run) clk_lf = ~clk_lf; else clk_lf = 1'b0; end end

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

//---------------------------------------------------------------------------
// Monitors
//---------------------------------------------------------------------------
reg  armed;                         // after the first POR assertion
time lf_pe, h_pe;                   // last rising edge of each clock
reg  warm_q1, warm_q2;              // warm_reset_i at the last two hclk edges
initial begin armed = 1'b0; lf_pe = 0; h_pe = 0; warm_q1 = 1'b0; warm_q2 = 1'b0; end
always @(posedge clk_lf) lf_pe = $time;
always @(posedge hclk) begin h_pe = $time; warm_q2 <= warm_q1; warm_q1 <= warm; end

always @(resetn_lf or dbgresetn or hresetn)
   if (armed) chk(^{resetn_lf, dbgresetn, hresetn} !== 1'bx, "reset output is X/Z");

// Releases happen on an edge of the output's own clock (scan bypass excepted).
always @(posedge resetn_lf) if (armed && !scan) chk($time == lf_pe, "resetn_lf_o released off a clk_lf_i edge");
always @(posedge dbgresetn) if (armed && !scan) chk($time == h_pe,  "dbgresetn_o released off an hclk_i edge");
always @(posedge hresetn)   if (armed && !scan) chk($time == h_pe,  "hresetn_o released off an hclk_i edge");

// The warm reset never reaches the LF or debug domain; POR alone lowers them.
always @(negedge resetn_lf) if (armed && !scan) chk(porn === 1'b0, "resetn_lf_o fell without POR");
always @(negedge dbgresetn) if (armed && !scan) chk(porn === 1'b0, "dbgresetn_o fell without POR");

// hresetn_o never releases with a warm reset seen at either of the last two edges.
always @(posedge hresetn) if (armed && !scan) chk(!(warm_q1 | warm_q2), "hresetn_o released during a warm reset");

always @(posedge hresetn) if (armed && !scan && `LF_GATE) chk(resetn_lf === 1'b1, "hresetn_o released before resetn_lf_o");

//---------------------------------------------------------------------------
// Scenarios
//---------------------------------------------------------------------------
integer k;
initial begin
   error = 0; porn = 1'b0; warm = 1'b0; scan = 1'b0; hclk_run = 1'b0; lf_run = 1'b0;
   #2 armed = 1'b1;

   // B2 / B9 / B3: POR with no clock running, released before the LF clock ever
   // starts. dbgresetn_o releases on hclk; resetn_lf_o must stay asserted until
   // the LF clock has delivered two edges.
   #1; chk({resetn_lf, dbgresetn, hresetn} === 3'b000, "outputs not asserted by POR with clocks stopped");
   #50  hclk_run = 1'b1;
   #150 porn = 1'b1;
   #2000;
   chk(dbgresetn === 1'b1, "dbgresetn_o not released with hclk running");
   chk(resetn_lf === 1'b0, "resetn_lf_o released without clk_lf_i edges");
   chk(hresetn   === (`LF_GATE ? 1'b0 : 1'b1), "hresetn_o wrong while the LF clock is dead");
   lf_run = 1'b1;
   #(290*5);
   chk(resetn_lf === 1'b1, "resetn_lf_o not released after the LF clock started");
   chk(hresetn   === 1'b1, "hresetn_o not released after resetn_lf_o");

   // B5: warm pulses of 1, 2 and 10 hclk cycles.
   for (k = 0; k < 3; k = k + 1) begin
      @(posedge hclk); #1 warm = 1'b1;
      repeat (k == 0 ? 1 : (k == 1 ? 2 : 10)) @(posedge hclk);
      #1 warm = 1'b0;
      repeat (6) @(posedge hclk);
      chk(hresetn === 1'b1 && resetn_lf === 1'b1 && dbgresetn === 1'b1, "not all released after a warm pulse");
   end

   // B5: a warm reset still releases with the LF clock stopped.
   lf_run = 1'b0; #600;
   @(posedge hclk); #1 warm = 1'b1; repeat (3) @(posedge hclk); #1 warm = 1'b0;
   repeat (6) @(posedge hclk);
   chk(hresetn === 1'b1, "warm reset did not release with the LF clock stopped");
   lf_run = 1'b1;

   // B7: POR re-asserted mid-run: everything falls at once, then the sequence restarts.
   #1000 porn = 1'b0; #1;
   chk({resetn_lf, dbgresetn, hresetn} === 3'b000, "POR not asynchronous with clocks running");
   #30 porn = 1'b1;
   #(290*6);
   chk({resetn_lf, dbgresetn, hresetn} === 3'b111, "sequence did not restart after a POR pulse");

   // B6: warm reset held across the cold-boot release of resetn_lf_o, at several
   // offsets: hresetn_o waits for both.
   for (k = 0; k < 6; k = k + 1) begin
      porn = 1'b0; #20 porn = 1'b1;
      @(posedge clk_lf); #(k * 30 + 1);
      warm = 1'b1;
      #(290*4);
      chk(hresetn === 1'b0, "hresetn_o released while the warm reset is held");
      @(posedge hclk); #1 warm = 1'b0;
      repeat (6) @(posedge hclk);
      chk(hresetn === 1'b1, "hresetn_o not released after the warm reset");
   end

   // B11: scan mode: every output is the POR pin, clocks running or stopped, warm ignored.
   scan = 1'b1; #1;
   chk({resetn_lf, dbgresetn, hresetn} === 3'b111, "scan: outputs not equal to porn_async_i");
   warm = 1'b1; #50;
   chk(hresetn === 1'b1, "scan: warm reset reached hresetn_o");
   porn = 1'b0; #1;
   chk({resetn_lf, dbgresetn, hresetn} === 3'b000, "scan: outputs do not follow porn_async_i");
   hclk_run = 1'b0; lf_run = 1'b0; #100 porn = 1'b1; #1;
   chk({resetn_lf, dbgresetn, hresetn} === 3'b111, "scan: outputs need a clock");
   warm = 1'b0; porn = 1'b0; #1 scan = 1'b0;            // leave test mode under POR

   #100;
   if (error == 0) $display("SIMULATION PASSED"); else $display("SIMULATION FAILED (%0d errors)", error);
   $finish;
end

endmodule
