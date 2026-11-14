//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    strobes
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : strobes.v
// Module Description : Byte and half-word writes on every lane, read
//                      back as bytes, half-words and words; PSTRB follows the
//                      lanes (the reference memory predicts the merged words)
//                      and is 0 on every read (protocol checker).
//----------------------------------------------------------------------------
integer k, l;
reg [ADDRW-1:0] a;

initial begin
    @(posedge hresetn);
    repeat (2) @(posedge hclk);
    for (k = 0; k < SLV_NR; k = k + 1) begin
        a = win_base(k);
        wr(a, 32'h0000_0000);
        for (l = 0; l < 4; l = l + 1) push_xfer(1'b1, a + l, 3'd0, 32'h11 * (l + 1) << (8 * l));
        rd(a);
        for (l = 0; l < 4; l = l + 1) push_xfer(1'b0, a + l, 3'd0, 32'h0);
        push_xfer(1'b1, a,     3'd1, 32'h0000_BEEF);
        push_xfer(1'b1, a + 2, 3'd1, 32'hCAFE_0000);
        push_xfer(1'b0, a,     3'd1, 32'h0);
        push_xfer(1'b0, a + 2, 3'd1, 32'h0);
        rd(a);
    end
    drain;
    stimulus_done = 1'b1;
end
