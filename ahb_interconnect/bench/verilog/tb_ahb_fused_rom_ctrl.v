//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tb_ahb_fused_rom_ctrl
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tb_ahb_fused_rom_ctrl.v
// Module Description : Testbench for the fused AHB ROM controller.
//----------------------------------------------------------------------------

`include "timescale.v"

module tb_ahb_fused_rom_ctrl;


//=============================================================================
// 1)  PARAMETERS
//=============================================================================

parameter  MEM_SIZE  = 256;                 // ROM size in bytes (64 words)
localparam MEM_ADDRW = $clog2(MEM_SIZE)-2;  // word address width = 6
localparam NR_WORDS  = MEM_SIZE / 4;        // 64 words


//=============================================================================
// 2)  SIGNAL DECLARATIONS
//=============================================================================

// Clock / reset
reg                    free_clk;
reg                    hresetn;

// Port A (instruction fetch)
reg            [31:0]  a_haddr;
reg                    a_hsel;
reg            [1:0]   a_htrans;
wire                   a_hready;

wire          [31:0]   a_hrdata;
wire                   a_hreadyout;
wire                   a_hresp;

// Port B (data bus)
reg            [31:0]  b_haddr;
reg                    b_hsel;
reg            [1:0]   b_htrans;
reg                    b_hwrite;
wire                   b_hready;

wire          [31:0]   b_hrdata;
wire                   b_hreadyout;
wire                   b_hresp;

// Clock enable
wire                   hclk_en;

// ROM macro wires
wire          [31:0]   rom_dout;
wire          [29:0]   rom_addr;
wire                   rom_cen;
wire                   rom_clk;

// Reference memory (mirror of rom_inst.mem — used for expected-value checks)
reg           [31:0]   rom_ref [0:NR_WORDS-1];

// Error counter
integer                error;
integer                ii;

// Test title for waveform annotation
reg           [64*8-1:0] test_title;


//=============================================================================
// 3)  HREADY FEEDBACK  (point-to-point: hready_i = hreadyout_o)
//=============================================================================

assign a_hready = a_hreadyout;
assign b_hready = b_hreadyout;


//=============================================================================
// 4)  CLOCK  (10 ns period)  [section numbers shifted by 1 below]
//=============================================================================

initial free_clk = 1'b0;
always  #5 free_clk = ~free_clk;


//=============================================================================
// 4)  RESET
//=============================================================================

initial begin
    hresetn = 1'b0;
    repeat(4) @(posedge free_clk);
    #1;
    hresetn = 1'b1;
end


//=============================================================================
// 5)  DUT
//=============================================================================
//
// FIXED_B_PRIO is selected at compile time via `+define+FUSED_FIXED_B_PRIO`.
// The integration test (tb_ahb_interconnect.v) uses the same macro name so a
// single CI flag drives both unit and integration TBs into the fixed-B variant.

`ifdef FUSED_FIXED_B_PRIO
localparam DUT_FIXED_B_PRIO = 1'b1;
`else
localparam DUT_FIXED_B_PRIO = 1'b0;
`endif

ahb_fused_rom_ctrl #(.FIXED_B_PRIO(DUT_FIXED_B_PRIO)) dut (
    .hclk_i        (free_clk),
    .hresetn_i     (hresetn),
    .hclk_en_o     (hclk_en),

    .a_haddr_i     (a_haddr),
    .a_hsel_i      (a_hsel),
    .a_htrans_i    (a_htrans),
    .a_hready_i    (a_hready),
    .a_hrdata_o    (a_hrdata),
    .a_hreadyout_o (a_hreadyout),
    .a_hresp_o     (a_hresp),

    .b_haddr_i     (b_haddr),
    .b_hsel_i      (b_hsel),
    .b_htrans_i    (b_htrans),
    .b_hwrite_i    (b_hwrite),
    .b_hready_i    (b_hready),
    .b_hrdata_o    (b_hrdata),
    .b_hreadyout_o (b_hreadyout),
    .b_hresp_o     (b_hresp),

    .rom_dout_i    (rom_dout),
    .rom_addr_o    (rom_addr),
    .rom_cen_o     (rom_cen),
    .rom_clk_o     (rom_clk)
);


//=============================================================================
// 6)  ROM MACRO MODEL
//=============================================================================

rom #(.MEM_ADDRW(MEM_ADDRW), .MEM_SIZE(MEM_SIZE)) rom_inst (
    .rom_dout_o (rom_dout),
    .rom_addr_i (rom_addr[MEM_ADDRW-1:0]),
    .rom_cen_i  (rom_cen),
    .rom_clk_i  (rom_clk)
);


//=============================================================================
// 7)  VCD DUMP
//=============================================================================

`ifndef NODUMP
initial begin
    $dumpfile("tb_ahb_fused_rom_ctrl.vcd");
    $dumpvars(0, tb_ahb_fused_rom_ctrl);
end
`endif


//=============================================================================
// 8)  IDLE HELPERS
//=============================================================================

task a_idle;
    begin
        a_hsel   = 1'b0;
        a_htrans = 2'b00;
        a_haddr  = {(32){1'b0}};
    end
endtask

task b_idle;
    begin
        b_hsel   = 1'b0;
        b_htrans = 2'b00;
        b_haddr  = {(32){1'b0}};
        b_hwrite = 1'b0;
    end
endtask


//=============================================================================
// 9)  CHECK HELPERS
//=============================================================================

// Check Port A read data against the reference memory
task chk_a;
    input [MEM_ADDRW-1:0] word_idx;
    input          [31:0] got;
    input          [80*8:1] msg;
    begin
        if (got !== rom_ref[word_idx]) begin
            $display("ERROR [%0s]: Port A @ word[%0d] — got 0x%08h, expected 0x%08h  (%0t ns)",
                     msg, word_idx, got, rom_ref[word_idx], $time);
            error = error + 1;
        end else
            $display("PASS  [%0s]: Port A @ word[%0d] = 0x%08h  (%0t ns)",
                     msg, word_idx, got, $time);
    end
endtask

// Check Port B read data against the reference memory
task chk_b;
    input [MEM_ADDRW-1:0] word_idx;
    input          [31:0] got;
    input          [80*8:1] msg;
    begin
        if (got !== rom_ref[word_idx]) begin
            $display("ERROR [%0s]: Port B @ word[%0d] — got 0x%08h, expected 0x%08h  (%0t ns)",
                     msg, word_idx, got, rom_ref[word_idx], $time);
            error = error + 1;
        end else
            $display("PASS  [%0s]: Port B @ word[%0d] = 0x%08h  (%0t ns)",
                     msg, word_idx, got, $time);
    end
endtask

// Check a 1-bit control signal
task chk_sig;
    input        got;
    input        expected;
    input [80*8:1] msg;
    begin
        if (got !== expected) begin
            $display("ERROR [%0s]: got %0b, expected %0b  (%0t ns)",
                     msg, got, expected, $time);
            error = error + 1;
        end else
            $display("PASS  [%0s]: = %0b  (%0t ns)", msg, got, $time);
    end
endtask


//=============================================================================
// 9b) AHB DRIVER TASKS
//
//     Address-phase tasks  — return at the posedge where hreadyout=1;
//       port is NOT idled; hsel/htrans remain driven so the caller can
//       immediately pipeline the next address or call a_idle/#1/b_idle.
//
//     Data-phase tasks  — advance one cycle then loop while hreadyout=0
//       (handles the one wait state inserted by the pending-replay mechanism
//       when the port lost arbitration); sample data when hreadyout=1.
//       All correctness checks are done by the caller after the task returns.
//
//     Timing at posedge T where hreadyout=1 (active region):
//       • a_rd_active / b_rd_active reflect the PREVIOUS cycle's NBA → data valid.
//       • rom_dout holds the PREVIOUS cycle's registered address output → valid.
//       • Combinatorial a_grant / b_grant reflect the CURRENT addr inputs.
//     After #1 (NBA region of posedge T):
//       • a_rd_active / b_rd_active commit the current-cycle grant.
//       • Changing haddr here (for pipelining) takes effect before posedge T+1.
//=============================================================================

// --- Port A: address phase ---
task ahb_a_read;
    input [31:0] addr;
    begin
        #1;
        a_hsel   = 1'b1;
        a_htrans = 2'b10;
        a_haddr  = addr;
        @(posedge free_clk);
        while (!a_hreadyout) @(posedge free_clk);
    end
endtask

// --- Port A: data phase ---
task ahb_a_data;
    output [31:0] data;
    begin
        @(posedge free_clk);
        while (!a_hreadyout) @(posedge free_clk);
        data = a_hrdata;
    end
endtask

// --- Port B: address phase ---
task ahb_b_read;
    input [31:0] addr;
    begin
        #1;
        b_hsel   = 1'b1;
        b_htrans = 2'b10;
        b_haddr  = addr;
        b_hwrite = 1'b0;
        @(posedge free_clk);
        while (!b_hreadyout) @(posedge free_clk);
    end
endtask

// --- Port B: data phase ---
task ahb_b_data;
    output [31:0] data;
    begin
        @(posedge free_clk);
        while (!b_hreadyout) @(posedge free_clk);
        data = b_hrdata;
    end
endtask

// --- Port B: write (ROM ignores; b_aph_read=0 → hreadyout always 1) ---
task ahb_b_write;
    input [31:0] addr;
    begin
        #1;
        b_hsel   = 1'b1;
        b_htrans = 2'b10;
        b_haddr  = addr;
        b_hwrite = 1'b1;
        @(posedge free_clk);
        while (!b_hreadyout) @(posedge free_clk);
    end
endtask


//=============================================================================
// 10)  TEST STIMULUS
//=============================================================================

initial begin

    error      = 0;
    test_title = "INIT";

    $display("");
    $display("================================================================");
`ifdef FUSED_FIXED_B_PRIO
    $display("ahb_fused_rom_ctrl unit testbench  —  FIXED_B_PRIO = 1 (Port-B priority)");
`else
    $display("ahb_fused_rom_ctrl unit testbench  —  FIXED_B_PRIO = 0 (round-robin)");
`endif
    $display("================================================================");

    // -----------------------------------------------------------------------
    // Initialise both ports to idle
    // -----------------------------------------------------------------------
    a_idle;
    b_idle;

    // -----------------------------------------------------------------------
    // Load ROM with known random values and mirror into rom_ref
    // -----------------------------------------------------------------------
    for (ii = 0; ii < NR_WORDS; ii = ii+1) begin
        rom_inst.mem[ii] = $urandom;
        rom_ref[ii]      = rom_inst.mem[ii];
    end

    // Wait for reset to deassert
    @(posedge hresetn);
    repeat(2) @(posedge free_clk);
    #1;


    // =======================================================================
    // T1 — Port A only: sequential reads across all addresses
    // =======================================================================
    test_title = "T1: Port A only reads";
    $display("");
    $display("================================================================");
    $display("T1: Port A only reads");
    $display("================================================================");

    begin : t1
        reg [31:0] a_got;

        ahb_a_read(0);
        for (ii = 0; ii < NR_WORDS; ii = ii+1) begin
            fork
                begin ahb_a_data(a_got); chk_a(ii[MEM_ADDRW-1:0], a_got, "T1 A read"); end
                begin ahb_a_read((ii+1) << 2); end
            join
        end
        #1; a_idle;
    end


    // =======================================================================
    // T2 — Port B only: sequential reads across all addresses
    // =======================================================================
    test_title = "T2: Port B only reads";
    $display("");
    $display("================================================================");
    $display("T2: Port B only reads");
    $display("================================================================");

    begin : t2
        reg [31:0] b_got;
        ahb_b_read(0);
        for (ii = 0; ii < NR_WORDS; ii = ii+1) begin
            fork
                begin ahb_b_data(b_got); chk_b(ii[MEM_ADDRW-1:0], b_got, "T2 B read"); end
                begin ahb_b_read((ii+1) << 2); end
            join
        end
        #1; b_idle;
    end


    // =======================================================================
    // T3 — Port B write attempt
    //       ROM is read-only: write must never mutate memory and must trigger
    //       the AHB-Lite 2-cycle ERROR response.
    //
    //       Cycle N   (aph):   hreadyout=1 (address accepted), hresp=0.
    //       Cycle N+1 (ERR_1): hreadyout=0, hresp=1.
    //       Cycle N+2 (ERR_2): hreadyout=1, hresp=1.
    //       Cycle N+3 (idle):  hreadyout=1, hresp=0.
    // =======================================================================
    test_title = "T3: Port B write attempt";
    $display("");
    $display("================================================================");
    $display("T3: Port B write attempt — ROM ignores it, 2-cycle ERROR response");
    $display("================================================================");

    begin : t3
        reg [31:0] before_val;
        integer    widx;

        widx       = 5;
        before_val = rom_ref[widx];

        ahb_b_write(widx << 2);                        // aph at posedge N
        #1;                                            // cycle N+1 (ERR_1)
        b_idle;
        chk_sig(b_hreadyout, 1'b0, "T3 b_hreadyout ERR_1");
        chk_sig(b_hresp,     1'b1, "T3 b_hresp ERR_1");

        @(posedge free_clk); #1;                       // cycle N+2 (ERR_2)
        chk_sig(b_hreadyout, 1'b1, "T3 b_hreadyout ERR_2");
        chk_sig(b_hresp,     1'b1, "T3 b_hresp ERR_2");

        @(posedge free_clk); #1;                       // cycle N+3 (idle)
        chk_sig(b_hreadyout, 1'b1, "T3 b_hreadyout idle");
        chk_sig(b_hresp,     1'b0, "T3 b_hresp idle");

        if (rom_inst.mem[widx] !== before_val) begin
            $display("ERROR [T3]: ROM word[%0d] was modified by B write (got 0x%08h, expected 0x%08h)",
                     widx, rom_inst.mem[widx], before_val);
            error = error + 1;
        end else
            $display("PASS  [T3]: ROM word[%0d] unchanged after B write attempt", widx);

        repeat(2) @(posedge free_clk); #1;
    end


`ifndef FUSED_FIXED_B_PRIO
    // =======================================================================
    // T4 — Simultaneous A+B read via fork/join  [RR mode only]
    //       Both address phases land in the same cycle.  priority_a=1 so A
    //       wins; B's address is accepted immediately (hreadyout=1 from the
    //       DUT's data-phase wait mechanism), then B sees one data-phase wait
    //       state before its data is ready.  Both values correct after join.
    //       Skipped in FIXED_B_PRIO=1: B always wins so the manual
    //       chk_sig(b_hreadyout=0) wait-state assertion would be inverted.
    // =======================================================================
    test_title = "T4: Simultaneous A+B read";
    $display("");
    $display("================================================================");
    $display("T4: Simultaneous A+B read — fork/join, A wins first (priority_a=1)");
    $display("================================================================");

    begin : t4
        integer    ai, bi;
        reg [31:0] a_got, b_got;

        ai = 10;
        bi = 20;

        fork
            begin ahb_a_read(ai << 2); end
            begin ahb_b_read(bi << 2); end
        join
        fork
            begin ahb_a_data(a_got); chk_a(ai[MEM_ADDRW-1:0], a_got, "T4 A simultaneous read"); end
            begin
                @(posedge free_clk);                                              // cycle where B waits
                chk_sig(b_hreadyout, 1'b0, "T4 b_hreadyout wait");
                @(posedge free_clk);                                              // cycle where B data valid
                b_got = b_hrdata;
                chk_b(bi[MEM_ADDRW-1:0], b_got, "T4 B simultaneous read");
            end
        join
        #1; a_idle; b_idle;

        repeat(2) @(posedge free_clk); #1;
    end
`endif


    // =======================================================================
    // T5 — Simultaneous A read + B write via fork/join
    //       b_aph_read=0 (b_hwrite=1) → no arbitration contest.  A's read data
    //       is valid at posedge N+1 while B is in ERR_1; at posedge N+2 B is
    //       in ERR_2.  A data correct; ROM content unchanged; B's 2-cycle
    //       ERROR response verified in parallel with A's data phase.
    // =======================================================================
    test_title = "T5: Simultaneous A read + B write";
    $display("");
    $display("================================================================");
    $display("T5: Simultaneous A read + B write — fork/join");
    $display("================================================================");

    begin : t5
        integer    ai, bi;
        reg [31:0] a_got;
        reg [31:0] b_before;

        ai       = 7;
        bi       = 3;
        b_before = rom_ref[bi];

        fork
            begin ahb_a_read(ai << 2); end
            begin ahb_b_write(bi << 2); end
        join
        // posedge N active region. B's error FSM armed by NBA of N.
        fork
            begin ahb_a_data(a_got); end
            begin
                // cycle N+1 (ERR_1): read at posedge N+1 active region
                @(posedge free_clk);
                chk_sig(b_hreadyout, 1'b0, "T5 b_hreadyout ERR_1");
                chk_sig(b_hresp,     1'b1, "T5 b_hresp ERR_1");
            end
        join
        #1;                                            // cycle N+2 (ERR_2)
        chk_sig(b_hreadyout, 1'b1, "T5 b_hreadyout ERR_2");
        chk_sig(b_hresp,     1'b1, "T5 b_hresp ERR_2");
        a_idle; b_idle;
        chk_a(ai[MEM_ADDRW-1:0], a_got, "T5 A read while B writes");

        if (rom_inst.mem[bi] !== b_before) begin
            $display("ERROR [T5]: ROM word[%0d] modified by B write during simultaneous A read", bi);
            error = error + 1;
        end else
            $display("PASS  [T5]: ROM word[%0d] unchanged", bi);

        repeat(2) @(posedge free_clk); #1;
    end


    // =======================================================================
    // T6 — Pipelined A reads (no idle gap between address phases)
    //
    //       ahb_a_read launches addr0 and returns when the address is accepted
    //       (posedge T, hreadyout=1).  Each subsequent ahb_a_data call:
    //         - is preceded by #1 + new a_haddr (next address drives ROM at T+1)
    //         - waits for posedge T+k where hreadyout=1
    //         - returns the data for the PREVIOUS address
    //       This gives 1-read-per-cycle throughput with no idle bubbles.
    //       a_hreadyout must remain 1 throughout (no stalls with A alone).
    // =======================================================================
    test_title = "T6: Pipelined A reads";
    $display("");
    $display("================================================================");
    $display("T6: Pipelined A reads — 1 read/cycle, hreadyout stays 1");
    $display("================================================================");

    begin : t6
        reg [31:0] data_t6 [0:7];
        integer i;

        ahb_a_read(0);
        for (i = 0; i < 7; i = i+1) begin
            #1; a_haddr = (i+1) << 2;   // next address — hsel/htrans remain 2'b10
            ahb_a_data(data_t6[i]);
            chk_a(i, data_t6[i], "T6 A pipelined");
            chk_sig(a_hreadyout, 1'b1, "T6 a_hreadyout");
        end
        #1; a_idle;
        ahb_a_data(data_t6[7]);
        chk_a(7, data_t6[7], "T6 A pipelined last");
        chk_sig(a_hreadyout, 1'b1, "T6 a_hreadyout last");

        repeat(2) @(posedge free_clk); #1;
    end


`ifndef FUSED_FIXED_B_PRIO
    // =======================================================================
    // T7 — Concurrent A+B reads, 16 rounds via fork/join  [RR mode only]
    //       Toggle-priority stress: A and B alternate winning across rounds.
    //       Each round forks one ahb_a_read+ahb_a_data pair and one
    //       ahb_b_read+ahb_b_data pair simultaneously; the data-phase wait
    //       state is handled transparently by the tasks.  All 32 data values
    //       are verified.
    //       Skipped in FIXED_B_PRIO=1: both ports always request, so A would
    //       be permanently starved (hreadyout=0 forever) and the test hangs.
    // =======================================================================
    test_title = "T7: Concurrent A+B reads, 16 rounds";
    $display("");
    $display("================================================================");
    $display("T7: Concurrent A+B reads, 16 rounds — toggle-priority stress");
    $display("================================================================");

    begin : t7
        integer    i;
        reg [31:0] a_got, b_got;

        fork
            begin ahb_a_read(16 << 2); end
            begin ahb_b_read(48 << 2); end
        join
        for (i = 0; i < 16; i = i+1) begin
            fork
                begin ahb_a_data(a_got); chk_a(16+i, a_got, "T7 A concurrent"); end
                begin ahb_a_read((17 + i) << 2); end
                begin ahb_b_data(b_got); chk_b(48+i, b_got, "T7 B concurrent"); end
                begin ahb_b_read((49 + i) << 2); end
            join
        end
        #1; a_idle; b_idle;

        repeat(2) @(posedge free_clk); #1;
    end


    // =======================================================================
    // T8 — Concurrent A+B reads, 8 rounds via fork/join
    //       Same pattern as T7 with a different address set.
    // =======================================================================
    test_title = "T8: Concurrent A+B reads";
    $display("");
    $display("================================================================");
    $display("T8: Concurrent A+B reads, 8 rounds — fork/join per round");
    $display("================================================================");

    begin : t8
        integer    i;
        reg [31:0] a_got, b_got;

        fork
            begin ahb_a_read(0); end
            begin ahb_b_read(32 << 2); end
        join
        for (i = 0; i < 8; i = i+1) begin
            fork
                begin ahb_a_data(a_got); chk_a(i, a_got, "T8 A concurrent"); end
                begin ahb_a_read((i + 1) << 2); end
                begin ahb_b_data(b_got); chk_b(32+i, b_got, "T8 B concurrent"); end
                begin ahb_b_read((33 + i) << 2); end
            join
        end
        #1; a_idle; b_idle;

        repeat(2) @(posedge free_clk); #1;
    end
`endif


`ifndef FUSED_FIXED_B_PRIO
    // =======================================================================
    // T9 — A sequential (always), B sporadic random, 32 rounds  [RR only]
    //       A reads sequentially (words 0..31) every round.
    //       B randomly decides each round whether to read (50% chance);
    //       when active it uses a random address.
    //       Rounds where B is idle exercise uncontended A throughput;
    //       rounds where B is active exercise the toggle-priority arbiter.
    //       Skipped in FIXED_B_PRIO=1: the pipelined fork-join chains B's
    //       next address phase before A's previous data phase completes, so
    //       as soon as the random sequence puts a few consecutive B-active
    //       rounds together, A is permanently starved and the join deadlocks.
    // =======================================================================
    test_title = "T9: A sequential + B sporadic random";
    $display("");
    $display("================================================================");
    $display("T9: A sequential + B sporadic random — 32 rounds");
    $display("================================================================");

    begin : t9
        integer    ia;
        reg [31:0] a_got_t9, b_got_t9;
        reg [31:0] b_waddr_t9  [0:32];
        reg [31:0] b_active_t9 [0:32];  // 1 = B requests this round

        for (ia = 0; ia <= 32; ia = ia+1) begin
            b_waddr_t9[ia]  = $urandom_range(0, NR_WORDS-1);
            b_active_t9[ia] = $urandom_range(0, 1);
        end
        b_active_t9[32] = 0;  // sentinel: idle B after last real round

        if (b_active_t9[0]) begin
            fork
                begin ahb_a_read(0); end
                begin ahb_b_read(b_waddr_t9[0] << 2); end
            join
        end else
            ahb_a_read(0);

        for (ia = 0; ia < 32; ia = ia+1) begin
            fork
                begin ahb_a_data(a_got_t9); chk_a(ia[MEM_ADDRW-1:0], a_got_t9, "T9 A"); end
                begin ahb_a_read((ia+1) << 2); end
                begin
                    if (b_active_t9[ia]) begin
                        ahb_b_data(b_got_t9);
                        chk_b(b_waddr_t9[ia][MEM_ADDRW-1:0], b_got_t9, "T9 B");
                    end
                end
                begin
                    if      (b_active_t9[ia+1]) ahb_b_read(b_waddr_t9[ia+1] << 2);
                    else if (b_active_t9[ia])   begin #1; b_idle; end
                end
            join
        end
        #1; a_idle; b_idle;

        repeat(2) @(posedge free_clk); #1;
    end


    // =======================================================================
    // T10 — A random addresses + B sequential, 32 concurrent rounds  [RR only]
    //       Mirror of T9: B addresses sequential, A addresses random.
    //       Skipped in FIXED_B_PRIO=1: B always requests, A would be starved.
    // =======================================================================
    test_title = "T10: A random + B sequential";
    $display("");
    $display("================================================================");
    $display("T10: A random + B sequential — 32 pipelined concurrent rounds");
    $display("================================================================");

    begin : t10
        integer    ib;
        reg [31:0] a_got_t10, b_got_t10;
        reg [31:0] a_waddr_t10 [0:32];

        for (ib = 0; ib <= 32; ib = ib+1)
            a_waddr_t10[ib] = $urandom_range(0, NR_WORDS-1);

        fork
            begin ahb_a_read(a_waddr_t10[0] << 2); end
            begin ahb_b_read(0); end
        join
        for (ib = 0; ib < 32; ib = ib+1) begin
            fork
                begin ahb_a_data(a_got_t10); chk_a(a_waddr_t10[ib][MEM_ADDRW-1:0], a_got_t10, "T10 A"); end
                begin ahb_a_read(a_waddr_t10[ib+1] << 2); end
                begin ahb_b_data(b_got_t10); chk_b(ib[MEM_ADDRW-1:0], b_got_t10, "T10 B"); end
                begin ahb_b_read((ib+1) << 2); end
            join
        end
        #1; a_idle; b_idle;

        repeat(2) @(posedge free_clk); #1;
    end


    // =======================================================================
    // T11 — Both A and B random addresses, 32 concurrent rounds
    //       Maximum address variability; exercises all toggle-priority patterns.
    // =======================================================================
    test_title = "T11: Both A and B random";
    $display("");
    $display("================================================================");
    $display("T11: Both A and B random — 32 pipelined concurrent rounds");
    $display("================================================================");

    begin : t11
        integer    i;
        reg [31:0] a_got_t11, b_got_t11;
        reg [31:0] a_waddr_t11 [0:32];
        reg [31:0] b_waddr_t11 [0:32];

        for (i = 0; i <= 32; i = i+1) begin
            a_waddr_t11[i] = $urandom_range(0, NR_WORDS-1);
            b_waddr_t11[i] = $urandom_range(0, NR_WORDS-1);
        end

        fork
            begin ahb_a_read(a_waddr_t11[0] << 2); end
            begin ahb_b_read(b_waddr_t11[0] << 2); end
        join
        for (i = 0; i < 32; i = i+1) begin
            fork
                begin ahb_a_data(a_got_t11); chk_a(a_waddr_t11[i][MEM_ADDRW-1:0], a_got_t11, "T11 A"); end
                begin ahb_a_read(a_waddr_t11[i+1] << 2); end
                begin ahb_b_data(b_got_t11); chk_b(b_waddr_t11[i][MEM_ADDRW-1:0], b_got_t11, "T11 B"); end
                begin ahb_b_read(b_waddr_t11[i+1] << 2); end
            join
        end
        #1; a_idle; b_idle;

        repeat(2) @(posedge free_clk); #1;
    end
`endif


    // =======================================================================
    // T12 — hclk_en_o and hresp_o
    //       hclk_en_o is a 3-input combinatorial OR: a_aph_read | b_aph_read |
    //       rom_was_active.  Checks: (a) idle=0, (b) high during an A read,
    //       (c) still high the cycle after the last access (rom_was_active tail),
    //       (d) low the cycle after that.  Also verifies a_hresp_o=0, b_hresp_o=0.
    // =======================================================================
    test_title = "T12: hclk_en_o and hresp_o";
    $display("");
    $display("================================================================");
    $display("T12: hclk_en_o and hresp_o");
    $display("================================================================");

    begin : t12
        reg [31:0] a_got_t12;

        // (a) idle: both ports idle after T11 + repeat(2) gap → hclk_en=0
        @(posedge free_clk); #1;
        chk_sig(hclk_en, 1'b0, "T12 hclk_en idle");

        // (b) A read active → hclk_en=1 (combinatorial on a_aph_read)
        ahb_a_read(4);
        chk_sig(hclk_en, 1'b1, "T12 hclk_en active");

        // (c) data phase — idle port, collect data; rom_was_active still set
        #1; a_idle;
        ahb_a_data(a_got_t12);
        chk_sig(hclk_en, 1'b1, "T12 hclk_en tail (rom_was_active)");

        // (d) one more cycle — rom_was_active clears → hclk_en=0
        @(posedge free_clk); #1;
        chk_sig(hclk_en, 1'b0, "T12 hclk_en back to idle");

        // hresp: ROM always responds OK (no error response) at idle
        chk_sig(a_hresp, 1'b0, "T12 a_hresp=0");
        chk_sig(b_hresp, 1'b0, "T12 b_hresp=0");

        repeat(2) @(posedge free_clk); #1;
    end


    // =======================================================================
    // T13 — Back-to-back Port B writes
    //       Master holds the write aph across the ERR_1 stall (hreadyout=0).
    //       At posedge N+2 (ERR_2, hreadyout=1) the DUT samples a fresh
    //       b_aph_write=1, so the FSM transitions 10→01 and a second 2-cycle
    //       error response follows immediately:
    //
    //         cycle N   : aph1 accepted     hreadyout=1, hresp=0
    //         cycle N+1 : ERR_1 (write 1)   hreadyout=0, hresp=1
    //         cycle N+2 : ERR_2 (write 1)   hreadyout=1, hresp=1  ← aph2 sampled
    //         cycle N+3 : ERR_1 (write 2)   hreadyout=0, hresp=1
    //         cycle N+4 : ERR_2 (write 2)   hreadyout=1, hresp=1
    //         cycle N+5 : idle              hreadyout=1, hresp=0
    // =======================================================================
    test_title = "T13: Back-to-back B writes";
    $display("");
    $display("================================================================");
    $display("T13: Back-to-back B writes — second write sampled during ERR_2");
    $display("================================================================");

    begin : t13
        integer widx1, widx2;
        reg [31:0] before_val1, before_val2;

        widx1       = 7;
        widx2       = 9;
        before_val1 = rom_ref[widx1];
        before_val2 = rom_ref[widx2];

        // aph1 at posedge N; task keeps hsel/htrans/hwrite driven
        ahb_b_write(widx1 << 2);
        #1;                                            // cycle N+1 (ERR_1 of write 1)
        b_haddr = widx2 << 2;                          // prep aph2 while holding hsel/hwrite
        chk_sig(b_hreadyout, 1'b0, "T13 b_hreadyout ERR_1 (write 1)");
        chk_sig(b_hresp,     1'b1, "T13 b_hresp ERR_1 (write 1)");

        @(posedge free_clk); #1;                       // cycle N+2 (ERR_2 of write 1; aph2 sampled)
        chk_sig(b_hreadyout, 1'b1, "T13 b_hreadyout ERR_2 (write 1)");
        chk_sig(b_hresp,     1'b1, "T13 b_hresp ERR_2 (write 1)");

        @(posedge free_clk); #1;                       // cycle N+3 (ERR_1 of write 2)
        b_idle;                                        // master gives up
        chk_sig(b_hreadyout, 1'b0, "T13 b_hreadyout ERR_1 (write 2)");
        chk_sig(b_hresp,     1'b1, "T13 b_hresp ERR_1 (write 2)");

        @(posedge free_clk); #1;                       // cycle N+4 (ERR_2 of write 2)
        chk_sig(b_hreadyout, 1'b1, "T13 b_hreadyout ERR_2 (write 2)");
        chk_sig(b_hresp,     1'b1, "T13 b_hresp ERR_2 (write 2)");

        @(posedge free_clk); #1;                       // cycle N+5 (idle)
        chk_sig(b_hreadyout, 1'b1, "T13 b_hreadyout idle");
        chk_sig(b_hresp,     1'b0, "T13 b_hresp idle");

        if (rom_inst.mem[widx1] !== before_val1 ||
            rom_inst.mem[widx2] !== before_val2) begin
            $display("ERROR [T13]: ROM modified by back-to-back B writes (w1=0x%08h exp=0x%08h, w2=0x%08h exp=0x%08h)",
                     rom_inst.mem[widx1], before_val1,
                     rom_inst.mem[widx2], before_val2);
            error = error + 1;
        end else
            $display("PASS  [T13]: ROM unchanged after back-to-back B writes");

        repeat(2) @(posedge free_clk); #1;
    end


    // =======================================================================
    // T14 — Back-to-back B reads while A is pending  (FIXED_B_PRIO regression)
    //
    //       Scenario: A and B contest cycle 0; B continues a 4-deep pipelined
    //       stream addrB[0..3] back-to-back; A has only one outstanding read
    //       and idles its address phase early.  The address-mux structure in
    //       FIXED_B_PRIO=1 (b_aph_read ? b_haddr : arb[1] ? saved_addr : ...)
    //       lets B preempt the saved replay address every cycle B is active.
    //       The bug it regresses: a_lost was masked by ~arb[1], so a_hreadyout
    //       wrongly went high mid-stream and A latched B's intermediate data
    //       (mem[addrB[1]]) instead of its own (mem[addrA]).
    //
    //       Pass criterion (both modes): A's eventual data == mem[addrA].
    //       In RR mode A wins cycle 0 immediately (priority_a=1) and the
    //       check is trivially true; in FIXED_B_PRIO=1 the test is only
    //       passable with the a_stall-driven hreadyout fix.
    // =======================================================================
    test_title = "T14: A pending across back-to-back B reads";
    $display("");
    $display("================================================================");
    $display("T14: A pending across back-to-back B reads (FIXED_B_PRIO regression)");
    $display("================================================================");

    begin : t14
        reg [31:0] a_got_t14;
        reg [31:0] b_got_t14;
        integer    a_idx_t14;
        integer    b_idx_t14 [0:3];
        integer    j;

        a_idx_t14    =  4;
        b_idx_t14[0] = 12;
        b_idx_t14[1] = 13;
        b_idx_t14[2] = 14;
        b_idx_t14[3] = 15;

        fork
            // --- Branch A: single read, idle immediately, then collect data
            begin
                ahb_a_read(a_idx_t14 << 2);
                #1; a_idle;
                ahb_a_data(a_got_t14);
                chk_a(a_idx_t14[MEM_ADDRW-1:0], a_got_t14, "T14 A pending");
            end
            // --- Branch B: 4-deep pipelined back-to-back reads, then idle
            begin
                ahb_b_read(b_idx_t14[0] << 2);
                for (j = 0; j < 3; j = j+1) begin
                    fork
                        begin ahb_b_data(b_got_t14); chk_b(b_idx_t14[j][MEM_ADDRW-1:0], b_got_t14, "T14 B"); end
                        begin ahb_b_read(b_idx_t14[j+1] << 2); end
                    join
                end
                #1; b_idle;
                ahb_b_data(b_got_t14);
                chk_b(b_idx_t14[3][MEM_ADDRW-1:0], b_got_t14, "T14 B last");
            end
        join

        repeat(2) @(posedge free_clk); #1;
    end


    // =======================================================================
    // END OF TEST
    // =======================================================================
    repeat(4) @(posedge free_clk);

    $display("");
    $display("================================================================");
    if (error == 0)
        $display("SIMULATION PASSED  (0 errors)");
    else
        $display("SIMULATION FAILED  (%0d errors)", error);
    $display("================================================================");
    $display("");

    $finish;

end // initial

endmodule // tb_ahb_fused_rom_ctrl
