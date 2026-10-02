//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    burst_lock_forwarding
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : burst_lock_forwarding.v
// Module Description : Every HBURST value, HMASTLOCK high and low, NONSEQ +
//                      SEQ beats with BUSY beats in between, from every
//                      manager at once, to every subordinate, to the default
//                      subordinate of every bus and (fused) to the ROM / SRAM
//                      controllers from both ports. All variants, with and
//                      without -random_ws.
//
// Phase A  The three managers run their burst programs concurrently, so
//          address phases (SEQ included) are cached and replayed. Each
//          program covers SINGLE, INCR (ending on BUSY), WRAP4, INCR4, WRAP8,
//          INCR8, WRAP16 and INCR16, locked and unlocked, reads and writes,
//          to ROM, SRAM, a peripheral, unmapped addresses and ROM writes
//          (ERROR per beat). Fused: M0 bursts to ROM / SRAM (Port A), an M0
//          write burst (diverted, ERROR per beat, SRAM untouched), M0 bursts
//          outside the executable decoder (executable-side default).
// Phase B  Every manager reads the same windows with a BUSY after every beat,
//          so beats of different managers interleave at the subordinates.
// Phase C  Fused only: M0 reads the SRAM window in NONSEQ + SEQ bursts, first
//          chained INCR8 / INCR16 / SINGLE with a beat every cycle (no BUSY, no
//          IDLE between bursts), then with BUSY beats, while M1 /
//          M2 keep Port B of the SRAM controller busy with back-to-back write
//          bursts, so M0's SEQ address phases lose contests on Port A and are
//          held and replayed; every beat's data is checked and the written
//          windows are read back. Required: a wait state inside an M0 SEQ
//          data phase and, in the chained bursts, an M0 SEQ accepted in the
//          cycle its previous beat completed, and an M0 NONSEQ accepted in the
//          cycle a SEQ completed, each stalled in the next cycle.
//
// Checks
//  - Manager side: every NONSEQ / SEQ beat completes, in order, with the
//    expected response and read data; an ERROR has the two-cycle shape; no
//    hresp outside a NONSEQ / SEQ data phase; hready high while a manager
//    presents IDLE / BUSY with nothing outstanding; every BUSY data phase
//    ends OKAY.
//  - Subordinate side (s0..s3 on generic / hiperf, s2 / s3 on fused), at
//    every commit (hsel & hready & htrans[1]): haddr, htrans (NONSEQ / SEQ
//    preserved), hburst, hmastlock, hprot, hauser, hsize, hwrite equal the
//    issuing manager's next observable beat; the manager is identified by
//    hmaster[2:0]. BUSY beats never commit.
//  - Evidence: cached address phases on M1 / M2 (and M0 on generic), a
//    cached SEQ, a SEQ committed right after another manager's commit on the
//    same bus (generic, non-executable side), every hburst / hmastlock bit
//    rising and falling and every htrans encoding on every manager port.
//  - End: SRAM and peripheral contents equal the shadow model.
//
// Basis (quoted)
//  ahb_interconnect.md, Integration requirements: "Bursts and locks. The
//    fabric arbitrates transfer by transfer. A BUSY beat releases the bus, so
//    another manager can be granted between the beats of a burst, and a SEQ
//    beat can follow an unrelated transfer at the subordinate. hmastlock is
//    forwarded but not honoured by the bundled arbiters."
//  ahb_interconnect.md, Glossary: "IDLE / BUSY | ... Both are answered with a
//    zero-wait OKAY."
//  ahb_interconnect.md, Building blocks: ahb_manager_if "caches it when the
//    bus is busy, asks the arbiter for the bus, replays the cached address
//    phase when granted"; ahb_default_subordinate "Answers every NONSEQ/SEQ
//    transfer with the AHB two-cycle ERROR (hreadyout low then high,
//    hresp = 1, hrdata = 0)."
//  ahb_interconnect.md, What differs: "hmaster / hprot / hauser / hmastlock on
//    the executable side | Forwarded | Forwarded to s_x_* | Not delivered to
//    the controllers"; "A write presented by m_x | ... | Diverted to the
//    executable-side default subordinate, answered ERROR"; Fused fabric: "on
//    the ROM controller a write is answered with the two-cycle ERROR".
//  ahb_interconnect.md, hready wiring: "m_hready_o[k] = dph_ongoing ?
//    hreadyout : aph_pending ? 0 : 1".
//  IHI0033C Table 3-1: BUSY "the address and control signals must reflect the
//    next transfer in the burst. Only undefined length bursts can have a BUSY
//    transfer as the last cycle of a burst."; SEQ "The control information
//    is identical to the previous transfer."
//  IHI0033C 3.5 / 3.6: wrapping bursts "wrap when they cross an address
//    boundary ... the product of the number of beats in a burst and the size
//    of the transfer"; "Managers must not attempt to start an incrementing
//    burst that crosses a 1KB address boundary."; "The Manager is not
//    permitted to perform a BUSY transfer immediately after a SINGLE burst."
//  ahb_interconnect.md, Fused fabric: "When both present an address phase to
//    the same controller in the same cycle, the controller's arbiter serves
//    one and holds the other for one wait state."; "The port that loses a
//    contest in a write's data phase takes two wait states".
//  IHI0033C 4.2.1: "If a NONSEQUENTIAL or SEQUENTIAL transfer is attempted to
//    a nonexistent address location, then the default Subordinate provides an
//    ERROR response. IDLE or BUSY transfers to nonexistent locations result
//    in a zero wait state OKAY response."
//----------------------------------------------------------------------------

localparam [31:0] BL_ROM    = 32'h00400000;
localparam [31:0] BL_SRAM   = 32'h00401000;
localparam [31:0] BL_P0     = 32'h00402000;
localparam [31:0] BL_P1     = 32'h00403000;
localparam [31:0] BL_UNMAP  = 32'h00800000;

localparam  [1:0] HT_IDLE   = 2'b00;
localparam  [1:0] HT_BUSY   = 2'b01;
localparam  [1:0] HT_NSEQ   = 2'b10;
localparam  [1:0] HT_SEQ    = 2'b11;

localparam  [2:0] HB_SINGLE = 3'd0;
localparam  [2:0] HB_INCR   = 3'd1;
localparam  [2:0] HB_WRAP4  = 3'd2;
localparam  [2:0] HB_INCR4  = 3'd3;
localparam  [2:0] HB_WRAP8  = 3'd4;
localparam  [2:0] HB_INCR8  = 3'd5;
localparam  [2:0] HB_WRAP16 = 3'd6;
localparam  [2:0] HB_INCR16 = 3'd7;

integer    bl_i;
integer    bl_j;
integer    bl_k;
reg [31:0] bl_sram     [0:511];
reg [31:0] bl_per      [0:31];


//----------------------------------------------------------------------------
// Address map helpers
//----------------------------------------------------------------------------
function integer bl_sub;
   input [31:0] a;
   begin
      if      ((a >= 32'h00400000) && (a < 32'h00400800)) bl_sub = 0;
      else if ((a >= 32'h00401000) && (a < 32'h00401800)) bl_sub = 1;
      else if ((a >= 32'h00402000) && (a < 32'h00402080)) bl_sub = 2;
      else if ((a >= 32'h00403000) && (a < 32'h00403080)) bl_sub = 3;
      else                                                 bl_sub = -1;
   end
endfunction

// Beat reaches an externally visible subordinate port.
function bl_obs;
   input integer m;
   input integer s;
   begin
`ifdef FUSED
      bl_obs = (m != 0) && ((s == 2) || (s == 3));
`elsif HIPERF
      bl_obs = (s >= 0) && !((m == 0) && (s >= 2));
`else
      bl_obs = (s >= 0);
`endif
   end
endfunction

// Beat answered ERROR.
function bl_err;
   input integer m;
   input integer s;
   input         wr;
   begin
      bl_err = (s < 0) || ((s == 0) && wr);
`ifndef GENERIC
      if ((m == 0) && (s >= 2)) bl_err = 1'b1;
`endif
`ifdef FUSED
      if ((m == 0) && wr)       bl_err = 1'b1;
`endif
   end
endfunction

function [31:0] bl_rdval;
   input integer s;
   input  [31:0] a;
   begin
      case (s)
         0:       bl_rdval = rom_inst0.mem[(a - BL_ROM)  >> 2];
         1:       bl_rdval = bl_sram     [(a - BL_SRAM) >> 2];
         2:       bl_rdval = bl_per      [(a - BL_P0)   >> 2];
         3:       bl_rdval = bl_per      [16 + ((a - BL_P1) >> 2)];
         default: bl_rdval = 32'h00000000;
      endcase
   end
endfunction

task bl_wrfx;
   input integer s;
   input  [31:0] a;
   input  [31:0] d;
   begin
      if (s == 1)                                    bl_sram[(a - BL_SRAM) >> 2]     = d;
      if ((s == 2) && (((a - BL_P0) >> 2) < 8))      bl_per[(a - BL_P0) >> 2]        = d;
      if ((s == 3) && (((a - BL_P1) >> 2) < 8))      bl_per[16 + ((a - BL_P1) >> 2)] = d;
   end
endtask

function [3:0] bl_prot;
   input integer m;
   begin
      bl_prot = (m == 0) ? MGR0_HPROT : (m == 1) ? MGR1_HPROT : MGR2_HPROT;
   end
endfunction


//----------------------------------------------------------------------------
// Manager-side response recorder
//----------------------------------------------------------------------------
reg        rc_out  [0:2];
reg        rc_err1 [0:2];
reg        rc_busy [0:2];
integer    rc_n    [0:2];
integer    bz_cnt  [0:2];
reg        rc_resp [0:767];
reg [31:0] rc_data [0:767];
integer    rc_k;

initial
   for (rc_k = 0; rc_k < 3; rc_k = rc_k + 1)
      begin
         rc_out[rc_k]  = 1'b0;
         rc_err1[rc_k] = 1'b0;
         rc_busy[rc_k] = 1'b0;
         rc_n[rc_k]    = 0;
         bz_cnt[rc_k]  = 0;
      end

task rc_sample;
   input integer m;
   input   [1:0] tr;
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
      else
         begin
            if (rsp !== 1'b0)
               begin
                  $display("ERROR: M%0d hresp=%b with no NONSEQ/SEQ data phase (htrans %b) %t", m, rsp, tr, $time);
                  error = error + 1;
               end
            if (!tr[1] && (rdy !== 1'b1))
               begin
                  $display("ERROR: M%0d hready=%b while presenting %0s with no transfer outstanding %t",
                           m, rdy, tr[0] ? "BUSY" : "IDLE", $time);
                  error = error + 1;
               end
            if (rc_busy[m] && rdy && !rsp) bz_cnt[m] = bz_cnt[m] + 1;
         end
      if (rdy)         rc_busy[m] = (tr == HT_BUSY);
      if (tr[1] & rdy) rc_out[m]  = 1'b1;
   end
endtask

always @(posedge free_clk)
   if (!hresetn)
      begin
         for (rc_k = 0; rc_k < 3; rc_k = rc_k + 1)
            begin
               rc_out[rc_k]  = 1'b0;
               rc_err1[rc_k] = 1'b0;
               rc_busy[rc_k] = 1'b0;
            end
      end
   else if (tb_rst_done)
      begin
         rc_sample(0, m0_htrans_d, m0_hready, m0_hresp, m0_hrdata);
         rc_sample(1, m1_htrans_d, m1_hready, m1_hresp, m1_hrdata);
         rc_sample(2, m2_htrans_d, m2_hready, m2_hresp, m2_hrdata);
      end


//----------------------------------------------------------------------------
// Subordinate-side forwarding FIFO
//   {sub[1:0], hwrite, hsize[2:0], hauser, hprot[3:0], hmastlock, hburst[2:0],
//    htrans[1:0], haddr[31:0]}
//----------------------------------------------------------------------------
reg [48:0] fq      [0:767];
integer    fq_wp   [0:2];
integer    fq_rp   [0:2];
integer    fq_cnt;
integer    fq_seq_cnt;
integer    bl_last_bus [0:3];
integer    bl_last_sub [0:3];
integer    bl_seq_after_other;
integer    bl_seq_after_other_sub;
reg        fq_en;

initial
   begin
      for (bl_i = 0; bl_i < 3; bl_i = bl_i + 1)
         begin
            fq_wp[bl_i] = 0;
            fq_rp[bl_i] = 0;
         end
      for (bl_i = 0; bl_i < 4; bl_i = bl_i + 1)
         begin
            bl_last_bus[bl_i] = -1;
            bl_last_sub[bl_i] = -1;
         end
      fq_cnt                 = 0;
      fq_seq_cnt             = 0;
      bl_seq_after_other     = 0;
      bl_seq_after_other_sub = 0;
      fq_en                  = 1'b0;
   end

task fq_push;
   input integer        m;
   input integer        s;
   input         [31:0] a;
   input          [1:0] tr;
   input          [2:0] bu;
   input                lk;
   input          [3:0] pr;
   input                us;
   input          [2:0] sz;
   input                wr;
   begin
      fq[m*256 + (fq_wp[m] % 256)] = {s[1:0], wr, sz, us, pr, lk, bu, tr, a};
      fq_wp[m] = fq_wp[m] + 1;
   end
endtask

// Bus a subordinate port sits on: 0 generic shared bus, 1 non-executable bus,
// 2 / 3 the hiperf executable subordinates' own buses.
function integer bl_bus;
   input integer s;
   begin
`ifdef GENERIC
      bl_bus = 0;
`else
      bl_bus = (s >= 2) ? 1 : 2 + s;
`endif
   end
endfunction

task fq_commit;
   input integer        s;
   input         [31:0] a;
   input          [1:0] tr;
   input          [2:0] bu;
   input                lk;
   input          [3:0] pr;
   input [HAUSER_W-1:0] us;
   input          [2:0] sz;
   input                wr;
   input          [3:0] hm;
   integer              m;
   integer              b;
   reg           [48:0] e;
   begin
      m = hm[2:0];
      b = bl_bus(s);
      if (m > 2)
         begin
            $display("ERROR: s%0d commit with hmaster 0x%h, which belongs to no manager %t", s, hm, $time);
            error = error + 1;
         end
      else if (fq_rp[m] == fq_wp[m])
         begin
            $display("ERROR: s%0d commit from M%0d (haddr 0x%h htrans %b) with no beat of M%0d outstanding %t",
                     s, m, a, tr, m, $time);
            error = error + 1;
         end
      else
         begin
            e        = fq[m*256 + (fq_rp[m] % 256)];
            fq_rp[m] = fq_rp[m] + 1;
            fq_cnt   = fq_cnt + 1;
            if (tr == HT_SEQ) fq_seq_cnt = fq_seq_cnt + 1;
            if ((e[48:47] !== s[1:0]) || (e[31:0] !== a) || (e[33:32] !== tr))
               begin
                  $display("ERROR: M%0d commit on s%0d haddr 0x%h htrans %b, next beat was s%0d haddr 0x%h htrans %b %t",
                           m, s, a, tr, e[48:47], e[31:0], e[33:32], $time);
                  error = error + 1;
               end
            if ((e[36:34] !== bu) || (e[37] !== lk) || (e[41:38] !== pr) || (e[42] !== us[0]) ||
                (e[45:43] !== sz) || (e[46] !== wr))
               begin
                  $display("ERROR: M%0d commit on s%0d haddr 0x%h: hburst %0d/%0d hmastlock %b/%b hprot %h/%h hauser %b/%b hsize %0d/%0d hwrite %b/%b (seen/issued) %t",
                           m, s, a, bu, e[36:34], lk, e[37], pr, e[41:38], us[0], e[42], sz, e[45:43], wr, e[46], $time);
                  error = error + 1;
               end
            if ((tr == HT_SEQ) && (b < 2) && (bl_last_bus[b] >= 0) && (bl_last_bus[b] != m))
               bl_seq_after_other = bl_seq_after_other + 1;
            if ((tr == HT_SEQ) && (bl_last_sub[s] >= 0) && (bl_last_sub[s] != m))
               bl_seq_after_other_sub = bl_seq_after_other_sub + 1;
         end
      if (m <= 2)
         begin
            bl_last_bus[b] = m;
            bl_last_sub[s] = m;
         end
   end
endtask

always @(posedge free_clk)
   if (hresetn && tb_rst_done && fq_en)
      begin
`ifndef FUSED
         if (s0_hsel & s0_hready & s0_htrans[1]) fq_commit(0, s0_haddr, s0_htrans, s0_hburst, s0_hmastlock, s0_hprot, s0_hauser, s0_hsize, s0_hwrite, s0_hmaster);
         if (s1_hsel & s1_hready & s1_htrans[1]) fq_commit(1, s1_haddr, s1_htrans, s1_hburst, s1_hmastlock, s1_hprot, s1_hauser, s1_hsize, s1_hwrite, s1_hmaster);
`endif
         if (s2_hsel & s2_hready & s2_htrans[1]) fq_commit(2, s2_haddr, s2_htrans, s2_hburst, s2_hmastlock, s2_hprot, s2_hauser, s2_hsize, s2_hwrite, s2_hmaster);
         if (s3_hsel & s3_hready & s3_htrans[1]) fq_commit(3, s3_haddr, s3_htrans, s3_hburst, s3_hmastlock, s3_hprot, s3_hauser, s3_hsize, s3_hwrite, s3_hmaster);
      end


//----------------------------------------------------------------------------
// Cached address phases (manager held by the fabric), SEQ among them
//----------------------------------------------------------------------------
wire bl_m0_pend;
wire bl_m1_pend;
wire bl_m2_pend;
`ifdef FUSED
assign bl_m0_pend = 1'b0;
assign bl_m1_pend = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_aph_pending;
assign bl_m2_pend = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_aph_pending;
`elsif HIPERF
assign bl_m0_pend = 1'b0;
assign bl_m1_pend = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_aph_pending;
assign bl_m2_pend = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_aph_pending;
`else
assign bl_m0_pend = dut.ahb_manager_mux_inst.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_aph_pending;
assign bl_m1_pend = dut.ahb_manager_mux_inst.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_aph_pending;
assign bl_m2_pend = dut.ahb_manager_mux_inst.AHB_MANAGER_IF[2].ahb_manager_if_inst.m_aph_pending;
`endif

integer bl_pc0, bl_pc1, bl_pc2;
integer bl_pseq;
initial
   begin
      bl_pc0  = 0;
      bl_pc1  = 0;
      bl_pc2  = 0;
      bl_pseq = 0;
   end

// Phase C evidence on M0: wait-state cycles inside the data phase of an
// accepted SEQ beat; and, while bl_c_nb is set, SEQ beats accepted in the cycle
// their previous NONSEQ / SEQ beat completed, and NONSEQ beats accepted in the
// cycle a SEQ completed, then stalled in the next cycle.
reg     bl_c_on;
reg     bl_c_nb;
reg     bl_c_lastseq;
reg     bl_c_prevreal;
reg     bl_c_seqacc;
reg     bl_c_prevseq;
reg     bl_c_nsacc;
integer bl_c_seqwait;
integer bl_c_seqstall;
integer bl_c_nsstall;
initial
   begin
      bl_c_on       = 1'b0;
      bl_c_nb       = 1'b0;
      bl_c_lastseq  = 1'b0;
      bl_c_prevreal = 1'b0;
      bl_c_seqacc   = 1'b0;
      bl_c_prevseq  = 1'b0;
      bl_c_nsacc    = 1'b0;
      bl_c_seqwait  = 0;
      bl_c_seqstall = 0;
      bl_c_nsstall  = 0;
   end

always @(posedge free_clk)
   if (hresetn && tb_rst_done)
      begin
         if (bl_c_on && bl_c_lastseq && (m0_hready === 1'b0) && (m0_hresp === 1'b0))
            bl_c_seqwait = bl_c_seqwait + 1;
         if (bl_c_on && bl_c_nb && bl_c_seqacc && (m0_hready === 1'b0) && (m0_hresp === 1'b0))
            bl_c_seqstall = bl_c_seqstall + 1;
         if (bl_c_on && bl_c_nb && bl_c_nsacc && (m0_hready === 1'b0) && (m0_hresp === 1'b0))
            bl_c_nsstall = bl_c_nsstall + 1;
         bl_c_seqacc = (m0_hready === 1'b1) && (m0_htrans_d == HT_SEQ)  && bl_c_prevreal;
         bl_c_nsacc  = (m0_hready === 1'b1) && (m0_htrans_d == HT_NSEQ) && bl_c_prevseq;
         if (m0_hready === 1'b1)
            bl_c_prevseq = (m0_htrans_d == HT_SEQ);
         if ((m0_hready === 1'b1) && m0_htrans_d[1])
            bl_c_lastseq = (m0_htrans_d == HT_SEQ);
         if (m0_hready === 1'b1)
            bl_c_prevreal = m0_htrans_d[1];
      end

always @(posedge free_clk)
   if (hresetn && tb_rst_done)
      begin
         if (bl_m0_pend === 1'b1) bl_pc0 = bl_pc0 + 1;
         if (bl_m1_pend === 1'b1) bl_pc1 = bl_pc1 + 1;
         if (bl_m2_pend === 1'b1) bl_pc2 = bl_pc2 + 1;
         if (((bl_m0_pend === 1'b1) && (m0_htrans_d == HT_SEQ)) ||
             ((bl_m1_pend === 1'b1) && (m1_htrans_d == HT_SEQ)) ||
             ((bl_m2_pend === 1'b1) && (m2_htrans_d == HT_SEQ)))
            bl_pseq = bl_pseq + 1;
      end


//----------------------------------------------------------------------------
// Manager-port toggle / encoding coverage (DUT side of the 1 ns delays)
//----------------------------------------------------------------------------
reg      [2:0] cv_hb_prev [0:2];
reg            cv_lk_prev [0:2];
reg            cv_init    [0:2];
integer        cv_hb_rise [0:8];
integer        cv_hb_fall [0:8];
integer        cv_lk_rise [0:2];
integer        cv_lk_fall [0:2];
integer        cv_tr      [0:11];

initial
   begin
      for (bl_i = 0; bl_i < 3; bl_i = bl_i + 1)
         begin
            cv_init[bl_i]    = 1'b0;
            cv_lk_rise[bl_i] = 0;
            cv_lk_fall[bl_i] = 0;
         end
      for (bl_i = 0; bl_i < 9; bl_i = bl_i + 1)
         begin
            cv_hb_rise[bl_i] = 0;
            cv_hb_fall[bl_i] = 0;
         end
      for (bl_i = 0; bl_i < 12; bl_i = bl_i + 1)
         cv_tr[bl_i] = 0;
   end

task cv_sample;
   input integer m;
   input   [2:0] hb;
   input         lk;
   input   [1:0] tr;
   integer       b;
   begin
      if (cv_init[m])
         begin
            for (b = 0; b < 3; b = b + 1)
               begin
                  if (!cv_hb_prev[m][b] &&  hb[b]) cv_hb_rise[m*3 + b] = cv_hb_rise[m*3 + b] + 1;
                  if ( cv_hb_prev[m][b] && !hb[b]) cv_hb_fall[m*3 + b] = cv_hb_fall[m*3 + b] + 1;
               end
            if (!cv_lk_prev[m] &&  lk) cv_lk_rise[m] = cv_lk_rise[m] + 1;
            if ( cv_lk_prev[m] && !lk) cv_lk_fall[m] = cv_lk_fall[m] + 1;
         end
      cv_tr[m*4 + tr] = cv_tr[m*4 + tr] + 1;
      cv_hb_prev[m]   = hb;
      cv_lk_prev[m]   = lk;
      cv_init[m]      = 1'b1;
   end
endtask

always @(posedge free_clk)
   if (hresetn && tb_rst_done)
      begin
         cv_sample(0, m0_hburst_d, m0_hmastlock_d, m0_htrans_d);
         cv_sample(1, m1_hburst_d, m1_hmastlock_d, m1_htrans_d);
         cv_sample(2, m2_hburst_d, m2_hmastlock_d, m2_htrans_d);
      end


//----------------------------------------------------------------------------
// Burst driver
//----------------------------------------------------------------------------
reg  [1:0] bl_tr [0:191];     // per manager, 64 entries: htrans of each cycle
reg [31:0] bl_a  [0:191];
reg [31:0] bl_wd [0:191];
reg        bl_er [0:191];     // per real beat: ERROR expected
reg        bl_ec [0:191];     //                read data checked
reg [31:0] bl_ed [0:191];     //                expected read data
reg  [2:0] bl_bu [0:2];
reg        bl_lk [0:2];
reg        bl_wr [0:2];
integer    bl_seqid [0:2];
integer    bl_nseq  [0:2];
integer    bl_nbeat [0:2];

initial
   for (bl_i = 0; bl_i < 3; bl_i = bl_i + 1)
      begin
         bl_seqid[bl_i] = 0;
         bl_nseq[bl_i]  = 0;
         bl_nbeat[bl_i] = 0;
      end

function bl_rdy;
   input integer m;
   begin
      bl_rdy = (m == 0) ? m0_hready : (m == 1) ? m1_hready : m2_hready;
   end
endfunction

function [31:0] bl_baddr;
   input [31:0] start;
   input [31:0] wrapb;
   input integer j;
   begin
      if (wrapb == 0) bl_baddr = start + 4*j;
      else            bl_baddr = (start & ~(wrapb - 1)) | ((start + 4*j) & (wrapb - 1));
   end
endfunction

task automatic bl_drive;
   input integer m;
   input   [1:0] tr;
   input  [31:0] a;
   integer       s;
   begin
      case (m)
         0:       begin m0_htrans = tr; m0_haddr = a; m0_hburst = bl_bu[0]; m0_hmastlock = bl_lk[0]; m0_hwrite = bl_wr[0]; m0_hsize = 3'b010; end
         1:       begin m1_htrans = tr; m1_haddr = a; m1_hburst = bl_bu[1]; m1_hmastlock = bl_lk[1]; m1_hwrite = bl_wr[1]; m1_hsize = 3'b010; end
         default: begin m2_htrans = tr; m2_haddr = a; m2_hburst = bl_bu[2]; m2_hmastlock = bl_lk[2]; m2_hwrite = bl_wr[2]; m2_hsize = 3'b010; end
      endcase
      s = bl_sub(a);
      if (tr[1] && bl_obs(m, s))
         fq_push(m, s, a, tr, bl_bu[m], bl_lk[m], bl_prot(m), 1'b0, 3'b010, bl_wr[m]);
   end
endtask

task automatic bl_idle;
   input integer m;
   begin
      case (m)
         0:       begin m0_htrans = HT_IDLE; m0_haddr = 32'h0; m0_hburst = HB_SINGLE; m0_hmastlock = 1'b0; m0_hwrite = 1'b0; m0_hsize = 3'b000; end
         1:       begin m1_htrans = HT_IDLE; m1_haddr = 32'h0; m1_hburst = HB_SINGLE; m1_hmastlock = 1'b0; m1_hwrite = 1'b0; m1_hsize = 3'b000; end
         default: begin m2_htrans = HT_IDLE; m2_haddr = 32'h0; m2_hburst = HB_SINGLE; m2_hmastlock = 1'b0; m2_hwrite = 1'b0; m2_hsize = 3'b000; end
      endcase
   end
endtask

task automatic bl_wdat;
   input integer m;
   input  [31:0] d;
   begin
      case (m)
         0:       m0_hwdata = d;
         1:       m1_hwdata = d;
         default: m2_hwdata = d;
      endcase
   end
endtask

// One burst: nb beats (NONSEQ then SEQ) of words from start, a BUSY after beat
// j when bmask[j] is set, and a trailing BUSY when ebusy (INCR only).
task automatic bl_seq;
   input integer m;
   input   [2:0] bu;
   input         lk;
   input         wr;
   input  [31:0] start;
   input integer nb;
   input  [15:0] bmask;
   input         ebusy;
   integer       base;
   integer       k;
   integer       j;
   integer       nr;
   integer       n0;
   integer       s;
   integer       idx;
   integer       bad;
   reg    [31:0] a;
   reg    [31:0] wrapb;
   begin
      base        = m*64;
      bl_bu[m]    = bu;
      bl_lk[m]    = lk;
      bl_wr[m]    = wr;
      bl_seqid[m] = bl_seqid[m] + 1;
      wrapb       = (bu == HB_WRAP4) ? 16 : (bu == HB_WRAP8) ? 32 : (bu == HB_WRAP16) ? 64 : 0;
      k           = 0;
      nr          = 0;
      for (j = 0; j < nb; j = j + 1)
         begin
            a               = bl_baddr(start, wrapb, j);
            s               = bl_sub(a);
            bl_tr[base + k] = (j == 0) ? HT_NSEQ : HT_SEQ;
            bl_a [base + k] = a;
            bl_wd[base + k] = 32'hB0000000 | (m << 24) | ((bl_seqid[m] % 256) << 12) | (j << 4) | 5;
            bl_er[base + nr] = bl_err(m, s, wr);
            if (wr)
               begin
                  bl_ec[base + nr] = 1'b0;
                  bl_ed[base + nr] = 32'h0;
                  if (!bl_er[base + nr]) bl_wrfx(s, a, bl_wd[base + k]);
               end
            else
               begin
                  bl_ec[base + nr] = 1'b1;
                  bl_ed[base + nr] = bl_er[base + nr] ? 32'h0 : bl_rdval(s, a);
               end
            nr = nr + 1;
            k  = k + 1;
            if ((j < nb - 1) && bmask[j])
               begin
                  bl_tr[base + k] = HT_BUSY;
                  bl_a [base + k] = bl_baddr(start, wrapb, j + 1);
                  k = k + 1;
               end
         end
      if (ebusy)
         begin
            bl_tr[base + k] = HT_BUSY;
            bl_a [base + k] = bl_baddr(start, wrapb, nb);
            k = k + 1;
         end

      n0 = rc_n[m];
      bl_drive(m, bl_tr[base], bl_a[base]);
      for (j = 0; j < k; j = j + 1)
         begin
            @(posedge free_clk);
            while (bl_rdy(m) !== 1'b1) @(posedge free_clk);
            #1;
            if (bl_tr[base + j][1] && wr) bl_wdat(m, bl_wd[base + j]);
            if (j + 1 < k) bl_drive(m, bl_tr[base + j + 1], bl_a[base + j + 1]);
            else           bl_idle(m);
         end
      @(posedge free_clk);
      while (bl_rdy(m) !== 1'b1) @(posedge free_clk);
      repeat(2) @(posedge free_clk);

      bad = 0;
      if (rc_n[m] - n0 != nr)
         begin
            $display("ERROR: M%0d burst %0d (hburst %0d, start 0x%h): %0d beats completed, %0d issued %t",
                     m, bl_seqid[m], bu, start, rc_n[m] - n0, nr, $time);
            error = error + 1;
            bad   = 1;
         end
      else
         for (j = 0; j < nr; j = j + 1)
            begin
               idx = m*256 + ((n0 + j) % 256);
               if (rc_resp[idx] !== bl_er[base + j])
                  begin
                     $display("ERROR: M%0d burst %0d (hburst %0d, start 0x%h) beat %0d: %0s, expected %0s %t",
                              m, bl_seqid[m], bu, start, j, rc_resp[idx] ? "ERROR" : "OKAY",
                              bl_er[base + j] ? "ERROR" : "OKAY", $time);
                     error = error + 1;
                     bad   = 1;
                  end
               else if (bl_ec[base + j] && (rc_data[idx] !== bl_ed[base + j]))
                  begin
                     $display("ERROR: M%0d burst %0d (hburst %0d, start 0x%h) beat %0d: hrdata 0x%h, expected 0x%h %t",
                              m, bl_seqid[m], bu, start, j, rc_data[idx], bl_ed[base + j], $time);
                     error = error + 1;
                     bad   = 1;
                  end
            end
      if (!bad)
         $display("PASS:  M%0d burst %0d -- hburst %0d hmastlock %b %0s start 0x%h, %0d beats + %0d BUSY",
                  m, bl_seqid[m], bu, lk, wr ? "write" : "read ", start, nr, k - nr);
      bl_nseq[m]  = bl_nseq[m] + 1;
      bl_nbeat[m] = bl_nbeat[m] + nr;
   end
endtask


//----------------------------------------------------------------------------
// Chained reads with no IDLE between bursts: two rounds of INCR8, INCR16 and
// SINGLE, each burst's NONSEQ presented as the previous burst's last beat is
// accepted. No BUSY. Reads of words that do not change during the chain.
//----------------------------------------------------------------------------
reg  [2:0] bl_ebu [0:191];

task automatic bl_chain;
   input integer m;
   input  [31:0] base_a;       // 0x100-byte region
   input  [31:0] incr16_a;     // 0x40-byte aligned
   integer       base;
   integer       k;
   integer       t;
   integer       j;
   integer       n0;
   integer       s;
   integer       idx;
   integer       bad;
   reg    [31:0] a;
   begin
      base        = m*64;
      bl_lk[m]    = 1'b0;
      bl_wr[m]    = 1'b0;
      bl_seqid[m] = bl_seqid[m] + 1;
      k           = 0;
      for (t = 0; t < 2; t = t + 1)
         begin
            for (j = 0; j < 8; j = j + 1)
               begin
                  a = base_a + t*32'h20 + 4*j;
                  bl_tr[base + k] = (j == 0) ? HT_NSEQ : HT_SEQ;  bl_ebu[base + k] = HB_INCR8;  bl_a[base + k] = a;  k = k + 1;
               end
            for (j = 0; j < 16; j = j + 1)
               begin
                  a = incr16_a + 4*j;
                  bl_tr[base + k] = (j == 0) ? HT_NSEQ : HT_SEQ;  bl_ebu[base + k] = HB_INCR16; bl_a[base + k] = a;  k = k + 1;
               end
            a = base_a + 32'hC0 + 4*t;
            bl_tr[base + k] = HT_NSEQ;  bl_ebu[base + k] = HB_SINGLE;  bl_a[base + k] = a;  k = k + 1;
         end
      for (j = 0; j < k; j = j + 1)
         begin
            s                = bl_sub(bl_a[base + j]);
            bl_er[base + j]  = bl_err(m, s, 1'b0);
            bl_ec[base + j]  = 1'b1;
            bl_ed[base + j]  = bl_er[base + j] ? 32'h0 : bl_rdval(s, bl_a[base + j]);
         end

      n0       = rc_n[m];
      bl_bu[m] = bl_ebu[base];
      bl_drive(m, bl_tr[base], bl_a[base]);
      for (j = 0; j < k; j = j + 1)
         begin
            @(posedge free_clk);
            while (bl_rdy(m) !== 1'b1) @(posedge free_clk);
            #1;
            if (j + 1 < k)
               begin
                  bl_bu[m] = bl_ebu[base + j + 1];
                  bl_drive(m, bl_tr[base + j + 1], bl_a[base + j + 1]);
               end
            else
               bl_idle(m);
         end
      @(posedge free_clk);
      while (bl_rdy(m) !== 1'b1) @(posedge free_clk);
      repeat(2) @(posedge free_clk);

      bad = 0;
      if (rc_n[m] - n0 != k)
         begin
            $display("ERROR: M%0d chain %0d (0x%h): %0d beats completed, %0d issued %t", m, bl_seqid[m], base_a, rc_n[m] - n0, k, $time);
            error = error + 1;
            bad   = 1;
         end
      else
         for (j = 0; j < k; j = j + 1)
            begin
               idx = m*256 + ((n0 + j) % 256);
               if ((rc_resp[idx] !== bl_er[base + j]) || (rc_data[idx] !== bl_ed[base + j]))
                  begin
                     $display("ERROR: M%0d chain %0d beat %0d (0x%h, hburst %0d): %0s hrdata 0x%h, expected %0s 0x%h %t",
                              m, bl_seqid[m], j, bl_a[base + j], bl_ebu[base + j], rc_resp[idx] ? "ERROR" : "OKAY",
                              rc_data[idx], bl_er[base + j] ? "ERROR" : "OKAY", bl_ed[base + j], $time);
                     error = error + 1;
                     bad   = 1;
                  end
            end
      if (!bad)
         $display("PASS:  M%0d chain %0d -- INCR8 / INCR16 / SINGLE x2 back to back from 0x%h, %0d beats", m, bl_seqid[m], base_a, k);
      bl_nseq[m]  = bl_nseq[m] + 1;
      bl_nbeat[m] = bl_nbeat[m] + k;
   end
endtask


//----------------------------------------------------------------------------
// Per-manager programs
//----------------------------------------------------------------------------
task automatic bl_program;
   input integer m;
   reg    [31:0] w;           // own SRAM window
   reg    [31:0] ro;          // read-only SRAM window
   reg    [31:0] px;          // own peripheral
   reg    [31:0] un;          // unmapped
   reg    [31:0] rm;          // ROM offset
   begin
      w  = BL_SRAM + ((m == 0) ? 32'h000 : (m == 1) ? 32'h200 : 32'h400);
      ro = BL_SRAM + 32'h600;
      px = (m == 1) ? BL_P0 : BL_P1;
      un = BL_UNMAP + m*32'h1000;
      rm = BL_ROM + m*32'h100;

      bl_seq(m, HB_SINGLE, 1'b0, 1'b0, rm + 32'h040,  1, 16'h0000, 1'b0);
      bl_seq(m, HB_SINGLE, 1'b1, 1'b1, w  + 32'h000,  1, 16'h0000, 1'b0);
      bl_seq(m, HB_INCR,   1'b0, 1'b0, rm + 32'h080,  5, 16'h0005, 1'b1);
      bl_seq(m, HB_WRAP4,  1'b1, 1'b1, w  + 32'h034,  4, 16'h0002, 1'b0);
      bl_seq(m, HB_INCR4,  1'b0, 1'b0, w  + 32'h030,  4, 16'h0005, 1'b0);
      bl_seq(m, HB_WRAP8,  1'b1, 1'b0, rm + 32'h0D8,  8, 16'h0081, 1'b0);
      if (m != 0)
         begin
            bl_seq(m, HB_INCR8,  1'b0, 1'b1, px + 32'h000,  8, 16'h002A, 1'b0);
            bl_seq(m, HB_WRAP16, 1'b1, 1'b0, px + 32'h028, 16, 16'h0421, 1'b0);
         end
      else
         begin
            // generic: REGIN of periph 0; hiperf / fused: outside the executable
            // decoder, executable-side default subordinate
            bl_seq(m, HB_INCR8,  1'b0, 1'b0, BL_P0 + 32'h020, 8, 16'h0055, 1'b0);
            bl_seq(m, HB_WRAP16, 1'b1, 1'b0, ro + 32'h028,   16, 16'h1111, 1'b0);
         end
      bl_seq(m, HB_INCR16, 1'b1, 1'b1, w  + 32'h080, 16, 16'h5A5A, 1'b0);
      bl_seq(m, HB_INCR16, 1'b0, 1'b0, w  + 32'h080, 16, 16'h0F0F, 1'b0);
      bl_seq(m, HB_INCR,   1'b1, 1'b0, un + 32'h010,  4, 16'h0003, 1'b1);
      bl_seq(m, HB_WRAP4,  1'b0, 1'b1, un + 32'h028,  4, 16'h0005, 1'b0);
      bl_seq(m, HB_INCR4,  1'b1, 1'b1, BL_ROM + 32'h300 + m*32'h40, 4, 16'h0006, 1'b0);
      bl_seq(m, HB_INCR,   1'b0, 1'b1, un + 32'h100,  3, 16'h0001, 1'b1);
`ifdef FUSED
      if (m == 0)
         bl_seq(m, HB_WRAP8, 1'b0, 1'b1, ro + 32'h018, 8, 16'h0049, 1'b0);   // m_x write, diverted
`endif
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

      for (bl_i = 0; bl_i < 512; bl_i = bl_i + 1)
         begin
            rom_inst0.mem[bl_i]  = 32'h5B000000 + (bl_i * 32'h00010003);
            sram_inst0.mem[bl_i] = 32'h3A000000 + (bl_i * 32'h00000105);
            bl_sram[bl_i]        = sram_inst0.mem[bl_i];
         end
      for (bl_i = 0; bl_i < 8; bl_i = bl_i + 1)
         begin
            set_regin_value(0, 8 + bl_i, 32'h0E080000 + bl_i);
            set_regin_value(1, 8 + bl_i, 32'h1E080000 + bl_i);
            bl_per[bl_i]      = 32'hxxxxxxxx;
            bl_per[16 + bl_i] = 32'hxxxxxxxx;
            bl_per[8 + bl_i]  = 32'h0E080000 + bl_i;
            bl_per[24 + bl_i] = 32'h1E080000 + bl_i;
         end

      @(negedge free_clk);
      force   ahb_periph_example_inst0.hresetn_i = 1'b0;
      force   ahb_periph_example_inst1.hresetn_i = 1'b0;
      @(negedge free_clk);
      release ahb_periph_example_inst0.hresetn_i;
      release ahb_periph_example_inst1.hresetn_i;
      repeat(10) @(posedge free_clk);

      fq_en = 1'b1;

      //==================================================================
      // A: concurrent burst programs
      //==================================================================
      $display("");
      $display(" =====================================================");
      $display("|  A: BURST PROGRAMS, ALL MANAGERS AT ONCE            |");
      $display(" =====================================================");
      fork
         bl_program(0);
         begin @(posedge free_clk); bl_program(1); end
         begin repeat(2) @(posedge free_clk); bl_program(2); end
      join
      repeat(10) @(posedge free_clk);

      //==================================================================
      // B: BUSY after every beat, same windows from every manager
      //==================================================================
      $display("");
      $display(" =====================================================");
      $display("|  B: INTERLEAVED BEATS (BUSY AFTER EVERY BEAT)       |");
      $display(" =====================================================");
      fork
         begin
`ifdef GENERIC
            bl_seq(0, HB_INCR8,  1'b0, 1'b0, BL_P0 + 32'h020,         8, 16'h007F, 1'b0);
            bl_seq(0, HB_INCR8,  1'b1, 1'b0, BL_P1 + 32'h020,         8, 16'h007F, 1'b0);
`endif
            bl_seq(0, HB_INCR16, 1'b0, 1'b0, BL_SRAM + 32'h600,      16, 16'h7FFF, 1'b0);
            bl_seq(0, HB_WRAP16, 1'b1, 1'b0, BL_ROM  + 32'h420,      16, 16'h7FFF, 1'b0);
         end
         begin
            bl_seq(1, HB_INCR8,  1'b1, 1'b0, BL_P0 + 32'h020,         8, 16'h007F, 1'b0);
            bl_seq(1, HB_WRAP8,  1'b0, 1'b0, BL_P1 + 32'h030,         8, 16'h007F, 1'b0);
            bl_seq(1, HB_INCR16, 1'b1, 1'b0, BL_SRAM + 32'h600,      16, 16'h7FFF, 1'b0);
            bl_seq(1, HB_INCR16, 1'b0, 1'b0, BL_ROM  + 32'h400,      16, 16'h7FFF, 1'b0);
         end
         begin
            bl_seq(2, HB_WRAP8,  1'b0, 1'b0, BL_P0 + 32'h034,         8, 16'h007F, 1'b0);
            bl_seq(2, HB_INCR8,  1'b1, 1'b0, BL_P1 + 32'h020,         8, 16'h007F, 1'b0);
            bl_seq(2, HB_WRAP16, 1'b0, 1'b0, BL_SRAM + 32'h640,      16, 16'h7FFF, 1'b0);
            bl_seq(2, HB_INCR16, 1'b1, 1'b0, BL_ROM  + 32'h440,      16, 16'h7FFF, 1'b0);
         end
      join
      repeat(20) @(posedge free_clk);

`ifdef FUSED
      //==================================================================
      // C: M0 SEQ reads of the SRAM against Port-B write streams
      //==================================================================
      $display("");
      $display(" =====================================================");
      $display("|  C: PORT-A SEQ READS AGAINST PORT-B WRITE BURSTS    |");
      $display(" =====================================================");
      bl_c_on = 1'b1;
      fork
         begin
            bl_c_nb = 1'b1;
            for (bl_i = 0; bl_i < 4; bl_i = bl_i + 1)
               bl_chain(0, BL_SRAM + 32'h600, BL_SRAM + 32'h700 + bl_i*32'h40);
            bl_c_nb = 1'b0;
            for (bl_i = 0; bl_i < 4; bl_i = bl_i + 1)
               begin
                  bl_seq(0, HB_INCR8,  1'b0, 1'b0, BL_SRAM + 32'h600 + bl_i*32'h20,  8, 16'h0012, 1'b0);
                  bl_seq(0, HB_WRAP8,  1'b0, 1'b0, BL_SRAM + 32'h68C + bl_i*32'h20,  8, 16'h0040, 1'b0);
                  bl_seq(0, HB_INCR16, 1'b1, 1'b0, BL_SRAM + 32'h700 + bl_i*32'h40, 16, 16'h0101, 1'b0);
                  bl_seq(0, HB_INCR,   1'b0, 1'b0, BL_SRAM + 32'h604 + bl_i*32'h10,  6, 16'h0004, 1'b1);
               end
         end
         begin
            @(posedge free_clk);
            for (bl_j = 0; bl_j < 12; bl_j = bl_j + 1)
               bl_seq(1, HB_INCR16, 1'b0, 1'b1, BL_SRAM + 32'h300 + (bl_j % 4)*32'h40, 16, 16'h0000, 1'b0);
         end
         begin
            repeat(2) @(posedge free_clk);
            for (bl_k = 0; bl_k < 12; bl_k = bl_k + 1)
               begin
                  bl_seq(2, HB_INCR8,  1'b1, 1'b1, BL_SRAM + 32'h500 + (bl_k % 4)*32'h20,  8, 16'h0000, 1'b0);
                  bl_seq(2, HB_WRAP8,  1'b0, 1'b1, BL_SRAM + 32'h58C + (bl_k % 2)*32'h20,  8, 16'h0000, 1'b0);
               end
         end
      join
      bl_c_on = 1'b0;
      repeat(10) @(posedge free_clk);
      for (bl_j = 0; bl_j < 4; bl_j = bl_j + 1)
         bl_seq(1, HB_INCR16, 1'b0, 1'b0, BL_SRAM + 32'h300 + bl_j*32'h40, 16, 16'h0000, 1'b0);
      for (bl_j = 0; bl_j < 4; bl_j = bl_j + 1)
         bl_seq(2, HB_INCR8,  1'b0, 1'b0, BL_SRAM + 32'h500 + bl_j*32'h20,  8, 16'h0000, 1'b0);
      bl_seq(2, HB_WRAP16, 1'b0, 1'b0, BL_SRAM + 32'h580, 16, 16'h0000, 1'b0);
      $display("INFO:  phase C: %0d M0 wait-state cycles inside SEQ data phases; %0d back-to-back SEQ, %0d NONSEQ-after-SEQ beats stalled",
               bl_c_seqwait, bl_c_seqstall, bl_c_nsstall);
      if (bl_c_nsstall == 0)
         begin
            $display("ERROR: phase C: no M0 NONSEQ presented back to back after a SEQ lost a Port-A contest");
            error = error + 1;
         end
      if (bl_c_seqwait == 0)
         begin
            $display("ERROR: phase C: no M0 SEQ beat was ever held on Port A");
            error = error + 1;
         end
      if (bl_c_seqstall == 0)
         begin
            $display("ERROR: phase C: no back-to-back M0 SEQ beat lost a Port-A contest");
            error = error + 1;
         end
      repeat(10) @(posedge free_clk);
`endif
      fq_en = 1'b0;

      //==================================================================
      // Final checks
      //==================================================================
      $display("");
      for (bl_i = 0; bl_i < 3; bl_i = bl_i + 1)
         begin
            if (fq_rp[bl_i] != fq_wp[bl_i])
               begin
                  $display("ERROR: M%0d issued %0d observable beats, %0d committed", bl_i, fq_wp[bl_i], fq_rp[bl_i]);
                  error = error + 1;
               end
            $display("INFO:  M%0d: %0d bursts, %0d beats, %0d BUSY data phases ended OKAY",
                     bl_i, bl_nseq[bl_i], bl_nbeat[bl_i], bz_cnt[bl_i]);
            if (bz_cnt[bl_i] == 0)
               begin
                  $display("ERROR: M%0d: no BUSY data phase observed", bl_i);
                  error = error + 1;
               end
         end
      $display("INFO:  %0d subordinate commits checked (%0d SEQ)", fq_cnt, fq_seq_cnt);
      $display("INFO:  cached-APH cycles: M0 %0d  M1 %0d  M2 %0d; cached SEQ cycles %0d", bl_pc0, bl_pc1, bl_pc2, bl_pseq);
      $display("INFO:  SEQ committed after another manager's commit: %0d on a shared bus, %0d on the same subordinate",
               bl_seq_after_other, bl_seq_after_other_sub);
      if (fq_seq_cnt == 0)
         begin
            $display("ERROR: no SEQ beat committed at a subordinate port");
            error = error + 1;
         end
      if ((bl_pc1 == 0) || (bl_pc2 == 0))
         begin
            $display("ERROR: no cached address phase on M1 / M2");
            error = error + 1;
         end
`ifdef GENERIC
      if (bl_pc0 == 0)
         begin
            $display("ERROR: no cached address phase on M0");
            error = error + 1;
         end
`endif
      if (bl_pseq == 0)
         begin
            $display("ERROR: no SEQ address phase was ever cached");
            error = error + 1;
         end
      if (bl_seq_after_other == 0)
         begin
            $display("ERROR: no SEQ beat followed another manager's transfer on a shared bus");
            error = error + 1;
         end

      for (bl_i = 0; bl_i < 3; bl_i = bl_i + 1)
         begin
            for (bl_j = 0; bl_j < 3; bl_j = bl_j + 1)
               if ((cv_hb_rise[bl_i*3 + bl_j] == 0) || (cv_hb_fall[bl_i*3 + bl_j] == 0))
                  begin
                     $display("ERROR: M%0d hburst[%0d] rose %0d / fell %0d times", bl_i, bl_j,
                              cv_hb_rise[bl_i*3 + bl_j], cv_hb_fall[bl_i*3 + bl_j]);
                     error = error + 1;
                  end
            if ((cv_lk_rise[bl_i] == 0) || (cv_lk_fall[bl_i] == 0))
               begin
                  $display("ERROR: M%0d hmastlock rose %0d / fell %0d times", bl_i, cv_lk_rise[bl_i], cv_lk_fall[bl_i]);
                  error = error + 1;
               end
            for (bl_j = 0; bl_j < 4; bl_j = bl_j + 1)
               if (cv_tr[bl_i*4 + bl_j] == 0)
                  begin
                     $display("ERROR: M%0d never presented htrans %b", bl_i, bl_j[1:0]);
                     error = error + 1;
                  end
         end

      for (bl_i = 0; bl_i < 512; bl_i = bl_i + 1)
         if (sram_inst0.mem[bl_i] !== bl_sram[bl_i])
            begin
               $display("ERROR: SRAM word %0d = 0x%h, expected 0x%h", bl_i, sram_inst0.mem[bl_i], bl_sram[bl_i]);
               error = error + 1;
            end
      for (bl_i = 0; bl_i < 8; bl_i = bl_i + 1)
         begin
            check_periph_reg_value(0, bl_i, bl_per[bl_i]);
            check_periph_reg_value(1, bl_i, bl_per[16 + bl_i]);
         end

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
