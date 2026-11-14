//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tb_apb_periph_example
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tb_apb_periph_example.v
// Module Description : Testbench of apb_periph_example: an APB4 manager
//                      (back-to-back or idle-separated transfers, random
//                      bus values while idle), a reference model of the
//                      registers and MDELEG that predicts every read, every
//                      PSLVERR and every register output in every cycle, and
//                      an APB4 completer checker. PER_ADDRW sets the window,
//                      PER_ASYNC_RST_EN the reset style, PER_MDELEG_RST the
//                      MDELEG reset value (an integer: MDELEG[8:0]);
//                      PER_FREE_CLK runs pclk free instead of gating it.
//----------------------------------------------------------------------------
`include "timescale.v"

`ifndef PER_ADDRW
   `define PER_ADDRW        7
`endif
`ifndef PER_ASYNC_RST_EN
   `define PER_ASYNC_RST_EN 1
`endif
`ifndef PER_MDELEG_RST
   `define PER_MDELEG_RST   271
`endif

module  tb_apb_periph_example;

localparam ADDRW        = `PER_ADDRW;
localparam ASYNC_RST_EN = `PER_ASYNC_RST_EN;
localparam [8:0] MDELEG_RST = `PER_MDELEG_RST;  // default 9'h10F
localparam WIN          = 1 << ADDRW;          // window size in bytes

localparam [1:0] USER       = 2'b00;
localparam [1:0] SUPERVISOR = 2'b01;
localparam [1:0] MACHINE    = 2'b11;

localparam [31:0] MDELEG_ADDR = 32'h40;
localparam [31:0] MDELEG_RST_WORD = {23'h0, MDELEG_RST};

//----------------------------------------------------------------------------
// Clock and reset
//----------------------------------------------------------------------------
reg          free_clk;
reg          presetn;
wire         pclk;
wire         pclk_en;
reg          pclk_en_latch;
integer      error;
reg          stimulus_done;
integer      seed;

initial begin
    free_clk = 1'b0;
    forever #5 free_clk = ~free_clk;
end

// Clock gate: the clock runs while the peripheral requests it, and during
// reset (the reset generator's request). PER_FREE_CLK: no gate, so a load
// outside a selected transfer would land and fail the register check.
always @(free_clk or pclk_en or presetn)
    if (~free_clk) pclk_en_latch <= pclk_en | ~presetn;
`ifdef PER_FREE_CLK
assign pclk = free_clk;
`else
assign pclk = free_clk & pclk_en_latch;
`endif

initial begin
    error         = 0;
    stimulus_done = 1'b0;
    seed          = `SEED;
    presetn       = 1'b0;
    repeat (5) @(posedge free_clk);
    #1 presetn    = 1'b1;
end

//----------------------------------------------------------------------------
// DUT
//----------------------------------------------------------------------------
reg              psel;
reg              penable;
reg  [ADDRW-1:0] paddr;
reg              pwrite;
reg       [31:0] pwdata;
reg        [3:0] pstrb;
reg        [2:0] pprot;
reg              psmode;
wire      [31:0] prdata;
wire             pready;
wire             pslverr;
wire      [31:0] regout [0:7];
reg       [31:0] regin  [0:7];

apb_periph_example #(
    .ADDRW         ( ADDRW         ),
    .ASYNC_RST_EN  ( ASYNC_RST_EN  ),
    .MDELEG_RST    ( MDELEG_RST    )
) dut (
    .pclk_i        ( pclk          ),
    .presetn_i     ( presetn       ),
    .pclk_en_o     ( pclk_en       ),
    .psel_i        ( psel          ),
    .penable_i     ( penable       ),
    .paddr_i       ( paddr         ),
    .pwrite_i      ( pwrite        ),
    .pwdata_i      ( pwdata        ),
    .pstrb_i       ( pstrb         ),
    .pprot_i       ( pprot         ),
    .psmode_i      ( psmode        ),
    .prdata_o      ( prdata        ),
    .pready_o      ( pready        ),
    .pslverr_o     ( pslverr       ),
    .register_00_o ( regout[0]     ),
    .register_01_o ( regout[1]     ),
    .register_02_o ( regout[2]     ),
    .register_03_o ( regout[3]     ),
    .register_04_o ( regout[4]     ),
    .register_05_o ( regout[5]     ),
    .register_06_o ( regout[6]     ),
    .register_07_o ( regout[7]     ),
    .register_08_i ( regin[0]      ),
    .register_09_i ( regin[1]      ),
    .register_10_i ( regin[2]      ),
    .register_11_i ( regin[3]      ),
    .register_12_i ( regin[4]      ),
    .register_13_i ( regin[5]      ),
    .register_14_i ( regin[6]      ),
    .register_15_i ( regin[7]      )
);

//----------------------------------------------------------------------------
// Reference model
//----------------------------------------------------------------------------
reg       [31:0] m_regout [0:7];
reg        [1:0] m_wr_priv;
reg        [1:0] m_rd_priv;
reg              m_resp;
reg              m_mdeleg_written;            // MDELEG written since reset
integer          mi;

task model_reset;
    begin
        for (mi = 0; mi < 8; mi = mi + 1) m_regout[mi] = 32'h0;
        m_wr_priv = MDELEG_RST[1:0];
        m_rd_priv = MDELEG_RST[3:2];
        m_resp    = MDELEG_RST[8];
        m_mdeleg_written = 1'b0;
    end
endtask

initial begin
    model_reset;
    for (mi = 0; mi < 8; mi = mi + 1) regin[mi] = 32'h0;
end
always @(negedge presetn) model_reset;

function [31:0] m_mdeleg;
    input dummy;
    m_mdeleg = {23'h0, m_resp, 4'h0, m_rd_priv, m_wr_priv};
endfunction

function [1:0] coerce;
    input [1:0] v;
    coerce = (v == 2'b10) ? 2'b11 : v;
endfunction

// Word index of an address inside the window
function integer widx;
    input [31:0] a;
    widx = (a % WIN) >> 2;
endfunction

function m_allowed;
    input        write;
    input  [1:0] mode;
    input [31:0] a;
    begin
        if (widx(a) == 16) m_allowed = (mode == MACHINE);
        else               m_allowed = (mode >= (write ? m_wr_priv : m_rd_priv));
    end
endfunction

function m_err;
    input        write;
    input  [1:0] mode;
    input [31:0] a;
    m_err = m_resp & ~m_allowed(write, mode, a);
endfunction

function [31:0] m_rdata;
    input  [1:0] mode;
    input [31:0] a;
    integer      w;
    begin
        w = widx(a);
        if (!m_allowed(1'b0, mode, a)) m_rdata = 32'h0;
        else if (w < 8)                m_rdata = m_regout[w];
        else if (w < 16)               m_rdata = regin[w - 8];
        else if (w == 16)              m_rdata = m_mdeleg(1'b0);
        else                           m_rdata = 32'h0;
    end
endfunction

task model_write;
    input  [1:0] mode;
    input [31:0] a;
    input [31:0] d;
    input  [3:0] s;
    integer      w;
    begin
        w = widx(a);
        if (m_allowed(1'b1, mode, a)) begin
            if (w < 8) begin
                if (s[0]) m_regout[w][ 7: 0] = d[ 7: 0];
                if (s[1]) m_regout[w][15: 8] = d[15: 8];
                if (s[2]) m_regout[w][23:16] = d[23:16];
                if (s[3]) m_regout[w][31:24] = d[31:24];
            end else if (w == 16) begin
                if (s[1:0] != 2'b00) m_mdeleg_written = 1'b1;
                if (s[0]) begin m_wr_priv = coerce(d[1:0]); m_rd_priv = coerce(d[3:2]); end
                if (s[1]) m_resp = d[8];
            end
        end
    end
endtask

// Every register output matches the model in every cycle: a write lands at
// the end of its ACCESS cycle and nowhere else
always @(negedge free_clk) begin
    if (presetn === 1'b1) begin
        for (mi = 0; mi < 8; mi = mi + 1)
            if (regout[mi] !== m_regout[mi]) begin
                $display("ERROR: register_%02d_o = 0x%h, model 0x%h %t", mi, regout[mi], m_regout[mi], $time);
                error = error + 1;
            end
    end
end

//----------------------------------------------------------------------------
// APB4 manager
//----------------------------------------------------------------------------
integer      xfers       = 0;              // completed transfers
integer      slverrs     = 0;              // ... answered with PSLVERR
reg          b2b         = 1'b0;           // next transfer starts in the cycle after ACCESS
reg   [31:0] last_rdata;
reg          last_err;

// Bus values while no transfer is running: random, the peripheral ignores them.
// PENABLE included: behind the bridge it is shared by every completer, so a
// deselected completer sees other completers' ACCESS cycles.
task bus_idle;
    begin
        psel    = 1'b0;
        penable = $random(seed);
        paddr   = $random(seed);
        pwrite  = $random(seed);
        pwdata  = $random(seed);
        pstrb   = $random(seed);
        pprot   = $random(seed);
        psmode  = $random(seed);
    end
endtask

initial bus_idle;

task idle;
    input integer n;
    begin
        repeat (n) begin
            bus_idle;
            @(posedge free_clk); #1;
        end
    end
endtask

// One transfer, from SETUP to the end of ACCESS. exp_err / exp_data < 0 take
// the model's prediction; extra = PPROT[2:1], which the peripheral ignores.
task xfer;
    input         write;
    input   [1:0] mode;
    input  [31:0] addr;
    input  [31:0] wdata;
    input   [3:0] strb;
    input   [1:0] extra;
    input integer exp_err;
    input  [31:0] exp_data;
    input         chk_data;
    reg           p_err;
    reg    [31:0] p_data;
    begin
        p_err  = (exp_err < 0) ? m_err(write, mode, addr) : exp_err[0];
        p_data = chk_data ? exp_data : m_rdata(mode, addr);
        if (p_err) p_data = 32'h0;
        // SETUP
        psel    = 1'b1;
        penable = 1'b0;
        paddr   = addr[ADDRW-1:0];
        pwrite  = write;
        pwdata  = write ? wdata : $random(seed);
        pstrb   = write ? strb  : $random(seed);   // reads ignore PSTRB (a requester drives 0)
        pprot   = {extra, (mode != USER)};
        psmode  = (mode == SUPERVISOR) | ((mode == USER) & $random(seed));
        @(posedge free_clk); #1;
        // ACCESS
        penable = 1'b1;
        @(negedge free_clk);
        last_rdata = prdata;
        last_err   = pslverr;
        if (presetn !== 1'b1) begin
            // reset during the transfer: no outcome to check
        end else if (pslverr !== p_err) begin
            $display("ERROR: %s 0x%h mode %0d -- PSLVERR %b, expected %b %t", write ? "write" : "read", addr, mode, pslverr, p_err, $time);
            error = error + 1;
        end
        if ((presetn === 1'b1) && !write && (prdata !== p_data)) begin
            $display("ERROR: read 0x%h mode %0d -- PRDATA 0x%h, expected 0x%h %t", addr, mode, prdata, p_data, $time);
            error = error + 1;
        end
        @(posedge free_clk); #1;
        if (presetn === 1'b1) begin
            if (write) model_write(mode, addr, wdata, strb);
            xfers   = xfers + 1;
            slverrs = slverrs + last_err;
        end
        if (!b2b) idle(1);
    end
endtask

// Shorthands: the model predicts the outcome
task wr;  input [1:0] mode; input [31:0] a; input [31:0] d;               begin xfer(1'b1, mode, a, d, 4'hF, 2'b00, -1, 32'h0, 1'b0); end endtask
task wrs; input [1:0] mode; input [31:0] a; input [31:0] d; input [3:0] s; begin xfer(1'b1, mode, a, d, s,    2'b00, -1, 32'h0, 1'b0); end endtask
task rd;  input [1:0] mode; input [31:0] a;                               begin xfer(1'b0, mode, a, 32'h0, 4'h0, 2'b00, -1, 32'h0, 1'b0); end endtask

// Directed forms: the test states the expected outcome
task wr_x; input [1:0] mode; input [31:0] a; input [31:0] d; input e;                begin xfer(1'b1, mode, a, d, 4'hF, 2'b00, e, 32'h0, 1'b0); end endtask
task rd_x; input [1:0] mode; input [31:0] a; input [31:0] exp; input e;              begin xfer(1'b0, mode, a, 32'h0, 4'h0, 2'b00, e, exp, 1'b1); end endtask

// Program MDELEG from machine mode
task set_mdeleg; input [1:0] wp; input [1:0] rp; input resp;
    begin xfer(1'b1, MACHINE, MDELEG_ADDR, {23'h0, resp, 4'h0, rp, wp}, 4'b0011, 2'b00, 0, 32'h0, 1'b0); end
endtask

// First transfer of a test: after reset, aligned to the manager's timing
task start;
    begin
        wait (presetn === 1'b1);
        @(posedge free_clk); #1;
    end
endtask

task finish;
    begin
        b2b = 1'b0;
        idle(2);
        $display("%0d transfers, %0d PSLVERR", xfers, slverrs);
        stimulus_done = 1'b1;
    end
endtask

task check_eq;
    input [31:0] got;
    input [31:0] exp;
    input [8*40-1:0] what;
    begin
        if (got !== exp) begin $display("ERROR: %0s = 0x%h, expected 0x%h %t", what, got, exp, $time); error = error + 1; end
    end
endtask

//----------------------------------------------------------------------------
// APB4 completer checks
//----------------------------------------------------------------------------
always @(negedge free_clk) begin
    if (presetn === 1'b1) begin
        if (pready !== 1'b1) begin $display("ERROR: PREADY not high %t", $time); error = error + 1; end
        if (!(psel && penable) && (pslverr !== 1'b0)) begin $display("ERROR: PSLVERR outside ACCESS %t", $time); error = error + 1; end
        if (!(psel && penable && !pwrite) && (prdata !== 32'h0)) begin $display("ERROR: PRDATA not 0 outside a read ACCESS %t", $time); error = error + 1; end
    end
end

//----------------------------------------------------------------------------
// Functional coverage: one flag per bin, reported at the end
//----------------------------------------------------------------------------
reg cv_read = 0, cv_write = 0, cv_err_rd = 0, cv_err_wr = 0, cv_ignored = 0, cv_b2b = 0;
reg cv_strb_part = 0, cv_strb_zero = 0, cv_mdeleg_wr = 0, cv_mode_u = 0, cv_mode_s = 0;
reg cv_mode_m = 0, cv_prot_hi = 0, cv_unmapped = 0, cv_reset_busy = 0, cv_en_lo = 0;
reg cv_open_rst = 0, cv_foreign = 0, cv_user_smode = 0, cv_rd_strb = 0;
reg cv_prev_access = 0;

// Privilege mode on the bus
function [1:0] bus_mode;
    input dummy;
    bus_mode = !pprot[0] ? USER : psmode ? SUPERVISOR : MACHINE;
endfunction

always @(posedge free_clk) begin
    if (presetn === 1'b1) begin
        if (psel && penable &&  pwrite) cv_write = 1;
        if (psel && penable && !pwrite) cv_read  = 1;
        if (psel && penable && pslverr &&  pwrite) cv_err_wr = 1;
        if (psel && penable && pslverr && !pwrite) cv_err_rd = 1;
        if (psel && penable && !m_resp && !m_allowed(pwrite, bus_mode(1'b0), paddr)) cv_ignored = 1;
        if (psel && !penable && cv_prev_access) cv_b2b = 1;
        if (psel && penable && pwrite && (pstrb != 4'hF) && (pstrb != 4'h0)) cv_strb_part = 1;
        if (psel && penable && pwrite && (pstrb == 4'h0)) cv_strb_zero = 1;
        if (psel && penable && pwrite && (widx(paddr) == 16) && pprot[0] && !psmode) cv_mdeleg_wr = 1;
        if (psel && penable && !pprot[0])           cv_mode_u = 1;
        if (psel && penable &&  pprot[0] &&  psmode) cv_mode_s = 1;
        if (psel && penable &&  pprot[0] && !psmode) cv_mode_m = 1;
        if (psel && penable && (pprot[2:1] != 2'b00)) cv_prot_hi = 1;
        if (psel && penable && (widx(paddr) > 16))  cv_unmapped = 1;
        if (pclk_en === 1'b0) cv_en_lo = 1;
        if (!psel && penable)                       cv_foreign = 1;
        if (psel && penable && !pprot[0] && psmode) cv_user_smode = 1;
        if (psel && penable && !pwrite && (pstrb != 4'h0)) cv_rd_strb = 1;
        if (psel && penable && !m_mdeleg_written && (bus_mode(1'b0) != MACHINE) && (widx(paddr) < 16) && m_allowed(pwrite, bus_mode(1'b0), paddr)) cv_open_rst = 1;
    end
    cv_prev_access = psel && penable;
end
always @(negedge presetn) if (psel) cv_reset_busy = 1;

task cover_report;
    begin
        if (cv_read)       $display("COVERAGE HIT: read");
        if (cv_write)      $display("COVERAGE HIT: write");
        if (cv_err_rd)     $display("COVERAGE HIT: pslverr_read");
        if (cv_err_wr)     $display("COVERAGE HIT: pslverr_write");
        if (cv_ignored)    $display("COVERAGE HIT: denied_ignored");
        if (cv_b2b)        $display("COVERAGE HIT: back_to_back");
        if (cv_strb_part)  $display("COVERAGE HIT: partial_strobe");
        if (cv_strb_zero)  $display("COVERAGE HIT: zero_strobe");
        if (cv_mdeleg_wr)  $display("COVERAGE HIT: mdeleg_write");
        if (cv_mode_u)     $display("COVERAGE HIT: user_mode");
        if (cv_mode_s)     $display("COVERAGE HIT: supervisor_mode");
        if (cv_mode_m)     $display("COVERAGE HIT: machine_mode");
        if (cv_prot_hi)    $display("COVERAGE HIT: pprot_upper");
        if (cv_unmapped)   $display("COVERAGE HIT: unmapped");
        if (cv_reset_busy) $display("COVERAGE HIT: reset_in_transfer");
        if (cv_en_lo)      $display("COVERAGE HIT: pclk_en_lo");
        if (cv_open_rst)   $display("COVERAGE HIT: open_reset");
        if (cv_foreign)    $display("COVERAGE HIT: foreign_access");
        if (cv_user_smode) $display("COVERAGE HIT: user_smode_hi");
        if (cv_rd_strb)    $display("COVERAGE HIT: read_strobe");
    end
endtask

//----------------------------------------------------------------------------
// Test, verdict, timeout
//----------------------------------------------------------------------------
`include "stimulus.v"

initial begin
    @(posedge stimulus_done);
    repeat (5) @(posedge free_clk);
    $display(" ===============================================");
    if (error != 0) begin
        $display("|               SIMULATION FAILED               |");
        $display("|     (%0d bench errors)                         ", error);
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
    $dumpfile("tb_apb_periph_example.vcd");
    $dumpvars(0, tb_apb_periph_example);
end
`endif

`ifdef ARV_COV_RESET_ZERO
initial begin
    wait (presetn === 1'b0);
    @(posedge presetn);
    $c("Verilated::threadContextp()->coveragep()->zero();");
end
`endif

endmodule // tb_apb_periph_example
