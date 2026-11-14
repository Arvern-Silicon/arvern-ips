//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    reset_mid_transfer
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : reset_mid_transfer.v
// Module Description : A reset in each state of a transfer (SETUP, a long
//                      ACCESS, the DONE response, both ERROR cycles) drops
//                      it: PSEL and PENABLE low, HREADYOUT high, OKAY, HRDATA
//                      0; the bridge is idle after the reset and transfers
//                      complete normally.
//----------------------------------------------------------------------------
integer k, r;

initial begin
    @(posedge hresetn);
    repeat (2) @(posedge hclk);
    for (r = 0; r < 5; r = r + 1) begin
        // A read so that HRDATA is not 0 before the reset
        wr(win_base(0) + 8, 32'h5EED_0000 + r);
        rd(win_base(0) + 8);
        drain;
        case (r)
            0: begin                              // SETUP
                wr_raw(win_base(0) + 4, 3'd2, 32'hDEAD_0000);
                rst_in(dut.st_setup, "SETUP");
            end
            1: begin                              // ACCESS: the completer's wait counter is frozen
                force g_slv[0].u_cmp.wait_n = 100;
                wr_raw(win_base(0) + 4, 3'd2, 32'hDEAD_0001);
                repeat (4) @(posedge hclk); #2;
                rst_in(dut.st_access, "ACCESS");
            end
            2: begin                              // DONE (the write reached the completer)
                wr_raw(win_base(0) + 4, 3'd2, 32'hDEAD_0002);
                while (!dut.st_done) begin @(posedge hclk); #2; end
                rst_in(dut.st_done, "DONE");
            end
            3: begin                              // ERR1: a transfer wider than a word
                wr_raw(win_base(0) + 4, 3'd3, 32'hDEAD_0003);
                rst_in(dut.st_err1, "ERR1");
            end
            default: begin                        // ERR2
                wr_raw(win_base(0) + 4, 3'd3, 32'hDEAD_0004);
                @(posedge hclk); #2;
                rst_in(dut.st_err2, "ERR2");
            end
        endcase
    end
    // Normal traffic afterwards (word 1 of completer 0, written by the raw
    // transfers, is not read)
    for (k = 0; k < SLV_NR; k = k + 1) begin
        wr(win_base(k) + 8, 32'hAF7E_0000 + k);
        rd(win_base(k) + 8);
    end
    drain;
    stimulus_done = 1'b1;
end

// A transfer issued directly on the bus (outside the master's queue, which a
// reset would leave mid-transfer); its write data stays on HWDATA until the
// reset. Returns early in the transfer's first data-phase cycle.
task wr_raw;
    input [ADDRW-1:0] a;
    input       [2:0] sz;
    input      [31:0] d;
    begin
        @(posedge hclk); #1;
        bus_raw = 1'b1;
        force haddr = a; force htrans = 2'b10; force hwrite = 1'b1; force hsel = 1'b1; force hsize = sz;
        force hprot = 4'h3; force hsmode = 1'b0;
        @(posedge hclk); #1;
        force htrans = 2'b00; force hsel = 1'b0; force hwdata = d;   // held until the reset (data phase)
        #1;
        release haddr; release htrans; release hwrite; release hsel; release hsize; release hprot; release hsmode;
    end
endtask

// Reset the bridge in the state st (checked first), check its outputs in and
// after the reset
task rst_in;
    input           st;
    input [8*6-1:0] name;
    begin
        if (st !== 1'b1) begin $display("ERROR: not in %0s before the reset", name); error = error + 1; end
        hresetn = 1'b0;
        if (ASYNC_RST_EN) #1;
        else begin @(posedge hclk); #1; end      // a synchronous reset acts at the next edge
        if ((dut.psel_o !== 0) || (dut.penable_o !== 1'b0) || (dut.hreadyout_o !== 1'b1) ||
            (dut.hresp_o !== 1'b0) || (dut.hrdata_o !== 32'h0)) begin
            $display("ERROR: reset in %0s: outputs not idle", name); error = error + 1;
        end
        release g_slv[0].u_cmp.wait_n;
        release hwdata;
        repeat (3) @(posedge hclk);
        #1 hresetn = 1'b1;
        repeat (3) @(posedge hclk);
        if ((dut.psel_o !== 0) || (dut.hreadyout_o !== 1'b1) || (dut.hresp_o !== 1'b0) || !dut.st_idle) begin
            $display("ERROR: reset in %0s: bridge not idle after the reset", name); error = error + 1;
        end
    end
endtask
