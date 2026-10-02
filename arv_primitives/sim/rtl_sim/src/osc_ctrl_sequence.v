//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    osc_ctrl_sequence
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : osc_ctrl_sequence.v
// Module Description : arv_osc_ctrl stop / wake contract against the bench
//                      oscillator model: exactly one osc_clk_i edge between the
//                      announce (clk_en_o falling) and the stop (osc_en_o
//                      falling); a request inside that window cancels the stop;
//                      an asynchronous wake restarts a stopped oscillator; the
//                      preset releases two osc_clk_i edges after the wake falls;
//                      in scan mode a wake is ignored.
//----------------------------------------------------------------------------
`include "timescale.v"

module osc_ctrl_sequence;

reg  resetn, wake, enable, scan;
wire osc_clk, osc_en, clk_en;
integer error;

osc #(.HALF_PERIOD(5)) u_osc (.en_i(osc_en), .clk_o(osc_clk));

arv_osc_ctrl dut (
    .osc_clk_i ( osc_clk ), .osc_en_o ( osc_en ),
    .resetn_i  ( resetn  ), .scan_mode_i ( scan ),
    .wake_i    ( wake    ), .enable_i ( enable ), .clk_en_o ( clk_en )
);

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

// Edges delivered between the announce and the stop.
integer gap_edges;
reg     in_gap;
initial begin in_gap = 1'b0; gap_edges = 0; end
always @(negedge clk_en) begin in_gap = 1'b1; gap_edges = 0; end
always @(posedge osc_clk) if (in_gap) gap_edges = gap_edges + 1;
always @(negedge osc_en)  begin chk(gap_edges == 1, "not exactly one edge between announce and stop"); in_gap = 1'b0; end

task stop_request;             // drop enable just after an edge
   begin
      @(posedge osc_clk); #1 enable = 1'b0;
   end
endtask

integer k;
initial begin
   error = 0; resetn = 1'b0; wake = 1'b0; enable = 1'b0; scan = 1'b0;
   #1;  chk(osc_en === 1'b1 && clk_en === 1'b1, "reset does not preset run / announce");
   #20 resetn = 1'b1; enable = 1'b1;
   repeat (5) @(posedge osc_clk);

   // Stop sequence: announce, one edge, stop.
   stop_request;
   #200;
   chk(osc_en === 1'b0 && clk_en === 1'b0, "oscillator not stopped");

   // Asynchronous wake restarts it with no clock; hold wake until the consumer asks.
   #50 wake = 1'b1; #1;
   chk(osc_en === 1'b1 && clk_en === 1'b1, "wake did not restart the stopped oscillator");
   repeat (3) @(posedge osc_clk);
   #1 enable = 1'b1;
   @(posedge osc_clk); #1 wake = 1'b0;
   repeat (5) @(posedge osc_clk);
   chk(osc_en === 1'b1, "oscillator stopped with the request held");

   // Preset release: after a wake falls with no request, the preset holds for two
   // edges before the stop sequence can start.
   stop_request; #200;
   #50 wake = 1'b1; #30 wake = 1'b0;
   @(posedge osc_clk); #1 chk(clk_en === 1'b1, "preset released on the first edge after wake");
   @(posedge osc_clk); #1 chk(clk_en === 1'b1, "preset released on the second edge after wake");
   #200;
   chk(osc_en === 1'b0, "oscillator not stopped after the wake released");

   // A request inside the announce window cancels the stop.
   #50 wake = 1'b1; #1 enable = 1'b1; #20 wake = 1'b0;
   repeat (5) @(posedge osc_clk);
   @(posedge osc_clk); #1 enable = 1'b0;       // announce at the next edge
   @(posedge osc_clk); #1 enable = 1'b1;       // back before the stop edge
   repeat (4) @(posedge osc_clk);
   chk(osc_en === 1'b1 && clk_en === 1'b1, "late request did not cancel the stop");

   // Scan mode: a wake does not reach the preset.
   stop_request; #200;
   chk(osc_en === 1'b0, "setup: oscillator not stopped");
   scan = 1'b1; #10 wake = 1'b1; #50;
   chk(osc_en === 1'b0, "scan: wake restarted the oscillator");
   wake = 1'b0; scan = 1'b0;

   #50;
   if (error == 0) $display("SIMULATION PASSED"); else $display("SIMULATION FAILED (%0d errors)", error);
   $finish;
end

endmodule
