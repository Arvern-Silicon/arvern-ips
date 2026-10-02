//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    fused_rom_contest
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : fused_rom_contest.v
// Module Description : Port-A / Port-B contention on the fused ROM controller
//                      at fabric level. Fused only (round-robin and
//                      -fixed_b_prio); other variants skip.
//
// 1. Directed contests on the ROM, which nothing has accessed since reset:
//    M0 (Port A) and M1 (Port B) read the ROM starting at the same edge; the
//    port whose read completes first won. Every read's data is checked.
//      FIXED_B_PRIO = 0      C1 -> A (reset), C2 -> B (lost C1),
//                            lone A, lone A, C3 -> A (lost C2),
//                            lone B, C4 -> B (lost C3)
//      FIXED_B_PRIO = 1      C1..C4 -> B
//    C3/C4 rest on the reading that the ROM controller's priority moves on
//    contests only: the doc calls out the SRAM controller as the one whose
//    bit "also advances on uncontested grants". The lone accesses are placed
//    so that a bit that moved on every grant would pick the other port.
// 2. Stream: M0 streams ROM reads, M1 and M2 stream ROM reads through Port B
//    at the same time, M2 interleaving peripheral accesses (random wait
//    states with -random_ws); M1 and M2 each issue one ROM write, which must
//    be answered with the two-cycle ERROR while the others keep streaming.
//    Every read is checked; M0 must see no ERROR.
//
// Basis (quoted)
//  ahb_interconnect.md, Fused fabric: "When both present an address phase to
//    the same controller in the same cycle, the controller's arbiter serves
//    one and holds the other for one wait state. FIXED_B_PRIO selects the
//    policy: 0 (default) serves Port A first after reset and then gives each
//    contest to the port that lost the previous one (the SRAM controller's
//    priority bit also advances on uncontested grants, so the winner is not a
//    strict alternation); 1 always serves Port B"
//  ahb_interconnect.md, Parameters: "FIXED_B_PRIO | 0 | Arbitration inside
//    the fused controllers: 0 the port that lost the previous contest wins
//    the next (Port A first after reset), 1 Port B (data) always wins."
//  ahb_interconnect.md, Fused fabric: "Port B ... on the ROM controller a
//    write is answered with the two-cycle ERROR."; "Sources of hresp = 1 |
//    ... Both default subordinates and the ROM controller on a Port-B write"
//  ahb_interconnect.md: "the fused ROM controller ignores hsize altogether on
//    both ports and returns the full word."
//  IHI0033C 5.1.3: "the ERROR response requires two cycles"
//----------------------------------------------------------------------------

localparam [31:0] FR_ROM = 32'h00400000;
localparam [31:0] FR_P1  = 32'h00403000;

integer    fr_i;
integer    fr_s0;
integer    fr_s1;
integer    fr_s2;
integer    fr_n0;
integer    fr_n1;
integer    fr_n2;
integer    fr_w1;
integer    fr_w2;
integer    fr_e0;
reg [63:0] fr_ta;
reg [63:0] fr_tb;


//----------------------------------------------------------------------------
// Manager-side response recorder (see sideband_hsmode.v)
//----------------------------------------------------------------------------
reg        rc_out  [0:2];
reg        rc_err1 [0:2];
integer    rc_n    [0:2];
integer    rc_errs [0:2];
reg        rc_resp [0:767];
reg [31:0] rc_data [0:767];
integer    rc_k;

initial
   for (rc_k = 0; rc_k < 3; rc_k = rc_k + 1)
      begin
         rc_out[rc_k]  = 1'b0;
         rc_err1[rc_k] = 1'b0;
         rc_n[rc_k]    = 0;
         rc_errs[rc_k] = 0;
      end

task rc_sample;
   input integer m;
   input         aph;
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
                  rc_n[m]    = rc_n[m] + 1;
                  rc_out[m]  = 1'b0;
                  rc_err1[m] = 1'b0;
               end
         end
      if (aph & rdy) rc_out[m] = 1'b1;
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
         rc_sample(0, m0_htrans_d[1], m0_hready, m0_hresp, m0_hrdata);
         rc_sample(1, m1_htrans_d[1], m1_hready, m1_hresp, m1_hrdata);
         rc_sample(2, m2_htrans_d[1], m2_hready, m2_hresp, m2_hrdata);
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
// Helpers
//----------------------------------------------------------------------------
task fr_lone;
   input integer m;
   input  [31:0] a;
   begin
      ahb_read(m, 1, a, rom_inst0.mem[(a - FR_ROM) >> 2], 2, 1);
      repeat(10) @(posedge free_clk);
   end
endtask

// Contest on the ROM: M0 (Port A) reads aa, M1 (Port B) reads ab, same edge.
task fr_contest;
   input     [31:0] aa;
   input     [31:0] ab;
   input            exp_b_first;
   input [8*40-1:0] what;
   begin
      fr_ta = 0;
      fr_tb = 0;
      fork
         begin
            ahb_read(0, 1, aa, rom_inst0.mem[(aa - FR_ROM) >> 2], 2, 1);
            fr_ta = $time;
         end
         begin
            ahb_read(1, 1, ab, rom_inst0.mem[(ab - FR_ROM) >> 2], 2, 1);
            fr_tb = $time;
         end
      join
      if (fr_ta == fr_tb)
         begin
            $display("ERROR: %0s: Port A and Port B completed at the same edge -- no contest seen", what);
            error = error + 1;
         end
      else if ((fr_tb < fr_ta) != exp_b_first)
         begin
            $display("ERROR: %0s: Port %0s won, expected Port %0s (A done %0t, B done %0t)", what,
                     (fr_tb < fr_ta) ? "B" : "A", exp_b_first ? "B" : "A", fr_ta, fr_tb);
            error = error + 1;
         end
      else
         $display("PASS:  %0s: Port %0s won", what, exp_b_first ? "B" : "A");
      repeat(10) @(posedge free_clk);
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

`ifdef FUSED
      $display("");
      $display(" =====================================================");
`ifdef FUSED_FIXED_B_PRIO
      $display("|  FUSED ROM CONTESTS: FIXED PORT-B PRIORITY          |");
`else
      $display("|  FUSED ROM CONTESTS: ROUND-ROBIN                    |");
`endif
      $display(" =====================================================");

      for (tb_idx = 0; tb_idx < MEM_SIZE/4; tb_idx = tb_idx + 1)
         rom_inst0.mem[tb_idx]  = 32'hC0000000 + (tb_idx * 32'h00030007);
      for (tb_idx = 0; tb_idx < MEM_SIZE/4; tb_idx = tb_idx + 1)
         sram_inst0.mem[tb_idx] = 32'h00000000;

      @(negedge free_clk);
      force   ahb_periph_example_inst0.hresetn_i = 1'b0;
      force   ahb_periph_example_inst1.hresetn_i = 1'b0;
      @(negedge free_clk);
      release ahb_periph_example_inst0.hresetn_i;
      release ahb_periph_example_inst1.hresetn_i;
      repeat(10) @(posedge free_clk);

      //---------------------------------------------------------------
      // 1. Directed contests (ROM untouched since reset)
      //---------------------------------------------------------------
`ifdef FUSED_FIXED_B_PRIO
      fr_contest(FR_ROM + 32'h000, FR_ROM + 32'h100, 1'b1, "C1 first contest after reset           ");
      fr_contest(FR_ROM + 32'h004, FR_ROM + 32'h104, 1'b1, "C2 contest right after a contest       ");
      fr_lone(0, FR_ROM + 32'h008);
      fr_lone(0, FR_ROM + 32'h00C);
      fr_contest(FR_ROM + 32'h010, FR_ROM + 32'h110, 1'b1, "C3 two lone A, then contest            ");
      fr_lone(1, FR_ROM + 32'h114);
      fr_contest(FR_ROM + 32'h018, FR_ROM + 32'h118, 1'b1, "C4 lone B, then contest                ");
`else
      fr_contest(FR_ROM + 32'h000, FR_ROM + 32'h100, 1'b0, "C1 first contest after reset           ");
      fr_contest(FR_ROM + 32'h004, FR_ROM + 32'h104, 1'b1, "C2 A won C1, B lost it                 ");
      fr_lone(0, FR_ROM + 32'h008);
      fr_lone(0, FR_ROM + 32'h00C);
      fr_contest(FR_ROM + 32'h010, FR_ROM + 32'h110, 1'b0, "C3 A lost C2 (two lone A in between)   ");
      fr_lone(1, FR_ROM + 32'h114);
      fr_contest(FR_ROM + 32'h018, FR_ROM + 32'h118, 1'b1, "C4 B lost C3 (one lone B in between)   ");
`endif

      //---------------------------------------------------------------
      // 2. Stream: Port A and two Port-B managers on the ROM, with ROM
      //    writes from Port B
      //---------------------------------------------------------------
      $display("");
      $display("Stream: M0 (A), M1 and M2 (B) on the ROM, one ROM write each from M1 / M2");
      fr_n0 = rc_n[0];
      fr_n1 = rc_n[1];
      fr_n2 = rc_n[2];
      fr_e0 = rc_errs[0];
      fr_w1 = -1;
      fr_w2 = -1;
      fork
         begin                                                    // M0 -- Port A, 40 reads
            for (fr_s0 = 0; fr_s0 < 40; fr_s0 = fr_s0 + 1)
               ahb_read(0, 0, FR_ROM + 32'h200 + 4*fr_s0, rom_inst0.mem[128 + fr_s0], 2, 1);
         end
         begin                                                    // M1 -- Port B, 20 transfers
            for (fr_s1 = 0; fr_s1 < 20; fr_s1 = fr_s1 + 1)
               if (fr_s1 == 9)
                  begin
                     fr_w1 = fr_s1;
                     ahb_write(1, 0, FR_ROM + 32'h300 + 4*fr_s1, 32'hDEAD0001, 2);
                  end
               else
                  ahb_read(1, 0, FR_ROM + 32'h300 + 4*fr_s1 + (fr_s1 % 4), rom_inst0.mem[192 + fr_s1] >> (8*(fr_s1 % 4)), 0, 1);
         end
         begin                                                    // M2 -- Port B and periph1
            for (fr_s2 = 0; fr_s2 < 20; fr_s2 = fr_s2 + 1)
               begin
                  if (fr_s2 == 12)
                     begin
                        fr_w2 = 3*fr_s2;
                        ahb_write(2, 0, FR_ROM + 32'h400 + 4*fr_s2, 32'hDEAD0002, 2);
                     end
                  else
                     ahb_read(2, 0, FR_ROM + 32'h400 + 4*fr_s2, rom_inst0.mem[256 + fr_s2], 2, 1);
                  ahb_write(2, 0, FR_P1 + 4*(fr_s2 % 8), 32'h7E000000 + fr_s2, 2);
                  ahb_read (2, 0, FR_P1 + 4*(fr_s2 % 8), 32'h7E000000 + fr_s2, 2, 1);
               end
         end
      join
      repeat(30) @(posedge free_clk);

      if ((rc_n[0] - fr_n0) != 40)
         begin
            $display("ERROR: Port A completed %0d of 40 reads", rc_n[0] - fr_n0);
            error = error + 1;
         end
      if (rc_errs[0] != fr_e0)
         begin
            $display("ERROR: Port A received %0d ERROR responses", rc_errs[0] - fr_e0);
            error = error + 1;
         end
      rc_expect(1, fr_n1 + fr_w1, 1'b1, "Port-B ROM write in the stream          ");
      rc_expect(1, fr_n1 + fr_w1 + 1, 1'b0, "Port-B ROM read right after the write  ");
      rc_expect(2, fr_n2 + fr_w2, 1'b1, "Port-B ROM write in the stream          ");
      rc_expect(2, fr_n2 + fr_w2 + 1, 1'b0, "periph1 access right after the write   ");
      if ((rc_errs[1] + rc_errs[2]) != 2)
         begin
            $display("ERROR: %0d ERROR responses on Port B, expected 2 (the two ROM writes)", rc_errs[1] + rc_errs[2]);
            error = error + 1;
         end

      // Every port still reads the ROM afterwards
      fr_lone(0, FR_ROM + 32'h7FC);
      fr_lone(1, FR_ROM + 32'h7F8);
      fr_lone(2, FR_ROM + 32'h7F4);
`else
      tb_skip_finish("|   (fused_rom_contest runs on the FUSED fabric only)       |");
`endif

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
