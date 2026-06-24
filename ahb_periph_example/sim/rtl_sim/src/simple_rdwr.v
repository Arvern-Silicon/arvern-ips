//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    simple_rdwr
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : simple_rdwr.v
// Module Description : Simple read/write test stimulus for the AHB peripheral
//                      example.
//----------------------------------------------------------------------------

integer ii;
integer jj;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      $display(" ===============================================");
      $display("|    SIMPLE 8b AHB WRITES - 8/16/32b READS      |");
      $display(" ===============================================");

      // Init
      for (ii = 0; ii < 8; ii = ii + 1) begin
         ahb_write(1, MACHINE, 32'h00400000+(ii*4), 32'h00000000, 2, OK);
      end

      // Non-Pipelined 8b AHB Write accesses
      //--------------------------------------------------
      for (ii = 0; ii < 8; ii = ii + 1) begin
         jj = $urandom;
         repeat(10) @(posedge free_clk);
         ahb_write(1, MACHINE, 32'h00400000+(ii*4), jj[7:0],   0, OK);
         check_reg_value(ii,           {24'h000000, jj[7:0]}        );
         ahb_read( 1, MACHINE, 32'h00400000+(ii*4), jj[7:0],                0, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400000+(ii*4), {8'h00,      jj[7:0]},  1, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400000+(ii*4), {24'h000000, jj[7:0]},  2, 1, OK);

         repeat(5) @(posedge free_clk);
         ahb_write(1, MACHINE, 32'h00400001+(ii*4), jj[15:8],  0, OK);
         check_reg_value(ii,           {16'h0000,   jj[15:0]}       );
         ahb_read( 1, MACHINE, 32'h00400001+(ii*4), jj[15:8],               0, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400000+(ii*4), jj[15:0],               1, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400000+(ii*4), {16'h0000, jj[15:0]},   2, 1, OK);

         repeat(5) @(posedge free_clk);
         ahb_write(1, MACHINE, 32'h00400002+(ii*4), jj[23:16], 0, OK);
         check_reg_value(ii,           {8'h00,      jj[23:0]}       );
         ahb_read( 1, MACHINE, 32'h00400002+(ii*4), jj[23:16],              0, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400002+(ii*4), {8'h00, jj[23:16]},     1, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400000+(ii*4), {8'h00, jj[23:0]},      2, 1, OK);

         repeat(5) @(posedge free_clk);
         ahb_write(1, MACHINE, 32'h00400003+(ii*4), jj[31:24], 0, OK);
         check_reg_value(ii,           {            jj[31:0]}       );
         ahb_read( 1, MACHINE, 32'h00400003+(ii*4), jj[31:24],              0, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400002+(ii*4), jj[31:16],              1, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400000+(ii*4), jj[31:0],               2, 1, OK);

         $display("");
      end

      $display(" ===============================================");
      $display("|    SIMPLE 16b AHB WRITES - 8/16/32b READS     |");
      $display(" ===============================================");

      // Init
      for (ii = 0; ii < 8; ii = ii + 1) begin
         ahb_write(1, MACHINE, 32'h00400000+(ii*4), 32'h00000000, 2, OK);
      end

      // Non-Pipelined 16b AHB Write accesses
      //--------------------------------------------------
      for (ii = 0; ii < 8; ii = ii + 1) begin
         jj = $urandom;
         repeat(10) @(posedge free_clk);
         ahb_write(1, MACHINE, 32'h00400000+(ii*4), jj[15:0],              1   , OK);
         check_reg_value(ii,             {16'h0000, jj[15:0]}                      );
         ahb_read( 1, MACHINE, 32'h00400000+(ii*4), jj[7:0],               0, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400001+(ii*4), jj[15:8],              0, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400002+(ii*4), 8'h00,                 0, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400003+(ii*4), 8'h00,                 0, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400000+(ii*4), jj[15:0],              1, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400002+(ii*4), 16'h0000,              1, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400000+(ii*4), {16'h0000, jj[15:0]},  2, 1, OK);

         repeat(5) @(posedge free_clk);
         ahb_write(1, MACHINE, 32'h00400002+(ii*4), jj[31:16],             1   , OK);
         check_reg_value(ii,                        jj[31:0]                       );
         ahb_read( 1, MACHINE, 32'h00400000+(ii*4), jj[7:0],               0, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400001+(ii*4), jj[15:8],              0, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400002+(ii*4), jj[23:16],             0, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400003+(ii*4), jj[31:24],             0, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400000+(ii*4), jj[15:0],              1, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400002+(ii*4), jj[31:16],             1, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400000+(ii*4), jj[31:0],              2, 1, OK);

         $display("");
      end

      $display(" ===============================================");
      $display("|    SIMPLE 32b AHB WRITES - 8/16/32b READS     |");
      $display(" ===============================================");

      // Init
      for (ii = 0; ii < 8; ii = ii + 1) begin
         ahb_write(1, MACHINE, 32'h00400000+(ii*4), 32'h00000000, 2, OK);
      end

      // Non-Pipelined 32b AHB Write accesses
      //--------------------------------------------------
      for (ii = 0; ii < 8; ii = ii + 1) begin
         jj = $urandom;
         repeat(10) @(posedge free_clk);
         ahb_write(1, MACHINE, 32'h00400000+(ii*4), jj[31:0],              2   , OK);
         check_reg_value(ii,                        jj[31:0]                       );
         ahb_read( 1, MACHINE, 32'h00400000+(ii*4), jj[7:0],               0, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400001+(ii*4), jj[15:8],              0, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400002+(ii*4), jj[23:16],             0, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400003+(ii*4), jj[31:24],             0, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400000+(ii*4), jj[15:0],              1, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400002+(ii*4), jj[31:16],             1, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400000+(ii*4), jj[31:0],              2, 1, OK);

         $display("");
      end

      $display("");

      $display(" ===============================================");
      $display("|    SIMPLE AHB READS - 8/16/32b READS          |");
      $display(" ===============================================");

      // Non-Pipelined AHB Read accesses
      //--------------------------------------------------
      for (ii = 8; ii < 16; ii = ii + 1) begin
         jj = $urandom;
         repeat(10) @(posedge free_clk);
	      $display("Set value to REGIN %d -- value: 0x%h -- %t ns", ii, jj, $time);
         set_regin_value(ii,                        jj[31:0]                       );
         ahb_read( 1, MACHINE, 32'h00400000+(ii*4), jj[7:0],               0, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400001+(ii*4), jj[15:8],              0, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400002+(ii*4), jj[23:16],             0, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400003+(ii*4), jj[31:24],             0, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400000+(ii*4), jj[15:0],              1, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400002+(ii*4), jj[31:16],             1, 1, OK);
         ahb_read( 1, MACHINE, 32'h00400000+(ii*4), jj[31:0],              2, 1, OK);

         $display("");
      end

      $display(" ===============================================");
      $display("|    OUT-OF-WINDOW ACCESSES (RAZ / no-op)       |");
      $display(" ===============================================");

      // The peripheral exposes 17 word-aligned registers at offsets
      // 0x00..0x40 of a 128-byte window. Reads to undefined offsets within
      // the window must return 0x00000000 with hresp=OK; writes must be
      // silently dropped (no side effect on the defined registers).
      // (The W7 coverage gap from the verification review.)

      // Seed REGOUT_0..7 with a known non-zero pattern so we can later
      // verify the out-of-window writes didn't corrupt them.
      ahb_write(1, MACHINE, 32'h00400000, 32'hAAAA0000, 2, OK);
      ahb_write(1, MACHINE, 32'h00400004, 32'hAAAA1111, 2, OK);
      ahb_write(1, MACHINE, 32'h00400008, 32'hAAAA2222, 2, OK);
      ahb_write(1, MACHINE, 32'h0040000C, 32'hAAAA3333, 2, OK);
      ahb_write(1, MACHINE, 32'h00400010, 32'hAAAA4444, 2, OK);
      ahb_write(1, MACHINE, 32'h00400014, 32'hAAAA5555, 2, OK);
      ahb_write(1, MACHINE, 32'h00400018, 32'hAAAA6666, 2, OK);
      ahb_write(1, MACHINE, 32'h0040001C, 32'hAAAA7777, 2, OK);

      // Read every undefined offset (0x44 .. 0x7C, 15 slots) - expect 0x0
      for (ii = 17; ii < 32; ii = ii + 1) begin
         ahb_read( 1, MACHINE, 32'h00400000+(ii*4), 32'h00000000, 2, 1, OK);
      end

      // Write all-ones to every undefined offset - must be silently dropped
      for (ii = 17; ii < 32; ii = ii + 1) begin
         ahb_write(1, MACHINE, 32'h00400000+(ii*4), 32'hFFFFFFFF, 2, OK);
      end

      // Re-verify that the defined REGOUT_0..7 are untouched
      check_reg_value(0, 32'hAAAA0000);
      check_reg_value(1, 32'hAAAA1111);
      check_reg_value(2, 32'hAAAA2222);
      check_reg_value(3, 32'hAAAA3333);
      check_reg_value(4, 32'hAAAA4444);
      check_reg_value(5, 32'hAAAA5555);
      check_reg_value(6, 32'hAAAA6666);
      check_reg_value(7, 32'hAAAA7777);

      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
