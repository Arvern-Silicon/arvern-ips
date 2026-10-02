//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    hprot_sweep
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : hprot_sweep.v
// Module Description : All 16 hprot values x hsmode (hauser[0]) 0 / 1 from
//                      every manager, concurrently, to every subordinate the
//                      manager reaches. All variants.
//
// Phase A  Both peripherals opened to User (MDELEG = 0x100). Each manager
//          sweeps hprot 0..15 x hsmode 0..1 and, per value, issues pipelined
//          transfers: SRAM write + read back of its own word (fused M0: read
//          of a preloaded word; Port A is read-only), a ROM read, and a
//          peripheral access (M1: periph 0 REGOUT write + read, M2: periph 1,
//          M0 on generic: REGIN reads of both). Every transfer must be OKAY
//          with the expected data.
// Phase B  MDELEG back to Machine-only (0x10F). M1 / M2 (and M0 on generic)
//          sweep again against the peripherals: the peripheral admits a
//          transfer only for hprot[1] = 1 with hsmode = 0 and answers every
//          other one with a two-cycle ERROR, so the response itself shows the
//          pair the peripheral received. Refused writes store nothing.
//
// At every commit on s0..s3 (generic, hiperf) and s2 / s3 (fused) the
// committed haddr / hwrite / hprot / hauser must equal the issuing manager's
// next observable transfer (FIFO per manager, manager identified by
// hmaster[2:0]). The bench's sideband checker compares against the fixed
// per-manager hprot and is disabled for the whole test. Every hprot bit and
// hauser[0] of every manager port rises and falls.
//
// Basis (quoted)
//  ahb_interconnect.md, What differs: "hmaster / hprot / hauser / hmastlock on
//    the executable side | Forwarded | Forwarded to s_x_* | Not delivered to
//    the controllers"
//  ahb_interconnect.md, Monitors: "HAUSER / HPROT | At the same instant, the
//    sideband pair a subordinate sees is that of the granted manager."
//  ahb_interconnect.md, Glossary: "HAUSER | ... The aRVern peripherals use it
//    as the secure-mode signal hsmode; the fabric only forwards it."
//  ahb_interconnect.md, Bench structure: "Each manager carries a distinct
//    hprot (4'h2, 4'h3, 4'hA) with the same privilege bits"
//  ahb_periph_example.md: "hprot_i[1] (priv) | hsmode_i (smode) | Decoded
//    privilege"; "A transfer is admitted when its decoded privilege is
//    numerically greater than or equal to the relevant gate"; "WR_PRIV |
//    [1:0] ... 00 = User"; "RD_PRIV | [3:2]"; "RESP | [8] | If 1, a denied
//    access produces a 2-cycle AHB ERROR response"; "Denied, RESP = 1 |
//    Two-cycle ERROR; nothing stored; hrdata_o = 0".
//  IHI0033C 3.7: "HPROT[1] Privileged When asserted, this bit indicates the
//    transfer is a privileged access."
//----------------------------------------------------------------------------

localparam [31:0] HP_ROM   = 32'h00400000;
localparam [31:0] HP_SRAM  = 32'h00401000;
localparam [31:0] HP_P0    = 32'h00402000;
localparam [31:0] HP_P1    = 32'h00403000;

integer    hp_i;
integer    hp_j;
reg [31:0] hp_sram [0:511];
reg [31:0] hp_per  [0:31];


function integer hp_sub;
   input [31:0] a;
   begin
      if      ((a >= 32'h00400000) && (a < 32'h00400800)) hp_sub = 0;
      else if ((a >= 32'h00401000) && (a < 32'h00401800)) hp_sub = 1;
      else if ((a >= 32'h00402000) && (a < 32'h00402080)) hp_sub = 2;
      else if ((a >= 32'h00403000) && (a < 32'h00403080)) hp_sub = 3;
      else                                                 hp_sub = -1;
   end
endfunction

function hp_obs;
   input integer m;
   input integer s;
   begin
`ifdef FUSED
      hp_obs = (m != 0) && ((s == 2) || (s == 3));
`elsif HIPERF
      hp_obs = (s >= 0) && !((m == 0) && (s >= 2));
`else
      hp_obs = (s >= 0);
`endif
   end
endfunction


//----------------------------------------------------------------------------
// Manager-side response recorder (see sideband_hsmode.v)
//----------------------------------------------------------------------------
reg        rc_out  [0:2];
reg        rc_err1 [0:2];
integer    rc_n    [0:2];
reg        rc_resp [0:767];
reg [31:0] rc_data [0:767];
integer    rc_k;

initial
   for (rc_k = 0; rc_k < 3; rc_k = rc_k + 1)
      begin
         rc_out[rc_k]  = 1'b0;
         rc_err1[rc_k] = 1'b0;
         rc_n[rc_k]    = 0;
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


//----------------------------------------------------------------------------
// Expected completions per manager: {resp, check data, data}
//----------------------------------------------------------------------------
reg        ex_resp [0:767];
reg        ex_chk  [0:767];
reg [31:0] ex_data [0:767];
integer    ex_n    [0:2];
integer    ex_base [0:2];

initial
   for (hp_i = 0; hp_i < 3; hp_i = hp_i + 1)
      begin
         ex_n[hp_i]    = 0;
         ex_base[hp_i] = 0;
      end

task hp_expect;
   input integer m;
   input         resp;
   input         chk;
   input  [31:0] d;
   integer       idx;
   begin
      idx          = m*256 + (ex_n[m] % 256);
      ex_resp[idx] = resp;
      ex_chk[idx]  = chk;
      ex_data[idx] = d;
      ex_n[m]      = ex_n[m] + 1;
   end
endtask

// Every expected completion since the last call, against the recorder.
task hp_check;
   input [8*16-1:0] phase;
   integer          m;
   integer          j;
   integer          bad;
   integer          idx;
   begin
      for (m = 0; m < 3; m = m + 1)
         begin
            bad = 0;
            if (rc_n[m] != ex_n[m])
               begin
                  $display("ERROR: phase %0s: M%0d completed %0d transfers, %0d issued", phase, m, rc_n[m], ex_n[m]);
                  error = error + 1;
                  bad   = 1;
               end
            else
               for (j = ex_base[m]; j < ex_n[m]; j = j + 1)
                  begin
                     idx = m*256 + (j % 256);
                     if (rc_resp[idx] !== ex_resp[idx])
                        begin
                           $display("ERROR: phase %0s: M%0d transfer %0d: %0s, expected %0s", phase, m, j,
                                    rc_resp[idx] ? "ERROR" : "OKAY", ex_resp[idx] ? "ERROR" : "OKAY");
                           error = error + 1;
                           bad   = 1;
                        end
                     else if (ex_chk[idx] && (rc_data[idx] !== ex_data[idx]))
                        begin
                           $display("ERROR: phase %0s: M%0d transfer %0d: hrdata 0x%h, expected 0x%h", phase, m, j,
                                    rc_data[idx], ex_data[idx]);
                           error = error + 1;
                           bad   = 1;
                        end
                  end
            if (!bad)
               $display("PASS:  phase %0s: M%0d %0d transfers, responses and data as expected", phase, m, ex_n[m] - ex_base[m]);
            ex_base[m] = ex_n[m];
         end
   end
endtask


//----------------------------------------------------------------------------
// Subordinate-side FIFO: {sub[1:0], hwrite, hauser, hprot[3:0], haddr[31:0]}
//----------------------------------------------------------------------------
reg [39:0] fq    [0:767];
integer    fq_wp [0:2];
integer    fq_rp [0:2];
integer    fq_cnt;
reg        fq_en;

initial
   begin
      for (hp_i = 0; hp_i < 3; hp_i = hp_i + 1)
         begin
            fq_wp[hp_i] = 0;
            fq_rp[hp_i] = 0;
         end
      fq_cnt = 0;
      fq_en  = 1'b0;
   end

task fq_commit;
   input integer        s;
   input         [31:0] a;
   input                wr;
   input          [3:0] pr;
   input [HAUSER_W-1:0] us;
   input          [3:0] hm;
   integer              m;
   reg           [39:0] e;
   begin
      m = hm[2:0];
      if (m > 2)
         begin
            $display("ERROR: s%0d commit with hmaster 0x%h, which belongs to no manager %t", s, hm, $time);
            error = error + 1;
         end
      else if (fq_rp[m] == fq_wp[m])
         begin
            $display("ERROR: s%0d commit from M%0d (haddr 0x%h) with no transfer of M%0d outstanding %t", s, m, a, m, $time);
            error = error + 1;
         end
      else
         begin
            e        = fq[m*256 + (fq_rp[m] % 256)];
            fq_rp[m] = fq_rp[m] + 1;
            fq_cnt   = fq_cnt + 1;
            if ((e[39:38] !== s[1:0]) || (e[31:0] !== a) || (e[37] !== wr))
               begin
                  $display("ERROR: M%0d commit on s%0d haddr 0x%h hwrite %b, next issued was s%0d haddr 0x%h hwrite %b %t",
                           m, s, a, wr, e[39:38], e[31:0], e[37], $time);
                  error = error + 1;
               end
            else if ((e[35:32] !== pr) || (e[36] !== us[0]))
               begin
                  $display("ERROR: M%0d commit on s%0d haddr 0x%h: hprot %h hauser %b, issued with hprot %h hauser %b %t",
                           m, s, a, pr, us[0], e[35:32], e[36], $time);
                  error = error + 1;
               end
         end
   end
endtask

always @(posedge free_clk)
   if (hresetn && tb_rst_done && fq_en)
      begin
`ifndef FUSED
         if (s0_hsel & s0_hready & s0_htrans[1]) fq_commit(0, s0_haddr, s0_hwrite, s0_hprot, s0_hauser, s0_hmaster);
         if (s1_hsel & s1_hready & s1_htrans[1]) fq_commit(1, s1_haddr, s1_hwrite, s1_hprot, s1_hauser, s1_hmaster);
`endif
         if (s2_hsel & s2_hready & s2_htrans[1]) fq_commit(2, s2_haddr, s2_hwrite, s2_hprot, s2_hauser, s2_hmaster);
         if (s3_hsel & s3_hready & s3_htrans[1]) fq_commit(3, s3_haddr, s3_hwrite, s3_hprot, s3_hauser, s3_hmaster);
      end


//----------------------------------------------------------------------------
// Manager-port toggle coverage: hprot[3:0] and hauser[0]
//----------------------------------------------------------------------------
reg      [4:0] cv_prev [0:2];
reg            cv_init [0:2];
integer        cv_rise [0:14];
integer        cv_fall [0:14];

initial
   begin
      for (hp_i = 0; hp_i < 3; hp_i = hp_i + 1)
         cv_init[hp_i] = 1'b0;
      for (hp_i = 0; hp_i < 15; hp_i = hp_i + 1)
         begin
            cv_rise[hp_i] = 0;
            cv_fall[hp_i] = 0;
         end
   end

task cv_sample;
   input integer m;
   input   [4:0] v;
   integer       b;
   begin
      if (cv_init[m])
         for (b = 0; b < 5; b = b + 1)
            begin
               if (!cv_prev[m][b] &&  v[b]) cv_rise[m*5 + b] = cv_rise[m*5 + b] + 1;
               if ( cv_prev[m][b] && !v[b]) cv_fall[m*5 + b] = cv_fall[m*5 + b] + 1;
            end
      cv_prev[m] = v;
      cv_init[m] = 1'b1;
   end
endtask

always @(posedge free_clk)
   if (hresetn && tb_rst_done)
      begin
         cv_sample(0, {m0_hauser_d[0], m0_hprot_d});
         cv_sample(1, {m1_hauser_d[0], m1_hprot_d});
         cv_sample(2, {m2_hauser_d[0], m2_hprot_d});
      end


//----------------------------------------------------------------------------
// Issue helpers
//----------------------------------------------------------------------------
task automatic hp_set;
   input integer m;
   input   [3:0] pr;
   input         us;
   begin
      case (m)
         0:       begin m0_hprot = pr; m0_hauser = us; end
         1:       begin m1_hprot = pr; m1_hauser = us; end
         default: begin m2_hprot = pr; m2_hauser = us; end
      endcase
   end
endtask

// Pipelined word transfer with the manager's current hprot / hauser. For a
// read, d is the expected data.
task automatic hp_xfer;
   input integer m;
   input         wr;
   input  [31:0] a;
   input  [31:0] d;
   input   [3:0] pr;
   input         us;
   input         resp;
   integer       s;
   begin
      s = hp_sub(a);
      if (fq_en && hp_obs(m, s))                  // commits are matched only while armed
         begin
            fq[m*256 + (fq_wp[m] % 256)] = {s[1:0], wr, us, pr, a};
            fq_wp[m] = fq_wp[m] + 1;
         end
      hp_expect(m, resp, !wr, resp ? 32'h0 : d);
      if (wr) ahb_write(m, 0, a, d, 2);
      else    ahb_read (m, 0, a, d, 2, 0);
   end
endtask

task automatic hp_drain;
   input integer m;
   begin
      @(posedge free_clk);
      while (((m == 0) ? m0_hready : (m == 1) ? m1_hready : m2_hready) !== 1'b1) @(posedge free_clk);
   end
endtask

function [3:0] hp_dflt;
   input integer m;
   begin
      hp_dflt = (m == 0) ? MGR0_HPROT : (m == 1) ? MGR1_HPROT : MGR2_HPROT;
   end
endfunction

// Phase A sweep for one manager.
task automatic hp_sweep_a;
   input integer m;
   integer       v;
   integer       w;
   reg     [3:0] pr;
   reg           us;
   reg    [31:0] d;
   reg    [31:0] a;
   begin
      for (v = 0; v < 32; v = v + 1)
         begin
            pr = v[4:1];
            us = v[0];
            hp_set(m, pr, us);
            // SRAM: own word per value (M0 window 0x000, M1 0x200, M2 0x400)
            w = 128*m + v;
`ifdef FUSED
            if (m == 0)
               hp_xfer(m, 1'b0, HP_SRAM + 32'h600 + 4*v, hp_sram[384 + v], pr, us, 1'b0);
            else
`endif
               begin
                  d = 32'hC0000000 | (m << 24) | (v << 8) | {pr, 3'b000, us};
                  hp_sram[w] = d;
                  hp_xfer(m, 1'b1, HP_SRAM + 4*w, d, pr, us, 1'b0);
                  hp_xfer(m, 1'b0, HP_SRAM + 4*w, d, pr, us, 1'b0);
               end
            // ROM
            hp_xfer(m, 1'b0, HP_ROM + 4*(64*m + v), rom_inst0.mem[64*m + v], pr, us, 1'b0);
            // peripheral
            if (m == 1)
               begin
                  d = 32'hA1000000 | (v << 8) | {pr, 3'b000, us};
                  hp_per[v % 8] = d;
                  hp_xfer(m, 1'b1, HP_P0 + 4*(v % 8), d, pr, us, 1'b0);
                  hp_xfer(m, 1'b0, HP_P0 + 4*(v % 8), d, pr, us, 1'b0);
               end
            else if (m == 2)
               begin
                  d = 32'hB2000000 | (v << 8) | {pr, 3'b000, us};
                  hp_per[16 + (v % 8)] = d;
                  hp_xfer(m, 1'b1, HP_P1 + 4*(v % 8), d, pr, us, 1'b0);
                  hp_xfer(m, 1'b0, HP_P1 + 4*(v % 8), d, pr, us, 1'b0);
               end
`ifdef GENERIC
            else
               begin
                  a = (v[0] ? HP_P1 : HP_P0) + 32'h20 + 4*(v % 8);
                  hp_xfer(m, 1'b0, a, hp_per[(v[0] ? 24 : 8) + (v % 8)], pr, us, 1'b0);
               end
`endif
         end
      hp_drain(m);
      hp_set(m, hp_dflt(m), 1'b0);
   end
endtask

// Phase B sweep against the Machine-only peripherals.
task automatic hp_sweep_b;
   input integer m;
   integer       v;
   reg     [3:0] pr;
   reg           us;
   reg           deny;
   reg    [31:0] d;
   reg    [31:0] a;
   integer       r;
   begin
      for (v = 0; v < 32; v = v + 1)
         begin
            pr   = v[4:1];
            us   = v[0];
            deny = !(pr[1] && !us);
            hp_set(m, pr, us);
            r    = (v + 3) % 8;
            if (m == 0)
               begin
                  a = (v[1] ? HP_P1 : HP_P0) + 32'h20 + 4*r;
                  hp_xfer(m, 1'b0, a, hp_per[(v[1] ? 24 : 8) + r], pr, us, deny);
               end
            else
               begin
                  a = ((m == 1) ? HP_P0 : HP_P1) + 4*r;
                  d = ((m == 1) ? 32'h5A000000 : 32'h6B000000) | (v << 8) | {pr, 3'b000, us};
                  if (!deny) hp_per[((m == 1) ? 0 : 16) + r] = d;
                  hp_xfer(m, 1'b1, a, d, pr, us, deny);
                  hp_xfer(m, 1'b0, a, hp_per[((m == 1) ? 0 : 16) + r], pr, us, deny);
               end
         end
      hp_drain(m);
      hp_set(m, hp_dflt(m), 1'b0);
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

      for (hp_i = 0; hp_i < 512; hp_i = hp_i + 1)
         begin
            rom_inst0.mem[hp_i]  = 32'h6D000000 + (hp_i * 32'h00010007);
            sram_inst0.mem[hp_i] = 32'h29000000 + (hp_i * 32'h00000203);
            hp_sram[hp_i]        = sram_inst0.mem[hp_i];
         end
      for (hp_i = 0; hp_i < 8; hp_i = hp_i + 1)
         begin
            set_regin_value(0, 8 + hp_i, 32'h0E080000 + hp_i);
            set_regin_value(1, 8 + hp_i, 32'h1E080000 + hp_i);
            hp_per[hp_i]      = 32'hxxxxxxxx;
            hp_per[16 + hp_i] = 32'hxxxxxxxx;
            hp_per[8 + hp_i]  = 32'h0E080000 + hp_i;
            hp_per[24 + hp_i] = 32'h1E080000 + hp_i;
         end

      @(negedge free_clk);
      force   ahb_periph_example_inst0.hresetn_i = 1'b0;
      force   ahb_periph_example_inst1.hresetn_i = 1'b0;
      @(negedge free_clk);
      release ahb_periph_example_inst0.hresetn_i;
      release ahb_periph_example_inst1.hresetn_i;
      repeat(10) @(posedge free_clk);

      sideband_checker_enable = 1'b0;

      //==================================================================
      // A: peripherals open to User; hprot x hsmode sweep everywhere
      //==================================================================
      $display("");
      $display(" =====================================================");
      $display("|  A: HPROT x HSMODE SWEEP, PERIPHERALS OPEN TO USER  |");
      $display(" =====================================================");
      hp_xfer(1, 1'b1, HP_P0 + 32'h40, 32'h00000100, MGR1_HPROT, 1'b0, 1'b0);   // WR_PRIV = RD_PRIV = User
      hp_xfer(1, 1'b1, HP_P1 + 32'h40, 32'h00000100, MGR1_HPROT, 1'b0, 1'b0);
      hp_xfer(1, 1'b0, HP_P0 + 32'h40, 32'h00000100, MGR1_HPROT, 1'b0, 1'b0);
      hp_xfer(1, 1'b0, HP_P1 + 32'h40, 32'h00000100, MGR1_HPROT, 1'b0, 1'b0);
      hp_drain(1);
      repeat(5) @(posedge free_clk);
      hp_check("setup A");

      fq_en = 1'b1;
      fork
         hp_sweep_a(0);
         begin @(posedge free_clk); hp_sweep_a(1); end
         begin repeat(2) @(posedge free_clk); hp_sweep_a(2); end
      join
      repeat(20) @(posedge free_clk);
      hp_check("A");

      //==================================================================
      // B: peripherals Machine-only; responses reveal hprot[1] / hsmode
      //==================================================================
      $display("");
      $display(" =====================================================");
      $display("|  B: SWEEP AGAINST MACHINE-ONLY PERIPHERALS          |");
      $display(" =====================================================");
      hp_xfer(1, 1'b1, HP_P0 + 32'h40, 32'h0000010F, MGR1_HPROT, 1'b0, 1'b0);
      hp_xfer(1, 1'b1, HP_P1 + 32'h40, 32'h0000010F, MGR1_HPROT, 1'b0, 1'b0);
      hp_xfer(1, 1'b0, HP_P0 + 32'h40, 32'h0000010F, MGR1_HPROT, 1'b0, 1'b0);
      hp_xfer(1, 1'b0, HP_P1 + 32'h40, 32'h0000010F, MGR1_HPROT, 1'b0, 1'b0);
      hp_drain(1);
      repeat(5) @(posedge free_clk);
      hp_check("setup B");

      fork
`ifdef GENERIC
         hp_sweep_b(0);
`endif
         begin @(posedge free_clk); hp_sweep_b(1); end
         begin repeat(2) @(posedge free_clk); hp_sweep_b(2); end
      join
      repeat(20) @(posedge free_clk);
      hp_check("B");
      fq_en = 1'b0;

      //==================================================================
      // Final checks
      //==================================================================
      for (hp_i = 0; hp_i < 3; hp_i = hp_i + 1)
         if (fq_rp[hp_i] != fq_wp[hp_i])
            begin
               $display("ERROR: M%0d issued %0d observable transfers, %0d committed", hp_i, fq_wp[hp_i], fq_rp[hp_i]);
               error = error + 1;
            end
      $display("INFO:  %0d subordinate commits checked for haddr / hwrite / hprot / hauser", fq_cnt);
      for (hp_i = 0; hp_i < 3; hp_i = hp_i + 1)
         for (hp_j = 0; hp_j < 5; hp_j = hp_j + 1)
            if ((cv_rise[hp_i*5 + hp_j] == 0) || (cv_fall[hp_i*5 + hp_j] == 0))
               begin
                  $display("ERROR: M%0d %0s rose %0d / fell %0d times", hp_i, (hp_j == 4) ? "hauser[0]" : "hprot bit",
                           cv_rise[hp_i*5 + hp_j], cv_fall[hp_i*5 + hp_j]);
                  error = error + 1;
               end
      for (hp_i = 0; hp_i < 512; hp_i = hp_i + 1)
         if (sram_inst0.mem[hp_i] !== hp_sram[hp_i])
            begin
               $display("ERROR: SRAM word %0d = 0x%h, expected 0x%h", hp_i, sram_inst0.mem[hp_i], hp_sram[hp_i]);
               error = error + 1;
            end
      for (hp_i = 0; hp_i < 8; hp_i = hp_i + 1)
         begin
            check_periph_reg_value(0, hp_i, hp_per[hp_i]);
            check_periph_reg_value(1, hp_i, hp_per[16 + hp_i]);
         end
      sideband_checker_enable = 1'b1;

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
