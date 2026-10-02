//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    sideband_hsmode
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : sideband_hsmode.v
// Module Description : HAUSER (hsmode) sideband carried through contended,
//                      delayed-grant traffic; a real subordinate's two-cycle
//                      ERROR with another manager's transfer taken in its
//                      second cycle; an oversized NONSEQ to the default
//                      subordinate. All variants, with/without -random_ws.
//
// Phases
//   A  M0/M1/M2 stream ROM reads and SRAM write/read-backs concurrently
//      (fused: M0 reads only), each manager toggling hauser on every
//      transfer. A monitor keeps a per-manager FIFO of {subordinate, haddr,
//      hauser} pushed at issue and popped at every fabric-side commit
//      (hsel & hready & htrans[1]); the manager is identified by its
//      distinct hprot. The popped entry must match the committed address,
//      subordinate and hauser, and hmaster must be the manager's ID (+tag).
//      Checked on s0..s3 (generic, hiperf) and s2/s3 (fused, where the
//      executable side does not receive the sideband).
//   B  MDELEG of both peripherals opened to Supervisor, then the same
//      toggling traffic on s2/s3 (all admitted), register data checked.
//   C  MDELEG back to Machine-only. M1 in Supervisor mode is refused by the
//      peripheral (two-cycle ERROR, under random wait states), while M2's
//      transfer, presented one cycle later, must be committed in the second
//      ERROR cycle: once for a read (M2 -> other peripheral), once for a
//      write (M2 -> the same peripheral).
//   D  NONSEQ with hsize = 3'b100 and hprot[2] = 1 to an unmapped address:
//      default-subordinate ERROR (reads and a write).
//
// The bench's HAUSER/HPROT checker compares the committed pair with the
// managers' live registers; it is disabled during A and B (the managers
// change hauser every transfer, and the hiperf executable side commits a
// cached transfer after the manager has moved on) and replaced by the FIFO
// check above, which is exact. It is re-enabled for C and D.
//
// Basis (quoted)
//  ahb_interconnect.md, Glossary: "HAUSER | AHB user-defined sideband,
//    HAUSER_W bits wide. The aRVern peripherals use it as the secure-mode
//    signal hsmode; the fabric only forwards it."
//  ahb_interconnect.md, Monitors: "HAUSER / HPROT | At the same instant, the
//    sideband pair a subordinate sees is that of the granted manager."
//  ahb_interconnect.md, What differs: "hmaster / hprot / hauser / hmastlock
//    on the executable side | Forwarded | Forwarded to s_x_* | Not delivered
//    to the controllers"
//  ahb_interconnect.md, HMASTER bits: "The tag is an address-phase signal and
//    follows the transfer through the fabric's address-phase caching like
//    haddr." / "m_x = 4'h0; m_nx[i] = M_NX_HMASTER_ID (default: i+1)"
//  IHI0033C 11.1: "These signals have the same timing and validity
//    requirements as the associated channel."
//  IHI0033C 7.x: "The following signals must be valid when HTRANS is not
//    IDLE: ... HAUSER"
//  ahb_periph_example.md: "1 | 1 | Supervisor mode"; "A transfer is admitted
//    when its decoded privilege is numerically greater than or equal to the
//    relevant gate"; "After reset, the peripheral is therefore fully
//    Machine-mode locked."; "Denied, RESP = 1 | Two-cycle ERROR; nothing
//    stored; hrdata_o = 0"
//  IHI0033C 5.1.3: "To start the ERROR response, the Subordinate drives
//    HRESP HIGH to indicate ERROR while driving HREADYOUT LOW to extend the
//    transfer for one extra cycle. In the next cycle HREADYOUT is driven HIGH
//    to end the transfer and HRESP remains driven HIGH to indicate ERROR."
//    "If the Subordinate requires more than two cycles to provide the ERROR
//    response, then additional wait states can be inserted at the start of
//    the transfer. During this time HREADY is LOW and the response must be
//    set to OKAY."
//  ahb_interconnect.md, Constraint #7: "A grant is acted upon only while the
//    bus can accept an address phase (m_grant_i & hreadyout_i)"; Arbitrated
//    grant switch: "the bus itself never idles."
//  IHI0033C 4.2.1: "If a NONSEQUENTIAL or SEQUENTIAL transfer is attempted to
//    a nonexistent address location, then the default Subordinate provides
//    an ERROR response."
//  ahb_interconnect.md: "Transfer sizes above a word are not checked either"
//    / default subordinate: "Answers every NONSEQ/SEQ transfer with the AHB
//    two-cycle ERROR (hreadyout low then high, hresp = 1, hrdata = 0)."
//----------------------------------------------------------------------------

localparam [31:0] SH_ROM   = 32'h00400000;
localparam [31:0] SH_SRAM  = 32'h00401000;
localparam [31:0] SH_P0    = 32'h00402000;
localparam [31:0] SH_P1    = 32'h00403000;
localparam [31:0] SH_UNMAP = 32'h00800000;

integer    sh_i;
integer    sh_a0;
integer    sh_a1;
integer    sh_a2;
integer    sh_r1;
integer    sh_r2;
integer    sh_n0;
integer    sh_n1;
integer    sh_n2;
integer    sh_e0;
integer    sh_e1;
integer    sh_e2;
reg [31:0] sh_p0 [0:7];
reg [31:0] sh_p1 [0:7];


//----------------------------------------------------------------------------
// Manager-side response recorder. A transfer is accepted at an edge where the
// DUT sees htrans[1] and the manager's hready is high; its data phase ends at
// the next edge with hready high. Logs response, data and time per transfer
// and checks the ERROR shape: optional OKAY wait states, then exactly one
// cycle hready=0/hresp=1, then hready=1/hresp=1.
//----------------------------------------------------------------------------
reg        rc_out  [0:2];
reg        rc_err1 [0:2];
integer    rc_n    [0:2];
integer    rc_errs [0:2];
reg        rc_resp [0:767];
reg [31:0] rc_data [0:767];
reg [63:0] rc_time [0:767];
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
                  rc_time[idx] = $time;
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
   input            chk_data;
   input     [31:0] exp_data;
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
      else if (chk_data && (rc_data[idx] !== exp_data))
         begin
            $display("ERROR: M%0d %0s -- hrdata 0x%h, expected 0x%h %t", m, what, rc_data[idx], exp_data, $time);
            error = error + 1;
         end
      else
         $display("PASS:  M%0d %0s -- %0s", m, what, exp_resp ? "ERROR" : "OKAY");
   end
endtask


//----------------------------------------------------------------------------
// Delayed-grant evidence: cycles with a cached address phase per manager.
//----------------------------------------------------------------------------
wire sh_m0_pend;
wire sh_m1_pend;
wire sh_m2_pend;
`ifdef FUSED
assign sh_m0_pend = 1'b0;
assign sh_m1_pend = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_aph_pending;
assign sh_m2_pend = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_aph_pending;
`elsif HIPERF
assign sh_m0_pend = 1'b0;
assign sh_m1_pend = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_aph_pending;
assign sh_m2_pend = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_aph_pending;
`else
assign sh_m0_pend = dut.ahb_manager_mux_inst.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_aph_pending;
assign sh_m1_pend = dut.ahb_manager_mux_inst.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_aph_pending;
assign sh_m2_pend = dut.ahb_manager_mux_inst.AHB_MANAGER_IF[2].ahb_manager_if_inst.m_aph_pending;
`endif

integer sh_pc0;
integer sh_pc1;
integer sh_pc2;
initial
   begin
      sh_pc0 = 0;
      sh_pc1 = 0;
      sh_pc2 = 0;
   end

always @(posedge free_clk)
   if (hresetn && tb_rst_done)
      begin
         if (sh_m0_pend === 1'b1) sh_pc0 = sh_pc0 + 1;
         if (sh_m1_pend === 1'b1) sh_pc1 = sh_pc1 + 1;
         if (sh_m2_pend === 1'b1) sh_pc2 = sh_pc2 + 1;
      end


//----------------------------------------------------------------------------
// Sideband FIFO monitor
//----------------------------------------------------------------------------
reg [34:0] sh_q      [0:767];      // {subordinate[1:0], hauser, haddr}
integer    sh_wp     [0:2];
integer    sh_rp     [0:2];
reg        sh_tog    [0:2];
reg        sh_mon_en;
integer    sh_obs_cnt;

initial
   begin
      for (sh_i = 0; sh_i < 3; sh_i = sh_i + 1)
         begin
            sh_wp[sh_i]  = 0;
            sh_rp[sh_i]  = 0;
            sh_tog[sh_i] = 1'b0;
         end
      sh_mon_en  = 1'b0;
      sh_obs_cnt = 0;
   end

function integer sh_sub;
   input [31:0] a;
   begin
      if      ((a >= 32'h00400000) && (a < 32'h00400800)) sh_sub = 0;
      else if ((a >= 32'h00401000) && (a < 32'h00401800)) sh_sub = 1;
      else if ((a >= 32'h00402000) && (a < 32'h00402080)) sh_sub = 2;
      else if ((a >= 32'h00403000) && (a < 32'h00403080)) sh_sub = 3;
      else                                                 sh_sub = -1;
   end
endfunction

function sh_observable;
   input integer s;
   begin
`ifdef FUSED
      sh_observable = (s == 2) || (s == 3);
`else
      sh_observable = (s >= 0);
`endif
   end
endfunction

task sh_commit;
   input integer        s;
   input         [31:0] a;
   input          [3:0] prot;
   input [HAUSER_W-1:0] hu;
   input          [3:0] hm;
   integer              m;
   integer              idx;
   reg           [34:0] e;
   reg            [3:0] exp_hm;
   begin
      m = (prot === MGR0_HPROT) ? 0 : (prot === MGR1_HPROT) ? 1 : (prot === MGR2_HPROT) ? 2 : -1;
      if (m < 0)
         begin
            $display("ERROR: s%0d commit with hprot 0x%h, which belongs to no manager %t", s, prot, $time);
            error = error + 1;
         end
      else if (sh_rp[m] == sh_wp[m])
         begin
            $display("ERROR: s%0d commit from M%0d (haddr 0x%h) with no transfer of M%0d outstanding %t", s, m, a, m, $time);
            error = error + 1;
         end
      else
         begin
            idx      = m*256 + (sh_rp[m] % 256);
            e        = sh_q[idx];
            sh_rp[m] = sh_rp[m] + 1;
            exp_hm   = m[3:0] | (((m == 1) && a[2]) ? 4'h8 : 4'h0);
            sh_obs_cnt = sh_obs_cnt + 1;
            if ((e[34:33] !== s[1:0]) || (e[31:0] !== a))
               begin
                  $display("ERROR: M%0d commit on s%0d haddr 0x%h, next issued was s%0d haddr 0x%h %t",
                           m, s, a, e[34:33], e[31:0], $time);
                  error = error + 1;
               end
            else if (hu[0] !== e[32])
               begin
                  $display("ERROR: M%0d commit on s%0d haddr 0x%h: hauser %b, issued with %b %t",
                           m, s, a, hu[0], e[32], $time);
                  error = error + 1;
               end
            if (hm !== exp_hm)
               begin
                  $display("ERROR: M%0d commit on s%0d haddr 0x%h: hmaster 0x%h, expected 0x%h %t",
                           m, s, a, hm, exp_hm, $time);
                  error = error + 1;
               end
         end
   end
endtask

always @(posedge free_clk)
   if (hresetn && tb_rst_done && sh_mon_en)
      begin
`ifndef FUSED
         if (s0_hsel & s0_hready & s0_htrans[1]) sh_commit(0, s0_haddr, s0_hprot, s0_hauser, s0_hmaster);
         if (s1_hsel & s1_hready & s1_htrans[1]) sh_commit(1, s1_haddr, s1_hprot, s1_hauser, s1_hmaster);
`endif
         if (s2_hsel & s2_hready & s2_htrans[1]) sh_commit(2, s2_haddr, s2_hprot, s2_hauser, s2_hmaster);
         if (s3_hsel & s3_hready & s3_htrans[1]) sh_commit(3, s3_haddr, s3_hprot, s3_hauser, s3_hmaster);
      end

// Issue one pipelined transfer with the manager's next hauser value.
task automatic sh_issue;
   input integer m;
   input         wr;
   input  [31:0] a;
   input  [31:0] d;          // write data, or expected read data
   integer       s;
   reg           hu;
   begin
      hu        = sh_tog[m];
      sh_tog[m] = ~sh_tog[m];
      s         = sh_sub(a);
      case (m)
         0:       m0_hauser = hu;
         1:       m1_hauser = hu;
         default: m2_hauser = hu;
      endcase
      if (sh_observable(s))
         begin
            sh_q[m*256 + (sh_wp[m] % 256)] = {s[1:0], hu, a};
            sh_wp[m] = sh_wp[m] + 1;
         end
      if (wr) ahb_write(m, 0, a, d, 2);
      else    ahb_read (m, 0, a, d, 2, 1);
   end
endtask

task sh_fifo_drained;
   input [8*16-1:0] phase;
   begin
      for (sh_i = 0; sh_i < 3; sh_i = sh_i + 1)
         if (sh_rp[sh_i] != sh_wp[sh_i])
            begin
               $display("ERROR: phase %0s: M%0d issued %0d observable transfers, %0d committed", phase, sh_i, sh_wp[sh_i], sh_rp[sh_i]);
               error = error + 1;
            end
      $display("INFO:  phase %0s: %0d commits checked for hauser/hmaster/order", phase, sh_obs_cnt);
   end
endtask


//----------------------------------------------------------------------------
// Commit watch for phase C: time at which M2's transfer is committed.
//----------------------------------------------------------------------------
integer    sh_cw;
reg [63:0] sh_ct;
initial
   begin
      sh_cw = 0;
      sh_ct = 0;
   end

always @(posedge free_clk)
   if (hresetn && tb_rst_done)
      begin
         if ((sh_cw == 2) && s2_hsel && s2_hready && s2_htrans[1] && (s2_hprot === MGR2_HPROT)) sh_ct = $time;
         if ((sh_cw == 3) && s3_hsel && s3_hready && s3_htrans[1] && (s3_hprot === MGR2_HPROT)) sh_ct = $time;
      end


//----------------------------------------------------------------------------
// Raw transfer with hsize = 3'b100 and hprot[2] set (not expressible with
// the bench tasks, which take a 2-bit size).
//----------------------------------------------------------------------------
function sh_rdy;
   input integer m;
   begin
      sh_rdy = (m == 0) ? m0_hready : (m == 1) ? m1_hready : m2_hready;
   end
endfunction

task automatic sh_raw;
   input integer m;
   input         wr;
   input  [31:0] a;
   begin
      case (m)
         0: begin m0_hprot = MGR0_HPROT | 4'h4; m0_haddr = a; m0_htrans = 2'b10; m0_hwrite = wr; m0_hsize = 3'b100; end
         1: begin m1_hprot = MGR1_HPROT | 4'h4; m1_haddr = a; m1_htrans = 2'b10; m1_hwrite = wr; m1_hsize = 3'b100; end
         default:
            begin m2_hprot = MGR2_HPROT | 4'h4; m2_haddr = a; m2_htrans = 2'b10; m2_hwrite = wr; m2_hsize = 3'b100; end
      endcase
      @(posedge free_clk);
      while (~sh_rdy(m)) @(posedge free_clk);
      #1;
      case (m)
         0: begin m0_hwdata = 32'hA5A55A5A; m0_haddr = 32'h0; m0_htrans = 2'b00; m0_hwrite = 1'b0; m0_hsize = 3'b000; end
         1: begin m1_hwdata = 32'hA5A55A5A; m1_haddr = 32'h0; m1_htrans = 2'b00; m1_hwrite = 1'b0; m1_hsize = 3'b000; end
         default:
            begin m2_hwdata = 32'hA5A55A5A; m2_haddr = 32'h0; m2_htrans = 2'b00; m2_hwrite = 1'b0; m2_hsize = 3'b000; end
      endcase
      $display("INFO:  M%0d NONSEQ hsize=3'b100 hprot[2]=1 %0s -- address: 0x%h %t", m, wr ? "write" : "read", a, $time);
      @(posedge free_clk);
      while (~sh_rdy(m)) @(posedge free_clk);
      case (m)
         0:       m0_hprot = MGR0_HPROT;
         1:       m1_hprot = MGR1_HPROT;
         default: m2_hprot = MGR2_HPROT;
      endcase
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

      for (tb_idx = 0; tb_idx < MEM_SIZE/4; tb_idx = tb_idx + 1)
         rom_inst0.mem[tb_idx]  = 32'h9E000000 + (tb_idx * 32'h00010003);
      for (tb_idx = 0; tb_idx < MEM_SIZE/4; tb_idx = tb_idx + 1)
         sram_inst0.mem[tb_idx] = 32'h00000000;
      for (tb_idx = 0; tb_idx < 16; tb_idx = tb_idx + 1)
         sram_inst0.mem[192 + tb_idx] = 32'h3C3C0000 + tb_idx;       // 0x300.., read by M0 on fused

      for (sh_i = 0; sh_i < 8; sh_i = sh_i + 1)
         begin
            set_regin_value(0, 8 + sh_i, 32'h0E080000 + sh_i);
            set_regin_value(1, 8 + sh_i, 32'h1E080000 + sh_i);
         end

      @(negedge free_clk);
      force   ahb_periph_example_inst0.hresetn_i = 1'b0;
      force   ahb_periph_example_inst1.hresetn_i = 1'b0;
      @(negedge free_clk);
      release ahb_periph_example_inst0.hresetn_i;
      release ahb_periph_example_inst1.hresetn_i;
      repeat(10) @(posedge free_clk);

      //==================================================================
      // A: contended ROM / SRAM traffic, hauser toggling per transfer
      //==================================================================
      $display("");
      $display(" =====================================================");
      $display("|  A: ROM/SRAM contention, hauser toggling           |");
      $display(" =====================================================");
      sideband_checker_enable = 1'b0;
      sh_mon_en = 1'b1;
      sh_pc0 = 0; sh_pc1 = 0; sh_pc2 = 0;
      sh_e0 = rc_errs[0]; sh_e1 = rc_errs[1]; sh_e2 = rc_errs[2];

      fork
         begin                                                    // M0
            for (sh_a0 = 0; sh_a0 < 16; sh_a0 = sh_a0 + 1)
               begin
                  sh_issue(0, 0, SH_ROM + 4*sh_a0, rom_inst0.mem[sh_a0]);
`ifdef FUSED
                  sh_issue(0, 0, SH_SRAM + 32'h300 + 4*sh_a0, 32'h3C3C0000 + sh_a0);
`else
                  sh_issue(0, 1, SH_SRAM + 32'h000 + 4*sh_a0, 32'h50000000 + sh_a0);
                  sh_issue(0, 0, SH_SRAM + 32'h000 + 4*sh_a0, 32'h50000000 + sh_a0);
`endif
               end
         end
         begin                                                    // M1
            for (sh_a1 = 0; sh_a1 < 16; sh_a1 = sh_a1 + 1)
               begin
                  sh_issue(1, 0, SH_ROM + 4*(16 + sh_a1), rom_inst0.mem[16 + sh_a1]);
                  sh_issue(1, 1, SH_SRAM + 32'h100 + 4*sh_a1, 32'h51000000 + sh_a1);
                  sh_issue(1, 0, SH_SRAM + 32'h100 + 4*sh_a1, 32'h51000000 + sh_a1);
               end
         end
         begin                                                    // M2
            for (sh_a2 = 0; sh_a2 < 16; sh_a2 = sh_a2 + 1)
               begin
                  sh_issue(2, 0, SH_ROM + 4*(32 + sh_a2), rom_inst0.mem[32 + sh_a2]);
                  sh_issue(2, 1, SH_SRAM + 32'h200 + 4*sh_a2, 32'h52000000 + sh_a2);
                  sh_issue(2, 0, SH_SRAM + 32'h200 + 4*sh_a2, 32'h52000000 + sh_a2);
               end
         end
      join
      repeat(40) @(posedge free_clk);

      sh_fifo_drained("A");
      if ((rc_errs[0] != sh_e0) || (rc_errs[1] != sh_e1) || (rc_errs[2] != sh_e2))
         begin
            $display("ERROR: phase A: unexpected ERROR responses");
            error = error + 1;
         end
      if ((sh_pc1 == 0) || (sh_pc2 == 0))
         begin
            $display("ERROR: phase A: no delayed grant observed (M1 %0d, M2 %0d cached cycles)", sh_pc1, sh_pc2);
            error = error + 1;
         end
`ifdef GENERIC
      if (sh_pc0 == 0)
         begin
            $display("ERROR: phase A: no delayed grant observed on M0");
            error = error + 1;
         end
`endif
      $display("INFO:  phase A cached-APH cycles: M0 %0d  M1 %0d  M2 %0d", sh_pc0, sh_pc1, sh_pc2);

      //==================================================================
      // B: peripherals opened to Supervisor, toggling traffic on s2/s3
      //==================================================================
      $display("");
      $display(" =====================================================");
      $display("|  B: peripherals opened to S-mode, hauser toggling   |");
      $display(" =====================================================");
      sh_mon_en = 1'b0;
      m1_hauser = 1'b0;                                           // Machine mode for MDELEG
      ahb_write(1, 1, SH_P0 + 32'h40, 32'h00000105, 2);          // WR_PRIV = RD_PRIV = S, RESP = 1
      ahb_write(1, 1, SH_P1 + 32'h40, 32'h00000105, 2);
      ahb_read (1, 1, SH_P0 + 32'h40, 32'h00000105, 2, 1);
      ahb_read (1, 1, SH_P1 + 32'h40, 32'h00000105, 2, 1);
      repeat(5) @(posedge free_clk);

      sh_mon_en = 1'b1;
      sh_pc0 = 0; sh_pc1 = 0; sh_pc2 = 0;
      sh_obs_cnt = 0;
      sh_e0 = rc_errs[0]; sh_e1 = rc_errs[1]; sh_e2 = rc_errs[2];

      fork
         begin                                                    // M1: REGOUT_00..03
            for (sh_r1 = 0; sh_r1 < 8; sh_r1 = sh_r1 + 1)
               begin
                  sh_p0[sh_r1 % 4] = 32'hA1000000 + (sh_r1 << 8) + (sh_r1 % 4);
                  sh_p1[sh_r1 % 4] = 32'hB1000000 + (sh_r1 << 8) + (sh_r1 % 4);
                  sh_issue(1, 1, SH_P0 + 4*(sh_r1 % 4), sh_p0[sh_r1 % 4]);
                  sh_issue(1, 1, SH_P1 + 4*(sh_r1 % 4), sh_p1[sh_r1 % 4]);
                  sh_issue(1, 0, SH_P0 + 4*(sh_r1 % 4), sh_p0[sh_r1 % 4]);
                  sh_issue(1, 0, SH_P1 + 4*(sh_r1 % 4), sh_p1[sh_r1 % 4]);
               end
         end
         begin                                                    // M2: REGOUT_04..07
            for (sh_r2 = 0; sh_r2 < 8; sh_r2 = sh_r2 + 1)
               begin
                  sh_p0[4 + (sh_r2 % 4)] = 32'hA2000000 + (sh_r2 << 8) + (sh_r2 % 4);
                  sh_p1[4 + (sh_r2 % 4)] = 32'hB2000000 + (sh_r2 << 8) + (sh_r2 % 4);
                  sh_issue(2, 1, SH_P0 + 32'h10 + 4*(sh_r2 % 4), sh_p0[4 + (sh_r2 % 4)]);
                  sh_issue(2, 1, SH_P1 + 32'h10 + 4*(sh_r2 % 4), sh_p1[4 + (sh_r2 % 4)]);
                  sh_issue(2, 0, SH_P0 + 32'h10 + 4*(sh_r2 % 4), sh_p0[4 + (sh_r2 % 4)]);
                  sh_issue(2, 0, SH_P1 + 32'h10 + 4*(sh_r2 % 4), sh_p1[4 + (sh_r2 % 4)]);
               end
         end
`ifdef GENERIC
         begin                                                    // M0: REGIN_08..15 (generic only)
            for (sh_a0 = 0; sh_a0 < 8; sh_a0 = sh_a0 + 1)
               begin
                  sh_issue(0, 0, SH_P0 + 32'h20 + 4*sh_a0, 32'h0E080000 + sh_a0);
                  sh_issue(0, 0, SH_P1 + 32'h20 + 4*sh_a0, 32'h1E080000 + sh_a0);
               end
         end
`endif
      join
      repeat(40) @(posedge free_clk);

      sh_fifo_drained("B");
      if ((rc_errs[0] != sh_e0) || (rc_errs[1] != sh_e1) || (rc_errs[2] != sh_e2))
         begin
            $display("ERROR: phase B: unexpected ERROR responses (Supervisor must be admitted)");
            error = error + 1;
         end
      if ((sh_pc1 == 0) || (sh_pc2 == 0))
         begin
            $display("ERROR: phase B: no delayed grant observed (M1 %0d, M2 %0d cached cycles)", sh_pc1, sh_pc2);
            error = error + 1;
         end
      for (sh_i = 0; sh_i < 8; sh_i = sh_i + 1)
         begin
            check_periph_reg_value(0, sh_i, sh_p0[sh_i]);
            check_periph_reg_value(1, sh_i, sh_p1[sh_i]);
         end

      //==================================================================
      // C: Supervisor access refused by a Machine-only peripheral
      //==================================================================
      $display("");
      $display(" =====================================================");
      $display("|  C: refused S-mode access, next transfer in ERROR#2 |");
      $display(" =====================================================");
      sh_mon_en = 1'b0;
      m1_hauser = 1'b0;
      m2_hauser = 1'b0;
      m0_hauser = 1'b0;
      ahb_write(1, 1, SH_P0 + 32'h40, 32'h0000010F, 2);          // back to Machine-only, RESP = 1
      ahb_write(1, 1, SH_P1 + 32'h40, 32'h0000010F, 2);
      ahb_read (1, 1, SH_P0 + 32'h40, 32'h0000010F, 2, 1);
      ahb_read (1, 1, SH_P1 + 32'h40, 32'h0000010F, 2, 1);
      repeat(5) @(posedge free_clk);
      sideband_checker_enable = 1'b1;

      // C1: M1 S-mode read of periph0 REGOUT_00 (refused); M2 M-mode read of periph1
      sh_n1 = rc_n[1];
      sh_n2 = rc_n[2];
      sh_ct = 0;
      sh_cw = 3;
      fork
         begin
            m1_hauser = 1'b1;
            ahb_read(1, 1, SH_P0 + 32'h00, 32'h00000000, 2, 1);
         end
         begin
            @(posedge free_clk);
            ahb_read(2, 1, SH_P1 + 32'h14, sh_p1[5], 2, 1);
         end
      join
      m1_hauser = 1'b0;
      repeat(5) @(posedge free_clk);
      sh_cw = 0;
      rc_expect(1, sh_n1, 1'b1, 1'b1, 32'h0,    "S-mode read of M-only REGOUT_00       ");
      rc_expect(2, sh_n2, 1'b0, 1'b1, sh_p1[5], "M-mode read issued during the ERROR   ");
      if (sh_ct == 0)
         begin
            $display("ERROR: C1: M2 read never committed on s3");
            error = error + 1;
         end
      else if ((rc_n[1] > sh_n1) && (sh_ct != rc_time[256 + (sh_n1 % 256)]))
         begin
            $display("ERROR: C1: M2 committed at %0t, M1's second ERROR cycle ended at %0t", sh_ct, rc_time[256 + (sh_n1 % 256)]);
            error = error + 1;
         end
      else
         $display("PASS:  C1: M2 address phase taken in M1's second ERROR cycle");

      // C2: M1 S-mode write of periph0 REGOUT_01 (refused); M2 M-mode write of periph0 REGOUT_06
      repeat(5) @(posedge free_clk);
      sh_n1 = rc_n[1];
      sh_n2 = rc_n[2];
      sh_ct = 0;
      sh_cw = 2;
      fork
         begin
            m1_hauser = 1'b1;
            ahb_write(1, 1, SH_P0 + 32'h04, 32'hBADBAD01, 2);
         end
         begin
            @(posedge free_clk);
            ahb_write(2, 1, SH_P0 + 32'h18, 32'h600D0006, 2);
         end
      join
      m1_hauser = 1'b0;
      sh_p0[6] = 32'h600D0006;
      repeat(5) @(posedge free_clk);
      sh_cw = 0;
      rc_expect(1, sh_n1, 1'b1, 1'b0, 32'h0, "S-mode write of M-only REGOUT_01      ");
      rc_expect(2, sh_n2, 1'b0, 1'b0, 32'h0, "M-mode write issued during the ERROR  ");
      if (sh_ct == 0)
         begin
            $display("ERROR: C2: M2 write never committed on s2");
            error = error + 1;
         end
      else if ((rc_n[1] > sh_n1) && (sh_ct != rc_time[256 + (sh_n1 % 256)]))
         begin
            $display("ERROR: C2: M2 committed at %0t, M1's second ERROR cycle ended at %0t", sh_ct, rc_time[256 + (sh_n1 % 256)]);
            error = error + 1;
         end
      else
         $display("PASS:  C2: M2 address phase taken in M1's second ERROR cycle (same subordinate)");
      check_periph_reg_value(0, 1, sh_p0[1]);                     // refused write stored nothing
      check_periph_reg_value(0, 6, sh_p0[6]);
      ahb_read(1, 1, SH_P0 + 32'h04, sh_p0[1], 2, 1);            // Machine mode reads it back
      ahb_read(2, 1, SH_P0 + 32'h18, sh_p0[6], 2, 1);

      //==================================================================
      // D: NONSEQ, hsize = 3'b100, hprot[2] = 1 to an unmapped address
      //==================================================================
      $display("");
      $display(" =====================================================");
      $display("|  D: hsize=3'b100 / hprot[2]=1 to unmapped address   |");
      $display(" =====================================================");
      repeat(5) @(posedge free_clk);
      sh_n0 = rc_n[0];
      sh_n1 = rc_n[1];
      sh_n2 = rc_n[2];
      sh_raw(1, 1'b0, SH_UNMAP + 32'h10);
      sh_raw(1, 1'b1, SH_UNMAP + 32'h20);
      sh_raw(0, 1'b0, SH_UNMAP + 32'h30);
      sh_raw(2, 1'b0, SH_UNMAP + 32'h40);
      repeat(5) @(posedge free_clk);
      rc_expect(1, sh_n1,     1'b1, 1'b1, 32'h0, "hsize=100 read, unmapped              ");
      rc_expect(1, sh_n1 + 1, 1'b1, 1'b0, 32'h0, "hsize=100 write, unmapped             ");
      rc_expect(0, sh_n0,     1'b1, 1'b1, 32'h0, "hsize=100 read, unmapped              ");
      rc_expect(2, sh_n2,     1'b1, 1'b1, 32'h0, "hsize=100 read, unmapped              ");

      // Every manager keeps working afterwards
      ahb_read(1, 1, SH_SRAM + 32'h100, 32'h51000000, 2, 1);
      ahb_read(2, 1, SH_P1 + 32'h14, sh_p1[5], 2, 1);
      ahb_read(0, 1, SH_ROM + 32'h40, rom_inst0.mem[16], 2, 1);

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
