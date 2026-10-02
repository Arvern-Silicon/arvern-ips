//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    subordinate_error
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : subordinate_error.v
// Module Description : A two-cycle ERROR from every subordinate port, seen by
//                      every manager that reaches it, and the transfers held
//                      through it. All variants.
//
// The bench's wait-state inserters carry an error-injection hook (err_req):
// raised once, the next NONSEQ / SEQ that reaches the inserter is answered
// with a two-cycle ERROR (hrdata 0) and never reaches the subordinate behind.
// Ports with an inserter: s0..s3 on generic and hiperf (executable side
// s0 / s1, non-executable s2 / s3), s2 / s3 on fused. The fused executable
// side has no subordinate port: its ERROR sources are the ROM controller on a
// Port-B write and the executable-side default subordinate (m_x write).
//
// Phase A  Isolated: for every (manager, port) pair the fabric connects, an
//          injected ERROR on a read and on a write, each followed by an OKAY
//          access to the same address; the refused write stores nothing.
//          ROM writes (generic / hiperf s0, fused ROM controller Port B) are
//          answered ERROR by the ROM controller itself.
// Phase B  Same manager, pipelined: an injected ERROR with the manager's next
//          two transfers presented during it (the manager does not cancel):
//          both are taken afterwards, in order, with their data.
// Phase C  Another manager, presented one cycle after the erroring transfer
//          (generic, and the non-executable side): its address phase is
//          committed in the second ERROR cycle. On the hiperf executable side
//          order and data only.
//
// Checks: ERROR shape at the manager (hready 0 with hresp 1, then hready 1
// with hresp 1), hrdata 0 on a refused read, no hresp outside a data phase,
// an idle manager reads hready = 1 during another manager's ERROR, every
// s_hresp bit of every port rises and falls, memory / register contents.
//
// Basis (quoted)
//  IHI0033C 5.1.3: "To start the ERROR response, the Subordinate drives HRESP
//    HIGH to indicate ERROR while driving HREADYOUT LOW to extend the transfer
//    for one extra cycle. In the next cycle HREADYOUT is driven HIGH to end
//    the transfer and HRESP remains driven HIGH to indicate ERROR."; "The
//    two-cycle response provides sufficient time for the Manager to cancel
//    this next access".
//  ahb_interconnect.md, Generic fabric: "hrdata / hreadyout / hresp reach the
//    manager in the cycle the subordinate drives them."
//  ahb_interconnect.md, hready wiring: "a manager that does not own the data
//    phase reads hready = 1 while the bus is stalled, and one with an address
//    phase waiting for a grant reads 0"; "The hiperf and fused variants run two
//    independent hready networks".
//  ahb_interconnect.md, Constraint #7: "A grant is acted upon only while the
//    bus can accept an address phase (m_grant_i & hreadyout_i)"; Arbitrated
//    grant switch: "the bus itself never idles."
//  ahb_interconnect.md, Integration requirements: "hresp = 1 comes only from
//    the default subordinates and from the fused ROM controller on a write"
//    (inside the fabric); Fused fabric: "on the ROM controller a write is
//    answered with the two-cycle ERROR"; "A write presented by m_x never
//    reaches a controller: the fabric routes it to the executable-side default
//    subordinate, which answers ERROR".
//----------------------------------------------------------------------------

localparam [31:0] SE_ROM   = 32'h00400000;
localparam [31:0] SE_SRAM  = 32'h00401000;
localparam [31:0] SE_P0    = 32'h00402000;
localparam [31:0] SE_P1    = 32'h00403000;

integer    se_i;
integer    se_m;
integer    se_s;
integer    se_n;
integer    se_n2;
reg [31:0] se_per [0:31];


//----------------------------------------------------------------------------
// Manager-side response recorder (see sideband_hsmode.v)
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
      else
         begin
            if (rsp !== 1'b0)
               begin
                  $display("ERROR: M%0d hresp=%b with no transfer outstanding %t", m, rsp, $time);
                  error = error + 1;
               end
            if (!tr[1] && (rdy !== 1'b1))
               begin
                  $display("ERROR: M%0d hready=%b while idle with no transfer outstanding %t", m, rdy, $time);
                  error = error + 1;
               end
         end
      if (tr[1] & rdy) rc_out[m] = 1'b1;
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
         rc_sample(0, m0_htrans_d, m0_hready, m0_hresp, m0_hrdata);
         rc_sample(1, m1_htrans_d, m1_hready, m1_hresp, m1_hrdata);
         rc_sample(2, m2_htrans_d, m2_hready, m2_hresp, m2_hrdata);
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
// Commit time per (port, manager); hresp edges per port
//----------------------------------------------------------------------------
reg [63:0] se_ct   [0:11];
integer    se_hr_r [0:3];
integer    se_hr_f [0:3];
reg        se_hr_p [0:3];

initial
   begin
      for (se_i = 0; se_i < 12; se_i = se_i + 1)
         se_ct[se_i] = 0;
      for (se_i = 0; se_i < 4; se_i = se_i + 1)
         begin
            se_hr_r[se_i] = 0;
            se_hr_f[se_i] = 0;
            se_hr_p[se_i] = 1'b0;
         end
   end

task se_commit;
   input integer s;
   input   [3:0] hm;
   begin
      if (hm[2:0] <= 2) se_ct[s*3 + hm[2:0]] = $time;
   end
endtask

task se_hresp;
   input integer s;
   input         r;
   begin
      if (!se_hr_p[s] && (r === 1'b1)) se_hr_r[s] = se_hr_r[s] + 1;
      if ( se_hr_p[s] && (r === 1'b0)) se_hr_f[s] = se_hr_f[s] + 1;
      se_hr_p[s] = (r === 1'b1);
   end
endtask

always @(posedge free_clk)
   if (hresetn && tb_rst_done)
      begin
`ifndef FUSED
         if (s0_hsel & s0_hready & s0_htrans[1]) se_commit(0, s0_hmaster);
         if (s1_hsel & s1_hready & s1_htrans[1]) se_commit(1, s1_hmaster);
         se_hresp(0, s0_hresp);
         se_hresp(1, s1_hresp);
`endif
         if (s2_hsel & s2_hready & s2_htrans[1]) se_commit(2, s2_hmaster);
         if (s3_hsel & s3_hready & s3_htrans[1]) se_commit(3, s3_hmaster);
         se_hresp(2, s2_hresp);
         se_hresp(3, s3_hresp);
      end


//----------------------------------------------------------------------------
// Helpers
//----------------------------------------------------------------------------
task se_arm;
   input integer s;
   begin
      case (s)
`ifndef FUSED
         0: ahb_waitstate_inserter_rom_inst.err_req     = ahb_waitstate_inserter_rom_inst.err_req     + 1;
         1: ahb_waitstate_inserter_sram_inst.err_req    = ahb_waitstate_inserter_sram_inst.err_req    + 1;
`endif
         2: ahb_waitstate_inserter_periph0_inst.err_req = ahb_waitstate_inserter_periph0_inst.err_req + 1;
         3: ahb_waitstate_inserter_periph1_inst.err_req = ahb_waitstate_inserter_periph1_inst.err_req + 1;
         default: ;
      endcase
   end
endtask

function se_armed;
   input integer s;
   begin
      case (s)
`ifndef FUSED
         0:       se_armed = ahb_waitstate_inserter_rom_inst.err_arm;
         1:       se_armed = ahb_waitstate_inserter_sram_inst.err_arm;
`endif
         2:       se_armed = ahb_waitstate_inserter_periph0_inst.err_arm;
         3:       se_armed = ahb_waitstate_inserter_periph1_inst.err_arm;
         default: se_armed = 1'b0;
      endcase
   end
endfunction

// Port s reachable from manager m on this variant.
function se_reach;
   input integer m;
   input integer s;
   begin
`ifdef FUSED
      se_reach = (m != 0) && (s >= 2);
`elsif HIPERF
      se_reach = (m != 0) || (s < 2);
`else
      se_reach = 1'b1;
`endif
   end
endfunction

// Word used on port s by manager m; its content is se_rd(m, s).
function [31:0] se_addr;
   input integer m;
   input integer s;
   begin
      case (s)
         0:       se_addr = SE_ROM  + 32'h100 + 4*m;
         1:       se_addr = SE_SRAM + 32'h100 + 4*m;
         2:       se_addr = SE_P0   + 4*m;
         default: se_addr = SE_P1   + 4*m;
      endcase
   end
endfunction

function [31:0] se_rd;
   input integer m;
   input integer s;
   begin
      case (s)
         0:       se_rd = rom_inst0.mem[64 + m];
         1:       se_rd = sram_inst0.mem[64 + m];
         2:       se_rd = se_per[m];
         default: se_rd = se_per[16 + m];
      endcase
   end
endfunction

// Ports taking writes: all but the ROM.
function se_wok;
   input integer s;
   begin
      se_wok = (s != 0);
   end
endfunction

task se_check_armed_clear;
   input integer s;
   input [8*24-1:0] what;
   begin
      if (se_armed(s))
         begin
            $display("ERROR: %0s: injected ERROR on s%0d was never taken %t", what, s, $time);
            error = error + 1;
         end
   end
endtask


//----------------------------------------------------------------------------
// Stimulus
//----------------------------------------------------------------------------
reg [31:0] se_d;
reg [31:0] se_old;
reg [31:0] se_a;
reg [31:0] se_b;
integer    se_t;
integer    se_o;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(10) @(posedge free_clk);

      for (se_i = 0; se_i < 512; se_i = se_i + 1)
         begin
            rom_inst0.mem[se_i]  = 32'h4E000000 + (se_i * 32'h00010011);
            sram_inst0.mem[se_i] = 32'h27000000 + (se_i * 32'h00000101);
         end

      @(negedge free_clk);
      force   ahb_periph_example_inst0.hresetn_i = 1'b0;
      force   ahb_periph_example_inst1.hresetn_i = 1'b0;
      @(negedge free_clk);
      release ahb_periph_example_inst0.hresetn_i;
      release ahb_periph_example_inst1.hresetn_i;
      repeat(10) @(posedge free_clk);

      // Known REGOUT contents
      for (se_i = 0; se_i < 8; se_i = se_i + 1)
         begin
            se_per[se_i]      = 32'h50500000 + se_i;
            se_per[16 + se_i] = 32'h51510000 + se_i;
            ahb_write(1, 1, SE_P0 + 4*se_i, se_per[se_i],      2);
            ahb_write(2, 1, SE_P1 + 4*se_i, se_per[16 + se_i], 2);
         end
      repeat(5) @(posedge free_clk);

      //==================================================================
      // A: isolated injected ERRORs, every (manager, port) pair
      //==================================================================
      $display("");
      $display(" =====================================================");
      $display("|  A: ONE ERROR PER PORT AND MANAGER                  |");
      $display(" =====================================================");
      for (se_s = 0; se_s < 4; se_s = se_s + 1)
         for (se_m = 0; se_m < 3; se_m = se_m + 1)
            if (se_reach(se_m, se_s))
               begin
                  se_a = se_addr(se_m, se_s);

                  // read
                  se_n = rc_n[se_m];
                  se_arm(se_s);
                  ahb_read(se_m, 1, se_a, 32'h0, 2, 0);
                  ahb_read(se_m, 1, se_a, 32'h0, 2, 0);
                  repeat(2) @(posedge free_clk);
                  se_check_armed_clear(se_s, "A read");
                  rc_expect(se_m, se_n,     1'b1, 1'b1, 32'h0,                  "injected ERROR, read                    ");
                  rc_expect(se_m, se_n + 1, 1'b0, 1'b1, se_rd(se_m, se_s),      "read after it                           ");

                  // write
                  if (se_wok(se_s))
                     begin
                        se_old = se_rd(se_m, se_s);
                        se_d   = 32'hBAD00000 | (se_s << 8) | se_m;
                        se_n   = rc_n[se_m];
                        se_arm(se_s);
                        ahb_write(se_m, 1, se_a, se_d, 2);
                        ahb_read (se_m, 1, se_a, 32'h0, 2, 0);
                        repeat(2) @(posedge free_clk);
                        se_check_armed_clear(se_s, "A write");
                        rc_expect(se_m, se_n,     1'b1, 1'b0, 32'h0,  "injected ERROR, write                   ");
                        rc_expect(se_m, se_n + 1, 1'b0, 1'b1, se_old, "refused write stored nothing            ");
                     end
                  else
                     begin
                        // ROM: a write is refused by the ROM controller itself
                        se_n = rc_n[se_m];
                        ahb_write(se_m, 1, se_a, 32'hDEAD0000 | se_m, 2);
                        repeat(2) @(posedge free_clk);
                        rc_expect(se_m, se_n, 1'b1, 1'b0, 32'h0,      "ROM controller refuses a write          ");
                     end
               end

`ifdef FUSED
      // Fused executable side: ROM controller Port-B writes; m_x write diverted.
      for (se_m = 1; se_m < 3; se_m = se_m + 1)
         begin
            se_n = rc_n[se_m];
            ahb_write(se_m, 1, SE_ROM + 32'h180 + 4*se_m, 32'hDEAD0000 | se_m, 2);
            ahb_read (se_m, 1, SE_ROM + 32'h180 + 4*se_m, 32'h0, 2, 0);
            repeat(2) @(posedge free_clk);
            rc_expect(se_m, se_n,     1'b1, 1'b0, 32'h0,                          "fused ROM controller Port-B write       ");
            rc_expect(se_m, se_n + 1, 1'b0, 1'b1, rom_inst0.mem[96 + se_m],       "ROM read after it                       ");
         end
      se_n = rc_n[0];
      ahb_write(0, 1, SE_SRAM + 32'h180, 32'hDEAD00AA, 2);
      ahb_read (0, 1, SE_SRAM + 32'h180, 32'h0, 2, 0);
      repeat(2) @(posedge free_clk);
      rc_expect(0, se_n,     1'b1, 1'b0, 32'h0,               "m_x write, executable-side default      ");
      rc_expect(0, se_n + 1, 1'b0, 1'b1, sram_inst0.mem[96],  "SRAM read after it                      ");
`endif

      //==================================================================
      // B: same manager, next transfers presented during the ERROR
      //==================================================================
      $display("");
      $display(" =====================================================");
      $display("|  B: PIPELINED TRANSFERS HELD THROUGH THE ERROR      |");
      $display(" =====================================================");
      for (se_s = 0; se_s < 4; se_s = se_s + 1)
         for (se_m = 0; se_m < 3; se_m = se_m + 1)
            if (se_reach(se_m, se_s))
               begin
                  se_a = se_addr(se_m, se_s);
                  se_o = (se_s == 1) ? 0 : 1;           // another port the manager reaches
                  if (!se_reach(se_m, se_o)) se_o = se_s;
                  se_b = se_addr(se_m, se_o);
                  se_n = rc_n[se_m];
                  se_arm(se_s);
                  ahb_read(se_m, 0, se_a, 32'h0, 2, 0);
                  ahb_read(se_m, 0, se_b, 32'h0, 2, 0);
                  ahb_read(se_m, 1, se_a, 32'h0, 2, 0);
                  repeat(2) @(posedge free_clk);
                  se_check_armed_clear(se_s, "B");
                  rc_expect(se_m, se_n,     1'b1, 1'b1, 32'h0,             "injected ERROR, pipelined               ");
                  rc_expect(se_m, se_n + 1, 1'b0, 1'b1, se_rd(se_m, se_o), "next transfer, other port               ");
                  rc_expect(se_m, se_n + 2, 1'b0, 1'b1, se_rd(se_m, se_s), "next transfer, same port                ");
               end

      //==================================================================
      // C: another manager's transfer taken in the second ERROR cycle
      //==================================================================
      $display("");
      $display(" =====================================================");
      $display("|  C: ANOTHER MANAGER TAKEN IN THE SECOND ERROR CYCLE |");
      $display(" =====================================================");
      for (se_s = 0; se_s < 4; se_s = se_s + 1)
         for (se_m = 0; se_m < 3; se_m = se_m + 1)
            if (se_reach(se_m, se_s))
               begin
                  // the other manager: the next one that reaches the same port
                  se_o = (se_m + 1) % 3;
                  if (!se_reach(se_o, se_s)) se_o = (se_m + 2) % 3;
                  if (se_reach(se_o, se_s) && (se_o != se_m))
                     begin
                        se_a  = se_addr(se_m, se_s);
                        se_b  = se_addr(se_o, se_s);
                        se_n  = rc_n[se_m];
                        se_n2 = rc_n[se_o];
                        se_ct[se_s*3 + se_o] = 0;
                        se_arm(se_s);
                        fork
                           ahb_read(se_m, 1, se_a, 32'h0, 2, 0);
                           begin
                              @(posedge free_clk);
                              ahb_read(se_o, 1, se_b, 32'h0, 2, 0);
                           end
                        join
                        repeat(3) @(posedge free_clk);
                        se_check_armed_clear(se_s, "C");
                        rc_expect(se_m, se_n,  1'b1, 1'b1, 32'h0,             "injected ERROR                          ");
                        rc_expect(se_o, se_n2, 1'b0, 1'b1, se_rd(se_o, se_s), "other manager, same port                ");
                        se_t = 1;
`ifdef HIPERF
                        if (se_s < 2) se_t = 0;         // executable side: order and data only
`endif
                        if (se_t && (rc_n[se_m] > se_n))
                           begin
                              if (se_ct[se_s*3 + se_o] != rc_time[se_m*256 + (se_n % 256)])
                                 begin
                                    $display("ERROR: C s%0d: M%0d committed at %0t, M%0d's second ERROR cycle ended at %0t",
                                             se_s, se_o, se_ct[se_s*3 + se_o], se_m, rc_time[se_m*256 + (se_n % 256)]);
                                    error = error + 1;
                                 end
                              else
                                 $display("PASS:  C s%0d: M%0d address phase taken in M%0d's second ERROR cycle", se_s, se_o, se_m);
                           end
                     end
               end

      //==================================================================
      // Final checks
      //==================================================================
      $display("");
      for (se_s = 0; se_s < 4; se_s = se_s + 1)
         begin
`ifdef FUSED
            if (se_s >= 2)
`endif
            begin
               $display("INFO:  s%0d hresp rose %0d / fell %0d times", se_s, se_hr_r[se_s], se_hr_f[se_s]);
               if ((se_hr_r[se_s] == 0) || (se_hr_f[se_s] == 0))
                  begin
                     $display("ERROR: s%0d hresp did not both rise and fall", se_s);
                     error = error + 1;
                  end
            end
         end
      for (se_i = 0; se_i < 8; se_i = se_i + 1)
         begin
            check_periph_reg_value(0, se_i, se_per[se_i]);
            check_periph_reg_value(1, se_i, se_per[16 + se_i]);
         end
      for (se_i = 0; se_i < 512; se_i = se_i + 1)
         if (sram_inst0.mem[se_i] !== (32'h27000000 + (se_i * 32'h00000101)))
            begin
               $display("ERROR: SRAM word %0d = 0x%h, a refused write landed", se_i, sram_inst0.mem[se_i]);
               error = error + 1;
            end

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
