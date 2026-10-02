//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tb_ahb_default_subordinate
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tb_ahb_default_subordinate.v
// Module Description : Unit testbench for ahb_default_subordinate: IHI0033C
//                      Table 3-1 response per HTRANS type (IDLE/BUSY get a
//                      zero-wait OKAY, NONSEQ/SEQ a two-cycle ERROR), plus
//                      back-to-back and unselected behaviour.
//----------------------------------------------------------------------------
`timescale 1ns/100ps

module tb_ahb_default_subordinate;

reg         hclk    = 1'b0;
reg         hresetn = 1'b0;
reg         hready  = 1'b1;
reg         hsel    = 1'b0;
reg   [1:0] htrans  = 2'b00;
wire        hclk_en;
wire [31:0] hrdata;
wire        hreadyout;
wire        hresp;

integer     error   = 0;

always #5 hclk = ~hclk;

ahb_default_subordinate dut (
    .hclk_i      (hclk),
    .hresetn_i   (hresetn),
    .hclk_en_o   (hclk_en),
    .hready_i    (hready),
    .hsel_i      (hsel),
    .htrans_i    (htrans),
    .hrdata_o    (hrdata),
    .hreadyout_o (hreadyout),
    .hresp_o     (hresp)
);

// Present one address phase (hsel/htrans for one cycle with hready=1), then
// sample the response over the following cycles and compare with the
// expected (hreadyout, hresp) sequence of IHI0033C Table 3-1:
//   OKAY  : one data-phase cycle, hreadyout=1 hresp=0
//   ERROR : two data-phase cycles, (0,1) then (1,1)
task drive_and_check;
    input  [1:0] trans;
    input        sel;
    input        expect_error;
    input [8*16:1] name;
    reg [1:0] got0, got1, got2;    // {hreadyout, hresp} in dph cycle 1, 2, 3
    begin
        @(negedge hclk);
        hsel = sel; htrans = trans;
        @(negedge hclk);            // address phase sampled at the posedge in between
        hsel = 1'b0; htrans = 2'b00;
        got0 = {hreadyout, hresp};  // data-phase cycle 1
        @(negedge hclk);
        got1 = {hreadyout, hresp};  // data-phase cycle 2
        @(negedge hclk);
        got2 = {hreadyout, hresp};  // bus must be idle again
        if (expect_error) begin
            if (got0 !== 2'b01 || got1 !== 2'b11 || got2 !== 2'b10) begin
                $display("ERROR [%0s]: expected 2-cycle ERROR {hreadyout,hresp} = 01,11,10 -- got %b,%b,%b", name, got0, got1, got2);
                error = error + 1;
            end else
                $display("PASS  [%0s]: 2-cycle ERROR response", name);
        end else begin
            if (got0 !== 2'b10 || got1 !== 2'b10 || got2 !== 2'b10) begin
                $display("ERROR [%0s]: expected zero-wait OKAY {hreadyout,hresp} = 10,10,10 -- got %b,%b,%b", name, got0, got1, got2);
                error = error + 1;
            end else
                $display("PASS  [%0s]: zero-wait OKAY", name);
        end
    end
endtask

initial begin
    $display("");
    $display(" =======================================================");
    $display("| ahb_default_subordinate unit test                     |");
    $display(" =======================================================");
    repeat (3) @(negedge hclk);
    hresetn = 1'b1;
    repeat (2) @(negedge hclk);

    drive_and_check(2'b10, 1'b1, 1'b1, "NONSEQ selected");
    drive_and_check(2'b11, 1'b1, 1'b1, "SEQ selected   ");
    drive_and_check(2'b00, 1'b1, 1'b0, "IDLE selected  ");
    drive_and_check(2'b01, 1'b1, 1'b0, "BUSY selected  ");   // Table 3-1: BUSY gets a zero-wait OKAY
    drive_and_check(2'b10, 1'b0, 1'b0, "NONSEQ deselect");
    drive_and_check(2'b01, 1'b0, 1'b0, "BUSY deselected");

    // Address phase presented while hready=0 must be ignored
    @(negedge hclk); hready = 1'b0; hsel = 1'b1; htrans = 2'b10;
    @(negedge hclk); hready = 1'b1; hsel = 1'b0; htrans = 2'b00;
    if (hreadyout !== 1'b1 || hresp !== 1'b0) begin
        $display("ERROR [NONSEQ hready=0]: address phase accepted while hready=0");
        error = error + 1;
    end else
        $display("PASS  [NONSEQ hready=0]: ignored");
    repeat (3) @(negedge hclk);

    $display("");
    $display(" =======================================================");
    if (error == 0) $display("|               SIMULATION PASSED                       |");
    else            $display("|               SIMULATION FAILED  (%0d errors)          |", error);
    $display(" =======================================================");
    $display("");
    $finish;
end

`ifdef ARV_COV_RESET_ZERO
// Coverage counts start once reset is released: the Verilator coverage flow starts
// every flop at 1 so the asynchronous resets see an edge, and the reset driving them
// to 0 would otherwise count as a toggle of every bit.
initial begin
    wait (hresetn === 1'b0);
    @(posedge hresetn);
    $c("Verilated::threadContextp()->coveragep()->zero();");
end
`endif

endmodule // tb_ahb_default_subordinate
