//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          File:      ahb_master.v (included in tb_ahb_apb_bridge)
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// A queued AHB-Lite master. Tests push items (transfers, IDLE or BUSY
// cycles, transfers with HSEL low); the master issues the next item's
// address phase in the cycle the previous data phase completes, so transfers
// run back to back. Each transfer's expected response and read data come from
// a reference memory updated when the item is pushed: OKAY, or ERROR for an
// address no completer decodes, a size wider than a word, a misaligned
// half-word or word, or the last word of a completer's window wider than one
// word (where the completer answers PSLVERR). For each transfer the master
// checks:
//   - the response, with HRESP high in exactly the last wait state of an
//     ERROR (its first cycle, HREADYOUT low) and in no wait of an OKAY;
//   - the wait states: 1 for an ERROR the bridge raises itself (no APB
//     transfer), 2 + the completer's waits for an OKAY, 3 + the completer's
//     waits after PSLVERR;
//   - its APB SETUP: PADDR, PWRITE, PPROT = {~HPROT[0], 0, HPROT[1]},
//     psmode = HSMODE and pmaster = HMASTER;
//   - the read data on the transfer's byte lanes, and HRDATA at 0 in both
//     cycles of an ERROR.
// Two standing checks run on every cycle: HRDATA holds the last OKAY read's
// data (0 after an ERROR or a reset) outside the cycles that change it, and
// the bridge answers a non-transfer address phase it takes (IDLE, BUSY or
// HSEL low) with a zero-wait OKAY. A test that drives the bus or the bridge
// directly sets bus_raw, which stands both down until the test or a reset
// clears it.
//
// The bus HREADY is the bridge's HREADYOUT during the bridge's data phases;
// outside them another subordinate's data phase may stall the bus
// (stall_pct % of those cycles, at random): the master then holds its address
// phase, and the bridge sees HREADY low.
//----------------------------------------------------------------------------

localparam QD     = 4096;
localparam K_XFER = 0, K_IDLE = 1, K_BUSY = 2, K_NOSEL = 3;

reg        [1:0] q_kind  [0:QD-1];
reg              q_write [0:QD-1];
reg  [ADDRW-1:0] q_addr  [0:QD-1];
reg        [2:0] q_size  [0:QD-1];
reg       [31:0] q_wdata [0:QD-1];
reg              q_err   [0:QD-1];
reg              q_pslv  [0:QD-1];          // ... from the completer's PSLVERR
reg       [31:0] q_rdata [0:QD-1];
reg       [31:0] q_mask  [0:QD-1];
reg        [3:0] q_prot  [0:QD-1];
reg              q_smode [0:QD-1];
reg        [3:0] q_master[0:QD-1];
integer          q_head = 0;
integer          q_tail = 0;

reg       [31:0] ref_mem [0:(1 << (ADDRW - 2)) - 1];
integer          ahb_errors = 0;            // response or data mismatches
integer          ahb_xfers  = 0;            // transfers completed
integer          last_wait  = 0;            // wait states of the last transfer
integer          max_wait   = 0;
integer          min_wait   = 1000;
reg        [3:0] cur_prot   = 4'h3;         // privileged data
reg              cur_smode  = 1'b0;
reg        [3:0] cur_master = 4'h1;         // hart data port
reg              bus_raw    = 1'b0;         // a test drives the bus or the bridge directly
integer          ri;

initial for (ri = 0; ri < (1 << (ADDRW - 2)); ri = ri + 1) ref_mem[ri] = 32'h0;

// Address phase outputs
reg  [ADDRW-1:0] haddr_r  = 0;
reg        [3:0] hprot_r  = 0;
reg        [2:0] hsize_r  = 0;
reg              hsmode_r = 0;
reg        [3:0] hmaster_r = 0;
reg        [1:0] htrans_r = 0;
reg              hwrite_r = 0;
reg              hsel_r   = 0;
reg       [31:0] hwdata_r = 0;
assign haddr  = haddr_r;
assign hprot  = hprot_r;
assign hsize  = hsize_r;
assign hsmode = hsmode_r;
assign hmaster = hmaster_r;
assign htrans = htrans_r;
assign hwrite = hwrite_r;
assign hsel   = hsel_r;
assign hwdata = hwdata_r;

integer          stall_pct  = 0;            // % of cycles another data phase stalls the bus
reg              stall_r    = 1'b0;
integer          stall_seed = 7;
reg              dp_v = 0;                  // a data phase is in progress
wire             hready_bus = dp_v ? hreadyout : ~stall_r;

reg              ap_v = 0;                  // an address phase of a transfer is out
integer          ap_i;
integer          dp_i;
integer          dp_cyc;
reg              s_ready, s_resp, p_ready, p_resp;
reg       [31:0] s_rdata, p_rdata;
reg              s_setup, s_apbw;           // an APB SETUP, an APB ACCESS wait state
integer          dp_rsp;                    // wait states with HRESP high
integer          dp_apbw;                   // APB wait states
integer          dp_setup;                  // APB SETUPs
reg       [31:0] hr_exp     = 32'h0;        // HRDATA outside the cycles that change it
reg              zw_chk     = 1'b0;         // a non-transfer address phase was taken

function [3:0] lanes;
    input [2:0] size;
    input [1:0] a;
    lanes = (size == 3'd0) ? (4'b0001 << a) : (size == 3'd1) ? (a[1] ? 4'b1100 : 4'b0011) : 4'b1111;
endfunction

function [31:0] lmask;
    input [3:0] l;
    lmask = {{8{l[3]}}, {8{l[2]}}, {8{l[1]}}, {8{l[0]}}};
endfunction

// Push a transfer; its expectations come from the reference memory
task push_xfer;
    input             write;
    input [ADDRW-1:0] addr;
    input       [2:0] size;
    input      [31:0] wdata;
    integer           s;
    reg               err;
    reg               pslv;
    reg        [31:0] m;
    begin
        s    = slv_of(addr);
        err  = (s < 0) || (size > 3'd2) ||
               ((size == 3'd1) && addr[0]) || ((size == 3'd2) && (addr[1:0] != 2'b00));
        pslv = !err && (win_size(s) > 4) && ((addr - win_base(s)) >= (win_size(s) - 4));
        err  = err || pslv;
        m   = (size > 3'd2) ? 32'h0 : lmask(lanes(size, addr[1:0]));
        q_kind[q_tail]  = K_XFER;      q_write[q_tail] = write;    q_addr[q_tail]  = addr;
        q_size[q_tail]  = size;        q_wdata[q_tail] = wdata;    q_err[q_tail]   = err;
        q_pslv[q_tail]  = pslv;
        q_mask[q_tail]  = write ? 32'h0 : m;
        q_rdata[q_tail] = ref_mem[addr >> 2] & m;
        q_prot[q_tail]  = cur_prot;    q_smode[q_tail] = cur_smode;   q_master[q_tail] = cur_master;
        if (write && !err)
            ref_mem[addr >> 2] = (ref_mem[addr >> 2] & ~m) | (wdata & m);
        q_tail = q_tail + 1;
    end
endtask

task push_kind;
    input       [1:0] kind;
    input [ADDRW-1:0] addr;
    begin
        q_kind[q_tail] = kind; q_addr[q_tail] = addr; q_write[q_tail] = 1'b0; q_size[q_tail] = 3'd2;
        q_prot[q_tail] = cur_prot; q_smode[q_tail] = cur_smode; q_master[q_tail] = cur_master; q_wdata[q_tail] = 32'h0;
        q_tail = q_tail + 1;
    end
endtask

task wr;  input [ADDRW-1:0] a; input [31:0] d; begin push_xfer(1'b1, a, 3'd2, d); end endtask
task rd;  input [ADDRW-1:0] a;                 begin push_xfer(1'b0, a, 3'd2, 32'h0); end endtask

// Wait until every pushed item has completed
task drain;
    begin
        while ((q_head != q_tail) || ap_v || dp_v) @(posedge hclk);
        repeat (2) @(posedge hclk);
    end
endtask

always @(posedge hclk) begin
    p_ready = s_ready; p_resp = s_resp; p_rdata = s_rdata;
    s_ready = hready_bus; s_resp = hresp; s_rdata = hrdata;
    s_setup = (psel != {SLV_NR{1'b0}}) && !penable;
    s_apbw  = (psel != {SLV_NR{1'b0}}) && penable && ((psel & pready) == {SLV_NR{1'b0}});
    // The APB SETUP of the transfer in its data phase
    if ((hresetn === 1'b1) && dp_v && s_setup &&
        ((paddr !== q_addr[dp_i]) || (pwrite !== q_write[dp_i]) ||
         (pprot !== {~q_prot[dp_i][0], 1'b0, q_prot[dp_i][1]}) || (psmode !== q_smode[dp_i]) ||
         (pmaster !== q_master[dp_i]))) begin
        $display("ERROR: AHB -- %s 0x%h (HPROT %h, HSMODE %b, HMASTER %h): APB SETUP PADDR 0x%h PWRITE %b PPROT %b psmode %b pmaster %h %t",
                 q_write[dp_i] ? "write" : "read", q_addr[dp_i], q_prot[dp_i], q_smode[dp_i], q_master[dp_i],
                 paddr, pwrite, pprot, psmode, pmaster, $time);
        ahb_errors = ahb_errors + 1;
    end
    // A non-transfer address phase taken at the previous edge: zero-wait OKAY
    if (zw_chk && (hresetn === 1'b1) && !bus_raw && ((hreadyout !== 1'b1) || (hresp !== 1'b0))) begin
        $display("ERROR: AHB -- IDLE, BUSY or HSEL low answered with HREADYOUT %b HRESP %b %t", hreadyout, hresp, $time);
        ahb_errors = ahb_errors + 1;
    end
    zw_chk  = (hresetn === 1'b1) && (hreadyout === 1'b1) && hready_bus && !(hsel && htrans[1]);
    // HRDATA changes only when an OKAY read completes or an ERROR starts
    if (hresetn !== 1'b1)
        hr_exp = 32'h0;
    else if (bus_raw)
        hr_exp = hrdata;
    else if (dp_v && q_err[dp_i] && s_resp)
        hr_exp = 32'h0;
    else if (dp_v && s_ready && !q_err[dp_i] && !q_write[dp_i])
        hr_exp = hrdata;
    else if (hrdata !== hr_exp) begin
        $display("ERROR: AHB -- HRDATA 0x%h, expected 0x%h held %t", hrdata, hr_exp, $time);
        ahb_errors = ahb_errors + 1;
    end
    if (dp_v) begin
        if (s_setup) dp_setup = dp_setup + 1;
        if (s_apbw)  dp_apbw  = dp_apbw + 1;
    end
    #1;
    stall_r = (stall_pct > 0) && (({$random(stall_seed)} % 100) < stall_pct);
    if (hresetn !== 1'b1) begin
        ap_v = 1'b0; dp_v = 1'b0;
        htrans_r = 2'b00; hsel_r = 1'b0;
        bus_raw  = 1'b0;
    end else if (s_ready) begin
        // The data phase completes
        if (dp_v) begin
            ahb_xfers = ahb_xfers + 1;
            last_wait = dp_cyc;
            if (!q_err[dp_i]) begin
                if (dp_cyc > max_wait) max_wait = dp_cyc;
                if (dp_cyc < min_wait) min_wait = dp_cyc;
            end
            if (s_resp !== q_err[dp_i]) begin
                $display("ERROR: AHB -- %s 0x%h: HRESP %b, expected %b %t", q_write[dp_i] ? "write" : "read",
                         q_addr[dp_i], s_resp, q_err[dp_i], $time);
                ahb_errors = ahb_errors + 1;
            end else if (q_err[dp_i] && !((p_ready === 1'b0) && (p_resp === 1'b1) && (dp_rsp == 1))) begin
                $display("ERROR: AHB -- ERROR response not exactly two cycles (HRESP high in %0d waits) %t", dp_rsp, $time);
                ahb_errors = ahb_errors + 1;
            end else if (dp_setup != ((q_pslv[dp_i] || !q_err[dp_i]) ? 1 : 0)) begin
                $display("ERROR: AHB -- %s 0x%h: %0d APB SETUPs %t", q_write[dp_i] ? "write" : "read",
                         q_addr[dp_i], dp_setup, $time);
                ahb_errors = ahb_errors + 1;
            end else if (dp_cyc != (q_pslv[dp_i] ? dp_apbw + 3 : q_err[dp_i] ? 1 : dp_apbw + 2)) begin
                $display("ERROR: AHB -- %s 0x%h: %0d wait states for %0d APB waits %t", q_write[dp_i] ? "write" : "read",
                         q_addr[dp_i], dp_cyc, dp_apbw, $time);
                ahb_errors = ahb_errors + 1;
            end else if (q_err[dp_i] && ((s_rdata !== 32'h0) || (p_rdata !== 32'h0))) begin
                $display("ERROR: AHB -- %s 0x%h: HRDATA 0x%h / 0x%h in the ERROR cycles, expected 0 %t",
                         q_write[dp_i] ? "write" : "read", q_addr[dp_i], p_rdata, s_rdata, $time);
                ahb_errors = ahb_errors + 1;
            end else if (!q_err[dp_i] && !q_write[dp_i] && ((s_rdata & q_mask[dp_i]) !== q_rdata[dp_i])) begin
                $display("ERROR: AHB -- read 0x%h: 0x%h, expected 0x%h %t", q_addr[dp_i], s_rdata & q_mask[dp_i],
                         q_rdata[dp_i], $time);
                ahb_errors = ahb_errors + 1;
            end
        end
        // The address phase becomes the data phase
        dp_v = ap_v;
        if (ap_v) begin
            dp_i     = ap_i;
            dp_cyc   = 0;
            dp_rsp   = 0;
            dp_apbw  = 0;
            dp_setup = 0;
            hwdata_r = q_wdata[ap_i];
        end
        // The next address phase
        ap_v = 1'b0;
        if (q_head != q_tail) begin
            haddr_r  = q_addr[q_head];  hsize_r = q_size[q_head];  hwrite_r = q_write[q_head];
            hprot_r  = q_prot[q_head];  hsmode_r = q_smode[q_head];  hmaster_r = q_master[q_head];
            htrans_r = (q_kind[q_head] == K_IDLE) ? 2'b00 : (q_kind[q_head] == K_BUSY) ? 2'b01 : 2'b10;
            hsel_r   = (q_kind[q_head] != K_NOSEL);
            ap_v     = (q_kind[q_head] == K_XFER);
            ap_i     = q_head;
            q_head   = q_head + 1;
        end else begin
            htrans_r = 2'b00; hsel_r = 1'b0; hwrite_r = 1'b0;
        end
    end else if (dp_v) begin
        dp_cyc = dp_cyc + 1;
        if (s_resp) dp_rsp = dp_rsp + 1;
        if (s_resp && !q_err[dp_i]) begin
            $display("ERROR: AHB -- HRESP high during an OKAY transfer's wait %t", $time);
            ahb_errors = ahb_errors + 1;
        end
    end
end
