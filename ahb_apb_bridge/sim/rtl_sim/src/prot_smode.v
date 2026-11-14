//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    prot_smode
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : prot_smode.v
// Module Description : PPROT = {instruction, 0, privileged}, psmode and
//                      pmaster follow HPROT, HSMODE and HMASTER for each
//                      transfer, read and write (machine, supervisor and user
//                      data accesses, a user access with HSMODE high, and an
//                      instruction access, each from a different manager ID:
//                      hart data, debugger, and the walking ones and zeros of
//                      HMASTER). The master checks every transfer's SETUP;
//                      this test also checks the ACCESS phase.
//----------------------------------------------------------------------------
integer k, m, w;
reg [3:0] pr [0:4];
reg       sm [0:4];
reg [3:0] hm [0:4];
reg [2:0] ep;

initial begin
    pr[0] = 4'h3; sm[0] = 1'b0; hm[0] = 4'h1;   // machine data, hart data port
    pr[1] = 4'h3; sm[1] = 1'b1; hm[1] = 4'h9;   // supervisor data, debugger (SBA)
    pr[2] = 4'h1; sm[2] = 1'b0; hm[2] = 4'h6;   // user data
    pr[3] = 4'h1; sm[3] = 1'b1; hm[3] = 4'hF;   // user data, HSMODE high (passed through)
    pr[4] = 4'h2; sm[4] = 1'b0; hm[4] = 4'h0;   // privileged instruction
    @(posedge hresetn);
    repeat (2) @(posedge hclk);
    for (k = 0; k < SLV_NR; k = k + 1)
        for (m = 0; m < 5; m = m + 1)
            for (w = 0; w < 2; w = w + 1) begin
                cur_prot = pr[m]; cur_smode = sm[m]; cur_master = hm[m] ^ {4{w[0]}};
                if (w == 0) wr(win_base(k), 32'h0);
                else        rd(win_base(k));
                drain;
                ep = {~pr[m][0], 1'b0, pr[m][1]};
                if ((pprot_seen !== ep) || (psmode_seen !== sm[m]) || (pmaster_seen !== (hm[m] ^ {4{w[0]}}))) begin
                    $display("ERROR: %s PPROT %b psmode %b pmaster %h, expected %b %b %h", (w == 0) ? "write" : "read",
                             pprot_seen, psmode_seen, pmaster_seen, ep, sm[m], hm[m] ^ {4{w[0]}}); error = error + 1;
                end
            end
    stimulus_done = 1'b1;
end

// PPROT and psmode of the last APB transfer
reg [2:0] pprot_seen;
reg       psmode_seen;
reg [3:0] pmaster_seen;
always @(posedge hclk) if ((psel != 0) && penable) begin pprot_seen = pprot; psmode_seen = psmode; pmaster_seen = pmaster; end
