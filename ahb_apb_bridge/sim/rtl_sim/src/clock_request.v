//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    clock_request
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : clock_request.v
// Module Description : hclk_en_o is high while a transfer is
//                      accepted or in flight, low when idle and in reset (the
//                      reset generator requests the clock during reset). The
//                      unused state encodings 6 and 7, loaded from a
//                      transfer's DONE cycle, request the clock, drive no APB
//                      transfer and no ERROR, and return to IDLE at the next
//                      edge.
//----------------------------------------------------------------------------
integer n, busy_lo, u;

initial begin
    @(posedge hresetn);
    repeat (2) @(posedge hclk);
    #1;
    if (hclk_en !== 1'b0) begin $display("ERROR: hclk_en_o high while idle"); error = error + 1; end
    busy_lo = 0;
    set_wmax(3);
    for (n = 0; n < 8; n = n + 1) begin wr(win_base(0), n); rd(win_base(0)); end
    drain;
    #1;
    if (hclk_en !== 1'b0) begin $display("ERROR: hclk_en_o high after the traffic"); error = error + 1; end
    if (busy_lo != 0) begin $display("ERROR: hclk_en_o low during %0d busy cycles", busy_lo); error = error + 1; end
    // Unused state encodings, loaded by the state register from a transfer's
    // DONE cycle (the edge after them comes only from hclk_en_o when gated)
    for (u = 6; u < 8; u = u + 1) begin
        wr(win_base(0), 32'h600D_0000 + u);
        while (!dut.st_done) @(negedge hclk);
        bus_raw = 1'b1;
        if (u == 6) force dut.state_nxt = 3'd6;
        else        force dut.state_nxt = 3'd7;
        @(posedge hclk); #1;
        release dut.state_nxt;
        #1;
        if ((dut.state !== u) || (hclk_en !== 1'b1) || (dut.hreadyout_o !== 1'b0) || (dut.hresp_o !== 1'b0) ||
            (dut.psel_o !== 0) || (dut.penable_o !== 1'b0)) begin
            $display("ERROR: state %0d (%0d): hclk_en_o %b HREADYOUT %b HRESP %b PSEL %b PENABLE %b", u, dut.state,
                     hclk_en, dut.hreadyout_o, dut.hresp_o, dut.psel_o, dut.penable_o); error = error + 1;
        end
        @(posedge hclk); #1;
        if (!dut.st_idle || (dut.hreadyout_o !== 1'b1) || (hclk_en !== 1'b0)) begin
            $display("ERROR: state %0d not left for IDLE at the next edge", u); error = error + 1;
        end
        @(negedge hclk);
        bus_raw = 1'b0;
    end
    wr(win_base(0), 32'h600D_0000);
    rd(win_base(0));
    drain;
    // In reset
    #2 hresetn = 1'b0;
    #1;
    if (hclk_en !== 1'b0) begin $display("ERROR: hclk_en_o high in reset"); error = error + 1; end
    repeat (2) @(posedge hclk);
    #1 hresetn = 1'b1;
    repeat (2) @(posedge hclk);
    stimulus_done = 1'b1;
end

always @(posedge hclk) if ((hresetn === 1'b1) && (!dut.st_idle || (hsel && htrans[1])) && (hclk_en !== 1'b1)) busy_lo = busy_lo + 1;
