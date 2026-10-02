//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ro_writes_hprot
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ro_writes_hprot.v
// Module Description : Writes to every REGIN_* offset: from Machine mode an OKAY
//                      no-op (the input value still reads back, no REGOUT_*
//                      changes), from User mode under the reset gates an ERROR.
//                      Then only hprot_i[1] (with hsmode_i) sets the privilege:
//                      all 16 hprot_i values with both hsmode_i values, under
//                      Machine-only and Supervisor gates, give the outcome of
//                      the decoded mode alone, on the data registers and MDELEG.
//----------------------------------------------------------------------------

localparam REGOUT_00 = 32'h00400000;
localparam REGOUT_01 = 32'h00400004;
localparam REGIN_08  = 32'h00400020;
localparam MDELEG    = 32'h00400040;

integer    ii;
integer    hp;
integer    sm;
reg [31:0] wr_value;

task chk;
   input            cond;
   input [8*72-1:0] msg;
   begin
      if (cond !== 1'b1) begin
         $display("ERROR: %0s %t ns", msg, $time);
         error = error + 1;
      end
   end
endtask

// ahb_write with hprot / hsmode driven as given.
task hp_write;
   input         blocking;
   input   [3:0] hprot_val;
   input         hsmode_val;
   input  [31:0] addr;
   input  [31:0] data;
   input   [1:0] size;
   input         expected_resp;
   begin
      haddr    = addr;
      htrans   = 2'b10;
      hwrite   = 1'b1;
      hsize    = {1'b0, size};
      hprot    = hprot_val;
      hsmode   = hsmode_val;

      @(posedge free_clk);
      #1;
      if (expected_resp !== hresp) begin
         $display("ERROR: AHB write response check -- address: 0x%h -- hprot: 0x%h hsmode: %b -- hresp: 0x%h / expected: 0x%h %t ns", addr, hprot_val, hsmode_val, hresp, expected_resp, $time);
         error = error+1;
      end
      hwdata  = size==0 ? (haddr[1:0]==0 ? {24'h000000, data[7:0]            } :
                           haddr[1:0]==1 ? {16'h0000,   data[7:0], 8'h00     } :
                           haddr[1:0]==2 ? {8'h00,      data[7:0], 16'h0000  } :
                                           {            data[7:0], 24'h000000} ) :
                size==1 ? (haddr[1]==0   ? {16'h0000,   data[15:0]           } :
                                           {            data[15:0], 16'h0000 } ) :
                          data;
      while(~hready) @(posedge free_clk);
      #1;
      haddr   = 32'h00000000;
      htrans  = 2'b00;
      hprot   = 4'h0;
      hsmode  = 1'b0;
      hwrite  = 1'b0;
      hsize   = 3'b000;
      if (blocking==1) begin
         @(posedge free_clk);
         while(~hready & blocking) @(posedge free_clk);
      end
   end
endtask

// ahb_read (word) with hprot / hsmode driven as given; uses the ahb_tasks
// read-check process.
task hp_read;
   input         blocking;
   input   [3:0] hprot_val;
   input         hsmode_val;
   input  [31:0] addr;
   input  [31:0] expected_data;
   input         check;
   input         expected_resp;
   begin
      haddr   = addr;
      htrans  = 2'b10;
      hwrite  = 1'b0;
      hsize   = 3'b010;
      hprot   = hprot_val;
      hsmode  = hsmode_val;

      @(posedge free_clk);
      #1;
      if (expected_resp !== hresp) begin
         $display("ERROR: AHB read response check -- address: 0x%h -- hprot: 0x%h hsmode: %b -- hresp: 0x%h / expected: 0x%h %t ns", addr, hprot_val, hsmode_val, hresp, expected_resp, $time);
         error = error+1;
      end
      while(~hready) @(posedge free_clk);
      #1;
      ahb_read_check_active =  check;
      ahb_read_check_addr   =  addr;
      ahb_read_check_size   =  2'b10;
      ahb_read_check_mode   =  ~hprot_val[1] ? USER : hsmode_val ? SUPERVISOR : MACHINE;
      ahb_read_check_data   =  expected_data;
      ahb_read_check_mask   =  32'hFFFFFFFF;

      haddr   = 32'h00000000;
      htrans  = 2'b00;
      hprot   = 4'h0;
      hsmode  = 1'b0;
      hwrite  = 1'b0;
      hsize   = 3'b000;
      if (blocking==1) begin
         @(posedge free_clk);
         while(~hready & blocking) @(posedge free_clk);
      end
   end
endtask

// Admitted write + read-back of REGOUT_01 and REGIN_08.
task access_ok;
   input   [3:0] hprot_val;
   input         hsmode_val;
   begin
      wr_value = {4'hA, hprot_val, 7'h00, hsmode_val, 16'h5A5A};
      hp_write(1, hprot_val, hsmode_val, REGOUT_01, wr_value,     2,    OK);
      hp_read (1, hprot_val, hsmode_val, REGOUT_01, wr_value,        1, OK);
      check_reg_value(1, wr_value);
      hp_read (1, hprot_val, hsmode_val, REGIN_08,  32'hC0DE0008,    1, OK);
   end
endtask

// Denied write + read of REGOUT_01 (ERROR, hrdata 0, nothing stored).
task access_denied;
   input   [3:0] hprot_val;
   input         hsmode_val;
   begin
      hp_write(1, hprot_val, hsmode_val, REGOUT_01, 32'hDEADBEEF, 2,    ERROR);
      hp_read (1, hprot_val, hsmode_val, REGOUT_01, 32'h00000000,    1, ERROR);
      check_reg_value(1, wr_value);
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(5) @(posedge free_clk);

      $display("");
      $display(" ===============================================");
      $display("|   WRITES TO THE READ-ONLY BANK                |");
      $display(" ===============================================");

      for (ii = 8; ii < 16; ii = ii + 1) begin
         set_regin_value(ii, 32'hC0DE0000 + ii);
      end
      for (ii = 0; ii < 8; ii = ii + 1) begin
         ahb_write(1, MACHINE, REGOUT_00 + ii*4, 32'h0A0B0C00 + ii, 2, OK);
      end

      // Machine mode: OKAY, no effect anywhere.
      for (ii = 0; ii < 8; ii = ii + 1) begin
         ahb_write(1, MACHINE, REGIN_08 + ii*4,     32'h3F21E7B9 ^ ii, 2,    OK);
         ahb_read (1, MACHINE, REGIN_08 + ii*4,     32'hC0DE0008 + ii, 2, 1, OK);
      end
      ahb_write(1, MACHINE, REGIN_08 + 1, 32'h000000FF, 0, OK);
      ahb_write(1, MACHINE, REGIN_08 + 2, 32'h0000FFFF, 1, OK);
      ahb_read (1, MACHINE, REGIN_08,     32'hC0DE0008, 2, 1, OK);

      // User mode under the reset gates (RESP=1): ERROR.
      for (ii = 0; ii < 8; ii = ii + 1) begin
         ahb_write(1, USER,    REGIN_08 + ii*4,     32'h3F21E7B9 ^ ii, 2,    ERROR);
      end
      for (ii = 0; ii < 8; ii = ii + 1) begin
         ahb_read (1, MACHINE, REGIN_08 + ii*4,     32'hC0DE0008 + ii, 2, 1, OK);
      end
      for (ii = 0; ii < 8; ii = ii + 1) begin
         check_reg_value(ii, 32'h0A0B0C00 + ii);
      end

      $display("");
      $display(" ===============================================");
      $display("|   HPROT[0] / HPROT[3:2] IGNORED               |");
      $display(" ===============================================");

      // Every hprot_i value with both hsmode_i values. Reset gates: only
      // Machine (hprot_i[1] & ~hsmode_i) is admitted, to the data registers
      // and to MDELEG.
      access_ok(4'h2, 1'b0);
      for (hp = 0; hp < 16; hp = hp + 1) begin
         for (sm = 0; sm < 2; sm = sm + 1) begin
            if (hp[1] & ~sm[0]) begin
               access_ok(hp[3:0], sm[0]);
               hp_read (1, hp[3:0], sm[0], MDELEG, 32'h0000010F, 1, OK);
            end else begin
               access_denied(hp[3:0], sm[0]);
               hp_read (1, hp[3:0], sm[0], MDELEG, 32'h00000000, 1, ERROR);
            end
         end
      end

      // Gates at Supervisor: Machine and Supervisor (hprot_i[1]) admitted to
      // the data registers, MDELEG still Machine only, User denied.
      ahb_write(1, MACHINE, MDELEG, 32'h00000105, 2, OK);
      for (hp = 0; hp < 16; hp = hp + 1) begin
         for (sm = 0; sm < 2; sm = sm + 1) begin
            if (hp[1]) begin
               access_ok(hp[3:0], sm[0]);
            end else begin
               access_denied(hp[3:0], sm[0]);
            end
            if (hp[1] & ~sm[0]) begin
               hp_read (1, hp[3:0], sm[0], MDELEG, 32'h00000105, 1, OK);
            end else begin
               hp_read (1, hp[3:0], sm[0], MDELEG, 32'h00000000, 1, ERROR);
            end
         end
      end

      // Restore the reset gates.
      ahb_write(1, MACHINE, MDELEG, 32'h0000010F, 2, OK);
      ahb_read (1, MACHINE, MDELEG, 32'h0000010F, 2, 1, OK);
      for (ii = 8; ii < 16; ii = ii + 1) begin
         set_regin_value(ii, 32'h00000000);
      end

      repeat(21) @(posedge free_clk);
      $display("");
      stimulus_done = 1;
   end
