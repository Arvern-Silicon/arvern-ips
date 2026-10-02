//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    midrun_reset
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : midrun_reset.v
// Module Description : hresetn asserted in the middle of traffic, then
//                      released. All variants, asynchronous and synchronous
//                      reset (SIM_EXTRA_DEFINES="-D ASYNC_RST_EN=0").
//
// The test drives the bench's hresetn itself. At assertion every manager is
// forced to IDLE (the AHB rule for managers in reset); the bench tasks still
// in flight complete once the fabric returns hready = 1 in reset, and no
// read check is enqueued for an interrupted transfer. Each subordinate gets a
// fixed 6-cycle wait state from its bench inserter so a data phase can be
// caught stalled.
//
//   S1  reset while M1's data phase on periph0 is stalled and M2's address
//       phase is cached behind it; generic: M0's SRAM write also cached (it
//       must never reach the SRAM); hiperf: M0's ROM data phase stalled on
//       the executable side; fused: M0 streaming SRAM reads.
//   S2  generic: reset during a stalled SRAM write with M0 / M2 cached;
//       hiperf: reset while M1's read waits in the ROM's level-2 channel
//       behind M0's stalled data phase; fused: reset in the cycle a Port-B
//       write parked by a Port-A read is written to the macro (detected on
//       the macro pins, retried until seen).
//   S3  reset in the first cycle of a default-subordinate ERROR.
//
// Each scenario's state is checked just before reset is asserted. After
// release the bus must be idle for 10 cycles (every manager hready = 1 and
// hresp = 0, no request, s_htrans IDLE, no cached address phase, fused: no
// SRAM macro write), then every manager runs fresh traffic, all checked.
// hclk_en during the idle window is reported, not checked.
//
// Basis (quoted)
//  IHI0033C 7.1.2: "The reset can be asserted asynchronously, but is
//    deasserted synchronously after the rising edge of HCLK." "During reset
//    all Managers must ensure the address and control signals are at valid
//    levels and that HTRANS[1:0] indicates IDLE." "During reset all
//    Subordinates must ensure that HREADYOUT is HIGH."
//  ahb_interconnect.md, Parameters: "ASYNC_RST_EN | 1 | 1: asynchronous
//    active-low reset; 0: synchronous reset (the clock must run while reset
//    is asserted)."
//  ahb_interconnect.md, Integration requirements: "Its de-assertion must be
//    synchronised to hclk_i by the integrator"
//  ahb_interconnect.md, Generic fabric: "Its state is the address-phase
//    caches and the phase-tracking flops of ahb_manager_if, the data-phase
//    select of ahb_subordinate_mux and the default subordinate's two-cycle
//    ERROR; hiperf adds the executable-side arbiters' priority bits, fused
//    the controllers' state machines."
//  ahb_interconnect.md, hready wiring: "m_hready_o[k] = dph_ongoing ?
//    hreadyout : aph_pending ? 0 : 1"
//  ahb_interconnect.md, Ports: "s_htrans_o ... forced to IDLE while no
//    granted address phase is on the bus"; "m_request_o | Request to the
//    external arbiter"
//  ahb_interconnect.md, Fused fabric: "A Port-B write whose data phase
//    collides with a read on either port ... is held in a one-word buffer
//    and written to the macro in the very next cycle, during which neither
//    port is granted."
//  ahb_interconnect.md, Integration requirements: "hclk_en_o is a
//    combinational enable that is high whenever the fabric has work in
//    flight" (reported only: "whenever" does not say low otherwise).
//----------------------------------------------------------------------------

localparam [31:0] MR_ROM   = 32'h00400000;
localparam [31:0] MR_SRAM  = 32'h00401000;
localparam [31:0] MR_P0    = 32'h00402000;
localparam [31:0] MR_P1    = 32'h00403000;
localparam [31:0] MR_UNMAP = 32'h00800000;
localparam        MR_W0    = 8;                 // SRAM word of generic M0's cached write

reg        mr_rst;
reg        mr_hit;
reg        mr_m1_done;
integer    mr_iter;
integer    mr_k0;
integer    mr_k1;
integer    mr_c;
integer    mr_en_cnt;
integer    mr_hitw;


//----------------------------------------------------------------------------
// Manager-side response recorder (see sideband_hsmode.v), plus the kind of
// the last completed transfer.
//----------------------------------------------------------------------------
reg        rc_out     [0:2];
reg        rc_err1    [0:2];
reg        rc_cwr     [0:2];
reg        rc_csram   [0:2];
reg        rc_lwr     [0:2];
reg        rc_lsram   [0:2];
reg [63:0] rc_lt      [0:2];
integer    rc_n       [0:2];
integer    rc_errs    [0:2];
reg        rc_resp    [0:767];
reg [31:0] rc_data    [0:767];
integer    rc_k;

initial
   begin
      for (rc_k = 0; rc_k < 3; rc_k = rc_k + 1)
         begin
            rc_out[rc_k]   = 1'b0;
            rc_err1[rc_k]  = 1'b0;
            rc_cwr[rc_k]   = 1'b0;
            rc_csram[rc_k] = 1'b0;
            rc_lwr[rc_k]   = 1'b0;
            rc_lsram[rc_k] = 1'b0;
            rc_lt[rc_k]    = 0;
            rc_n[rc_k]     = 0;
            rc_errs[rc_k]  = 0;
         end
      mr_rst     = 1'b0;
      mr_hit     = 1'b0;
      mr_m1_done = 1'b0;
      mr_iter    = 0;
   end

task rc_sample;
   input integer m;
   input         aph;
   input         wr;
   input  [31:0] a;
   input         rdy;
   input         rsp;
   input  [31:0] rd;
   integer       idx;
   begin
      if (rc_out[m])
         begin
            if (!rdy)
               begin
                  if (rsp & rc_err1[m])
                     begin
                        $display("ERROR: M%0d ERROR response first cycle lasted more than one cycle %t", m, $time);
                        error = error + 1;
                     end
                  else if (!rsp & rc_err1[m])
                     begin
                        $display("ERROR: M%0d wait state after the first ERROR cycle %t", m, $time);
                        error = error + 1;
                     end
                  rc_err1[m] = rsp;
               end
            else
               begin
                  idx          = m*256 + (rc_n[m] % 256);
                  rc_resp[idx] = rsp;
                  rc_data[idx] = rd;
                  if (rsp & ~rc_err1[m])
                     begin
                        $display("ERROR: M%0d ERROR completed without its first (hready=0) cycle %t", m, $time);
                        error = error + 1;
                     end
                  if (~rsp & rc_err1[m])
                     begin
                        $display("ERROR: M%0d first ERROR cycle followed by OKAY %t", m, $time);
                        error = error + 1;
                     end
                  if (rsp) rc_errs[m] = rc_errs[m] + 1;
                  rc_lwr[m]   = rc_cwr[m];
                  rc_lsram[m] = rc_csram[m];
                  rc_lt[m]    = $time;
                  rc_n[m]     = rc_n[m] + 1;
                  rc_out[m]   = 1'b0;
                  rc_err1[m]  = 1'b0;
               end
         end
      if (aph & rdy)
         begin
            rc_out[m]   = 1'b1;
            rc_cwr[m]   = wr;
            rc_csram[m] = (a >= MR_SRAM) && (a < MR_SRAM + 32'h800);
         end
   end
endtask

always @(posedge free_clk)
   if (!hresetn)
      begin
         for (rc_k = 0; rc_k < 3; rc_k = rc_k + 1)
            begin
               rc_out[rc_k]  = 1'b0;
               rc_err1[rc_k] = 1'b0;
            end
      end
   else if (tb_rst_done)
      begin
         rc_sample(0, m0_htrans_d[1], m0_hwrite_d, m0_haddr_d, m0_hready, m0_hresp, m0_hrdata);
         rc_sample(1, m1_htrans_d[1], m1_hwrite_d, m1_haddr_d, m1_hready, m1_hresp, m1_hrdata);
         rc_sample(2, m2_htrans_d[1], m2_hwrite_d, m2_haddr_d, m2_hready, m2_hresp, m2_hrdata);
      end

task rc_expect;
   input integer    m;
   input integer    n;
   input            exp_resp;
   input [8*48-1:0] what;
   integer          idx;
   begin
      idx = m*256 + (n % 256);
      if (rc_n[m] <= n)
         begin
            $display("ERROR: M%0d %0s -- transfer never completed %t", m, what, $time);
            error = error + 1;
         end
      else if (rc_resp[idx] !== exp_resp)
         begin
            $display("ERROR: M%0d %0s -- response %0s, expected %0s %t", m, what,
                     rc_resp[idx] ? "ERROR" : "OKAY", exp_resp ? "ERROR" : "OKAY", $time);
            error = error + 1;
         end
      else
         $display("PASS:  M%0d %0s -- %0s", m, what, exp_resp ? "ERROR" : "OKAY");
   end
endtask


//----------------------------------------------------------------------------
// Cached address phases (names used by arbiter_stress.v)
//----------------------------------------------------------------------------
wire mr_m0_pend;
wire mr_m1_pend;
wire mr_m2_pend;
`ifdef FUSED
assign mr_m0_pend = 1'b0;
assign mr_m1_pend = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_aph_pending;
assign mr_m2_pend = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_aph_pending;
`elsif HIPERF
assign mr_m0_pend = 1'b0;
assign mr_m1_pend = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_aph_pending;
assign mr_m2_pend = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_aph_pending;
`else
assign mr_m0_pend = dut.ahb_manager_mux_inst.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_aph_pending;
assign mr_m1_pend = dut.ahb_manager_mux_inst.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_aph_pending;
assign mr_m2_pend = dut.ahb_manager_mux_inst.AHB_MANAGER_IF[2].ahb_manager_if_inst.m_aph_pending;
`endif


//----------------------------------------------------------------------------
// Reset control and checks
//----------------------------------------------------------------------------
task mr_scenario_fail;
   input [8*56-1:0] what;
   begin
      $display("ERROR: scenario not reached before reset: %0s %t", what, $time);
      error = error + 1;
   end
endtask

// Called mid-cycle
task mr_assert;
   begin
      hresetn = 1'b0;
      force m0_htrans = 2'b00;
      force m1_htrans = 2'b00;
      force m2_htrans = 2'b00;
      mr_rst = 1'b1;
      $display("INFO:  hresetn asserted %t", $time);
   end
endtask

// Called once every traffic thread has returned
task mr_release;
   begin
      repeat(2) @(posedge free_clk);
      if ((m0_hready !== 1'b1) || (m1_hready !== 1'b1) || (m2_hready !== 1'b1))
         begin
            $display("ERROR: manager hready not high during reset (M0 %b M1 %b M2 %b) %t", m0_hready, m1_hready, m2_hready, $time);
            error = error + 1;
         end
      release m0_htrans;
      release m1_htrans;
      release m2_htrans;
      m0_htrans = 2'b00;  m0_haddr = 32'h0;  m0_hwrite = 1'b0;  m0_hsize = 3'b000;
      m1_htrans = 2'b00;  m1_haddr = 32'h0;  m1_hwrite = 1'b0;  m1_hsize = 3'b000;
      m2_htrans = 2'b00;  m2_haddr = 32'h0;  m2_hwrite = 1'b0;  m2_hsize = 3'b000;
      repeat(2) @(posedge free_clk);
      #11;
      hresetn = 1'b1;
      mr_rst  = 1'b0;
      $display("INFO:  hresetn released %t", $time);
   end
endtask

// The bus must come out of reset idle
task mr_check_idle;
   begin
      mr_en_cnt = 0;
      for (mr_c = 0; mr_c < 10; mr_c = mr_c + 1)
         begin
            @(posedge free_clk);
            if ((m0_hready !== 1'b1) || (m1_hready !== 1'b1) || (m2_hready !== 1'b1))
               begin
                  $display("ERROR: after reset: manager hready low with no transfer (M0 %b M1 %b M2 %b) %t", m0_hready, m1_hready, m2_hready, $time);
                  error = error + 1;
               end
            if ((m0_hresp !== 1'b0) || (m1_hresp !== 1'b0) || (m2_hresp !== 1'b0))
               begin
                  $display("ERROR: after reset: hresp high with no transfer %t", $time);
                  error = error + 1;
               end
            if (m_request !== 3'b000)
               begin
                  $display("ERROR: after reset: request %b with every manager IDLE %t", m_request, $time);
                  error = error + 1;
               end
            if ((mr_m0_pend !== 1'b0) || (mr_m1_pend !== 1'b0) || (mr_m2_pend !== 1'b0))
               begin
                  $display("ERROR: after reset: a cached address phase survived the reset %t", $time);
                  error = error + 1;
               end
`ifndef FUSED
            if ((s0_htrans !== 2'b00) || (s1_htrans !== 2'b00))
               begin
                  $display("ERROR: after reset: executable/ROM/SRAM subordinate sees htrans %b / %b %t", s0_htrans, s1_htrans, $time);
                  error = error + 1;
               end
`else
            if ((sram0_cen === 1'b0) && (sram0_wen !== 4'hF))
               begin
                  $display("ERROR: after reset: SRAM macro written with no transfer (wen %b) %t", sram0_wen, $time);
                  error = error + 1;
               end
`endif
            if ((s2_htrans !== 2'b00) || (s3_htrans !== 2'b00))
               begin
                  $display("ERROR: after reset: peripheral sees htrans %b / %b %t", s2_htrans, s3_htrans, $time);
                  error = error + 1;
               end
            if (dut_hclk_en === 1'b1) mr_en_cnt = mr_en_cnt + 1;
         end
      $display("INFO:  after reset: idle window checked; hclk_en high in %0d of 10 idle cycles", mr_en_cnt);
   end
endtask

// Fresh traffic from every manager, all checked
task mr_recover;
   integer n0;
   integer n1;
   integer n2;
   integer e0;
   integer e1;
   integer e2;
   begin
      mr_iter = mr_iter + 1;
      n0 = rc_n[0];    n1 = rc_n[1];    n2 = rc_n[2];
      e0 = rc_errs[0]; e1 = rc_errs[1]; e2 = rc_errs[2];
      fork
         begin
`ifdef FUSED
            ahb_read (0, 0, MR_ROM  + 32'h020, rom_inst0.mem[8],    2, 1);
            ahb_read (0, 0, MR_SRAM + 32'h300, sram_inst0.mem[192], 2, 1);
            ahb_read (0, 1, MR_ROM  + 32'h024, rom_inst0.mem[9],    2, 1);
`else
            ahb_write(0, 0, MR_SRAM + 32'h040, 32'h0A000000 + mr_iter, 2);
            ahb_read (0, 0, MR_SRAM + 32'h040, 32'h0A000000 + mr_iter, 2, 1);
            ahb_read (0, 1, MR_ROM  + 32'h020, rom_inst0.mem[8],       2, 1);
`endif
         end
         begin
            ahb_write(1, 0, MR_SRAM  + 32'h100, 32'h1A000000 + mr_iter, 2);
            ahb_read (1, 0, MR_SRAM  + 32'h100, 32'h1A000000 + mr_iter, 2, 1);
            ahb_write(1, 0, MR_P0    + 32'h004, 32'h1B000000 + mr_iter, 2);
            ahb_read (1, 0, MR_P0    + 32'h004, 32'h1B000000 + mr_iter, 2, 1);
            ahb_read (1, 0, MR_ROM   + 32'h028, rom_inst0.mem[10],      2, 1);
            ahb_read (1, 1, MR_UNMAP + 32'h010, 32'h00000000,           2, 1);
         end
         begin
            ahb_write(2, 0, MR_SRAM  + 32'h200, 32'h2A000000 + mr_iter, 2);
            ahb_read (2, 0, MR_SRAM  + 32'h200, 32'h2A000000 + mr_iter, 2, 1);
            ahb_write(2, 0, MR_P1    + 32'h008, 32'h2B000000 + mr_iter, 2);
            ahb_read (2, 0, MR_P1    + 32'h008, 32'h2B000000 + mr_iter, 2, 1);
            ahb_read (2, 1, MR_ROM   + 32'h02C, rom_inst0.mem[11],      2, 1);
         end
      join
      repeat(10) @(posedge free_clk);
      if (((rc_n[0] - n0) != 3) || ((rc_n[1] - n1) != 6) || ((rc_n[2] - n2) != 5))
         begin
            $display("ERROR: after reset: completed M0 %0d/3, M1 %0d/6, M2 %0d/5 transfers", rc_n[0] - n0, rc_n[1] - n1, rc_n[2] - n2);
            error = error + 1;
         end
      if ((rc_errs[0] != e0) || (rc_errs[2] != e2) || (rc_errs[1] != (e1 + 1)))
         begin
            $display("ERROR: after reset: unexpected ERROR count (M0 +%0d, M1 +%0d (1 expected), M2 +%0d)",
                     rc_errs[0] - e0, rc_errs[1] - e1, rc_errs[2] - e2);
            error = error + 1;
         end
      rc_expect(1, n1 + 5, 1'b1, "unmapped read after reset               ");
      check_mem_value(64,  32'h1A000000 + mr_iter);
      check_mem_value(128, 32'h2A000000 + mr_iter);
   end
endtask

// Wait (sampling after the recorder) until manager m has an accepted transfer
task mr_wait_accepted;
   input integer m;
   begin
      @(posedge free_clk);
      #1;
      while (rc_out[m] !== 1'b1)
         begin
            @(posedge free_clk);
            #1;
         end
   end
endtask


//----------------------------------------------------------------------------
// Stimulus
//----------------------------------------------------------------------------
initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(10) @(posedge free_clk);

      $display("");
      $display(" =====================================================");
`ifdef FUSED
      $display("|  MID-RUN RESET -- FUSED                             |");
`elsif HIPERF
      $display("|  MID-RUN RESET -- HIPERF                            |");
`else
      $display("|  MID-RUN RESET -- GENERIC                           |");
`endif
      $display("|  ASYNC_RST_EN = %0d                                   |", ASYNC_RST_EN);
      $display(" =====================================================");

      for (tb_idx = 0; tb_idx < MEM_SIZE/4; tb_idx = tb_idx + 1)
         begin
            rom_inst0.mem[tb_idx]  = 32'hA0000000 + (tb_idx * 32'h00010001);
            sram_inst0.mem[tb_idx] = 32'h5E000000 + tb_idx;
         end

      @(negedge free_clk);
      force   ahb_periph_example_inst0.hresetn_i = 1'b0;
      force   ahb_periph_example_inst1.hresetn_i = 1'b0;
      @(negedge free_clk);
      release ahb_periph_example_inst0.hresetn_i;
      release ahb_periph_example_inst1.hresetn_i;
      repeat(10) @(posedge free_clk);

      // Fixed 6-cycle wait states on every inserter; one access each loads
      // the new count (an inserter takes it at the address phase before).
      s0_number_wait_states = 6;  s0_random_wait_states_en = 1'b0;
      s1_number_wait_states = 6;  s1_random_wait_states_en = 1'b0;
      s2_number_wait_states = 6;  s2_random_wait_states_en = 1'b0;
      s3_number_wait_states = 6;  s3_random_wait_states_en = 1'b0;
      ahb_read(1, 1, MR_P0   + 32'h1C, 32'h0, 2, 0);
      ahb_read(1, 1, MR_P1   + 32'h1C, 32'h0, 2, 0);
`ifndef FUSED
      ahb_read(0, 1, MR_ROM  + 32'h3C, 32'h0, 2, 0);
      ahb_read(1, 1, MR_SRAM + 32'h7FC, 32'h0, 2, 0);
`endif
      repeat(5) @(posedge free_clk);

      //==================================================================
      // S1: stalled data phase + cached address phase(s)
      //==================================================================
      $display("");
      $display("S1: reset during a stalled data phase with cached address phases");
      mr_rst = 1'b0;
      fork
         begin
            fork
               ahb_read(1, 1, MR_P0 + 32'h00, 32'h0, 2, 0);                   // M1: 6 wait states on periph0
               begin
                  @(posedge free_clk);
                  ahb_read(2, 1, MR_P1 + 32'h04, 32'h0, 2, 0);                // M2: behind M1
               end
`ifdef FUSED
               begin
                  mr_k0 = 0;
                  while (!mr_rst)
                     begin
                        ahb_read(0, 0, MR_SRAM + 32'h300 + 4*(mr_k0 % 8), 32'h0, 2, 0);
                        mr_k0 = mr_k0 + 1;
                     end
               end
`elsif HIPERF
               ahb_read(0, 1, MR_ROM + 32'h40, 32'h0, 2, 0);                  // M0: 6 wait states on the ROM
`else
               begin
                  @(posedge free_clk);
                  ahb_write(0, 1, MR_SRAM + 4*MR_W0, 32'hBADC0DE0, 2);        // M0: behind M1 on the shared bus
               end
`endif
            join
         end
         begin
            mr_wait_accepted(1);
            repeat(3) @(posedge free_clk);
            #11;
            if (m1_hready !== 1'b0)   mr_scenario_fail("S1: M1 data phase not stalled");
            if (mr_m2_pend !== 1'b1)  mr_scenario_fail("S1: M2 address phase not cached");
`ifdef HIPERF
            if (m0_hready !== 1'b0)   mr_scenario_fail("S1: M0 data phase on the ROM not stalled");
`elsif FUSED
`else
            if (mr_m0_pend !== 1'b1)  mr_scenario_fail("S1: M0 address phase not cached");
`endif
            mr_assert;
         end
      join
      mr_release;
      mr_check_idle;
`ifdef GENERIC
      check_mem_value(MR_W0, 32'h5E000000 + MR_W0);                  // the cached write was dropped
`endif
      mr_recover;

      //==================================================================
      // S2
      //==================================================================
      $display("");
      mr_rst = 1'b0;
`ifdef FUSED
      $display("S2: reset while a parked Port-B write is written to the macro");
      mr_hit     = 1'b0;
      mr_m1_done = 1'b0;
      mr_hitw    = -1;
      fork
         begin
            mr_k0 = 0;
            while (!mr_rst)
               begin
                  ahb_read(0, 0, MR_SRAM + 32'h300 + 4*(mr_k0 % 8), 32'h0, 2, 0);   // Port A: continuous reads
                  mr_k0 = mr_k0 + 1;
               end
         end
         begin
            repeat(3) @(posedge free_clk);
            mr_k1 = 0;
            while ((mr_k1 < 8) && !mr_rst)
               begin
                  mr_hitw = 80 + mr_k1;
                  ahb_write(1, 0, MR_SRAM + 4*mr_hitw, 32'hB0B00000 + mr_k1, 2);    // Port B: one write
                  repeat(4) @(posedge free_clk);
                  mr_k1 = mr_k1 + 1;
               end
            mr_m1_done = 1'b1;
         end
         begin
            while (!mr_hit && !mr_m1_done)
               begin
                  @(posedge free_clk);
                  #5;
                  // The cycle after M1's write data phase: a macro write here
                  // is the parked write (neither port is granted in it).
                  if ((rc_lt[1] == ($time - 5)) && rc_lwr[1] && rc_lsram[1] &&
                      (sram0_cen === 1'b0) && (sram0_wen !== 4'hF))
                     begin
                        mr_hit = 1'b1;
                        $display("INFO:  parked write of SRAM word %0d on the macro pins", mr_hitw);
                     end
               end
            if (!mr_hit) mr_scenario_fail("S2: no Port-B write was parked by a Port-A read");
            mr_assert;
         end
      join
      mr_release;
      mr_check_idle;
      mr_recover;
      // The interrupted word: whatever reset left in it, a new write wins
      if (mr_hitw >= 0)
         begin
            ahb_write(1, 1, MR_SRAM + 4*mr_hitw, 32'hC0FFEE00 + mr_hitw, 2);
            ahb_read (0, 1, MR_SRAM + 4*mr_hitw, 32'hC0FFEE00 + mr_hitw, 2, 1);
            ahb_read (1, 1, MR_SRAM + 4*mr_hitw, 32'hC0FFEE00 + mr_hitw, 2, 1);
            repeat(5) @(posedge free_clk);
            check_mem_value(mr_hitw, 32'hC0FFEE00 + mr_hitw);
         end
`elsif HIPERF
      $display("S2: reset while M1 waits in the ROM's level-2 channel behind M0");
      fork
         begin
            fork
               ahb_read(0, 1, MR_ROM + 32'h80, 32'h0, 2, 0);                  // M0: 6 wait states on the ROM
               begin
                  @(posedge free_clk);
                  ahb_read(1, 1, MR_ROM + 32'h84, 32'h0, 2, 0);               // M1: same ROM, level-2 channel
               end
            join
         end
         begin
            mr_wait_accepted(0);
            repeat(3) @(posedge free_clk);
            #11;
            if (m0_hready !== 1'b0)       mr_scenario_fail("S2: M0 data phase on the ROM not stalled");
            if (m1_hready !== 1'b0)       mr_scenario_fail("S2: M1 not waiting");
            if (dph_owners_x0 !== 2'b01)  mr_scenario_fail("S2: ROM data phase not owned by m_x alone");
            mr_assert;
         end
      join
      mr_release;
      mr_check_idle;
      mr_recover;
`else
      $display("S2: reset during a stalled SRAM write, M0 and M2 cached");
      fork
         begin
            fork
               ahb_write(1, 1, MR_SRAM + 32'h180, 32'h5A5AA5A5, 2);           // M1: 6 wait states on the SRAM
               begin
                  @(posedge free_clk);
                  ahb_write(2, 1, MR_P0 + 32'h08, 32'h22222222, 2);           // M2: behind M1
               end
               begin
                  @(posedge free_clk);
                  ahb_read(0, 1, MR_ROM + 32'h80, 32'h0, 2, 0);               // M0: behind M1
               end
            join
         end
         begin
            mr_wait_accepted(1);
            repeat(2) @(posedge free_clk);
            #11;
            if (m1_hready !== 1'b0)   mr_scenario_fail("S2: M1 write data phase not stalled");
            if (mr_m2_pend !== 1'b1)  mr_scenario_fail("S2: M2 address phase not cached");
            if (mr_m0_pend !== 1'b1)  mr_scenario_fail("S2: M0 address phase not cached");
            mr_assert;
         end
      join
      mr_release;
      mr_check_idle;
      mr_recover;
`endif

      //==================================================================
      // S3: reset in the first cycle of a default-subordinate ERROR
      //==================================================================
      $display("");
      $display("S3: reset in the first ERROR cycle of the default subordinate");
      mr_rst = 1'b0;
      fork
         ahb_read(1, 1, MR_UNMAP, 32'h0, 2, 0);
         begin
            @(posedge m1_hresp_dut);
            #5;
            if ((m1_hresp_dut !== 1'b1) || (m1_hready_dut !== 1'b0))
               mr_scenario_fail("S3: M1 not in the first ERROR cycle");
            mr_assert;
         end
      join
      mr_release;
      mr_check_idle;
      mr_recover;

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
