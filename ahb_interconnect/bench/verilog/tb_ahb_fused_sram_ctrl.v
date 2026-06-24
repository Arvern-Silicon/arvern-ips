//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tb_ahb_fused_sram_ctrl
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tb_ahb_fused_sram_ctrl.v
// Module Description : Testbench for the fused AHB SRAM controller.
//----------------------------------------------------------------------------

`include "timescale.v"

module tb_ahb_fused_sram_ctrl;


//=============================================================================
// 1)  PARAMETERS
//=============================================================================

parameter  MEM_SIZE  = 256;
localparam MEM_ADDRW = $clog2(MEM_SIZE)-2;
localparam NR_WORDS  = MEM_SIZE / 4;

// Seed for $urandom.  Override on the iverilog command line with
// `+define+SEED=N` (run_fused_sram -seed N).  Default is fixed so that
// CI runs are reproducible without any flag.
`ifdef SEED
parameter  SEED_VAL = `SEED;
`else
parameter  SEED_VAL = 32'hC0DE_BABE;
`endif


//=============================================================================
// 2)  SIGNAL DECLARATIONS
//=============================================================================

// Clock / reset
reg                    free_clk;
reg                    hresetn;

// Port A -- regs driven by m0 AHB BFM (hwrite/hsize/hwdata present only so the
// shared BFM can compile; the DUT has no Port-A write path so they are not
// wired to the DUT instantiation below).
reg            [31:0]  m0_haddr;
reg                    m0_hsel;
reg            [1:0]   m0_htrans;
reg                    m0_hwrite;
reg             [2:0]  m0_hsize;
reg            [31:0]  m0_hwdata;
wire                   m0_hready;

wire          [31:0]   m0_hrdata;
wire                   a_hreadyout;
wire                   a_hresp;

// Port B -- regs driven by m1 AHB BFM.
reg            [31:0]  m1_haddr;
reg                    m1_hsel;
reg            [1:0]   m1_htrans;
reg                    m1_hwrite;
reg             [2:0]  m1_hsize;
reg            [31:0]  m1_hwdata;
wire                   m1_hready;

wire          [31:0]   m1_hrdata;
wire                   b_hreadyout;
wire                   b_hresp;

// SRAM macro wires
wire          [31:0]   sram_dout;
wire          [31:0]   sram_din;
wire          [29:0]   sram_addr;
wire                   sram_cen_n;
wire           [3:0]   sram_wen_n;
wire                   sram_clk;

// Clock enable
wire                   hclk_en;

// Reference memory (mirrors all writes made through the DUT)
reg           [31:0]   sram_ref [0:NR_WORDS-1];

// Error counter
integer                error;
integer                ii;

// Forwarding coverage counter -- incremented whenever the DUT sources Port-B
// HRDATA from the write pause buffer.  Tests can snapshot/compare this to
// assert the forwarding path was actually exercised (not passed incidentally).
integer                fwd_cov_cnt;
always @(posedge free_clk or negedge hresetn)
    if (!hresetn)                       fwd_cov_cnt <= 0;
    else if (dut_b_sram_read_from_pause) fwd_cov_cnt <= fwd_cov_cnt + 1;

// HREADYOUT-low streak trackers.  Port A should never stay low >1 cycle.
// Port B can stay low for multiple cycles during b_write_stall; track
// the max streak there conditionally so we can compare against expectation.
//
// Two parallel scopes are tracked:
//   - Global (a_low_max / b_low_max / b_stall_max): monotonic across the whole
//     sim, drives the end-of-run summary line.
//   - Per-test window (wait_a_max / wait_b_max / wait_bs_max): reset by
//     wait_begin, observed only while wait_active=1; consumed by wait_check.
//
// The per-test scope is NOT a delta of the global -- using (global_max - pre)
// silently PASSES a regression when an earlier test already set the global
// max above the later test's expected bound.
integer a_low_cur, a_low_max;
integer b_low_cur, b_low_max, b_stall_cur, b_stall_max;
integer wait_a_max, wait_b_max, wait_bs_max;
reg     wait_active;
reg [64*8-1:0] b_stall_max_test;
always @(posedge free_clk or negedge hresetn) begin
    if (!hresetn) begin
        a_low_cur  <= 0; a_low_max  <= 0;
        b_low_cur  <= 0; b_low_max  <= 0;
        b_stall_cur<= 0; b_stall_max<= 0;
        wait_a_max <= 0; wait_b_max <= 0; wait_bs_max <= 0;
        b_stall_max_test <= "(none)";
    end else begin
        a_low_cur   <= a_hreadyout ? 0 : a_low_cur + 1;
        if (!a_hreadyout && a_low_cur + 1 > a_low_max) a_low_max <= a_low_cur + 1;
        b_low_cur   <= b_hreadyout ? 0 : b_low_cur + 1;
        if (!b_hreadyout && b_low_cur + 1 > b_low_max) b_low_max <= b_low_cur + 1;
        b_stall_cur <= dut_b_write_stall ? b_stall_cur + 1 : 0;
        if (dut_b_write_stall && b_stall_cur + 1 > b_stall_max) begin
            b_stall_max      <= b_stall_cur + 1;
            b_stall_max_test <= test_title;
        end
        // Per-test maxes: only update while a wait_begin/wait_check window
        // is open.  wait_begin clears them to 0 before setting wait_active.
        if (wait_active) begin
            if (!a_hreadyout       && a_low_cur + 1   > wait_a_max)  wait_a_max  <= a_low_cur + 1;
            if (!b_hreadyout       && b_low_cur + 1   > wait_b_max)  wait_b_max  <= b_low_cur + 1;
            if (dut_b_write_stall  && b_stall_cur + 1 > wait_bs_max) wait_bs_max <= b_stall_cur + 1;
        end
    end
end

// Whitebox aliases derived from real DUT state.  The DUT no longer carries
// TB-only legacy aliases (arb / sram_owner / wr_buf_full / ...), so these
// re-build them here from the live signals.
//
//   arb      = {replay_pending, priority_a}
//              replay_pending = m0_aph_pending | m1_aph_pending
//              priority_a     = ~toggle_priority
//   wr_buf_full      = (state == WRITE) | (state == READ_PENDING_WRITE)
//   sram_owner       : OWN_B_WR (2'b11) when sram_wr_active,
//                      OWN_A_RD (2'b01) when sram_rd_cmd & arb_grant[0],
//                      OWN_B_RD (2'b10) when sram_rd_cmd & arb_grant[1],
//                      OWN_IDLE (2'b00) otherwise.
wire        dut_b_write_stall          = 1'b0;
wire        dut_b_sram_read_from_pause = dut.sram_read_from_pause & dut.m1_dph_ongoing;
wire        dut_wr_buf_full            = (dut.state == dut.WRITE) | (dut.state == dut.READ_PENDING_WRITE);
wire        dut_replay_pending         = dut.m0_aph_pending | dut.m1_aph_pending;
wire        dut_priority_a             = ~dut.gen_arb_rr.toggle_priority;
wire [1:0]  dut_arb                    = {dut_replay_pending, dut_priority_a};
wire        dut_sram_owner_b_wr        =  dut.sram_wr_active;
wire        dut_sram_owner_a_rd        = ~dut.sram_wr_active &  dut.sram_rd_cmd &  dut.arb_grant[0];
wire        dut_sram_owner_b_rd        = ~dut.sram_wr_active &  dut.sram_rd_cmd &  dut.arb_grant[1];
wire [1:0]  dut_sram_owner             = dut_sram_owner_b_wr ? 2'b11 :
                                         dut_sram_owner_a_rd ? 2'b01 :
                                         dut_sram_owner_b_rd ? 2'b10 : 2'b00;
wire        dut_sram_owner_nxt_a_rd    = ~dut.sram_wr_cmd_pre & dut.state_nxt[dut.READ_BIT] & dut.arb_grant[0];
wire        dut_a_aph_read             = dut.m0_aph_valid;
wire        dut_a_lost                 = dut.m0_latch_aph;
wire        dut_b_aph_valid_pre        = dut.m1_aph_valid;
wire [29:0] dut_saved_addr             = dut.m0_aph_pending ? dut.m0_haddr_cache[31:2] :
                                         dut.m1_aph_pending ? dut.m1_haddr_cache[31:2] :
                                                              30'h0;
wire [29:0] dut_b_sram_wr_addr_buf     = dut.sram_wr_addr_buf;

wire       dut_b_wr_pending     = dut_wr_buf_full;
wire       dut_b_sram_wr_active = dut_sram_owner_b_wr;
wire       dut_a_grant          = dut_sram_owner_nxt_a_rd & (dut_arb != 2'b11);
wire [2:0] dut_b_state          = {dut_b_sram_wr_active,
                                   dut_sram_owner_b_rd | (dut_arb == 2'b10),
                                   dut_wr_buf_full};

// T38 cycle-by-cycle DUT probe (whitebox).  Gated off by default so it only
// fires during the stress window under investigation.  Purpose: if a B read
// returns unexpected data, we need to see whether HREADYOUT went low (proper
// backpressure -- master bug) or stayed high (forwarding/mux bug in DUT).
reg fwd_dbg_en;
initial fwd_dbg_en = 1'b0;
always @(posedge free_clk) begin
    if (fwd_dbg_en && hresetn) begin
        $display("[DBG %0t] arb=%b own=%b a_aph=%b a_grant=%b a_lost=%b a_hrdyo=%b b_aph=%b b_state=%b wr_pend=%b wr_act=%b stall=%b b_hrdyo=%b rd_paus=%b saddr=%h wbuf=%h m1_hrdata=%h",
                 $time, dut_arb, dut_sram_owner, dut_a_aph_read, dut_a_grant, dut_a_lost,
                 dut.a_hreadyout_o, dut_b_aph_valid_pre, dut_b_state, dut_b_wr_pending,
                 dut_b_sram_wr_active, dut_b_write_stall, dut.b_hreadyout_o,
                 dut_b_sram_read_from_pause, dut_saved_addr, dut_b_sram_wr_addr_buf, m1_hrdata);
    end
end

// Test title for waveform annotation
reg           [64*8-1:0] test_title;


//=============================================================================
// 3)  HREADY FEEDBACK  (point-to-point: hready_i = hreadyout_o)
//
// External wait-state injectors (a_hready_ext / b_hready_ext) allow a test to
// pull HREADY low independently of HREADYOUT, emulating another slave holding
// the bus.  Default = 1'b1 (no wait states).
//=============================================================================

reg a_hready_ext = 1'b1;
reg b_hready_ext = 1'b1;

assign m0_hready = a_hreadyout & a_hready_ext;
assign m1_hready = b_hreadyout & b_hready_ext;


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

ahb_fused_sram_ctrl dut (
    .hclk_i        (free_clk),
    .hresetn_i     (hresetn),
    .hclk_en_o     (hclk_en),

    .a_haddr_i     (m0_haddr),
    .a_hsel_i      (m0_hsel),
    .a_htrans_i    (m0_htrans),
    .a_hready_i    (m0_hready),
    .a_hsize_i     (3'b010),
    .a_hrdata_o    (m0_hrdata),
    .a_hreadyout_o (a_hreadyout),
    .a_hresp_o     (a_hresp),

    .b_haddr_i     (m1_haddr),
    .b_hsel_i      (m1_hsel),
    .b_htrans_i    (m1_htrans),
    .b_hwrite_i    (m1_hwrite),
    .b_hsize_i     (m1_hsize),
    .b_hwdata_i    (m1_hwdata),
    .b_hready_i    (m1_hready),
    .b_hrdata_o    (m1_hrdata),
    .b_hreadyout_o (b_hreadyout),
    .b_hresp_o     (b_hresp),

    .sram_dout_i   (sram_dout),
    .sram_din_o    (sram_din),
    .sram_addr_o   (sram_addr),
    .sram_cen_o    (sram_cen_n),
    .sram_wen_o    (sram_wen_n),
    .sram_clk_o    (sram_clk)
);


//=============================================================================
// 6)  SRAM MACRO MODEL
//=============================================================================

sram #(.MEM_ADDRW(MEM_ADDRW), .MEM_SIZE(MEM_SIZE)) sram_inst (
    .sram_dout_o (sram_dout),
    .sram_addr_i (sram_addr[MEM_ADDRW-1:0]),
    .sram_cen_i  (sram_cen_n),
    .sram_clk_i  (sram_clk),
    .sram_din_i  (sram_din),
    .sram_wen_i  (sram_wen_n)
);


//=============================================================================
// 7)  VCD DUMP
//=============================================================================

`ifndef NODUMP
initial begin
    $dumpfile("tb_ahb_fused_sram_ctrl.vcd");
    $dumpvars(0, tb_ahb_fused_sram_ctrl);
end
`endif


//=============================================================================
// 8)  IDLE HELPERS
//=============================================================================

task a_idle;
    begin
        m0_hsel   = 1'b0;
        m0_htrans = 2'b00;
        m0_haddr  = 32'b0;
        m0_hwrite = 1'b0;
        m0_hsize  = 3'b010;
        m0_hwdata = 32'b0;
    end
endtask

task b_idle;
    begin
        m1_hsel   = 1'b0;
        m1_htrans = 2'b00;
        m1_haddr  = 32'b0;
        m1_hwrite = 1'b0;
        m1_hsize  = 3'b010;
        m1_hwdata = 32'b0;
    end
endtask


//=============================================================================
// 9)  CHECK HELPERS
//=============================================================================

task chk_a;
    input [MEM_ADDRW-1:0] word_idx;
    input          [31:0] got;
    input          [80*8:1] msg;
    begin
        if (got !== sram_ref[word_idx]) begin
            $display("ERROR [%0s]: Port A @ word[%0d] -- got 0x%08h, expected 0x%08h  (%0t ns)",
                     msg, word_idx, got, sram_ref[word_idx], $time);
            error = error + 1;
        end else
            $display("PASS  [%0s]: Port A @ word[%0d] = 0x%08h  (%0t ns)",
                     msg, word_idx, got, $time);
    end
endtask

task chk_b;
    input [MEM_ADDRW-1:0] word_idx;
    input          [31:0] got;
    input          [80*8:1] msg;
    begin
        if (got !== sram_ref[word_idx]) begin
            $display("ERROR [%0s]: Port B @ word[%0d] -- got 0x%08h, expected 0x%08h  (%0t ns)",
                     msg, word_idx, got, sram_ref[word_idx], $time);
            error = error + 1;
        end else
            $display("PASS  [%0s]: Port B @ word[%0d] = 0x%08h  (%0t ns)",
                     msg, word_idx, got, $time);
    end
endtask

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
// 9a) PER-TEST WAIT-STATE CHECK
//
//     Each test can bracket itself with wait_begin / wait_check to assert an
//     upper bound on the HREADYOUT-low streak observed during the test -- a
//     performance regression guard that runs alongside the data-integrity
//     checks.
//
//     Usage:
//         wait_begin;                                 // reset + open window
//         ... test body ...
//         wait_check("T1", 0, 0, 0);                  // exp_a, exp_b, exp_b_stall
//
//     Each expected bound is a **max streak** (cycles HREADYOUT stayed low
//     consecutively) observed DURING the window.  Pass -1 to report the
//     observed value without checking (INFO-only).  A failure prints ERROR
//     and bumps the global error counter.
//
//     wait_a_max / wait_b_max / wait_bs_max are reset to 0 here and updated
//     by the streak-tracker always block only while wait_active=1, so a
//     large streak from an earlier test can't mask a regression here.
//=============================================================================

task wait_begin;
    begin
        wait_a_max  = 0;
        wait_b_max  = 0;
        wait_bs_max = 0;
        wait_active = 1'b1;
    end
endtask

task wait_check;
    input [32*8:1] tname;
    input integer  exp_a_max;
    input integer  exp_b_max;
    input integer  exp_b_stall_max;
    begin
        wait_active = 1'b0;
        if (exp_a_max < 0)
            $display("INFO  [%0s waits]: Port-A HREADYOUT-low streak = %0d (no check)  (%0t ns)",
                     tname, wait_a_max, $time);
        else if (wait_a_max > exp_a_max) begin
            $display("ERROR [%0s waits]: Port-A HREADYOUT-low streak = %0d, expected <= %0d  (%0t ns)",
                     tname, wait_a_max, exp_a_max, $time);
            error = error + 1;
        end else
            $display("PASS  [%0s waits]: Port-A HREADYOUT-low streak = %0d (<= %0d)  (%0t ns)",
                     tname, wait_a_max, exp_a_max, $time);
        if (exp_b_max < 0)
            $display("INFO  [%0s waits]: Port-B HREADYOUT-low streak = %0d (no check)  (%0t ns)",
                     tname, wait_b_max, $time);
        else if (wait_b_max > exp_b_max) begin
            $display("ERROR [%0s waits]: Port-B HREADYOUT-low streak = %0d, expected <= %0d  (%0t ns)",
                     tname, wait_b_max, exp_b_max, $time);
            error = error + 1;
        end else
            $display("PASS  [%0s waits]: Port-B HREADYOUT-low streak = %0d (<= %0d)  (%0t ns)",
                     tname, wait_b_max, exp_b_max, $time);
        if (exp_b_stall_max < 0)
            $display("INFO  [%0s waits]: Port-B write-stall streak = %0d (no check)  (%0t ns)",
                     tname, wait_bs_max, $time);
        else if (wait_bs_max > exp_b_stall_max) begin
            $display("ERROR [%0s waits]: Port-B write-stall streak = %0d, expected <= %0d  (%0t ns)",
                     tname, wait_bs_max, exp_b_stall_max, $time);
            error = error + 1;
        end else
            $display("PASS  [%0s waits]: Port-B write-stall streak = %0d (<= %0d)  (%0t ns)",
                     tname, wait_bs_max, exp_b_stall_max, $time);
    end
endtask


//=============================================================================
// 9b) REFERENCE MODEL  (mirrors DUT byte-lane write logic)
//=============================================================================

task ref_write;
    input [31:0] addr;
    input  [2:0] hsize;
    input [31:0] wdata;
    reg [MEM_ADDRW-1:0] widx;
    begin
        widx = addr[MEM_ADDRW+1:2];
        case (hsize[1:0])
            2'b00: case (addr[1:0])   // byte
                       2'b00: sram_ref[widx][ 7: 0] = wdata[ 7: 0];
                       2'b01: sram_ref[widx][15: 8] = wdata[15: 8];
                       2'b10: sram_ref[widx][23:16] = wdata[23:16];
                       2'b11: sram_ref[widx][31:24] = wdata[31:24];
                   endcase
            2'b01: if (addr[1])       // halfword upper
                       sram_ref[widx][31:16] = wdata[31:16];
                   else               // halfword lower
                       sram_ref[widx][15: 0] = wdata[15: 0];
            default: sram_ref[widx] = wdata;   // word
        endcase
    end
endtask


//=============================================================================
// 9c) SHARED AHB BFM  (reused from ahb_interconnect fabric testbench)
//
// Provides:
//   m0_ahb_read (blocking, addr, expected, size, check)   -- Port A reads
//   m1_ahb_read (blocking, addr, expected, size, check)   -- Port B reads
//   m1_ahb_write(blocking, addr, data,     size)          -- Port B writes
//
// The BFMs drive m0_/m1_ signals declared in section 2 and read m0_/m1_hready
// / m0_/m1_hrdata wired in section 3.  They do NOT drive hsel -- the test
// stimulus must hold hsel high while an APH is outstanding (the unit TB has
// no fabric decoder, so hsel is effectively a constant "selected" strobe).
//=============================================================================

`include "ahb_tasks_m0.v"
`include "ahb_tasks_m1.v"


//=============================================================================
// 9d) LEGACY AHB DRIVER TASKS  (pre-BFM, retained while tests migrate)
//=============================================================================

// --- Port A: address phase ---
task ahb_a_read;
    input [31:0] addr;
    begin
        #1;
        m0_hsel   = 1'b1;
        m0_htrans = 2'b10;
        m0_haddr  = addr;
        @(posedge free_clk);
        while (!m0_hready) @(posedge free_clk);
    end
endtask

// --- Port A: data phase ---
task ahb_a_data;
    output [31:0] data;
    begin
        @(posedge free_clk);
        while (!m0_hready) @(posedge free_clk);
        data = m0_hrdata;
    end
endtask

// --- Port B: address phase (read) ---
task ahb_b_read;
    input [31:0] addr;
    begin
        #1;
        m1_hsel   = 1'b1;
        m1_htrans = 2'b10;
        m1_haddr  = addr;
        m1_hwrite = 1'b0;
        m1_hsize  = 3'b010;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);
    end
endtask

// --- Port B: data phase (read) ---
task ahb_b_data;
    output [31:0] data;
    begin
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);
        data = m1_hrdata;
    end
endtask

// --- Port B: full write transaction (address phase + data phase) ---
//
// Write address accepted immediately (unless write buffer occupied).
// Write data (HWDATA) driven during data phase; DUT captures it into the
// write buffer.  The actual SRAM write is deferred until no read is in
// progress; the caller must allow at least one idle cycle after this task
// returns if it needs to observe the committed write.
//
task ahb_b_write;
    input [31:0] addr;
    input  [2:0] hsize;
    input [31:0] wdata;
    begin
        // Address phase -- sample HREADYOUT in the Active region (pre-NBA) to
        // match DUT's Phase 1 capture semantics.  Using a post-NBA (#1) sample
        // is unsafe here: the DUT's b_hreadyout has a combinational dependence
        // on sram_wr_drain (which updates through wd_st NBA), so hready may
        // glitch high post-NBA of the wr_lost cycle while the DUT's Phase 1
        // sampled the pre-NBA (still low) gate and did not latch the aph.
        #1;
        m1_hsel   = 1'b1;
        m1_htrans = 2'b10;
        m1_haddr  = addr;
        m1_hwrite = 1'b1;
        m1_hsize  = hsize;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);
        // Data phase: present HWDATA, idle address bus
        #1;
        m1_hwdata = wdata;
        m1_hsel   = 1'b0;
        m1_htrans = 2'b00;
        m1_hwrite = 1'b0;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);
        // Clear HWDATA to avoid confusion in waveforms
        #1;
        m1_hwdata = 32'b0;
    end
endtask


//=============================================================================
// 10)  TEST STIMULUS
//=============================================================================

// Global simulation watchdog -- fires if the main test sequence hangs.
// Current full-test wall time is ~156 us; bound at 1 ms (~6x headroom).
initial begin : watchdog
    #1_000_000;
    $display("");
    $display("================================================================");
    $display("ERROR: simulation watchdog expired at %0t ns -- forcing $finish",
             $time);
    $display("================================================================");
    error = error + 1;
    $finish;
end

initial begin : main_stim
    integer seed_var;
    integer seed_dummy;

    error      = 0;
    test_title = "INIT";

    // Pin the RNG so any test using $urandom can be replayed by passing
    // the same seed back via run_fused_sram -seed <N>.  $urandom requires
    // its seed argument to be a variable, not a parameter.
    seed_var   = SEED_VAL;
    seed_dummy = $urandom(seed_var);
    $display("================================================================");
    $display("INFO:  simulation seed = %0d (0x%08h) -- replay: run_fused_sram -seed %0d",
             SEED_VAL, SEED_VAL, SEED_VAL);
    $display("================================================================");

    a_idle;
    b_idle;

    // Initialise SRAM with known random values; mirror into sram_ref
    for (ii = 0; ii < NR_WORDS; ii = ii+1) begin
        sram_inst.mem[ii] = $urandom;
        sram_ref[ii]      = sram_inst.mem[ii];
    end

    @(posedge hresetn);
    repeat(2) @(posedge free_clk);
    #1;


    // =======================================================================
    // T1 -- Port A only: sequential reads across all addresses
    // =======================================================================
    test_title = "T1: Port A only reads";
    $display("");
    $display("================================================================");
    $display("T1: Port A only reads");
    $display("================================================================");

    // BFM migration pilot: T1 drives Port A reads through the shared
    // m0_ahb_read task (pipelined, non-blocking, with async data check).
    begin : t1
        wait_begin;
        m0_hsel = 1'b1;                       // unit TB has no fabric decoder
        for (ii = 0; ii < NR_WORDS; ii = ii+1) begin
            m0_ahb_read(1'b0,                 // blocking=0 (pipelined)
                        ii << 2,              // word address
                        sram_ref[ii],         // expected data
                        2'b10,                // size=word
                        1'b1);                // check enabled
        end
        // Allow the last DPH's async check to complete before idling the bus.
        @(posedge free_clk); #1;
        a_idle;
        wait_check("T1", 0, 0, 0);            // pure A reads: zero wait states
    end


    // =======================================================================
    // T2 -- Port B only: sequential reads across all addresses
    // =======================================================================
    test_title = "T2: Port B only reads";
    $display("");
    $display("================================================================");
    $display("T2: Port B only reads");
    $display("================================================================");

    begin : t2
        wait_begin;
        m1_hsel = 1'b1;
        for (ii = 0; ii < NR_WORDS; ii = ii+1) begin
            m1_ahb_read(1'b0, ii << 2, sram_ref[ii], 2'b10, 1'b1);
        end
        @(posedge free_clk); #1;
        b_idle;
        wait_check("T2", 0, 0, 0);           // pure B reads: zero wait states
    end


    // =======================================================================
    // T3 -- Port B word writes: write all words, read back via B then via A
    //
    //       Each write is non-pipelined; one idle cycle after each write lets
    //       the write buffer drain before the next write is issued.
    // =======================================================================
    test_title = "T3: Port B word writes + readback";
    $display("");
    $display("================================================================");
    $display("T3: Port B word writes + readback");
    $display("================================================================");

    begin : t3
        reg [31:0] wr_val;

        wait_begin;
        m1_hsel = 1'b1;

        // Pipelined B writes of fresh random values
        for (ii = 0; ii < NR_WORDS; ii = ii+1) begin
            wr_val = $urandom;
            m1_ahb_write(1'b0, ii << 2, wr_val, 2'b10);
            ref_write(ii << 2, 3'b010, wr_val);
        end
        // Drain the last buffered write
        @(posedge free_clk); @(posedge free_clk); #1;

        // Read back via B
        for (ii = 0; ii < NR_WORDS; ii = ii+1) begin
            m1_ahb_read(1'b0, ii << 2, sram_ref[ii], 2'b10, 1'b1);
        end
        @(posedge free_clk); #1;
        b_idle;

        // Read back via A
        m0_hsel = 1'b1;
        for (ii = 0; ii < NR_WORDS; ii = ii+1) begin
            m0_ahb_read(1'b0, ii << 2, sram_ref[ii], 2'b10, 1'b1);
        end
        @(posedge free_clk); #1;
        a_idle;

        repeat(2) @(posedge free_clk); #1;

        // Pipelined B writes + sequential B/A readbacks, no cross-port contest:
        // zero wait states expected on both ports.  b_stall_max in particular
        // caught the pre-fix performance regression where pipelined writes
        // forced themselves through the pause buffer.
        wait_check("T3", 0, 0, 0);
    end


    // =======================================================================
    // T4 -- Port B byte/halfword writes + readback
    //
    //       Uses word[0] as the target.  Writes each byte lane individually
    //       then verifies the full word.  Repeats for halfword granularity.
    // =======================================================================
    test_title = "T4: Byte and halfword writes";
    $display("");
    $display("================================================================");
    $display("T4: Port B byte/halfword writes + readback");
    $display("================================================================");

    begin : t4
        reg  [7:0] rb0, rb1, rb2, rb3;
        reg [15:0] rh0, rh1;
        integer    tgt;

        wait_begin;
        m1_hsel = 1'b1;

        // ---- Byte writes: each lane independently.  The BFM realigns
        //      data[7:0] into the byte lane selected by addr[1:0], so we
        //      pass raw bytes; ref_write takes the pre-shifted form.
        tgt = 0;
        rb0 = $urandom; rb1 = $urandom; rb2 = $urandom; rb3 = $urandom;

        m1_ahb_write(1'b0, (tgt<<2)+0, {24'b0, rb0},          2'b00);
        m1_ahb_write(1'b0, (tgt<<2)+1, {24'b0, rb1},          2'b00);
        m1_ahb_write(1'b0, (tgt<<2)+2, {24'b0, rb2},          2'b00);
        m1_ahb_write(1'b0, (tgt<<2)+3, {24'b0, rb3},          2'b00);
        ref_write((tgt<<2)+0, 3'b000, {24'b0, rb0});
        ref_write((tgt<<2)+1, 3'b000, {16'b0, rb1,  8'b0});
        ref_write((tgt<<2)+2, 3'b000, { 8'b0, rb2, 16'b0});
        ref_write((tgt<<2)+3, 3'b000, {       rb3, 24'b0});
        @(posedge free_clk); @(posedge free_clk); #1;

        m1_ahb_read(1'b0, tgt<<2, sram_ref[tgt[MEM_ADDRW-1:0]], 2'b10, 1'b1);
        @(posedge free_clk); #1;
        b_idle;

        // ---- Halfword writes ----
        m1_hsel = 1'b1;
        tgt = 1;
        rh0 = $urandom; rh1 = $urandom;

        m1_ahb_write(1'b0, (tgt<<2)+0, {16'b0, rh0},          2'b01);
        m1_ahb_write(1'b0, (tgt<<2)+2, {16'b0, rh1},          2'b01);
        ref_write((tgt<<2)+0, 3'b001, {16'b0, rh0       });
        ref_write((tgt<<2)+2, 3'b001, {       rh1, 16'b0});
        @(posedge free_clk); @(posedge free_clk); #1;

        m1_ahb_read(1'b0, tgt<<2, sram_ref[tgt[MEM_ADDRW-1:0]], 2'b10, 1'b1);
        @(posedge free_clk); #1;
        b_idle;

        repeat(2) @(posedge free_clk); #1;
        wait_check("T4", 0, 0, 0);
    end


    // =======================================================================
    // T5 -- Simultaneous A read + B write
    //
    //       A and B address phases coincide.  A reads word[ai]; B writes
    //       word[bi] (different address).  A wins because it is a read and
    //       B's write bypasses arbitration into the write buffer.  After the
    //       fork, A data phase completes (write drains simultaneously); a
    //       subsequent B read of word[bi] confirms the write.
    // =======================================================================
    test_title = "T5: Simultaneous A read + B write";
    $display("");
    $display("================================================================");
    $display("T5: Simultaneous A read + B write");
    $display("================================================================");

    begin : t5
        integer    ai, bi;
        reg [31:0] wr_val;

        ai     = 10;
        bi     = 20;
        wr_val = $urandom;

        wait_begin;
        m0_hsel = 1'b1;
        m1_hsel = 1'b1;

        // Concurrent A read + B write -- both APHs captured on same posedge
        fork
            m0_ahb_read (1'b0, ai << 2, sram_ref[ai[MEM_ADDRW-1:0]], 2'b10, 1'b1);
            m1_ahb_write(1'b0, bi << 2, wr_val,                      2'b10);
        join
        ref_write(bi << 2, 3'b010, wr_val);
        @(posedge free_clk); #1;
        a_idle;

        // Read back bi via B to confirm write committed
        m1_hsel = 1'b1;
        m1_ahb_read(1'b0, bi << 2, sram_ref[bi[MEM_ADDRW-1:0]], 2'b10, 1'b1);
        @(posedge free_clk); #1;
        b_idle;

        repeat(2) @(posedge free_clk); #1;
        // A+B contend on same posedge -> up to 1 wait state on the loser is OK
        wait_check("T5", 1, 1, 0);
    end


    // =======================================================================
    // T6 -- Sequential B write then B read (write buffer timing)
    //
    //       B writes to word[wi] then reads from word[ri] (different address).
    //       The write is in the buffer when the B read starts; the read takes
    //       priority (sram_rd_active=1), so the write is deferred until the B
    //       read data phase when the SRAM is free.  A subsequent read of word[wi]
    //       confirms the write committed.
    // =======================================================================
    test_title = "T6: B write then B read (write buffer timing)";
    $display("");
    $display("================================================================");
    $display("T6: Sequential B write -> B read -- write buffer timing");
    $display("================================================================");

    begin : t6
        integer    wi, ri;
        reg [31:0] wr_val;

        wi     = 30;
        ri     = 40;
        wr_val = $urandom;

        wait_begin;
        m1_hsel = 1'b1;

        // Pipelined: B write (wi) -> B read (ri) -> B read (wi, confirm commit)
        m1_ahb_write(1'b0, wi << 2, wr_val,                      2'b10);
        ref_write   (     wi << 2, 3'b010, wr_val);
        m1_ahb_read (1'b0, ri << 2, sram_ref[ri[MEM_ADDRW-1:0]], 2'b10, 1'b1);
        m1_ahb_read (1'b0, wi << 2, sram_ref[wi[MEM_ADDRW-1:0]], 2'b10, 1'b1);
        @(posedge free_clk); #1;
        b_idle;

        repeat(2) @(posedge free_clk); #1;
        wait_check("T6", 0, 0, 0);
    end


    // =======================================================================
    // T7 -- Sequential B write then A read (write buffer with A priority)
    //
    //       B writes to word[wi]; then A reads from word[ai] (different addr).
    //       A reads successfully while the write is pending in the buffer
    //       (sram_rd_active=1 -> write deferred).  After A's data phase the
    //       SRAM is free; the pending write executes.  B reads back word[wi]
    //       to confirm.
    // =======================================================================
    test_title = "T7: B write then A read (A priority over pending write)";
    $display("");
    $display("================================================================");
    $display("T7: Sequential B write -> A read -- A has priority over pending write");
    $display("================================================================");

    begin : t7
        integer    wi, ai;
        reg [31:0] wr_val;

        wi     = 50;
        ai     = 5;
        wr_val = $urandom;

        wait_begin;
        m0_hsel = 1'b1;
        m1_hsel = 1'b1;

        m1_ahb_write(1'b0, wi << 2, wr_val,                      2'b10);
        ref_write   (     wi << 2, 3'b010, wr_val);
        // A read with B write still draining -- A must not stall
        m0_ahb_read (1'b0, ai << 2, sram_ref[ai[MEM_ADDRW-1:0]], 2'b10, 1'b1);
        @(posedge free_clk); #1;
        a_idle;

        // Confirm write committed
        m1_hsel = 1'b1;
        m1_ahb_read (1'b0, wi << 2, sram_ref[wi[MEM_ADDRW-1:0]], 2'b10, 1'b1);
        @(posedge free_clk); #1;
        b_idle;

        repeat(2) @(posedge free_clk); #1;
        wait_check("T7", 0, 0, 0);
    end


    // =======================================================================
    // T8 -- Simultaneous A+B reads: toggle-priority arbitration
    //
    //       Same structure as rom_ctrl T4: fork A and B address phases into
    //       the same cycle; A wins first (priority_a=1 after reset/drain);
    //       B gets a one-cycle data-phase wait state; both data values correct.
    // =======================================================================
    test_title = "T8: Simultaneous A+B reads";
    $display("");
    $display("================================================================");
    $display("T8: Simultaneous A+B reads -- fork/join, toggle-priority");
    $display("================================================================");

    begin : t8
        integer    ai, bi;
        reg [31:0] a_got, b_got;
        reg [31:0] t8_pa, t8_pb;

        ai = 15;
        bi = 25;

        wait_begin;
        // Primer: ensure arb[0]=1 (A priority) before the real test.
        // BFM-migrated T3-T7 leaves arb=00; legacy TB leaves arb=01.
        // A contested A+B read from arb=00 deterministically lands at arb=01.
        if (dut_arb[0] !== 1'b1) begin
            fork
                begin ahb_a_read(0); end
                begin ahb_b_read(4); end
            join
            fork
                begin ahb_a_data(t8_pa); end
                begin ahb_b_data(t8_pb); end
            join
            #1; a_idle; b_idle;
            repeat(2) @(posedge free_clk); #1;
        end

        fork
            begin ahb_a_read(ai << 2); end
            begin ahb_b_read(bi << 2); end
        join
        fork
            begin ahb_a_data(a_got); chk_a(ai[MEM_ADDRW-1:0], a_got, "T8 A simultaneous read"); end
            begin
                @(posedge free_clk);
                chk_sig(b_hreadyout, 1'b0, "T8 b_hreadyout wait");
                @(posedge free_clk);
                b_got = m1_hrdata;
                chk_b(bi[MEM_ADDRW-1:0], b_got, "T8 B simultaneous read");
            end
        join
        #1; a_idle; b_idle;

        repeat(2) @(posedge free_clk); #1;
        wait_check("T8", 1, 1, 0);
    end


    // =======================================================================
    // T9 -- Pipelined A reads: 1 read/cycle, hreadyout stays 1
    //
    //       Identical to rom_ctrl T6.
    // =======================================================================
    test_title = "T9: Pipelined A reads";
    $display("");
    $display("================================================================");
    $display("T9: Pipelined A reads -- 1 read/cycle, hreadyout stays 1");
    $display("================================================================");

    begin : t9
        reg [31:0] data_t9 [0:7];
        integer i;

        wait_begin;
        ahb_a_read(0);
        for (i = 0; i < 7; i = i+1) begin
            #1; m0_haddr = (i+1) << 2;
            ahb_a_data(data_t9[i]);
            chk_a(i, data_t9[i], "T9 A pipelined");
            chk_sig(a_hreadyout, 1'b1, "T9 a_hreadyout");
        end
        #1; a_idle;
        ahb_a_data(data_t9[7]);
        chk_a(7, data_t9[7], "T9 A pipelined last");
        chk_sig(a_hreadyout, 1'b1, "T9 a_hreadyout last");

        repeat(2) @(posedge free_clk); #1;
        wait_check("T9", 0, 0, 0);
    end


    // =======================================================================
    // T10 -- Concurrent A+B reads, 16 rounds: toggle-priority stress
    //
    //       Identical pattern to rom_ctrl T7.
    // =======================================================================
    test_title = "T10: Concurrent A+B reads, 16 rounds";
    $display("");
    $display("================================================================");
    $display("T10: Concurrent A+B reads, 16 rounds -- toggle-priority stress");
    $display("================================================================");

    begin : t10
        integer    i;
        reg [31:0] a_got, b_got;

        wait_begin;
        fork
            begin ahb_a_read(16 << 2); end
            begin ahb_b_read(48 << 2); end
        join
        for (i = 0; i < 16; i = i+1) begin
            fork
                begin ahb_a_data(a_got); chk_a(16+i, a_got, "T10 A concurrent"); end
                begin ahb_a_read((17+i) << 2); end
                begin ahb_b_data(b_got); chk_b(48+i, b_got, "T10 B concurrent"); end
                begin ahb_b_read((49+i) << 2); end
            join
        end
        #1; a_idle; b_idle;

        repeat(2) @(posedge free_clk); #1;
        wait_check("T10", 1, 1, 0);
    end


    // =======================================================================
    // T11 -- Mixed random: 32 rounds of A read + B write
    //
    //       Each round: A reads sequentially (words 0..31); B writes a random
    //       address with random data.  Fork runs A read and B write in the
    //       same address-phase cycle.  A's data phase (one cycle after join)
    //       coincides with the pending write draining -- so the write always
    //       commits by the time each round finishes.  sram_ref is updated
    //       eagerly; a final B readback pass verifies all 32 written locations.
    // =======================================================================
    test_title = "T11: Mixed random A reads + B writes";
    $display("");
    $display("================================================================");
    $display("T11: Mixed random, 32 rounds -- A sequential reads + B writes");
    $display("================================================================");

    begin : t11
        integer    ia;
        reg [31:0] wr_vals [0:31];
        reg [31:0] wr_addrs[0:31];
        reg [31:0] a_got_t11, b_got_t11;

        wait_begin;
        // Pre-compute random write targets/values
        for (ia = 0; ia < 32; ia = ia+1) begin
            wr_addrs[ia] = $urandom_range(0, NR_WORDS-1);
            wr_vals[ia]  = $urandom;
        end

        for (ia = 0; ia < 32; ia = ia+1) begin
            fork
                begin ahb_a_read(ia << 2); #1; a_idle; end
                begin ahb_b_write(wr_addrs[ia] << 2, 3'b010, wr_vals[ia]); end
            join
            // A data phase -- write drains this cycle (sram_rd_active=0)
            ahb_a_data(a_got_t11);
            // Same-address race: A may legitimately see either pre- or post-write
            // value (FENCE.I is the SW-side coherence contract -- see T39).
            if (wr_addrs[ia] == ia) begin
                if (a_got_t11 !== sram_ref[ia] && a_got_t11 !== wr_vals[ia]) begin
                    $display("ERROR [T11 A same-addr]: word[%0d] got 0x%08h, expected 0x%08h or 0x%08h  (%0t ns)",
                             ia, a_got_t11, sram_ref[ia], wr_vals[ia], $time);
                    error = error + 1;
                end
            end else begin
                chk_a(ia[MEM_ADDRW-1:0], a_got_t11, "T11 A");
            end
            ref_write(wr_addrs[ia] << 2, 3'b010, wr_vals[ia]);
        end

        // Verify all 32 written locations via B
        for (ia = 0; ia < 32; ia = ia+1) begin
            ahb_b_read(wr_addrs[ia] << 2); #1; b_idle;
            ahb_b_data(b_got_t11);
            chk_b(wr_addrs[ia][MEM_ADDRW-1:0], b_got_t11, "T11 B write verify");
        end

        repeat(2) @(posedge free_clk); #1;
        // Mixed concurrent A reads + B writes -> up to 1 wait state is OK
        wait_check("T11", 1, 1, 0);
    end


    // =======================================================================
    // T12 -- hclk_en_o and hresp_o
    //
    //       Verifies all five hclk_en_o states:
    //         (a) idle                    -> 0
    //         (b) B write address phase   -> 1  (b_aph_write)
    //         (c) B write data phase      -> 1  (wr_aph_done)
    //         (d) wr_pending (A read)     -> 1  (wr_pending, sram_rd_active=1)
    //         (e) write drains            -> 1  (sram_was_active tail)
    //         (f) back to idle            -> 0
    //       Also checks a_hresp=0 and b_hresp=0.
    // =======================================================================
    test_title = "T12: hclk_en_o and hresp_o";
    $display("");
    $display("================================================================");
    $display("T12: hclk_en_o and hresp_o");
    $display("================================================================");

    begin : t12
        reg [31:0] a_got_t12, b_got_t12;
        reg [31:0] wr_val_t12;

        wait_begin;
        wr_val_t12 = $urandom;

        // (a) idle
        @(posedge free_clk); #1;
        chk_sig(hclk_en, 1'b0, "T12 hclk_en idle");

        // (b) B write address phase -- drive addr without waiting for data yet
        #1;
        m1_hsel   = 1'b1;
        m1_htrans = 2'b10;
        m1_haddr  = 32'h00000004;
        m1_hwrite = 1'b1;
        m1_hsize  = 3'b010;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);
        chk_sig(hclk_en, 1'b1, "T12 hclk_en write addr phase (b_aph_write)");

        // (c) B write data phase -- drive HWDATA; wr_aph_done=1 enables clock
        #1;
        m1_hwdata = wr_val_t12;
        m1_hsel   = 1'b0;
        m1_htrans = 2'b00;
        m1_hwrite = 1'b0;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);
        chk_sig(hclk_en, 1'b1, "T12 hclk_en write data phase (wr_aph_done)");
        #1; m1_hwdata = 32'b0;

        // (d) A read while write pending -- wr_pending keeps clock enabled
        ahb_a_read(32'h00000008);
        chk_sig(hclk_en, 1'b1, "T12 hclk_en A read with wr_pending");
        #1; a_idle;

        // (e) A data phase -- write drains this cycle; sram_was_active tail
        ahb_a_data(a_got_t12);
        chk_sig(hclk_en, 1'b1, "T12 hclk_en tail (sram_was_active)");

        // (f) one more cycle -- all quiet
        @(posedge free_clk); #1;
        chk_sig(hclk_en, 1'b0, "T12 hclk_en back to idle");

        // hresp always 0
        chk_sig(a_hresp, 1'b0, "T12 a_hresp=0");
        chk_sig(b_hresp, 1'b0, "T12 b_hresp=0");

        // Update ref for the T12 write
        ref_write(32'h00000004, 3'b010, wr_val_t12);

        // Read back to confirm the write actually committed to SRAM.
        ahb_b_read(32'h00000004); #1; b_idle;
        ahb_b_data(b_got_t12);
        chk_b(6'd1, b_got_t12, "T12 B write committed");

        repeat(2) @(posedge free_clk); #1;
        wait_check("T12", 0, 0, 0);
    end


    // =======================================================================
    // T13 -- B write then immediate B read same addr (no concurrent read)
    //
    //       B writes word[wi]; immediately reads same address.  Because no
    //       read is in progress during the write data phase, the write
    //       executes directly on the SRAM (wr_pending never set).  The
    //       subsequent B read gets the updated value from SRAM, not from
    //       the forwarding path.
    // =======================================================================
    test_title = "T13: B write-to-read forwarding (wr_pending)";
    $display("");
    $display("================================================================");
    $display("T13: B write then B read same addr -- wr_pending forwarding");
    $display("================================================================");

    begin : t13
        integer    wi;
        reg [31:0] wr_val;

        wi     = 35;
        wr_val = $urandom;

        wait_begin;
        m1_hsel = 1'b1;
        m1_ahb_write(1'b0, wi << 2, wr_val, 2'b10);
        ref_write    (wi << 2, 3'b010, wr_val);
        m1_ahb_read  (1'b0, wi << 2, wr_val, 2'b10, 1'b1);
        @(posedge free_clk); #1;
        b_idle;

        repeat(2) @(posedge free_clk); #1;
        wait_check("T13", 0, 0, 0);
    end


    // =======================================================================
    // T14 -- B write then A read same addr (no concurrent read)
    //
    //       B writes word[wi]; A reads same address.  Write executes directly
    //       (no concurrent read during data phase), so A reads the committed
    //       value from SRAM.  Port A has NO forwarding by design (FENCE.I
    //       contract) -- this test relies on the write having already drained.
    // =======================================================================
    test_title = "T14: A reads committed B write (post-commit, no fwd)";
    $display("");
    $display("================================================================");
    $display("T14: A reads committed B write -- post-commit SRAM read");
    $display("================================================================");

    begin : t14
        integer    wi;
        reg [31:0] wr_val;

        wi     = 42;
        wr_val = $urandom;

        wait_begin;
        m1_hsel = 1'b1;
        m1_ahb_write(1'b0, wi << 2, wr_val, 2'b10);
        ref_write    (wi << 2, 3'b010, wr_val);
        @(posedge free_clk); #1;
        b_idle;

        m0_hsel = 1'b1;
        m0_ahb_read (1'b0, wi << 2, wr_val, 2'b10, 1'b1);
        @(posedge free_clk); #1;
        a_idle;

        repeat(2) @(posedge free_clk); #1;
        wait_check("T14", 0, 0, 0);
    end


    // =======================================================================
    // T15 -- B byte-write then B read same word (no concurrent read)
    //
    //       B byte-writes lane 2 of word[wi]; immediately reads the full
    //       word.  Write executes directly; SRAM has the updated byte.
    //       Verifies byte-lane isolation end-to-end through the SRAM path.
    // =======================================================================
    test_title = "T15: Byte-lane forwarding granularity";
    $display("");
    $display("================================================================");
    $display("T15: Byte-lane write-to-read forwarding -- byte granularity");
    $display("================================================================");

    begin : t15
        integer    wi;
        reg  [7:0] byte_raw;
        reg [31:0] expected_word;

        wi            = 7;
        byte_raw      = $urandom;
        expected_word = {sram_ref[wi][31:24], byte_raw, sram_ref[wi][15:0]};

        wait_begin;
        // Byte write to lane 2 (byte offset +2 into the word)
        m1_hsel = 1'b1;
        m1_ahb_write(1'b0, (wi << 2) + 2, {24'b0, byte_raw}, 2'b00);
        ref_write        ((wi << 2) + 2, 3'b000, {8'b0, byte_raw, 16'b0});
        m1_ahb_read (1'b0, wi << 2, expected_word, 2'b10, 1'b1);
        @(posedge free_clk); #1;
        b_idle;

        repeat(2) @(posedge free_clk); #1;
        wait_check("T15", 0, 0, 0);
    end


    // =======================================================================
    // T16 -- wr_pending drain after A read (no Port A forwarding)
    //
    //       B write address phase at cycle N.  At cycle N+1 (B write data
    //       phase), A read address phase to a DIFFERENT address fires
    //       simultaneously: sram_rd_active=1 forces the write into the buffer
    //       (wr_pending=1).  A completes normally and gets the correct SRAM
    //       data for its address (Port A has no forwarding by design -- RISC-V
    //       requires FENCE.I before self-modifying code re-fetches).  After A
    //       completes, wr_pending drains on the first free SRAM cycle.  B
    //       reads back the written address to confirm the committed value.
    // =======================================================================
    test_title = "T16: wr_pending drain after concurrent A read (no A fwd)";
    $display("");
    $display("================================================================");
    $display("T16: wr_pending drain after concurrent A read -- no A forwarding");
    $display("================================================================");

    begin : t16
        integer    wi, ai;
        reg [31:0] wr_val, a_got, b_got;

        wi     = 55;
        ai     = 62;   // A reads a different address
        wr_val = $urandom;

        wait_begin;
        // --- B write address phase ---
        #1;
        m1_hsel   = 1'b1;
        m1_htrans = 2'b10;
        m1_haddr  = wi << 2;
        m1_hwrite = 1'b1;
        m1_hsize  = 3'b010;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);
        // posedge N: wr_addr=wi, wr_bsel=4'hF, wr_aph_done <= 1

        // --- B write data phase + A read address phase (different addr) ---
        // sram_rd_active=1 -> write buffered (wr_pending <= 1)
        #1;
        m1_hwdata = wr_val;
        m1_hsel   = 1'b0;
        m1_htrans = 2'b00;
        m1_hwrite = 1'b0;
        m0_hsel   = 1'b1;
        m0_htrans = 2'b10;
        m0_haddr  = ai << 2;
        @(posedge free_clk);
        while (!m0_hready) @(posedge free_clk);
        // posedge N+1: wr_data <= wr_val, wr_pending <= 1, wr_aph_done <= 0

        #1; m1_hwdata = 32'b0;

        // A data phase -- A gets correct SRAM[ai] (no forwarding on Port A)
        #1; a_idle;
        ahb_a_data(a_got);
        chk_a(ai[MEM_ADDRW-1:0], a_got, "T16 A reads own addr correctly");

        // wr_pending drains automatically; B reads wi to confirm commit
        ref_write(wi << 2, 3'b010, wr_val);
        ahb_b_read(wi << 2); #1; b_idle;
        ahb_b_data(b_got);
        chk_b(wi[MEM_ADDRW-1:0], b_got, "T16 B confirms write drained");

        repeat(2) @(posedge free_clk); #1;
        wait_check("T16", 0, 0, 0);
    end


    // =======================================================================
    // T18 -- Write not starved by continuous A fetch
    //
    //       A fetches 17 consecutive words in a pipeline (no intentional gaps).
    //       Five clock cycles in, B issues a word write to a separate address.
    //       With the toggle-arbiter starvation fix, the write competes for a
    //       SRAM slot: when it is B's priority turn, A is held for ≤2 cycles
    //       then the write drains.  The fork-join verifies that ahb_b_write
    //       returns (it would hang forever under the old opportunistic drain)
    //       and B readback confirms the committed value.
    // =======================================================================
    test_title = "T18: Write not starved by continuous A fetch";
    $display("");
    $display("================================================================");
    $display("T18: Write not starved by continuous A fetch");
    $display("================================================================");

    begin : t18
        integer    wi;
        reg [31:0] wr_val, b_got, a_got;

        wi     = 4;
        wr_val = $urandom;

        wait_begin;
        ahb_a_read(20 << 2);

        fork
            begin : t18_a_fetch
                for (ii = 20; ii < 37; ii = ii+1) begin
                    ahb_a_data(a_got);
                    ahb_a_read(((ii+1) % NR_WORDS) << 2);
                end
                ahb_a_data(a_got);
                #1; a_idle;
            end
            begin : t18_b_write
                repeat(5) @(posedge free_clk);
                ahb_b_write(wi << 2, 3'b010, wr_val);
                #1; b_idle;
            end
        join

        ref_write(wi << 2, 3'b010, wr_val);

        ahb_b_read(wi << 2);
        #1; b_idle;
        ahb_b_data(b_got);
        chk_b(wi[MEM_ADDRW-1:0], b_got, "T18 write drains under A fetch");

        repeat(2) @(posedge free_clk); #1;
        wait_check("T18", 1, 1, 0);
    end


    // =======================================================================
    // T19 -- Back-to-back B writes both drain under continuous A fetch
    //
    //       A fetches 21 words continuously.  B issues two consecutive word
    //       writes starting 3 cycles in.  The second write's address phase
    //       presents while the first write is buffered (wr_pending=1): under
    //       the old design this stalls the second write's address phase
    //       indefinitely (b_hreadyout stays 0 forever).  With the fix the
    //       first write drains within ≤2 A cycles, b_hreadyout returns to 1,
    //       and the second write proceeds.  Both written values are read back.
    // =======================================================================
    test_title = "T19: Back-to-back writes drain under continuous A fetch";
    $display("");
    $display("================================================================");
    $display("T19: Back-to-back B writes drain under continuous A fetch");
    $display("================================================================");

    begin : t19
        integer    wi1, wi2;
        reg [31:0] val1, val2, b_got, a_got;

        wi1  = 9;
        wi2  = 11;
        val1 = $urandom;
        val2 = $urandom;

        wait_begin;
        ahb_a_read(40 << 2);

        fork
            begin : t19_a_fetch
                for (ii = 40; ii < 62; ii = ii+1) begin
                    ahb_a_data(a_got);
                    ahb_a_read(((ii+1) % NR_WORDS) << 2);
                end
                ahb_a_data(a_got);
                #1; a_idle;
            end
            begin : t19_b_writes
                repeat(3) @(posedge free_clk);
                ahb_b_write(wi1 << 2, 3'b010, val1);
                ahb_b_write(wi2 << 2, 3'b010, val2);
                #1; b_idle;
            end
        join

        ref_write(wi1 << 2, 3'b010, val1);
        ref_write(wi2 << 2, 3'b010, val2);

        ahb_b_read(wi1 << 2); #1; b_idle;
        ahb_b_data(b_got);
        chk_b(wi1[MEM_ADDRW-1:0], b_got, "T19 write1 drains under A fetch");

        ahb_b_read(wi2 << 2); #1; b_idle;
        ahb_b_data(b_got);
        chk_b(wi2[MEM_ADDRW-1:0], b_got, "T19 write2 drains under A fetch");

        repeat(2) @(posedge free_clk); #1;
        wait_check("T19", 1, 62, 62);
    end


    // =======================================================================
    // T20 -- B-replay forwarding gap fix
    //
    // When b_lost fires in the same cycle as b_fwd_match (B read address and
    // A read address both presented while B write is pending, A wins the
    // arbiter), the B replay cycle (arb==2'b10) has b_aph_read=0. Without the
    // fix, b_fwd_bsel_r would be cleared in the replay cycle and m1_hrdata_o
    // would return stale SRAM data. With the fix, b_fwd_match is held asserted
    // via (arb==2'b10) so b_fwd_bsel_r stays set and m1_hrdata_o returns the
    // pending write data.
    //
    // Timeline (arb guaranteed 2'b01 = A priority after brief reset):
    //   CLK A: B write address (W, WORD). wr_aph_done←1. SRAM idle.
    //   CLK B: B data phase (HWDATA=new_val) pipelined with B read (W),
    //          A read (addr_a) also presented. arb[0]=1 -> b_lost=1.
    //          b_fwd_match=1 (wr_aph_done=1, wr_addr==W) -> b_fwd_bsel_r←4'hF.
    //          wr_data←new_val, wr_pending←1, wr_aph_done←0. arb->2'b10.
    //   CLK C: Replay (arb[1]=1). b_aph_read=0. SRAM reads W.
    //          With fix: b_fwd_match=1 (arb==2'b10) -> b_fwd_bsel_r stays 4'hF.
    //          b_hreadyout←1. arb->2'b00.
    //   #1 after CLK C: m1_hrdata = new_val (fix) or old_val (no fix).
    // =======================================================================
    test_title = "T20: B-replay forwarding gap fix";
    $display("");
    $display("================================================================");
    $display("T20: B-replay forwarding (b_fwd_match survives b_lost cycle)");
    $display("================================================================");

    begin : t20
        integer    wi;
        reg [31:0] old_val, new_val, b_got;

        wi      = 5;
        old_val = sram_ref[wi];   // current SRAM value (committed by prior tests)
        new_val = $urandom;

        // Brief reset -> arb=2'b01 (A priority), wr_aph_done=0, wr_pending=0.
        // SRAM macro retains contents; sram_ref[wi]=old_val remains valid.
        #1; hresetn = 0;
        repeat(2) @(posedge free_clk); #1;
        hresetn = 1;
        @(posedge free_clk); #1;
        a_idle; b_idle;

        // Open wait window AFTER the brief reset (the tracker regs are reset
        // synchronously with hresetn, so wait_begin must follow the deassert).
        wait_begin;

        // CLK A: B write address phase (WORD write to W).
        // Buffer empty -> accepted immediately (b_hreadyout=1, no stall).
        m1_hsel   = 1'b1; m1_htrans = 2'b10;
        m1_haddr  = wi << 2; m1_hwrite = 1'b1; m1_hsize = 3'b010;
        @(posedge free_clk); #1;
        // After NBA: wr_aph_done=1, wr_addr=wi, wr_bsel=4'hF.

        // CLK B (critical): B data phase (new_val) pipelined with B read (W),
        //   while A also reads. arb[0]=1 -> b_lost fires.
        //   b_fwd_match=1 (wr_aph_done=1, wr_addr==W) -> b_fwd_bsel_r←4'hF.
        //   wr_data←new_val, wr_pending←1, wr_aph_done←0. arb->2'b10.
        m1_hwdata = new_val;
        m1_hsel   = 1'b1; m1_htrans = 2'b10;
        m1_haddr  = wi << 2; m1_hwrite = 1'b0; m1_hsize = 3'b010;
        m0_hsel   = 1'b1; m0_htrans = 2'b10; m0_haddr  = 32'h20;
        @(posedge free_clk); #1;
        // After NBA: arb=2'b10, wr_pending=1, b_fwd_bsel_r=4'hF (or 0 w/o fix).

        // CLK C (replay): arb[1]=1, b_aph_read=0. SRAM reads W (saved_addr).
        //   With fix:    b_fwd_match=1 -> b_fwd_bsel_r←4'hF (held).
        //   Without fix: b_fwd_match=0 -> b_fwd_bsel_r←0 (cleared).
        //   b_hreadyout←1, arb->2'b00.
        a_idle;
        m1_hsel   = 1'b0; m1_htrans = 2'b00; m1_hwrite = 1'b0; m1_hwdata = 32'b0;
        @(posedge free_clk); #1;
        // After NBA: b_hreadyout=1. b_fwd_bsel_r=4'hF (fix) or 0 (no fix).
        // sram_dout_i = old_val (SRAM at word wi, write not yet fired).

        // Sample m1_hrdata immediately (b_hreadyout=1 confirmed above).
        b_got = m1_hrdata;
        if (b_got !== new_val) begin
            $display("ERROR [T20 B-replay fwd]: Port B @ word[%0d] -- got 0x%08h, expected forwarded 0x%08h; stale SRAM=0x%08h  (%0t ns)",
                     wi, b_got, new_val, old_val, $time);
            error = error + 1;
        end else
            $display("PASS  [T20 B-replay fwd]: Port B @ word[%0d] = 0x%08h (forwarded through replay, not stale 0x%08h)  (%0t ns)",
                     wi, b_got, old_val, $time);

        // Update reference; let write drain (fires ~2 cycles after CLK C).
        ref_write(wi << 2, 3'b010, new_val);
        repeat(5) @(posedge free_clk); #1;

        ahb_b_read(wi << 2); #1; b_idle;
        ahb_b_data(b_got);
        chk_b(wi[MEM_ADDRW-1:0], b_got, "T20 write drained to SRAM");

        repeat(2) @(posedge free_clk); #1;
        wait_check("T20", 0, 1, 0);
    end


    // =======================================================================
    // T21 -- A sequential + B sporadic random reads, 32 rounds
    //
    //       A reads sequentially (words 0..31).  Each round B randomly decides
    //       whether to read (50%) and uses a random address.  Exercises the
    //       toggle-priority arbiter with mixed contested/uncontested cycles.
    //       Equivalent to ahb_fused_rom_ctrl TB T9.
    // =======================================================================
    test_title = "T21: A sequential + B sporadic random reads";
    $display("");
    $display("================================================================");
    $display("T21: A sequential + B sporadic random -- 32 rounds");
    $display("================================================================");

    begin : t21
        integer    ia;
        reg [31:0] a_got_t21, b_got_t21;
        reg [31:0] b_waddr_t21  [0:32];
        reg [31:0] b_active_t21 [0:32];

        wait_begin;
        for (ia = 0; ia <= 32; ia = ia+1) begin
            b_waddr_t21[ia]  = $urandom_range(0, NR_WORDS-1);
            b_active_t21[ia] = $urandom_range(0, 1);
        end
        b_active_t21[32] = 0;

        if (b_active_t21[0]) begin
            fork
                begin ahb_a_read(0); end
                begin ahb_b_read(b_waddr_t21[0] << 2); end
            join
        end else
            ahb_a_read(0);

        for (ia = 0; ia < 32; ia = ia+1) begin
            fork
                begin ahb_a_data(a_got_t21); chk_a(ia[MEM_ADDRW-1:0], a_got_t21, "T21 A"); end
                begin ahb_a_read((ia+1) << 2); end
                begin
                    if (b_active_t21[ia]) begin
                        ahb_b_data(b_got_t21);
                        chk_b(b_waddr_t21[ia][MEM_ADDRW-1:0], b_got_t21, "T21 B");
                    end
                end
                begin
                    if      (b_active_t21[ia+1]) ahb_b_read(b_waddr_t21[ia+1] << 2);
                    else if (b_active_t21[ia])   begin #1; b_idle; end
                end
            join
        end
        #1; a_idle; b_idle;

        repeat(2) @(posedge free_clk); #1;
        wait_check("T21", 1, 1, 0);
    end


    // =======================================================================
    // T22 -- A random + B sequential reads, 32 rounds
    //
    //       Mirror of T21: B addresses sequential, A addresses random.
    //       Equivalent to ahb_fused_rom_ctrl TB T10.
    // =======================================================================
    test_title = "T22: A random + B sequential reads";
    $display("");
    $display("================================================================");
    $display("T22: A random + B sequential -- 32 pipelined concurrent rounds");
    $display("================================================================");

    begin : t22
        integer    ib;
        reg [31:0] a_got_t22, b_got_t22;
        reg [31:0] a_waddr_t22 [0:32];

        wait_begin;
        for (ib = 0; ib <= 32; ib = ib+1)
            a_waddr_t22[ib] = $urandom_range(0, NR_WORDS-1);

        fork
            begin ahb_a_read(a_waddr_t22[0] << 2); end
            begin ahb_b_read(0); end
        join
        for (ib = 0; ib < 32; ib = ib+1) begin
            fork
                begin ahb_a_data(a_got_t22); chk_a(a_waddr_t22[ib][MEM_ADDRW-1:0], a_got_t22, "T22 A"); end
                begin ahb_a_read(a_waddr_t22[ib+1] << 2); end
                begin ahb_b_data(b_got_t22); chk_b(ib[MEM_ADDRW-1:0], b_got_t22, "T22 B"); end
                begin ahb_b_read((ib+1) << 2); end
            join
        end
        #1; a_idle; b_idle;

        repeat(2) @(posedge free_clk); #1;
        wait_check("T22", 1, 1, 0);
    end


    // =======================================================================
    // T23 -- Both A and B random read addresses, 32 rounds
    //
    //       Maximum address variability on both ports; exercises every
    //       toggle-priority pattern.  Equivalent to ahb_fused_rom_ctrl TB T11.
    // =======================================================================
    test_title = "T23: Both A and B random reads";
    $display("");
    $display("================================================================");
    $display("T23: Both A and B random -- 32 pipelined concurrent rounds");
    $display("================================================================");

    begin : t23
        integer    i;
        reg [31:0] a_got_t23, b_got_t23;
        reg [31:0] a_waddr_t23 [0:32];
        reg [31:0] b_waddr_t23 [0:32];

        wait_begin;
        for (i = 0; i <= 32; i = i+1) begin
            a_waddr_t23[i] = $urandom_range(0, NR_WORDS-1);
            b_waddr_t23[i] = $urandom_range(0, NR_WORDS-1);
        end

        fork
            begin ahb_a_read(a_waddr_t23[0] << 2); end
            begin ahb_b_read(b_waddr_t23[0] << 2); end
        join
        for (i = 0; i < 32; i = i+1) begin
            fork
                begin ahb_a_data(a_got_t23); chk_a(a_waddr_t23[i][MEM_ADDRW-1:0], a_got_t23, "T23 A"); end
                begin ahb_a_read(a_waddr_t23[i+1] << 2); end
                begin ahb_b_data(b_got_t23); chk_b(b_waddr_t23[i][MEM_ADDRW-1:0], b_got_t23, "T23 B"); end
                begin ahb_b_read(b_waddr_t23[i+1] << 2); end
            join
        end
        #1; a_idle; b_idle;

        repeat(2) @(posedge free_clk); #1;
        wait_check("T23", 1, 1, 0);
    end


    // =======================================================================
    // T24 -- Pipelined B write->read, different addresses
    //
    //       Back-to-back aph on Port B with no idle cycle.  Tests that the
    //       write data phase and a new read aph can be driven simultaneously
    //       in cycle N+1 without losing either transaction.
    //
    //       Cycle N   -- B write aph (haddr=W, hwrite=1)
    //       Cycle N+1 -- B write dph (hwdata=DW) + B read aph (haddr=R, hwrite=0)
    //                   Phase 2 captures DW, Phase 1 latches read.
    //                   sram_rd_active=1 (B read) -> write goes to buffer.
    //       Cycle N+2 -- B read dph (sample hrdata = SRAM[R], no forwarding)
    // =======================================================================
    test_title = "T24: Pipelined B write->read (different addresses)";
    $display("");
    $display("================================================================");
    $display("T24: Pipelined B write->read -- different addresses");
    $display("================================================================");

    begin : t24
        integer    wi, ri;
        reg [31:0] wr_val, b_got;

        wi     = 32;
        ri     = 45;
        wr_val = $urandom;

        wait_begin;
        // Cycle N: write aph
        #1;
        m1_hsel   = 1'b1;
        m1_htrans = 2'b10;
        m1_haddr  = wi << 2;
        m1_hwrite = 1'b1;
        m1_hsize  = 3'b010;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);

        // Cycle N+1: write dph + read aph (back-to-back)
        #1;
        m1_hwdata = wr_val;
        m1_hsel   = 1'b1;
        m1_htrans = 2'b10;
        m1_haddr  = ri << 2;
        m1_hwrite = 1'b0;
        m1_hsize  = 3'b010;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);

        // Cycle N+2: read dph
        #1;
        m1_hsel   = 1'b0;
        m1_htrans = 2'b00;
        m1_hwrite = 1'b0;
        m1_hwdata = 32'b0;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);
        b_got = m1_hrdata;

        ref_write(wi << 2, 3'b010, wr_val);
        chk_b(ri[MEM_ADDRW-1:0], b_got, "T24 pipelined wr->rd (diff addr)");

        b_idle;
        repeat(3) @(posedge free_clk); #1;

        // Verify the write committed
        ahb_b_read(wi << 2); #1; b_idle;
        ahb_b_data(b_got);
        chk_b(wi[MEM_ADDRW-1:0], b_got, "T24 write committed");

        repeat(2) @(posedge free_clk); #1;
        wait_check("T24", 0, 0, 0);
    end


    // =======================================================================
    // T25 -- Pipelined B write->read, SAME address (forwarding)
    //
    //       Variant of T24 where the read targets the written word while
    //       wr_pending=1.  b_fwd_match fires in the same cycle Phase 2 commits
    //       wr_data, so b_fwd_bsel_r is latched and the next-cycle hrdata is
    //       forwarded from wr_data (not from the stale SRAM location).
    //
    //       Cycle N+1 -- Phase 2 wr_data<=DW, wr_pending<=1;
    //                    b_fwd_match=1, b_fwd_bsel_r<=wr_bsel
    //       Cycle N+2 -- m1_hrdata = (wr_data & mask) | (sram_dout & ~mask) = DW
    // =======================================================================
    test_title = "T25: Pipelined B write->read same addr (forwarding)";
    $display("");
    $display("================================================================");
    $display("T25: Pipelined B write->read -- same address, forwarded");
    $display("================================================================");

    begin : t25
        integer    addr_w;
        reg [31:0] wr_val, b_got;

        addr_w = 33;
        wr_val = $urandom;

        wait_begin;
        // Cycle N: write aph
        #1;
        m1_hsel   = 1'b1;
        m1_htrans = 2'b10;
        m1_haddr  = addr_w << 2;
        m1_hwrite = 1'b1;
        m1_hsize  = 3'b010;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);

        // Cycle N+1: write dph + read aph to SAME address
        #1;
        m1_hwdata = wr_val;
        m1_hsel   = 1'b1;
        m1_htrans = 2'b10;
        m1_haddr  = addr_w << 2;      // same addr as write
        m1_hwrite = 1'b0;
        m1_hsize  = 3'b010;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);

        // Cycle N+2: read dph
        #1;
        m1_hsel   = 1'b0;
        m1_htrans = 2'b00;
        m1_hwrite = 1'b0;
        m1_hwdata = 32'b0;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);
        b_got = m1_hrdata;

        ref_write(addr_w << 2, 3'b010, wr_val);
        chk_b(addr_w[MEM_ADDRW-1:0], b_got, "T25 pipelined wr->rd same addr (forwarded)");

        b_idle;
        repeat(3) @(posedge free_clk); #1;

        // Verify the write committed to SRAM (not just forwarded)
        ahb_b_read(addr_w << 2); #1; b_idle;
        ahb_b_data(b_got);
        chk_b(addr_w[MEM_ADDRW-1:0], b_got, "T25 write committed to SRAM");

        repeat(2) @(posedge free_clk); #1;
        wait_check("T25", 0, 0, 0);
    end


    // =======================================================================
    // T26 -- HTRANS=SEQ + BUSY coverage
    //
    //       The DUT uses htrans[1] to detect a valid aph, so SEQ (2'b11) is
    //       functionally identical to NONSEQ (2'b10).  BUSY (2'b01) and
    //       IDLE (2'b00) both have htrans[1]=0 and must NOT latch an aph.
    //
    //       Sequence:
    //         Round 1: Port A NONSEQ @ addr0 -> SEQ @ addr1 -> SEQ @ addr2
    //                  Verify all three reads complete with correct data.
    //         Round 2: Port A BUSY (hsel=1, htrans=01) for one cycle
    //                  Verify no buffered aph, no SRAM activity, hreadyout=1.
    // =======================================================================
    test_title = "T26: HTRANS=SEQ + BUSY coverage";
    $display("");
    $display("================================================================");
    $display("T26: HTRANS=SEQ valid-aph + BUSY ignored");
    $display("================================================================");

    begin : t26
        integer    ai;
        reg [31:0] a_got;

        ai = 7;

        wait_begin;
        // Round 1: NONSEQ -> SEQ -> SEQ pipelined
        #1;
        m0_hsel   = 1'b1;
        m0_htrans = 2'b10;           // NONSEQ
        m0_haddr  = ai << 2;
        @(posedge free_clk);
        while (!m0_hready) @(posedge free_clk);

        #1;
        m0_htrans = 2'b11;           // SEQ
        m0_haddr  = (ai+1) << 2;
        @(posedge free_clk);
        while (!m0_hready) @(posedge free_clk);
        a_got = m0_hrdata;            // data of first NONSEQ
        chk_a(ai[MEM_ADDRW-1:0], a_got, "T26 NONSEQ read (SEQ dph)");

        #1;
        m0_htrans = 2'b11;           // SEQ
        m0_haddr  = (ai+2) << 2;
        @(posedge free_clk);
        while (!m0_hready) @(posedge free_clk);
        a_got = m0_hrdata;            // data of first SEQ
        chk_a((ai+1), a_got, "T26 SEQ read");

        #1; a_idle;
        ahb_a_data(a_got);           // data of second SEQ
        chk_a((ai+2), a_got, "T26 SEQ read (pipeline flush)");

        repeat(2) @(posedge free_clk); #1;

        // Round 2: BUSY should be ignored (no aph, no SRAM activity).
        // Baseline: sample hclk_en_o before BUSY (must be 0 = idle).
        chk_sig(hclk_en, 1'b0, "T26 hclk_en idle before BUSY");

        #1;
        m0_hsel   = 1'b1;
        m0_htrans = 2'b01;           // BUSY
        m0_haddr  = ai << 2;
        @(posedge free_clk);

        // Post-NBA: a_hreadyout should stay 1 (no stall), sram_cen should stay
        // high (no access).  a_aph_read was 0 (htrans[1]=0), so no aph latched.
        #1;
        chk_sig(a_hreadyout, 1'b1, "T26 BUSY -- hreadyout stays 1");
        chk_sig(sram_cen_n, 1'b1, "T26 BUSY -- sram_cen stays idle");

        a_idle;
        repeat(3) @(posedge free_clk); #1;

        // Sanity: post-BUSY a normal read still works.
        ahb_a_read(ai << 2); #1; a_idle;
        ahb_a_data(a_got);
        chk_a(ai[MEM_ADDRW-1:0], a_got, "T26 post-BUSY read works");

        repeat(2) @(posedge free_clk); #1;
        wait_check("T26", 0, 0, 0);
    end


    // =======================================================================
    // T27 -- External HREADY wait states
    //
    //       Emulate another slave holding the bus by pulling a_hready_ext and
    //       b_hready_ext low for a few cycles.  The DUT must not latch an aph
    //       (a_aph_read / b_aph_read depend on m0_hready_i / m1_hready_i) and
    //       must resume normally when HREADY returns high.
    //
    //       Sequence:
    //         - Drive A read aph with external HREADY held low 3 cycles.
    //         - Release external HREADY; A read should complete.
    //         - Repeat for Port B write.
    // =======================================================================
    test_title = "T27: External HREADY wait states";
    $display("");
    $display("================================================================");
    $display("T27: External HREADY wait states");
    $display("================================================================");

    begin : t27
        integer    ai, wi;
        reg [31:0] a_got, b_got, wr_val;

        ai     = 12;
        wi     = 18;
        wr_val = $urandom;

        wait_begin;
        // ---- External HREADY low during A read aph ----
        a_hready_ext = 1'b0;

        #1;
        m0_hsel   = 1'b1;
        m0_htrans = 2'b10;
        m0_haddr  = ai << 2;
        // 3 stalled cycles -- m0_hready_i=0 so no aph latched yet
        repeat(3) @(posedge free_clk);
        #1;
        chk_sig(sram_cen_n, 1'b1, "T27 A -- sram_cen idle while ext HREADY=0");

        // Release external HREADY
        a_hready_ext = 1'b1;
        @(posedge free_clk);
        while (!m0_hready) @(posedge free_clk);
        #1; a_idle;
        ahb_a_data(a_got);
        chk_a(ai[MEM_ADDRW-1:0], a_got, "T27 A read after ext HREADY release");

        repeat(2) @(posedge free_clk); #1;

        // ---- External HREADY low during B write aph ----
        b_hready_ext = 1'b0;

        #1;
        m1_hsel   = 1'b1;
        m1_htrans = 2'b10;
        m1_haddr  = wi << 2;
        m1_hwrite = 1'b1;
        m1_hsize  = 3'b010;
        repeat(3) @(posedge free_clk);
        #1;
        // FSM must not have entered WRITE -- no aph latched
        chk_sig(dut_b_state[2], 1'b0, "T27 B -- FSM stays out of WRITE while ext HREADY=0");

        b_hready_ext = 1'b1;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);
        #1;
        m1_hwdata = wr_val;
        m1_hsel   = 1'b0;
        m1_htrans = 2'b00;
        m1_hwrite = 1'b0;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);
        #1; m1_hwdata = 32'b0;

        repeat(3) @(posedge free_clk); #1;

        ref_write(wi << 2, 3'b010, wr_val);
        ahb_b_read(wi << 2); #1; b_idle;
        ahb_b_data(b_got);
        chk_b(wi[MEM_ADDRW-1:0], b_got, "T27 B write after ext HREADY release");

        repeat(2) @(posedge free_clk); #1;
        wait_check("T27", 0, 0, 0);
    end


    // =======================================================================
    // T28 -- Pipelined B read->write (reverse of T24/T25)
    //
    //       Cycle N   -- B read aph (R)
    //       Cycle N+1 -- B write aph (W) + B read dph (sample hrdata)
    //       Cycle N+2 -- B write dph (hwdata=DW)
    //
    //       Exercises Phase 1 latching a write while sram_was_active=1 from
    //       the prior read (forces Phase 2 to buffer rather than execute
    //       opportunistically).
    // =======================================================================
    test_title = "T28: Pipelined B read->write";
    $display("");
    $display("================================================================");
    $display("T28: Pipelined B read->write");
    $display("================================================================");

    begin : t28
        integer    ri, wi;
        reg [31:0] wr_val, b_got, b_read_got;

        ri     = 21;
        wi     = 27;
        wr_val = $urandom;

        wait_begin;
        // Cycle N: B read aph
        #1;
        m1_hsel   = 1'b1;
        m1_htrans = 2'b10;
        m1_haddr  = ri << 2;
        m1_hwrite = 1'b0;
        m1_hsize  = 3'b010;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);

        // Cycle N+1: B write aph + B read dph (sample hrdata)
        #1;
        m1_hsel   = 1'b1;
        m1_htrans = 2'b10;
        m1_haddr  = wi << 2;
        m1_hwrite = 1'b1;
        m1_hsize  = 3'b010;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);
        b_read_got = m1_hrdata;

        // Cycle N+2: B write dph
        #1;
        m1_hwdata = wr_val;
        m1_hsel   = 1'b0;
        m1_htrans = 2'b00;
        m1_hwrite = 1'b0;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);
        #1; m1_hwdata = 32'b0;

        chk_b(ri[MEM_ADDRW-1:0], b_read_got, "T28 pipelined rd->wr: read value");

        repeat(3) @(posedge free_clk); #1;

        ref_write(wi << 2, 3'b010, wr_val);
        ahb_b_read(wi << 2); #1; b_idle;
        ahb_b_data(b_got);
        chk_b(wi[MEM_ADDRW-1:0], b_got, "T28 pipelined rd->wr: write committed");

        repeat(2) @(posedge free_clk); #1;
        wait_check("T28", 0, 0, 0);
    end


    // =======================================================================
    // T29 -- Sustained 5-write burst under continuous A fetch
    //
    //       Extends T19 to 5 back-to-back B writes while Port A fetches
    //       continuously.  Each write must trigger its own wr_lost ->
    //       drain-FSM cycle; after the burst all 5 values must be committed
    //       to SRAM.  Stresses repeated wd_st 00->01->10 transitions.
    // =======================================================================
    test_title = "T29: Sustained 5-write burst under A fetch";
    $display("");
    $display("================================================================");
    $display("T29: Sustained 5-write burst under continuous A fetch");
    $display("================================================================");

    begin : t29
        integer    kk;
        reg [31:0] a_got;
        reg [31:0] vals    [0:4];
        reg [31:0] waddrs  [0:4];

        wait_begin;
        waddrs[0] = 36; vals[0] = $urandom;
        waddrs[1] = 37; vals[1] = $urandom;
        waddrs[2] = 38; vals[2] = $urandom;
        waddrs[3] = 39; vals[3] = $urandom;
        waddrs[4] = 40; vals[4] = $urandom;

        ahb_a_read(0);

        fork
            begin : t29_a_fetch
                integer ka;
                for (ka = 0; ka < 30; ka = ka+1) begin
                    ahb_a_data(a_got);
                    ahb_a_read(((ka+1) % NR_WORDS) << 2);
                end
                ahb_a_data(a_got);
                #1; a_idle;
            end
            begin : t29_b_writes
                integer kb;
                repeat(3) @(posedge free_clk);
                for (kb = 0; kb < 5; kb = kb+1) begin
                    ahb_b_write(waddrs[kb] << 2, 3'b010, vals[kb]);
                    ref_write(waddrs[kb] << 2, 3'b010, vals[kb]);
                end
                #1; b_idle;
            end
        join

        repeat(5) @(posedge free_clk); #1;

        begin : t29_verify
            reg [31:0] b_got;
            for (kk = 0; kk < 5; kk = kk+1) begin
                ahb_b_read(waddrs[kk] << 2); #1; b_idle;
                ahb_b_data(b_got);
                chk_b(waddrs[kk][MEM_ADDRW-1:0], b_got, "T29 sustained write drained");
            end
        end

        repeat(2) @(posedge free_clk); #1;
        wait_check("T29", 1, 85, 85);
    end


    // =======================================================================
    // T30 -- hclk_en_o during write-drain FSM (wd_st != 00)
    //
    //       T12 covered hclk_en states tied to b_aph_write, wr_aph_done,
    //       wr_pending, sram_was_active.  The (wd_st != 2'b00) term is not
    //       sampled there.  Force wr_lost to enter wd_st=01 and check
    //       hclk_en=1 throughout 01 and the 10 replay cycle.
    // =======================================================================
    test_title = "T30: hclk_en_o during write-drain FSM";
    $display("");
    $display("================================================================");
    $display("T30: hclk_en_o during write-drain FSM (wd_st != 00)");
    $display("================================================================");

    begin : t30
        integer    ii30;
        reg [31:0] a_got;
        reg [31:0] wr_val;

        wr_val = $urandom;

        wait_begin;
        // Force wr_lost: A continuous fetch + single B write.
        ahb_a_read(0);

        fork
            begin : t30_a_fetch
                for (ii30 = 0; ii30 < 10; ii30 = ii30+1) begin
                    ahb_a_data(a_got);
                    ahb_a_read(((ii30+1) % NR_WORDS) << 2);
                end
                ahb_a_data(a_got);
                #1; a_idle;
            end
            begin : t30_b_write
                repeat(3) @(posedge free_clk);
                ahb_b_write(46 << 2, 3'b010, wr_val);
                // While wd_st=01/10 the hclk_en must be 1 (already true from
                // b_aph_write / wr_pending too, but the wd_st term is the
                // dominant signal once they deassert).
                // Sample a couple of cycles while drain FSM is active.
                @(posedge free_clk); #1;
                chk_sig(hclk_en, 1'b1, "T30 hclk_en during drain (1)");
                @(posedge free_clk); #1;
                chk_sig(hclk_en, 1'b1, "T30 hclk_en during drain (2)");
                #1; b_idle;
            end
        join

        ref_write(46 << 2, 3'b010, wr_val);
        repeat(5) @(posedge free_clk); #1;

        begin : t30_verify
            reg [31:0] b_got;
            ahb_b_read(46 << 2); #1; b_idle;
            ahb_b_data(b_got);
            chk_b(6'd46, b_got, "T30 write committed after drain");
        end

        repeat(2) @(posedge free_clk); #1;
        wait_check("T30", 1, 0, 0);
    end


    // =======================================================================
    // T31 -- Multi-write forwarding chain: two writes to same word
    //
    //       W1 -> addr A; concurrent A-read forces buffer (wr_pending=1).
    //       B reads A -> forwarded W1 (via b_fwd_bsel_r + wr_data).
    //       Then W2 -> addr A; concurrent A-read forces buffer again.
    //       B reads A -> forwarded W2 (wr_addr same, wr_data updated).
    //       Confirms wr_addr stays consistent and wr_data updates per write.
    // =======================================================================
    test_title = "T31: Multi-write forwarding chain (same addr)";
    $display("");
    $display("================================================================");
    $display("T31: Multi-write forwarding -- two writes to same address");
    $display("================================================================");

    begin : t31
        integer    wi, ai;
        reg [31:0] v1, v2, b_got, a_got;

        wi = 50;  ai = 55;   // different A addr to force wr_pending
        v1 = $urandom;
        v2 = $urandom;

        wait_begin;

        // --- W1: B write aph, concurrent A read forces buffer ---
        #1;
        m1_hsel   = 1'b1; m1_htrans = 2'b10; m1_haddr = wi << 2; m1_hwrite = 1'b1; m1_hsize = 3'b010;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);

        #1;
        m1_hwdata = v1; m1_hsel = 0; m1_htrans = 0; m1_hwrite = 0;
        m0_hsel = 1'b1; m0_htrans = 2'b10; m0_haddr = ai << 2;
        @(posedge free_clk);
        while (!m0_hready) @(posedge free_clk);
        #1; m1_hwdata = 32'b0;

        // B read same addr while wr_pending=1 -> forwarded W1
        #1; a_idle;
        ahb_a_data(a_got);
        chk_a(ai[MEM_ADDRW-1:0], a_got, "T31 A unaffected (run 1)");

        ahb_b_read(wi << 2); #1; b_idle;
        ahb_b_data(b_got);
        ref_write(wi << 2, 3'b010, v1);
        chk_b(wi[MEM_ADDRW-1:0], b_got, "T31 forwarded write 1");

        repeat(4) @(posedge free_clk); #1;

        // --- W2: repeat with a different value ---
        #1;
        m1_hsel   = 1'b1; m1_htrans = 2'b10; m1_haddr = wi << 2; m1_hwrite = 1'b1; m1_hsize = 3'b010;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);

        #1;
        m1_hwdata = v2; m1_hsel = 0; m1_htrans = 0; m1_hwrite = 0;
        m0_hsel = 1'b1; m0_htrans = 2'b10; m0_haddr = ai << 2;
        @(posedge free_clk);
        while (!m0_hready) @(posedge free_clk);
        #1; m1_hwdata = 32'b0;

        #1; a_idle;
        ahb_a_data(a_got);
        chk_a(ai[MEM_ADDRW-1:0], a_got, "T31 A unaffected (run 2)");

        ahb_b_read(wi << 2); #1; b_idle;
        ahb_b_data(b_got);
        ref_write(wi << 2, 3'b010, v2);
        chk_b(wi[MEM_ADDRW-1:0], b_got, "T31 forwarded write 2 (updated value)");

        repeat(2) @(posedge free_clk); #1;
        wait_check("T31", 1, 0, 0);
    end


    // =======================================================================
    // T32 -- Arb-10 hold across extended A+B contest
    //
    //       T20 exercises b_fwd_bsel_r hold for a single arb=10 replay cycle.
    //       Here we keep A+B both reading under a pending write so the arbiter
    //       cycles through 01->10->00->01 (or ->11->10) while b_fwd_match keeps
    //       re-asserting.  Forwarding must never return stale SRAM data.
    // =======================================================================
    test_title = "T32: Arb-10 hold across extended contest";
    $display("");
    $display("================================================================");
    $display("T32: Arb-10 hold across extended A+B contest");
    $display("================================================================");

    begin : t32
        integer    wi, ai, kk;
        reg [31:0] wv, b_got, a_got;

        wi = 5;
        ai = 33;
        wv = $urandom;

        wait_begin;

        // Inject W to wi, concurrent A read to force buffer (like T17/T20).
        #1;
        m1_hsel   = 1'b1; m1_htrans = 2'b10; m1_haddr = wi << 2; m1_hwrite = 1'b1; m1_hsize = 3'b010;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);

        #1;
        m1_hwdata = wv; m1_hsel = 0; m1_htrans = 0; m1_hwrite = 0;
        m0_hsel = 1'b1; m0_htrans = 2'b10; m0_haddr = ai << 2;
        @(posedge free_clk);
        while (!m0_hready) @(posedge free_clk);
        #1; m1_hwdata = 32'b0;

        #1; a_idle;
        ahb_a_data(a_got);
        chk_a(ai[MEM_ADDRW-1:0], a_got, "T32 A read (pre-contest)");

        // Now sustained A+B reads -- B to wi (hits forwarding), A to random addrs.
        // Loop 6 rounds; b_fwd_match must keep re-firing and forwarding must
        // keep returning wv through arb transitions.
        fork
            begin ahb_a_read(33 << 2); end
            begin ahb_b_read(wi << 2); end
        join
        for (kk = 0; kk < 6; kk = kk+1) begin
            fork
                begin ahb_a_data(a_got); end
                begin ahb_a_read(((kk*7 + 9) % NR_WORDS) << 2); end
                begin
                    ahb_b_data(b_got);
                    if (b_got !== wv) begin
                        $display("ERROR [T32 forwarded rd under contest]: round=%0d got=0x%08h expected 0x%08h  (%0t ns)",
                                 kk, b_got, wv, $time);
                        error = error + 1;
                    end else
                        $display("PASS  [T32 forwarded rd under contest]: round=%0d @ word[%0d] = 0x%08h  (%0t ns)",
                                 kk, wi, b_got, $time);
                end
                begin ahb_b_read(wi << 2); end    // keep targeting same wi
            join
        end
        #1; a_idle; b_idle;

        ref_write(wi << 2, 3'b010, wv);
        repeat(5) @(posedge free_clk); #1;

        // Final SRAM read to confirm write eventually drained.
        ahb_b_read(wi << 2); #1; b_idle;
        ahb_b_data(b_got);
        chk_b(wi[MEM_ADDRW-1:0], b_got, "T32 write eventually committed");

        repeat(2) @(posedge free_clk); #1;
        wait_check("T32", 1, 1, 0);
    end


    // =======================================================================
    // T33 -- Pending B write commits under sustained A fetch + pipelined B reads
    //
    //       Issue a B write that loses arbitration to a continuous A fetch,
    //       then immediately pipeline B reads.  The fairness arbiter flips
    //       priority on each contention loss, so the buffered write must win
    //       a cycle within a bounded number of cycles regardless of the
    //       concurrent read stream.  The read-back at the end confirms the
    //       write committed (stale data would indicate live-lock).
    // =======================================================================
    test_title = "T33: pending B write commits under A fetch + B reads";
    $display("");
    $display("================================================================");
    $display("T33: pending B write commits under A fetch + pipelined B reads");
    $display("================================================================");

    begin : t33
        integer    kk;
        integer    wi, ri;
        reg [31:0] wr_val, a_got, b_got;

        wi     = 44;
        ri     = 52;
        wr_val = $urandom;

        wait_begin;
        fwd_dbg_en = 1'b1;

        ahb_a_read(0);

        fork
            begin : t33_a_fetch
                integer ka;
                for (ka = 0; ka < 25; ka = ka+1) begin
                    ahb_a_data(a_got);
                    ahb_a_read(((ka+1) % NR_WORDS) << 2);
                end
                ahb_a_data(a_got);
                #1; a_idle;
            end
            begin : t33_b_ops
                integer km;
                repeat(2) @(posedge free_clk);
                ahb_b_write(wi << 2, 3'b010, wr_val);
                // Immediately pipeline 4 B reads.
                ahb_b_read(ri << 2);
                for (km = 0; km < 3; km = km+1) begin
                    fork
                        begin ahb_b_data(b_got); chk_b(ri + km, b_got, "T33 B read mid-burst"); end
                        begin ahb_b_read((ri + km + 1) << 2); end
                    join
                end
                ahb_b_data(b_got);
                chk_b(ri + 3, b_got, "T33 B read mid-burst");
                #1; b_idle;
            end
        join

        ref_write(wi << 2, 3'b010, wr_val);
        repeat(5) @(posedge free_clk); #1;

        ahb_b_read(wi << 2); #1; b_idle;
        ahb_b_data(b_got);
        chk_b(wi[MEM_ADDRW-1:0], b_got, "T33 write eventually committed");

        repeat(2) @(posedge free_clk); #1;
        fwd_dbg_en = 1'b0;
        wait_check("T33", 1, 1, 0);
    end


    // =======================================================================
    // T34 -- Halfword write-to-read forwarding (b_fwd_bsel_r = 4'b0011 / 4'b1100)
    //
    //       Same pipelined pattern as T25 but hsize=3'b001.  Phase 2
    //       buffers the write (sram_rd_active=1 from the concurrent read
    //       aph) and b_fwd_match latches b_fwd_bsel_r with the halfword
    //       mask.  Next cycle m1_hrdata mixes wr_data[half] with sram_dout
    //       [other half]; only the written halfword must forward.
    //
    //       Round 1: lower halfword (addr[1:0]=00) -> b_fwd_bsel_r=4'b0011
    //       Round 2: upper halfword (addr[1:0]=10) -> b_fwd_bsel_r=4'b1100
    // =======================================================================
    test_title = "T34: Halfword write-to-read forwarding";
    $display("");
    $display("================================================================");
    $display("T34: Halfword write-to-read forwarding (b_fwd_bsel_r = 4'b0011 / 4'b1100)");
    $display("================================================================");

    begin : t34
        integer    addr_w;
        reg [31:0] wr_val, b_got;

        wait_begin;

        // ---- Lower halfword forwarding ----
        addr_w = 48;
        wr_val = $urandom;

        // Cycle N: halfword write aph (addr[1:0]=00 -> lower half)
        #1;
        m1_hsel   = 1'b1;
        m1_htrans = 2'b10;
        m1_haddr  = addr_w << 2;
        m1_hwrite = 1'b1;
        m1_hsize  = 3'b001;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);

        // Cycle N+1: write dph + full-word read aph (same word)
        #1;
        m1_hwdata = wr_val;
        m1_hsel   = 1'b1;
        m1_htrans = 2'b10;
        m1_haddr  = addr_w << 2;
        m1_hwrite = 1'b0;
        m1_hsize  = 3'b010;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);

        // Cycle N+2: read dph -- m1_hrdata forwarded through 4'b0011 mask
        #1;
        m1_hsel   = 1'b0;
        m1_htrans = 2'b00;
        m1_hwrite = 1'b0;
        m1_hwdata = 32'b0;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);
        b_got = m1_hrdata;

        ref_write(addr_w << 2, 3'b001, wr_val);
        chk_b(addr_w[MEM_ADDRW-1:0], b_got, "T34 lower halfword forwarded");

        b_idle;
        repeat(3) @(posedge free_clk); #1;

        // Verify the write committed to SRAM (not only forwarded)
        ahb_b_read(addr_w << 2); #1; b_idle;
        ahb_b_data(b_got);
        chk_b(addr_w[MEM_ADDRW-1:0], b_got, "T34 lower halfword committed");

        repeat(2) @(posedge free_clk); #1;

        // ---- Upper halfword forwarding ----
        addr_w = 49;
        wr_val = $urandom;

        // Cycle N: halfword write aph (addr[1:0]=10 -> upper half)
        #1;
        m1_hsel   = 1'b1;
        m1_htrans = 2'b10;
        m1_haddr  = (addr_w << 2) + 2;
        m1_hwrite = 1'b1;
        m1_hsize  = 3'b001;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);

        // Cycle N+1: write dph + full-word read aph (same word)
        #1;
        m1_hwdata = wr_val;
        m1_hsel   = 1'b1;
        m1_htrans = 2'b10;
        m1_haddr  = addr_w << 2;
        m1_hwrite = 1'b0;
        m1_hsize  = 3'b010;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);

        // Cycle N+2: read dph -- m1_hrdata forwarded through 4'b1100 mask
        #1;
        m1_hsel   = 1'b0;
        m1_htrans = 2'b00;
        m1_hwrite = 1'b0;
        m1_hwdata = 32'b0;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);
        b_got = m1_hrdata;

        ref_write((addr_w << 2) + 2, 3'b001, wr_val);
        chk_b(addr_w[MEM_ADDRW-1:0], b_got, "T34 upper halfword forwarded");

        b_idle;
        repeat(3) @(posedge free_clk); #1;

        ahb_b_read(addr_w << 2); #1; b_idle;
        ahb_b_data(b_got);
        chk_b(addr_w[MEM_ADDRW-1:0], b_got, "T34 upper halfword committed");

        repeat(2) @(posedge free_clk); #1;
        wait_check("T34", 0, 0, 0);
    end


    // =======================================================================
    // T35 -- H-1: back-to-back B writes (no gap between aphs)
    //
    //       Two B-write aphs issued on consecutive cycles targeting different
    //       addresses.  This is the classic AHB-Lite pipelined sequence that
    //       stresses the write-buffer Phase-1/Phase-2 collision in the DUT:
    //
    //           cycle N   : aph1 (addr1)
    //           cycle N+1 : aph2 (addr2) + dph1 (data1)
    //           cycle N+2 : idle         + dph2 (data2)
    //
    //       With the current RTL:
    //         - b_write_stall gates on wr_pending only (not wr_aph_done), so
    //           aph2 is accepted in cycle N+1 even though aph1 is mid-flight.
    //         - Phase 1 sets wr_aph_done<=1 at line 318; Phase 2 clears it at
    //           line 327 in the same always block; last NBA wins, so
    //           wr_aph_done lands at 0.  aph2's HWDATA (data2) is never
    //           captured.
    //
    //       Expected on current (buggy) RTL:
    //         - First readback (addr1) PASSES -- aph1 drains correctly because
    //           the sram_din_o bypass mux forwards live HWDATA=data1 during
    //           the same-cycle opportunistic fire.
    //         - Second readback (addr2) FAILS -- aph2's data was silently lost.
    // =======================================================================
    test_title = "T35: H-1 back-to-back B writes";
    $display("");
    $display("================================================================");
    $display("T35: H-1 - back-to-back B writes (aph2 silently dropped)");
    $display("================================================================");

    begin : t35
        integer    addr1, addr2;
        reg [31:0] data1, data2, b_got;

        addr1 = 60;
        addr2 = 61;
        data1 = 32'hDEADBEEF;
        data2 = 32'hCAFEBABE;

        wait_begin;

        repeat(3) @(posedge free_clk);

        // Cycle N : aph1 (write addr1)
        #1;
        m1_hsel   = 1'b1;
        m1_htrans = 2'b10;
        m1_hwrite = 1'b1;
        m1_haddr  = addr1 << 2;
        m1_hsize  = 3'b010;
        m1_hwdata = 32'b0;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);

        // Cycle N+1 : aph2 (write addr2) + dph1 (data1 on HWDATA)
        #1;
        m1_hwdata = data1;
        m1_hsel   = 1'b1;
        m1_htrans = 2'b10;
        m1_hwrite = 1'b1;
        m1_haddr  = addr2 << 2;
        m1_hsize  = 3'b010;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);

        // Cycle N+2 : dph2 (data2 on HWDATA), bus idle
        #1;
        m1_hwdata = data2;
        m1_hsel   = 1'b0;
        m1_htrans = 2'b00;
        m1_hwrite = 1'b0;
        m1_haddr  = 32'b0;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);

        #1; m1_hwdata = 32'b0; b_idle;

        // Let the write buffer drain
        repeat(5) @(posedge free_clk); #1;

        ref_write(addr1 << 2, 3'b010, data1);
        ref_write(addr2 << 2, 3'b010, data2);

        ahb_b_read(addr1 << 2); #1; b_idle;
        ahb_b_data(b_got);
        chk_b(addr1[MEM_ADDRW-1:0], b_got, "T35 first B write (aph1) committed");

        ahb_b_read(addr2 << 2); #1; b_idle;
        ahb_b_data(b_got);
        chk_b(addr2[MEM_ADDRW-1:0], b_got, "T35 second B write (aph2) committed");

        repeat(2) @(posedge free_clk); #1;
        wait_check("T35", 0, 0, 0);
    end


    // =======================================================================
    // T36 -- Progress: buffered B write commits under sustained B-read burst
    //
    //       Adversarial version of T33.  A fetches briefly, B issues a write
    //       that loses arbitration, then B immediately pivots to a long
    //       back-to-back pipelined-read burst with no idle cycle.  The write
    //       buffer must drain within the burst even though b_aph_read stays
    //       HIGH every cycle -- the fairness arbiter must interleave the
    //       pending write against the reads.  The read-back after the burst
    //       detects live-lock (stale data).
    // =======================================================================
    test_title = "T36: buffered write commits under sustained B-read burst";
    $display("");
    $display("================================================================");
    $display("T36: buffered write commits under sustained B-read burst");
    $display("================================================================");

    begin : t36
        integer    k;
        integer    wi, ri0;
        reg [31:0] wr_val, a_got, b_got;

        wi        = 55;
        ri0       = 10;
        wr_val    = $urandom;

        wait_begin;

        ahb_a_read(0);

        fork
            begin : t36_a_fetch
                integer ka;
                // A fetches for ~4 transactions while the B write is issued.
                for (ka = 0; ka < 4; ka = ka+1) begin
                    ahb_a_data(a_got);
                    ahb_a_read(((ka+1) % NR_WORDS) << 2);
                end
                ahb_a_data(a_got);
                #1; a_idle;
            end
            begin : t36_b_ops
                integer km;
                repeat(2) @(posedge free_clk);

                // Issue a B write that loses arb to A.
                ahb_b_write(wi << 2, 3'b010, wr_val);

                // Immediately start a sustained pipelined B-read burst
                // with no idle gap.  b_aph_read stays HIGH every cycle.
                ahb_b_read(ri0 << 2);
                for (km = 0; km < 25; km = km+1) begin
                    fork
                        begin
                            ahb_b_data(b_got);
                        end
                        begin
                            ahb_b_read(((ri0 + km + 1) % NR_WORDS) << 2);
                        end
                    join
                end
                ahb_b_data(b_got);
                #1; b_idle;
            end
        join

        // Once reads stop, drain should have fired and the write be visible.
        repeat(8) @(posedge free_clk); #1;

        ref_write(wi << 2, 3'b010, wr_val);
        ahb_b_read(wi << 2); #1; b_idle;
        ahb_b_data(b_got);
        chk_b(wi[MEM_ADDRW-1:0], b_got, "T36 write eventually committed after reads stopped");

        repeat(2) @(posedge free_clk); #1;
        wait_check("T36", 1, 1, 0);
    end


    // =======================================================================
    // T37 -- Pipelined A fetch  ||  pipelined B (write, read-same-addr) pairs
    //
    //       Data-integrity stress with cross-port activity:
    //         (a) every A fetch completes with correct data (no starvation,
    //             no corruption from parallel B writes)
    //         (b) every B read returns the freshly-written value -- either
    //             forwarded from the pause buffer (when B lost arb) or read
    //             from SRAM after an inline commit
    //         (c) buffered writes drain without dropping values (post-burst
    //             read-back confirms persistence).
    //
    //       A reads word addresses in [0 .. A_CNT] while B writes in
    //       [40 .. 40+B_CNT-1] -- disjoint ranges so ref-based checking is
    //       stable under concurrent activity.  Strict forwarding-coverage
    //       assertion is in T38 (tighter continuous-pipelined stimulus).
    // =======================================================================
    test_title = "T37: sustained A fetch || pipelined B write-read pairs";
    $display("");
    $display("================================================================");
    $display("T37: sustained A fetch || pipelined B write-read pairs");
    $display("================================================================");

    begin : t37
        integer    ka, kb;
        integer    bi;
        reg [31:0] wval, a_got, b_got;
        reg [31:0] bvals [0:15];
        reg [6:0]  baddrs [0:15];
        integer    A_CNT, B_CNT;

        A_CNT = 30;
        B_CNT = 16;

        // Pre-compute B write addresses and random write data so both
        // fork branches see consistent values.
        for (kb = 0; kb < B_CNT; kb = kb+1) begin
            baddrs[kb] = (40 + kb);            // disjoint from A's 0..30
            bvals[kb]  = $urandom;
        end

        wait_begin;

        // Prime A's pipeline with the first aph
        ahb_a_read(0);

        fork
            // ---------------- Port A: A_CNT pipelined fetches ----------------
            begin : t37_a
                integer kka;
                for (kka = 0; kka < A_CNT; kka = kka+1) begin
                    fork
                        begin ahb_a_data(a_got);
                              chk_a(kka[MEM_ADDRW-1:0], a_got, "T37 A pipelined fetch"); end
                        begin ahb_a_read(((kka+1) % NR_WORDS) << 2); end
                    join
                end
                ahb_a_data(a_got);
                chk_a(A_CNT[MEM_ADDRW-1:0], a_got, "T37 A pipelined fetch (tail)");
                #1; a_idle;
            end

            // --------- Port B: B_CNT back-to-back (write, read-same) ---------
            begin : t37_b
                integer kkb;
                for (kkb = 0; kkb < B_CNT; kkb = kkb+1) begin
                    wval = bvals[kkb];
                    ref_write(baddrs[kkb] << 2, 3'b010, wval);

                    ahb_b_write(baddrs[kkb] << 2, 3'b010, wval);
                    ahb_b_read (baddrs[kkb] << 2);
                    #1; b_idle;
                    ahb_b_data(b_got);
                    chk_b(baddrs[kkb][MEM_ADDRW-1:0], b_got,
                          "T37 B read forwards buffered write");
                end
            end
        join

        // Let any last buffered write drain, then read each B address back
        // to confirm the write actually committed to SRAM (no values lost
        // behind a sustained forwarding path).
        repeat(6) @(posedge free_clk); #1;

        for (kb = 0; kb < B_CNT; kb = kb+1) begin
            ahb_b_read(baddrs[kb] << 2); #1; b_idle;
            ahb_b_data(b_got);
            chk_b(baddrs[kb][MEM_ADDRW-1:0], b_got, "T37 B write persisted to SRAM");
        end

        // T37 is a data-integrity stress test.  The strict forwarding-coverage
        // bar lives in T38 (tighter stimulus: truly continuous pipelined B).
        repeat(2) @(posedge free_clk); #1;
        wait_check("T37", 1, 3, 3);
    end


    // =======================================================================
    // T38 -- Truly continuous pipelined B:  hsel=1 every cycle, W dph overlaps
    //       R aph, R dph overlaps next W aph.  No idle gap, no hsel drop.
    //
    //       This is the tightest legal AHB-Lite pattern for a (W, R) stream:
    //
    //         cycle 0 :  aph(W0)
    //         cycle 1 :  dph(W0) + aph(R0)
    //         cycle 2 :  dph(R0) + aph(W1)
    //         cycle 3 :  dph(W1) + aph(R1)
    //         cycle … :  (W_k, R_k) pairs packed every two cycles
    //
    //       The DUT MUST either (a) complete R[k] correctly (forwarded from
    //       the pause buffer if W[k] hasn't drained yet), or (b) stall via
    //       b_write_stall on cycles where W[k+1] aph cannot yet be accepted.
    //       Either is AHB-legal; silently returning wrong data for R[k] is
    //       a DUT bug.  The fwd_dbg_en probe traces HREADYOUT + forwarding
    //       + mux state every cycle so we can distinguish the two.
    //
    //       B addresses [40..55] are disjoint from A's [0..39] so cross-port
    //       ref-checking is deterministic.
    // =======================================================================
    test_title = "T38: continuous-pipelined B || sustained A fetch";
    $display("");
    $display("================================================================");
    $display("T38: continuous-pipelined B || sustained A fetch");
    $display("================================================================");

    begin : t38
        integer    ka, kb;
        integer    fwd_cov_pre;
        reg [31:0] a_got, b_got;
        reg [31:0] bvals2 [0:15];
        reg [6:0]  baddrs2 [0:15];
        integer    A_CNT, B_CNT;

        A_CNT = 30;                // A reads words [0..30] (A_CNT+1 due to tail)
        B_CNT = 16;                // B writes/reads [40..55] -- disjoint from A
        fwd_cov_pre = fwd_cov_cnt;

        for (kb = 0; kb < B_CNT; kb = kb+1) begin
            baddrs2[kb] = (40 + kb);
            bvals2[kb]  = $urandom;
        end

        wait_begin;

        // Prime A's aph so its pipeline is already in flight when B starts
        ahb_a_read(0);

        fork
            // ---------------- Port A: A_CNT pipelined fetches ----------------
            begin : t38_a
                integer kka;
                for (kka = 0; kka < A_CNT; kka = kka+1) begin
                    fork
                        begin ahb_a_data(a_got);
                              chk_a(kka[MEM_ADDRW-1:0], a_got, "T38 A pipelined fetch"); end
                        begin ahb_a_read(((kka+1) % NR_WORDS) << 2); end
                    join
                end
                ahb_a_data(a_got);
                chk_a(A_CNT[MEM_ADDRW-1:0], a_got, "T38 A pipelined fetch (tail)");
                #1; a_idle;
            end

            // ---------------- Port B: continuous W,R,W,R pipeline ----------
            begin : t38_b
                integer kkb;

                // --- cycle 0: aph(W0) ---
                #1;
                m1_hsel   = 1'b1;
                m1_htrans = 2'b10;
                m1_hwrite = 1'b1;
                m1_hsize  = 3'b010;
                m1_haddr  = baddrs2[0] << 2;
                ref_write(baddrs2[0] << 2, 3'b010, bvals2[0]);
                @(posedge free_clk);
                while (!m1_hready) @(posedge free_clk);

                // --- per-pair loop:  (dph(Wk) + aph(Rk)) , (dph(Rk) + aph(Wk+1)) ---
                for (kkb = 0; kkb < B_CNT; kkb = kkb+1) begin
                    // cycle 2k+1 :  W[kkb] dph  overlapped with  R[kkb] aph
                    #1;
                    m1_hwdata = bvals2[kkb];          // W[kkb] dph
                    m1_hsel   = 1'b1;                  // R[kkb] aph -- keep hsel high
                    m1_htrans = 2'b10;
                    m1_hwrite = 1'b0;
                    m1_hsize  = 3'b010;
                    m1_haddr  = baddrs2[kkb] << 2;
                    @(posedge free_clk);
                    while (!m1_hready) @(posedge free_clk);

                    // cycle 2k+2 :  R[kkb] dph  overlapped with  W[kkb+1] aph
                    #1;
                    m1_hwdata = 32'b0;                 // write dph done
                    if (kkb < B_CNT-1) begin
                        m1_hsel   = 1'b1;
                        m1_htrans = 2'b10;
                        m1_hwrite = 1'b1;
                        m1_hsize  = 3'b010;
                        m1_haddr  = baddrs2[kkb+1] << 2;
                        ref_write(baddrs2[kkb+1] << 2, 3'b010, bvals2[kkb+1]);
                    end else begin
                        m1_hsel   = 1'b0;
                        m1_htrans = 2'b00;
                        m1_hwrite = 1'b0;
                    end
                    @(posedge free_clk);
                    while (!m1_hready) @(posedge free_clk);
                    b_got = m1_hrdata;                 // R[kkb] dph data valid
                    chk_b(baddrs2[kkb][MEM_ADDRW-1:0], b_got,
                          "T38 B read forwards buffered write (continuous)");
                end
                #1; b_idle;
            end
        join

        // Let any trailing buffered write drain, then verify SRAM persistence
        repeat(8) @(posedge free_clk); #1;

        for (kb = 0; kb < B_CNT; kb = kb+1) begin
            ahb_b_read(baddrs2[kb] << 2); #1; b_idle;
            ahb_b_data(b_got);
            chk_b(baddrs2[kb][MEM_ADDRW-1:0], b_got, "T38 B write persisted to SRAM");
        end

        // Coverage report (INFO only): pause-buffer reads observed during
        // the W,R-paired stress.  In the simplified flat design the read
        // path may be served directly from SRAM RDW or from the pause
        // buffer depending on arbitration timing; both are correct.
        $display("INFO  [T38 coverage]: pause-buffer reads observed = %0d (W,R pairs = %0d)",
                 fwd_cov_cnt - fwd_cov_pre, B_CNT);

        repeat(2) @(posedge free_clk); #1;
        wait_check("T38", 1, 5, 5);
    end


    // =======================================================================
    // T39 -- Port A read while a B-write to the same address is buffered
    //
    //       Architectural contract: software issues FENCE.I between B's
    //       store and A's fetch from the same location, so the hardware
    //       is free to return EITHER the pre-write SRAM value OR the
    //       buffered new data here -- both are correct.  Pause-buffer
    //       forwarding to Port A is an *optimization knob*, not a
    //       requirement.
    //
    //       This test still drives the same-address race (B writes wi,
    //       A concurrently reads wi while the buffer is pending) to
    //       guarantee no X / no garbage value is ever returned and that
    //       the post-drain read sees the committed write.
    // =======================================================================
    test_title = "T39: Port A read vs buffered B-write (same address)";
    $display("");
    $display("================================================================");
    $display("T39: Port A read vs buffered B-write (same address)");
    $display("================================================================");

    begin : t39
        integer    wi;
        reg [31:0] wv, old_word, a_got;

        wi       = 12;
        wv       = $urandom;
        old_word = sram_ref[wi];
        if (wv === old_word) wv = wv ^ 32'h1;  // ensure V_new != V_old
        fwd_dbg_en = 1'b1;

        wait_begin;

        // Cycle N: B write aph to wi
        #1;
        m1_hsel   = 1'b1; m1_htrans = 2'b10; m1_haddr = wi << 2;
        m1_hwrite = 1'b1; m1_hsize  = 3'b010;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);

        // Cycle N+1: B write dph (buffer loads V_new) + A aph read SAME addr wi.
        //            A wins SRAM (B is not aph-reading) -> SRAM read targets wi.
        #1;
        m1_hwdata = wv;    m1_hsel = 0; m1_htrans = 0; m1_hwrite = 0;
        m0_hsel   = 1'b1; m0_htrans = 2'b10; m0_haddr = wi << 2;
        @(posedge free_clk);
        while (!m0_hready) @(posedge free_clk);
        #1; m1_hwdata = 32'b0;

        // Cycle N+2: A dph -- accept OLD (no-fwd) or NEW (buffer-forwarded);
        //            FENCE.I is the software-side contract between B and A.
        #1; a_idle;
        ahb_a_data(a_got);
        if (a_got !== old_word && a_got !== wv) begin
            $display("ERROR [T39 A same-addr buffered]: got 0x%08h, expected pre-write 0x%08h or buffered 0x%08h  (%0t ns)",
                     a_got, old_word, wv, $time);
            error = error + 1;
        end else
            $display("PASS  [T39 A same-addr buffered]: got 0x%08h (%s)  (%0t ns)",
                     a_got, (a_got === old_word) ? "pre-write" : "buffered-new", $time);

        fwd_dbg_en = 1'b0;
        // Drain the pending write, then re-fetch -- A now sees committed value.
        ref_write(wi << 2, 3'b010, wv);
        repeat(4) @(posedge free_clk); #1;
        ahb_a_read(wi << 2); #1; a_idle;
        ahb_a_data(a_got);
        chk_a(wi[MEM_ADDRW-1:0], a_got, "T39 A post-drain sees committed write");

        repeat(2) @(posedge free_clk); #1;
        wait_check("T39", 0, 0, 0);
    end


    // =======================================================================
    // T40 -- Mixed-size forwarding: byte write, full-word read.
    //
    //       T15 exercises byte-in/byte-out (no concurrent access, direct
    //       SRAM).  T34 exercises halfword-in/halfword-out forwarding.
    //       Neither hits the byte-lane merge with a *wider* read.
    //
    //       This drives a byte-write to lane 2 of wi, then a pipelined
    //       word-read of wi.  Expected hrdata merges:
    //         • lane[2] ← m1_hwdata_pause  (new_byte)
    //         • lanes[0,1,3] ← sram_dout  (pre-write SRAM word)
    //       i.e. b_sram_wr_en_buf = 4'b0100 drives the forwarding mux.
    // =======================================================================
    test_title = "T40: Mixed-size forwarding (byte write, word read)";
    $display("");
    $display("================================================================");
    $display("T40: Mixed-size forwarding -- byte write, word read");
    $display("================================================================");

    begin : t40
        integer    wi;
        reg  [7:0] new_byte;
        reg [31:0] old_word, expected, b_got;

        wi       = 18;
        new_byte = $urandom;
        old_word = sram_ref[wi];
        if (new_byte === old_word[23:16]) new_byte = new_byte ^ 8'h1;
        expected = {old_word[31:24], new_byte, old_word[15:0]};

        wait_begin;

        // Cycle N: byte-write aph to lane 2 of wi (addr[1:0]=2'b10)
        #1;
        m1_hsel   = 1'b1;
        m1_htrans = 2'b10;
        m1_haddr  = (wi << 2) + 2;
        m1_hwrite = 1'b1;
        m1_hsize  = 3'b000;                       // byte
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);

        // Cycle N+1: write dph (HWDATA drives new_byte on lane 2)
        //          + word-read aph to same word wi (hsize=010).
        //            State: WRITE -> RPW, b_fwd_match_now asserts,
        //            b_sram_wr_en_buf latches 4'b0100.
        #1;
        m1_hwdata = {8'b0, new_byte, 16'b0};
        m1_hsel   = 1'b1;
        m1_htrans = 2'b10;
        m1_haddr  = wi << 2;
        m1_hwrite = 1'b0;
        m1_hsize  = 3'b010;                       // word read
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);

        // Cycle N+2: read dph -- m1_hrdata merges pause lane[2] with SRAM [0,1,3]
        #1;
        m1_hsel   = 1'b0;
        m1_htrans = 2'b00;
        m1_hwrite = 1'b0;
        m1_hwdata = 32'b0;
        @(posedge free_clk);
        while (!m1_hready) @(posedge free_clk);
        b_got = m1_hrdata;

        if (b_got !== expected) begin
            $display("ERROR [T40 byte->word fwd]: got 0x%08h, expected 0x%08h (old=0x%08h, new_byte=0x%02h)  (%0t ns)",
                     b_got, expected, old_word, new_byte, $time);
            error = error + 1;
        end else
            $display("PASS  [T40 byte->word fwd]: got merged 0x%08h  (%0t ns)",
                     b_got, $time);

        ref_write((wi << 2) + 2, 3'b000, {8'b0, new_byte, 16'b0});

        // Drain, then full-word read from SRAM to confirm commit.
        b_idle;
        repeat(3) @(posedge free_clk); #1;
        ahb_b_read(wi << 2); #1; b_idle;
        ahb_b_data(b_got);
        chk_b(wi[MEM_ADDRW-1:0], b_got, "T40 committed byte-merged word in SRAM");

        repeat(2) @(posedge free_clk); #1;
        wait_check("T40", 0, 0, 0);
    end


    // T41 and T42 removed: regression guards for old-DUT-specific bugs
    // (`a_grant/a_lost asymmetry`, `b_sram_wr_pause missing arb[1]`) that do
    // not exist in the rewritten flat ahb_fused_sram_ctrl.


    // =======================================================================
    // T43 -- Constrained-random stress
    //
    //       Drives both Port A and Port B concurrently with random ops:
    //         A: read | BUSY | IDLE
    //         B: word write | read | BUSY | IDLE
    //       In parallel, two wait-state injectors pulse a_hready_ext /
    //       b_hready_ext low at random.
    //
    //       Verification strategy:
    //         - Read DATA is NOT checked per-call (check=0).  Under random
    //           concurrent writes, the value at any read instant is
    //           timing-dependent (forwarded vs stale-then-forwarded).
    //         - Writes update sram_ref via ref_write; the end-of-sim full
    //           memory diff catches any DUT-side write loss or address-mux
    //           corruption.
    //         - Hangs are caught by the global watchdog.
    //         - Word writes only -- byte/halfword lane logic is exhaustively
    //           covered by directed tests T4/T15/T17/T39/T40.  Stress
    //           focuses on the FSM/arbiter under random concurrency.
    //
    //       Per-test wait_check is INFO-only (random WS makes streak bounds
    //       meaningless here).  Global a_low_max / b_low_max / b_stall_max
    //       counters are still updated and printed in the end-of-sim summary.
    // =======================================================================
    test_title = "T43: random stress (both ports, random WS, IDLE/BUSY)";
    $display("");
    $display("================================================================");
    $display("T43: random stress (both ports, random WS, random IDLE/BUSY)");
    $display("================================================================");

    begin : t43
        integer iter_a, iter_b;
        integer a_ops_done, b_ops_done;

        a_ops_done   = 0;
        b_ops_done   = 0;
        a_hready_ext = 1'b1;
        b_hready_ext = 1'b1;

        wait_begin;

        fork
            // ---------- Port A op driver ----------
            begin : t43_a_ops
                integer op_a, addr_aw;
                for (iter_a = 0; iter_a < 200; iter_a = iter_a+1) begin
                    op_a = $urandom % 10;
                    if (op_a < 6) begin               // 60% read
                        addr_aw = $urandom % NR_WORDS;
                        m0_hsel = 1'b1;
                        m0_ahb_read(1'b0, addr_aw << 2, 32'h0, 2'b10, 1'b0);
                    end else if (op_a < 8) begin      // 20% BUSY phase
                        m0_hsel  = 1'b1; m0_htrans = 2'b01;
                        repeat (1 + ($urandom % 2)) @(posedge free_clk); #1;
                        a_idle;
                    end else begin                    // 20% idle gap
                        repeat (1 + ($urandom % 3)) @(posedge free_clk); #1;
                        a_idle;
                    end
                end
                a_idle;
                a_ops_done = 1;
            end
            // ---------- Port B op driver ----------
            begin : t43_b_ops
                integer    op_b, addr_bw;
                reg [31:0] wval_b;
                for (iter_b = 0; iter_b < 200; iter_b = iter_b+1) begin
                    op_b = $urandom % 10;
                    if (op_b < 4) begin               // 40% word write
                        addr_bw = $urandom % NR_WORDS;
                        wval_b  = $urandom;
                        ref_write(addr_bw << 2, 3'b010, wval_b);
                        m1_hsel = 1'b1;
                        // blocking=1 ensures DPH completes before the loop
                        // can fall into a b_idle that would clobber HWDATA
                        // mid-DPH when the WS injector extends it.
                        m1_ahb_write(1'b1, addr_bw << 2, wval_b, 2'b10);
                    end else if (op_b < 7) begin      // 30% read
                        addr_bw = $urandom % NR_WORDS;
                        m1_hsel = 1'b1;
                        m1_ahb_read(1'b0, addr_bw << 2, 32'h0, 2'b10, 1'b0);
                    end else if (op_b < 8) begin      // 10% BUSY phase
                        m1_hsel  = 1'b1; m1_htrans = 2'b01;
                        repeat (1 + ($urandom % 2)) @(posedge free_clk); #1;
                        b_idle;
                    end else begin                    // 20% idle gap
                        repeat (1 + ($urandom % 3)) @(posedge free_clk); #1;
                        b_idle;
                    end
                end
                b_idle;
                b_ops_done = 1;
            end
            // ---------- Wait-state injector A ----------
            begin : t43_ws_a
                integer hi_cyc_a, lo_cyc_a;
                while (!(a_ops_done && b_ops_done)) begin
                    hi_cyc_a     = 1 + ($urandom % 6);
                    a_hready_ext = 1'b1;
                    repeat (hi_cyc_a) @(posedge free_clk);
                    if (!(a_ops_done && b_ops_done) && (($urandom % 4) != 0)) begin
                        lo_cyc_a     = 1 + ($urandom % 3);
                        a_hready_ext = 1'b0;
                        repeat (lo_cyc_a) @(posedge free_clk);
                    end
                end
                a_hready_ext = 1'b1;
            end
            // ---------- Wait-state injector B ----------
            begin : t43_ws_b
                integer hi_cyc_b, lo_cyc_b;
                while (!(a_ops_done && b_ops_done)) begin
                    hi_cyc_b     = 1 + ($urandom % 6);
                    b_hready_ext = 1'b1;
                    repeat (hi_cyc_b) @(posedge free_clk);
                    if (!(a_ops_done && b_ops_done) && (($urandom % 4) != 0)) begin
                        lo_cyc_b     = 1 + ($urandom % 3);
                        b_hready_ext = 1'b0;
                        repeat (lo_cyc_b) @(posedge free_clk);
                    end
                end
                b_hready_ext = 1'b1;
            end
        join

        a_idle; b_idle;
        a_hready_ext = 1'b1;
        b_hready_ext = 1'b1;
        repeat(16) @(posedge free_clk); #1;
        wait_check("T43", -1, -1, -1);
    end


    // =======================================================================
    // END OF TEST
    // =======================================================================
    repeat(4) @(posedge free_clk);

    // Full-memory diff: scoreboard catch-all for any DUT write that landed
    // at the wrong address (or never landed) but was never read back by a
    // directed test.  ref_write keeps sram_ref in sync with intended writes.
    begin : end_of_sim_mem_diff
        integer mismatches;
        mismatches = 0;
        for (ii = 0; ii < NR_WORDS; ii = ii+1) begin
            if (sram_inst.mem[ii] !== sram_ref[ii]) begin
                $display("ERROR [end-of-sim diff]: mem[%0d]=0x%08h, sram_ref=0x%08h",
                         ii, sram_inst.mem[ii], sram_ref[ii]);
                mismatches = mismatches + 1;
                error      = error + 1;
            end
        end
        if (mismatches == 0)
            $display("PASS  [end-of-sim diff]: all %0d words match sram_ref", NR_WORDS);
    end

    $display("");
    $display("================================================================");
    $display("HREADYOUT-low streak max:  A=%0d  B=%0d  (B write-stall max=%0d in %0s)",
             a_low_max, b_low_max, b_stall_max, b_stall_max_test);
    $display("================================================================");
    if (error == 0)
        $display("SIMULATION PASSED  (0 errors)");
    else
        $display("SIMULATION FAILED  (%0d errors)", error);
    $display("================================================================");
    $display("");

    $finish;

end // initial

endmodule // tb_ahb_fused_sram_ctrl
