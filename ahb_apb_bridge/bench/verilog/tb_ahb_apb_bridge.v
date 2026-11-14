//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tb_ahb_apb_bridge
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tb_ahb_apb_bridge.v
// Module Description : Testbench of ahb_apb_bridge: an AHB-Lite master
//                      (ahb_master.v, queued and pipelined), one APB completer
//                      model per window, an APB4 protocol checker and a
//                      reference memory. BRG_CFG selects the completer map:
//                      0 three completers with gaps, 1 one completer owning the
//                      window, 2 sixteen completers, 3 the map of 0 with a
//                      one-word completer; BRG_ASYNC_RST_EN the reset
//                      style; BRG_CGATE=1 clocks the bridge and the completers
//                      through a latch-based clock gate enabled by hclk_en_o
//                      (and by the reset generator's request during reset),
//                      while the AHB master and the checkers stay on the
//                      free-running hclk.
//                      The test is stimulus.v.
//----------------------------------------------------------------------------
`include "timescale.v"

`ifndef BRG_CFG
   `define BRG_CFG          0
`endif
`ifndef BRG_ASYNC_RST_EN
   `define BRG_ASYNC_RST_EN 1
`endif
`ifndef BRG_CGATE
   `define BRG_CGATE        0
`endif

module  tb_ahb_apb_bridge;

localparam CFG          = `BRG_CFG;
localparam ASYNC_RST_EN = `BRG_ASYNC_RST_EN;
localparam CGATE        = `BRG_CGATE;

localparam SLV_NR       = (CFG == 1) ? 1 : (CFG == 2) ? 16 : 3;
localparam ADDRW        = (CFG == 1) ? 8 : (CFG == 2) ? 16 : 12;

function [16*16-1:0] base16;           // sixteen 4-KB windows
    input integer dummy;
    integer       k;
    begin
        base16 = 0;
        for (k = 0; k < 16; k = k + 1) base16[k*16 +: 16] = k * 16'h1000;
    end
endfunction

localparam [SLV_NR*ADDRW-1:0] SLV_BASE = (CFG == 1) ? 8'h00 :
                                         (CFG == 2) ? base16(0) :
                                                      {12'h800, 12'h400, 12'h000};
localparam     [SLV_NR*5-1:0] SLV_AW   = (CFG == 1) ? 5'd8 :
                                         (CFG == 2) ? {16{5'd12}} :
                                         (CFG == 3) ? {5'd2, 5'd10, 5'd8} :
                                                      {5'd4, 5'd10, 5'd8};

//----------------------------------------------------------------------------
// Clock, reset, verdict
//----------------------------------------------------------------------------
reg          hclk;                         // free-running: AHB master, checkers, tests
wire         bclk;                         // bridge and completers
reg          hresetn;
integer      error;
reg          stimulus_done;

initial begin
    hclk = 1'b0;
    forever #5 hclk = ~hclk;
end

initial begin
    error = 0; stimulus_done = 1'b0;
    hresetn = 1'b0;
    repeat (5) @(posedge hclk);
    #1 hresetn = 1'b1;
end

//----------------------------------------------------------------------------
// AHB and APB nets
//----------------------------------------------------------------------------
wire     [ADDRW-1:0] haddr;
wire           [3:0] hprot;
wire           [2:0] hsize;
wire                 hsmode;
wire           [3:0] hmaster;
wire           [1:0] htrans;
wire          [31:0] hwdata;
wire                 hwrite;
wire                 hsel;
wire          [31:0] hrdata;
wire                 hreadyout;
wire                 hresp;
wire                 hclk_en;

wire    [SLV_NR-1:0] psel;
wire     [ADDRW-1:0] paddr;
wire                 penable;
wire                 pwrite;
wire          [31:0] pwdata;
wire           [3:0] pstrb;
wire           [2:0] pprot;
wire                 psmode;
wire           [3:0] pmaster;
wire [SLV_NR*32-1:0] prdata;
wire    [SLV_NR-1:0] pready;
wire    [SLV_NR-1:0] pslverr;

reg            [7:0] wmax = 8'd0;          // every completer's most wait states per transfer

`include "ahb_master.v"

//----------------------------------------------------------------------------
// Clock gate (topology A of the bridge document: one ICG from hclk_en_o for
// the bridge and every completer; the reset generator requests the clock
// during reset)
//----------------------------------------------------------------------------
generate
    if (CGATE) begin : g_cgate
        reg cg_en;                         // ICG latch, transparent while hclk is low
        always @(hclk or hclk_en or hresetn)
            if (~hclk) cg_en <= hclk_en | ~hresetn;
        assign bclk = hclk & cg_en;
    end else begin : g_free
        assign bclk = hclk;
    end
endgenerate

//----------------------------------------------------------------------------
// DUT
//----------------------------------------------------------------------------
ahb_apb_bridge #(
    .SLV_NR       ( SLV_NR       ),
    .ADDRW        ( ADDRW        ),
    .SLV_BASE     ( SLV_BASE     ),
    .SLV_AW       ( SLV_AW       ),
    .ASYNC_RST_EN ( ASYNC_RST_EN )
) dut (
    .hclk_i       ( bclk         ),
    .hresetn_i    ( hresetn      ),
    .hclk_en_o    ( hclk_en      ),

    .haddr_i      ( haddr        ),
    .hmaster_i    ( hmaster      ),
    .hprot_i      ( hprot        ),
    .hready_i     ( hready_bus   ),
    .hsize_i      ( hsize        ),
    .hsmode_i     ( hsmode       ),
    .htrans_i     ( htrans       ),
    .hwdata_i     ( hwdata       ),
    .hwrite_i     ( hwrite       ),
    .hsel_i       ( hsel         ),
    .hrdata_o     ( hrdata       ),
    .hreadyout_o  ( hreadyout    ),
    .hresp_o      ( hresp        ),

    .psel_o       ( psel         ),
    .paddr_o      ( paddr        ),
    .penable_o    ( penable      ),
    .pwrite_o     ( pwrite       ),
    .pwdata_o     ( pwdata       ),
    .pstrb_o      ( pstrb        ),
    .pprot_o      ( pprot        ),
    .psmode_o     ( psmode       ),
    .pmaster_o    ( pmaster      ),
    .prdata_i     ( prdata       ),
    .pready_i     ( pready       ),
    .pslverr_i    ( pslverr      )
);

//----------------------------------------------------------------------------
// APB completers
//----------------------------------------------------------------------------
genvar gk;
generate
    for (gk = 0; gk < SLV_NR; gk = gk + 1) begin : g_slv
        apb_completer_model #(.AW(SLV_AW[gk*5 +: 5]), .ADDRW(ADDRW), .SEED(gk + 1)) u_cmp (
            .clk_i     ( bclk                  ),
            .wmax_i    ( wmax                  ),
            .psel_i    ( psel[gk]              ),
            .penable_i ( penable               ),
            .pwrite_i  ( pwrite                ),
            .paddr_i   ( paddr                 ),
            .pwdata_i  ( pwdata                ),
            .pstrb_i   ( pstrb                 ),
            .pprot_i   ( pprot                 ),
            .psmode_i  ( psmode                ),
            .prdata_o  ( prdata[gk*32 +: 32]   ),
            .pready_o  ( pready[gk]            ),
            .pslverr_o ( pslverr[gk]           )
        );
    end
endgenerate

// Completer k's window: base and size in bytes
function integer win_base; input integer k; win_base = SLV_BASE[k*ADDRW +: ADDRW]; endfunction
function integer win_size; input integer k; win_size = 1 << SLV_AW[k*5 +: 5];      endfunction

// Completer decoding an address, -1 for none
function integer slv_of;
    input [ADDRW-1:0] a;
    integer           k;
    begin
        slv_of = -1;
        for (k = 0; k < SLV_NR; k = k + 1)
            if ((a >= win_base(k)) && (a < win_base(k) + win_size(k))) slv_of = k;
    end
endfunction

task set_wmax; input integer w; begin wmax = w; end endtask

//----------------------------------------------------------------------------
// APB4 protocol checker
//----------------------------------------------------------------------------
integer      apb_setups = 0;               // SETUP phases seen
integer      rst_edges  = 0;               // clock edges seen in the current reset
reg          prev_sel;
reg          prev_en;
reg          prev_wait;
reg   [ADDRW+1+32+4+3+1+4+SLV_NR-1:0] prev_bus;
wire  [ADDRW+1+32+4+3+1+4+SLV_NR-1:0] bus = {paddr, pwrite, pwdata, pstrb, pprot, psmode, pmaster, psel};
integer      ones;
integer      kk;

always @(posedge hclk) begin
    if (hresetn === 1'b1) begin
        ones = 0;
        for (kk = 0; kk < SLV_NR; kk = kk + 1) ones = ones + psel[kk];
        if (ones > 1) begin $display("ERROR: APB -- PSEL not one-hot %t", $time); error = error + 1; end
        if (penable && (ones == 0)) begin $display("ERROR: APB -- PENABLE without PSEL %t", $time); error = error + 1; end
        if ((ones != 0) && penable && !(prev_sel && (!prev_en || prev_wait)))
            begin $display("ERROR: APB -- ACCESS not after SETUP %t", $time); error = error + 1; end
        if (prev_sel && (!prev_en || prev_wait)) begin
            if (!((ones != 0) && penable)) begin $display("ERROR: APB -- SETUP or a wait not followed by ACCESS %t", $time); error = error + 1; end
            if (bus !== prev_bus) begin $display("ERROR: APB -- address, control or data changed during a transfer %t", $time); error = error + 1; end
        end
        if ((ones != 0) && !pwrite && (pstrb !== 4'b0000)) begin $display("ERROR: APB -- PSTRB not 0 on a read %t", $time); error = error + 1; end
        if ((ones != 0) && !penable) apb_setups = apb_setups + 1;
    end else if ((rst_edges > 0) && ((psel !== {SLV_NR{1'b0}}) || (penable !== 1'b0))) begin
        // (a synchronous reset takes effect at the first edge in reset)
        $display("ERROR: APB -- PSEL or PENABLE during reset %t", $time); error = error + 1;
    end
    rst_edges = (hresetn === 1'b1) ? 0 : rst_edges + 1;
    prev_sel  = (hresetn === 1'b1) && (psel != {SLV_NR{1'b0}});
    prev_en   = penable;
    prev_wait = penable && ((psel & pready) == {SLV_NR{1'b0}});
    prev_bus  = bus;
end

//----------------------------------------------------------------------------
// Functional coverage: one flag per bin, reported at the end
//----------------------------------------------------------------------------
reg cv_read = 0, cv_write = 0, cv_wait = 0, cv_slverr = 0, cv_unmapped = 0, cv_size = 0;
reg cv_b2b = 0, cv_err_next = 0, cv_strb_part = 0, cv_busy = 0, cv_idle_sel = 0, cv_nosel = 0;
reg cv_en_hi = 0, cv_en_lo = 0, cv_reset_busy = 0, cv_stall = 0, cv_misal = 0, cv_gated = 0;
reg cv_rdy_out = 0, cv_err_wait = 0;

always @(posedge hclk) begin
    if (hresetn === 1'b1) begin
        if ((psel != 0) && penable && (psel & pready) &&  pwrite) cv_write = 1;
        if ((psel != 0) && penable && (psel & pready) && !pwrite) cv_read  = 1;
        if ((psel != 0) && penable && !(psel & pready)) cv_wait = 1;
        if ((psel != 0) && penable && (psel & pready & pslverr)) cv_slverr = 1;
        if (dut.attr_en && dut.aph_bad && !(|dut.aph_sel)) cv_unmapped = 1;
        if (dut.attr_en && (hsize > 3'd2)) cv_size = 1;
        if (dut.attr_en && (((hsize == 3'd1) && haddr[0]) || ((hsize == 3'd2) && (haddr[1:0] != 2'b00)))) cv_misal = 1;
        if (dut.attr_en && dut.st_done) cv_b2b = 1;
        if (dut.attr_en && dut.st_err2) cv_err_next = 1;
        if ((psel != 0) && pwrite && (pstrb != 4'b1111)) cv_strb_part = 1;
        if (hsel && (htrans == 2'b01)) cv_busy = 1;
        if (hsel && (htrans == 2'b00)) cv_idle_sel = 1;
        if (!hsel && htrans[1]) cv_nosel = 1;
        if (hsel && htrans[1] && !hready_bus) cv_stall = 1;
        if (hclk_en === 1'b1) cv_en_hi = 1;
        if (hclk_en === 1'b0) cv_en_lo = 1;
        if (CGATE && (hclk_en === 1'b0) && !(hsel && htrans[1])) cv_gated = 1;
        if ((psel != 0) && |(pready & ~(psel & {SLV_NR{penable}}))) cv_rdy_out = 1;
        if ((psel != 0) && penable && |(psel & ~pready & pslverr)) cv_err_wait = 1;
    end
end
always @(negedge hresetn) if (!dut.st_idle) cv_reset_busy = 1;

task cover_report;
    begin
        if (cv_read)       $display("COVERAGE HIT: read");
        if (cv_write)      $display("COVERAGE HIT: write");
        if (cv_wait)       $display("COVERAGE HIT: apb_wait");
        if (cv_slverr)     $display("COVERAGE HIT: pslverr");
        if (cv_unmapped)   $display("COVERAGE HIT: unmapped");
        if (cv_size)       $display("COVERAGE HIT: size_err");
        if (cv_b2b)        $display("COVERAGE HIT: back_to_back");
        if (cv_err_next)   $display("COVERAGE HIT: accept_after_error");
        if (cv_strb_part)  $display("COVERAGE HIT: partial_strobe");
        if (cv_busy)       $display("COVERAGE HIT: htrans_busy");
        if (cv_idle_sel)   $display("COVERAGE HIT: htrans_idle_selected");
        if (cv_nosel)      $display("COVERAGE HIT: hsel_low");
        if (cv_en_hi)      $display("COVERAGE HIT: hclk_en_hi");
        if (cv_en_lo)      $display("COVERAGE HIT: hclk_en_lo");
        if (cv_reset_busy) $display("COVERAGE HIT: reset_in_transfer");
        if (cv_stall)      $display("COVERAGE HIT: bus_stall");
        if (cv_misal)      $display("COVERAGE HIT: misaligned");
        if (cv_gated)      $display("COVERAGE HIT: clock_gated");
        if (cv_rdy_out)    $display("COVERAGE HIT: pready_outside_access");
        if (cv_err_wait)   $display("COVERAGE HIT: pslverr_in_wait");
    end
endtask

//----------------------------------------------------------------------------
// Test, verdict, timeout
//----------------------------------------------------------------------------
`include "stimulus.v"

initial begin
    @(posedge stimulus_done);
    repeat (5) @(posedge hclk);
    $display(" ===============================================");
    if ((error != 0) || (ahb_errors != 0)) begin
        $display("|               SIMULATION FAILED               |");
        $display("|     (%0d bench errors, %0d AHB check errors)      ", error, ahb_errors);
    end else
        $display("|               SIMULATION PASSED               |");
    $display(" ===============================================");
    cover_report;
    $finish;
end

initial begin
    #20000000;
    $display(" ===============================================");
    $display("|               SIMULATION FAILED               |");
    $display("|              (simulation Timeout)             |");
    $display(" ===============================================");
    $finish;
end

`ifdef NODUMP
`else
initial begin
    $dumpfile("tb_ahb_apb_bridge.vcd");
    $dumpvars(0, tb_ahb_apb_bridge);
end
`endif

endmodule // tb_ahb_apb_bridge
