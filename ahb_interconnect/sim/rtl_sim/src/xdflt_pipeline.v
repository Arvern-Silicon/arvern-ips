//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    xdflt_pipeline
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : xdflt_pipeline.v
// Module Description : Executable manager (M0 = m_x) issuing back-to-back
//                      transfers that alternate between the executable-side
//                      default subordinate and real executable subordinates,
//                      while M1 streams SRAM writes and M2 streams ROM reads.
//                      Fused and hiperf; generic skips.
//
// M0 presents each address phase in the data phase of the previous one and
// never cancels a transfer after an ERROR, so the next transfer is taken in
// the second ERROR cycle. Every response and every read's data is checked in
// order from a manager-side response log.
//
//   #  M0 transfer                          fused                hiperf
//   0  write SRAM word 16 = NEW             ERROR (m_x write     OKAY (forwarded
//                                           diverted)            unchanged)
//   1  read  SRAM word 16                   OKAY, OLD            OKAY, NEW
//   2  read  unmapped 0x0080_0000           ERROR, hrdata 0      ERROR, hrdata 0
//   3  read  ROM word 20                    OKAY                 OKAY
//   4  write ROM word 21                    ERROR (diverted)     ERROR (ROM ctrl)
//   5  read  ROM word 21                    OKAY                 OKAY
//   6  read  0x0040_2000 (periph0, outside ERROR, hrdata 0      ERROR, hrdata 0
//      the executable decoder)
//   7  read  SRAM word 17                   OKAY                 OKAY
//   8  read  SRAM word 16                   OKAY, OLD            OKAY, NEW
//
// Basis (quoted)
//  ahb_interconnect.md, What differs: "A write presented by m_x | n/a |
//    Forwarded to the executable subordinate unchanged | Diverted to the
//    executable-side default subordinate, answered ERROR"
//  ahb_interconnect.md, Fused fabric: "A write presented by m_x never reaches
//    a controller: the fabric routes it to the executable-side default
//    subordinate, which answers ERROR, and the memory is untouched."
//  ahb_interconnect.md, Hiperf: "The executable manager's writes are NOT
//    filtered on hiperf. m_x_hwrite_i is forwarded to the executable
//    subordinates unchanged"
//  ahb_rom_controller.md (hiperf s0): "Write (any size) | No ROM access.
//    Two-cycle ERROR"
//  ahb_interconnect.md, High-performance fabric: "An m_x access outside the
//    executable decoder is answered ERROR by the executable-side default
//    subordinate"; bench: "s_x_decoder_1hot = s_decoder_1hot[1:0]"
//  ahb_interconnect.md, Building blocks: ahb_default_subordinate "Answers
//    every NONSEQ/SEQ transfer with the AHB two-cycle ERROR (hreadyout low
//    then high, hresp = 1, hrdata = 0)."
//  IHI0033C 5.1.3: "The two-cycle response provides sufficient time for the
//    Manager to cancel this next access" (optional: M0 does not cancel).
//----------------------------------------------------------------------------

localparam [31:0] XD_ROM   = 32'h00400000;
localparam [31:0] XD_SRAM  = 32'h00401000;
localparam [31:0] XD_P0    = 32'h00402000;
localparam [31:0] XD_UNMAP = 32'h00800000;
localparam [31:0] XD_OLD   = 32'h0BAD0BAD;
localparam [31:0] XD_NEW   = 32'hC0DEC0DE;

integer    xd_n0;
integer    xd_n1;
integer    xd_n2;
integer    xd_e1;
integer    xd_e2;
integer    xd_s1;
integer    xd_s2;
integer    xd_i;
reg [31:0] xd_w16;       // expected content of SRAM word 16 after transfer 0


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
// Stimulus
//----------------------------------------------------------------------------
initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(10) @(posedge free_clk);

`ifdef GENERIC
      tb_skip_finish("|   (xdflt_pipeline runs on the FUSED and HIPERF fabrics)   |");
`else
      $display("");
      $display(" =====================================================");
      $display("|  m_x PIPELINE THROUGH THE X-SIDE DEFAULT SUBORDINATE |");
      $display(" =====================================================");

      for (tb_idx = 0; tb_idx < MEM_SIZE/4; tb_idx = tb_idx + 1)
         rom_inst0.mem[tb_idx]  = 32'h7C000000 + (tb_idx * 32'h00010101);
      for (tb_idx = 0; tb_idx < MEM_SIZE/4; tb_idx = tb_idx + 1)
         sram_inst0.mem[tb_idx] = 32'h11000000 + tb_idx;
      sram_inst0.mem[16] = XD_OLD;

`ifdef FUSED
      xd_w16 = XD_OLD;
`else
      xd_w16 = XD_NEW;
`endif

      @(negedge free_clk);
      force   ahb_periph_example_inst0.hresetn_i = 1'b0;
      force   ahb_periph_example_inst1.hresetn_i = 1'b0;
      @(negedge free_clk);
      release ahb_periph_example_inst0.hresetn_i;
      release ahb_periph_example_inst1.hresetn_i;
      repeat(10) @(posedge free_clk);

      xd_n0 = rc_n[0];
      xd_n1 = rc_n[1];
      xd_n2 = rc_n[2];
      xd_e1 = rc_errs[1];
      xd_e2 = rc_errs[2];

      fork
         begin                                                    // M0 -- m_x, back to back
            ahb_write(0, 0, XD_SRAM + 32'h040, XD_NEW,              2   );   // 0
            ahb_read (0, 0, XD_SRAM + 32'h040, xd_w16,              2, 1);   // 1
            ahb_read (0, 0, XD_UNMAP,          32'h0,               2, 0);   // 2
            ahb_read (0, 0, XD_ROM  + 32'h050, rom_inst0.mem[20],   2, 1);   // 3
            ahb_write(0, 0, XD_ROM  + 32'h054, 32'hDEADDEAD,        2   );   // 4
            ahb_read (0, 0, XD_ROM  + 32'h054, rom_inst0.mem[21],   2, 1);   // 5
            ahb_read (0, 0, XD_P0,             32'h0,               2, 0);   // 6
            ahb_read (0, 0, XD_SRAM + 32'h044, sram_inst0.mem[17],  2, 1);   // 7
            ahb_read (0, 1, XD_SRAM + 32'h040, xd_w16,              2, 1);   // 8
         end
         begin                                                    // M1 -- NX, SRAM write stream
            for (xd_s1 = 0; xd_s1 < 16; xd_s1 = xd_s1 + 1)
               ahb_write(1, 0, XD_SRAM + 32'h100 + 4*xd_s1, 32'hB1000000 + xd_s1, 2);
         end
         begin                                                    // M2 -- NX, ROM read stream
            for (xd_s2 = 0; xd_s2 < 16; xd_s2 = xd_s2 + 1)
               ahb_read(2, 0, XD_ROM + 32'h050 + 4*xd_s2, rom_inst0.mem[20 + xd_s2], 2, 1);
         end
      join
      repeat(20) @(posedge free_clk);

`ifdef FUSED
      rc_expect(0, xd_n0 + 0, 1'b1, 1'b0, 32'h0,              "0 m_x write SRAM (diverted)             ");
`else
      rc_expect(0, xd_n0 + 0, 1'b0, 1'b0, 32'h0,              "0 m_x write SRAM (forwarded)            ");
`endif
      rc_expect(0, xd_n0 + 1, 1'b0, 1'b1, xd_w16,             "1 read SRAM word just written           ");
      rc_expect(0, xd_n0 + 2, 1'b1, 1'b1, 32'h0,              "2 read unmapped                         ");
      rc_expect(0, xd_n0 + 3, 1'b0, 1'b1, rom_inst0.mem[20],  "3 read ROM                              ");
      rc_expect(0, xd_n0 + 4, 1'b1, 1'b0, 32'h0,              "4 m_x write ROM                         ");
      rc_expect(0, xd_n0 + 5, 1'b0, 1'b1, rom_inst0.mem[21],  "5 read ROM word just written            ");
      rc_expect(0, xd_n0 + 6, 1'b1, 1'b1, 32'h0,              "6 read outside the executable decoder   ");
      rc_expect(0, xd_n0 + 7, 1'b0, 1'b1, sram_inst0.mem[17], "7 read SRAM                             ");
      rc_expect(0, xd_n0 + 8, 1'b0, 1'b1, xd_w16,             "8 read SRAM word 16 again               ");
      if ((rc_n[0] - xd_n0) != 9)
         begin
            $display("ERROR: M0 completed %0d transfers, issued 9", rc_n[0] - xd_n0);
            error = error + 1;
         end
      check_mem_value(16, xd_w16);

      if (((rc_n[1] - xd_n1) != 16) || ((rc_n[2] - xd_n2) != 16) ||
          (rc_errs[1] != xd_e1) || (rc_errs[2] != xd_e2))
         begin
            $display("ERROR: NX streams: M1 %0d/16, M2 %0d/16 completed, %0d ERROR responses",
                     rc_n[1] - xd_n1, rc_n[2] - xd_n2, (rc_errs[1] - xd_e1) + (rc_errs[2] - xd_e2));
            error = error + 1;
         end
      for (xd_i = 0; xd_i < 16; xd_i = xd_i + 1)
         ahb_read(1, 0, XD_SRAM + 32'h100 + 4*xd_i, 32'hB1000000 + xd_i, 2, 1);
      ahb_read(1, 1, XD_SRAM + 32'h044, 32'h11000011, 2, 1);
      repeat(5) @(posedge free_clk);
      for (xd_i = 0; xd_i < 16; xd_i = xd_i + 1)
         check_mem_value(64 + xd_i, 32'hB1000000 + xd_i);
`endif

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
