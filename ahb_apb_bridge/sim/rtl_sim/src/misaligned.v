//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    misaligned
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : misaligned.v
// Module Description : A half-word at an odd address and a word at any
//                      address with HADDR[1:0] != 0 get the two-cycle ERROR
//                      with HRDATA at 0 and no APB transfer, reads and writes,
//                      in every completer, as do misaligned transfers that are
//                      also wider than a word or (in a map with a gap) also
//                      unmapped; the words they touch keep their value (read
//                      back aligned afterwards).
//----------------------------------------------------------------------------
integer k, o, s0;
reg [ADDRW-1:0] g;

initial begin
    @(posedge hresetn);
    repeat (2) @(posedge hclk);
    for (k = 0; k < SLV_NR; k = k + 1) begin
        wr(win_base(k),     32'h1111_1111 * (k + 1));
        wr(win_base(k) + 4, 32'h2222_2222 * (k + 1));
    end
    drain;
    s0 = apb_setups;
    for (k = 0; k < SLV_NR; k = k + 1) begin
        rd(win_base(k));                                  // last read data on HRDATA before the ERRORs
        for (o = 1; o < 4; o = o + 2) begin               // half-word at offsets 1, 3, 5
            push_xfer(1'b1, win_base(k) + o,     3'd1, 32'hDEAD_BEEF);
            push_xfer(1'b0, win_base(k) + o,     3'd1, 32'h0);
            push_xfer(1'b1, win_base(k) + o + 2, 3'd1, 32'hDEAD_BEEF);
        end
        for (o = 1; o < 4; o = o + 1) begin               // word at offsets 1, 2, 3
            push_xfer(1'b1, win_base(k) + o, 3'd2, 32'hDEAD_BEEF);
            push_xfer(1'b0, win_base(k) + o, 3'd2, 32'h0);
        end
        push_xfer(1'b1, win_base(k) + 1, 3'd3, 32'hDEAD_BEEF);      // misaligned and wider than a word
        push_xfer(1'b0, win_base(k) + 2, 3'd4, 32'h0);
    end
    g = win_base(0) + win_size(0);                                  // the gap above completer 0, if any
    if (slv_of(g) < 0) begin                                        // misaligned and unmapped
        push_xfer(1'b1, g + 1, 3'd1, 32'hDEAD_BEEF);
        push_xfer(1'b0, g + 3, 3'd1, 32'h0);
        push_xfer(1'b1, g + 2, 3'd2, 32'hDEAD_BEEF);
        push_xfer(1'b0, g + 1, 3'd2, 32'h0);
    end
    drain;
    if (apb_setups - s0 != SLV_NR) begin $display("ERROR: %0d APB transfers, expected %0d", apb_setups - s0, SLV_NR); error = error + 1; end
    for (k = 0; k < SLV_NR; k = k + 1) begin
        rd(win_base(k));
        rd(win_base(k) + 4);
    end
    drain;
    stimulus_done = 1'b1;
end
