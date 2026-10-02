//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    osc
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : osc.v
// Module Description : Behavioural oscillator. Toggles while en_i is high and
//                      parks LOW when it is not, restarting cleanly from the low
//                      phase. That is all it does: the decision of WHEN to stop,
//                      and the announcement that lets consumers prepare for it,
//                      belong to arv_osc_ctrl, which is synthesizable RTL an
//                      integrator can lift into a real SoC.
//
//                      en_i is read once per period, at the end of the low
//                      phase -- half a period after arv_osc_ctrl's flops move on
//                      the rising edge, so the two never race.
//
//                      An undriven or unknown en_i counts as "run": a bench can
//                      leave the controller's flops to resolve out of X over the
//                      first couple of edges without the clock having to exist
//                      before they do.
//----------------------------------------------------------------------------
`include "timescale.v"

module  osc #(
    parameter integer HALF_PERIOD  = 500,   // Half-period in timescale units (full clock period = 2 * HALF_PERIOD)
    parameter integer PHASE_OFFSET = 0      // One-shot initial delay before the loop starts, in timescale units
) (
    input     wire    en_i,                 // 1 = toggle, 0 = park low. Drive from arv_osc_ctrl.osc_en_o
    output    reg     clk_o                 // Oscillator output
);

initial
  begin
     clk_o = 1'b0;
     #(PHASE_OFFSET);
     forever
       begin
          if (en_i === 1'b0) @(posedge en_i);
          #(HALF_PERIOD);
          clk_o = 1'b1;
          #(HALF_PERIOD);
          clk_o = 1'b0;
       end
  end

endmodule
