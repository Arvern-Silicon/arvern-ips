//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    unselected_pins
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : unselected_pins
// Module Description : Random activity on every input pin of the transports the
//                      wrapper did not select leaves the selected transport's DMI
//                      traffic and the unselected outputs untouched.
//
//   doc/arv_dtm.md, wrapper: "only the chosen front-end is elaborated; the others
//   contribute no logic"; "Unselected transports hold their PHY outputs at idle
//   (TDO/TMSC released, UART TX high, I2C pull-downs off), and dbg_wakeup_o is tied
//   low for UART/I2C. The bench checks those levels on every cycle of every test."
//   idcode_version_i is "JTAG and cJTAG" only; the serial DTMs have "no scan_mode_i
//   port". Cold attach: dbg_wakeup_o "toggles on every rising probe-clock edge"
//   (TCK for JTAG, TCKC for cJTAG).
//
//   While DMI write/read rounds run on the selected transport, a noise process
//   toggles, at random 3..60 ns gaps, every input of the other transports: tms, tdi,
//   trst_n, tckc, tmsc, uart_rx, scl, sda; in the UART and I2C builds also
//   scan_mode_i and idcode_version_i[3:0] (forced on the wrapper port); tck, the
//   bench's free-running clock, is forced to the noise outside the JTAG build. Each
//   toggled pin must see at least UP_MIN edges, rises and falls both. Every read returns its word with success,
//   the PSEL count equals the number of ops, the bench's pin-tie monitor runs every
//   cycle; UART/I2C: dbg_wakeup_o never moves; JTAG/cJTAG: it toggles on every
//   probe-clock rise and at no other time. A final round runs with the pins parked.
//----------------------------------------------------------------------------

localparam integer UP_NPIN = 14;
localparam integer UP_MIN  = 300;

// 0 tms, 1 tdi, 2 trst_n, 3 tckc, 4 tmsc, 5 uart_rx, 6 scl, 7 sda,
// 8 scan_mode, 9..12 idcode_version_i[0..3], 13 tck (forced)
reg     [UP_NPIN-1:0] up_act;
integer               up_rise [0:UP_NPIN-1];
integer               up_fall [0:UP_NPIN-1];
reg                   up_run;
reg                   up_noise_done;
reg                   up_min_met;
reg             [3:0] up_idv;
reg                   up_tck;
integer               up_seed;
integer               up_psel;
integer               up_i;

initial begin
   up_run        = 1'b0;
   up_noise_done = 1'b0;
   up_min_met    = 1'b0;
   up_idv        = DUT_IDVER;
   up_tck        = 1'b0;
   up_seed       = SEEDV ^ 32'h5A5A_0F0F;
   up_psel       = 0;
   for (up_i = 0; up_i < UP_NPIN; up_i = up_i + 1) begin
      up_rise[up_i] = 0;
      up_fall[up_i] = 0;
   end
`ifdef DTM_UART
   up_act = 14'b11_1111_1101_1111;
`elsif DTM_I2C
   up_act = 14'b11_1111_0011_1111;
`elsif DTM_CJTAG
   up_act = 14'b10_0000_1110_0111;
`else
   up_act = 14'b00_0000_1111_1000;
`endif
end

always @(posedge dmi_psel) up_psel = up_psel + 1;

always @(posedge tms)       if (up_run) up_rise[0]  = up_rise[0]  + 1;
always @(negedge tms)       if (up_run) up_fall[0]  = up_fall[0]  + 1;
always @(posedge tdi)       if (up_run) up_rise[1]  = up_rise[1]  + 1;
always @(negedge tdi)       if (up_run) up_fall[1]  = up_fall[1]  + 1;
always @(posedge trst_n)    if (up_run) up_rise[2]  = up_rise[2]  + 1;
always @(negedge trst_n)    if (up_run) up_fall[2]  = up_fall[2]  + 1;
always @(posedge tckc)      if (up_run) up_rise[3]  = up_rise[3]  + 1;
always @(negedge tckc)      if (up_run) up_fall[3]  = up_fall[3]  + 1;
always @(posedge tmsc)      if (up_run) up_rise[4]  = up_rise[4]  + 1;
always @(negedge tmsc)      if (up_run) up_fall[4]  = up_fall[4]  + 1;
always @(posedge uart_rx)   if (up_run) up_rise[5]  = up_rise[5]  + 1;
always @(negedge uart_rx)   if (up_run) up_fall[5]  = up_fall[5]  + 1;
always @(posedge scl)       if (up_run) up_rise[6]  = up_rise[6]  + 1;
always @(negedge scl)       if (up_run) up_fall[6]  = up_fall[6]  + 1;
always @(posedge sda)       if (up_run) up_rise[7]  = up_rise[7]  + 1;
always @(negedge sda)       if (up_run) up_fall[7]  = up_fall[7]  + 1;
always @(posedge scan_mode) if (up_run) up_rise[8]  = up_rise[8]  + 1;
always @(negedge scan_mode) if (up_run) up_fall[8]  = up_fall[8]  + 1;
always @(posedge dut.idcode_version_i[0]) if (up_run) up_rise[9]  = up_rise[9]  + 1;
always @(negedge dut.idcode_version_i[0]) if (up_run) up_fall[9]  = up_fall[9]  + 1;
always @(posedge dut.idcode_version_i[1]) if (up_run) up_rise[10] = up_rise[10] + 1;
always @(negedge dut.idcode_version_i[1]) if (up_run) up_fall[10] = up_fall[10] + 1;
always @(posedge dut.idcode_version_i[2]) if (up_run) up_rise[11] = up_rise[11] + 1;
always @(negedge dut.idcode_version_i[2]) if (up_run) up_fall[11] = up_fall[11] + 1;
always @(posedge dut.idcode_version_i[3]) if (up_run) up_rise[12] = up_rise[12] + 1;
always @(negedge dut.idcode_version_i[3]) if (up_run) up_fall[12] = up_fall[12] + 1;
always @(posedge tck)       if (up_run) up_rise[13] = up_rise[13] + 1;
always @(negedge tck)       if (up_run) up_fall[13] = up_fall[13] + 1;

// Event-driven: a sub-cycle glitch on an unselected output is caught too.
always @(ties_ok)
   if (up_run && (ties_ok !== 1'b1)) begin
      $display("ERROR: unselected output left idle during noise  %0t ns", $time);
      error = error + 1;
   end

//----------------------------------------------------------------------------
// dbg_wakeup_o
//----------------------------------------------------------------------------
reg up_wk_chk;
initial up_wk_chk = 1'b0;

`ifdef DTM_UART
  `define UP_SERIAL
`elsif DTM_I2C
  `define UP_SERIAL
`endif

`ifdef UP_SERIAL
always @(dbg_wakeup)
   if (dbgresetn === 1'b1) begin
      $display("ERROR: dbg_wakeup_o moved in a serial build (%b)  %0t ns", dbg_wakeup, $time);
      error = error + 1;
   end
`else
`ifdef DTM_CJTAG
wire up_probe = tckc;
`else
wire up_probe = tck;
`endif
time up_probe_t;
reg  up_wk_prev;
initial up_probe_t = 0;
always @(posedge up_probe) begin
   up_probe_t = $time;
   if (up_wk_chk) begin
      up_wk_prev = dbg_wakeup;
      #2;
      if (up_wk_chk && (dbg_wakeup === up_wk_prev)) begin
         $display("ERROR: dbg_wakeup_o did not toggle on a probe-clock rise  %0t ns", $time);
         error = error + 1;
      end
   end
end
always @(dbg_wakeup)
   if (up_wk_chk && ($time - up_probe_t > 2)) begin
      $display("ERROR: dbg_wakeup_o moved away from a probe-clock rise  %0t ns", $time);
      error = error + 1;
   end
`endif

//----------------------------------------------------------------------------
// Noise
//----------------------------------------------------------------------------
task up_toggle;
   input integer idx;
   begin
      case (idx)
         0:  tms       = ~tms;
         1:  tdi       = ~tdi;
         2:  trst_n    = ~trst_n;
         3:  tckc      = ~tckc;
         4:  host_tmsc = ~host_tmsc;
         5:  uart_rx   = ~uart_rx;
         6:  m_scl_pd  = ~m_scl_pd;
         7:  m_sda_pd  = ~m_sda_pd;
         8:  scan_mode = ~scan_mode;
         13: up_tck    = ~up_tck;
         default: up_idv[idx-9] = ~up_idv[idx-9];
      endcase
   end
endtask

task up_check_min;
   integer k;
   begin
      up_min_met = 1'b1;
      for (k = 0; k < UP_NPIN; k = k + 1)
         if (up_act[k] && ((up_rise[k] + up_fall[k] < UP_MIN) || (up_rise[k] == 0) || (up_fall[k] == 0)))
            up_min_met = 1'b0;
   end
endtask

initial
   begin : noise
      integer idx;
      integer gap;
      wait (up_run === 1'b1);
      while (up_run) begin
         gap = 3 + ({$random(up_seed)} % 58);
         #(gap);
         idx = {$random(up_seed)} % UP_NPIN;
         if (up_act[idx]) up_toggle(idx);
         up_check_min;
      end
      up_noise_done = 1'b1;
   end

//----------------------------------------------------------------------------
// DMI traffic
//----------------------------------------------------------------------------
task up_round;
   input integer r;
   input integer quiet;
   reg [31:0] wd;
   reg [31:0] rd;
   reg  [1:0] st;
   reg  [6:0] a;
   reg  [7:0] rb;
   reg  [7:0] kb;
   integer    k;
   integer    p0;
   begin
      p0 = up_psel;
      rb = r;
      for (k = 0; k < 3; k = k + 1) begin
         kb = k;
         a  = 7'h08 + ((r * 3 + k) % 100);
         wd = {rb, 8'h5A ^ kb, 8'hC3, 1'b0, a} ^ (quiet ? 32'hFFFF_0000 : 32'h0);
         dtm_dmi_write(a, wd, st);
         check_eq("wr_st", st, OP_SUCCESS);
         dtm_dmi_read(a, rd, st);
         check_eq("rd_st",   st, OP_SUCCESS);
         check_eq("rd_data", rd, wd);
         check_eq("slave_word", slave_mem[a], wd);
      end
      dtm_settle(4);
      repeat (20) @(posedge free_clk);
      check_eq("round_psel", up_psel - p0, 6);
   end
endtask

initial
   begin : test
      integer r;
      integer k;

      dtm_init;
      slave_latency = 1;
      repeat (20) @(posedge free_clk);

`ifdef UP_SERIAL
      force dut.idcode_version_i = up_idv;
`endif
      if (up_act[13]) force tck = up_tck;
      up_wk_chk = 1'b1;
      up_run    = 1'b1;

      r = 0;
      while ((r == 0) || !up_min_met) begin
         $display("----- noisy round %0d -----", r);
         up_round(r, 0);
         r = r + 1;
      end
      up_run = 1'b0;
      wait (up_noise_done === 1'b1);

      for (k = 0; k < UP_NPIN; k = k + 1)
         if (up_act[k]) begin
            $display("INFO:  pin %0d: %0d rises, %0d falls", k, up_rise[k], up_fall[k]);
            if ((up_rise[k] + up_fall[k] < UP_MIN) || (up_rise[k] == 0) || (up_fall[k] == 0)) begin
               $display("ERROR: pin %0d toggled too little (%0d rises, %0d falls)", k, up_rise[k], up_fall[k]);
               error = error + 1;
            end
         end

      // Park the toggled pins at the bench's idle levels.
      if (up_act[0]) tms       = 1'b1;
      if (up_act[1]) tdi       = 1'b0;
      if (up_act[2]) trst_n    = 1'b1;
      if (up_act[3]) tckc      = 1'b0;
      if (up_act[4]) host_tmsc = 1'b1;
      if (up_act[5]) uart_rx   = 1'b1;
      if (up_act[6]) m_scl_pd  = 1'b0;
      if (up_act[7]) m_sda_pd  = 1'b0;
      if (up_act[8]) scan_mode = 1'b0;
      if (up_act[13]) release tck;
`ifdef UP_SERIAL
      up_idv = DUT_IDVER;
      release dut.idcode_version_i;
`endif
      repeat (40) @(posedge free_clk);

      $display("----- quiet round -----");
      up_round(r, 1);
      up_wk_chk = 1'b0;

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
