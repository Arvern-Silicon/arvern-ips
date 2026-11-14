//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    apb_tasks
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : apb_tasks.v
// Module Description : APB4 requester tasks for the apb_usb_host testbench.
//
//   - mode is {pprot[0], psmode}: MACHINE=2'b10, SUPERVISOR=2'b11,
//     USER=2'b00, USER_S=2'b01 (U-mode with the S sideband set);
//   - PPROT[2:1] come from tb_pprot_other;
//   - size (SZ_B / SZ_H / SZ_W) and the address low bits select PSTRB as a
//     bridge derives it from HSIZE / HADDR; the unstrobed lanes of PWDATA
//     carry random junk, so a completer that ignores PSTRB corrupts them;
//   - reads are checked on the FULL 32-bit word, whatever the size;
//   - every ACCESS cycle is checked: PREADY high, PSLVERR as expected,
//     PRDATA as expected for a checked read;
//   - while no transfer runs the bus carries random address, data, strobe
//     and protection values with PSEL low.
//
// blocking=1 returns one #1 after the edge that ends the ACCESS cycle.
// blocking=0 returns one #1 after the edge that ends the SETUP cycle; the
// ACCESS cycle then completes in the background, and the next task call
// starts its SETUP in the cycle after it (back to back).
//----------------------------------------------------------------------------

localparam [1:0] USER       = 2'b00;
localparam [1:0] USER_S     = 2'b01;
localparam [1:0] MACHINE    = 2'b10;
localparam [1:0] SUPERVISOR = 2'b11;

localparam       OK         = 1'b0;
localparam       ERROR      = 1'b1;

localparam [1:0] SZ_B       = 2'd0;
localparam [1:0] SZ_H       = 2'd1;
localparam [1:0] SZ_W       = 2'd2;

reg  [1:0] tb_pprot_other;   // PPROT[2:1] of every transfer

// ACCESS-cycle tracker (one transfer at a time on APB)
reg        acc_pending;
reg        acc_is_read;
reg        acc_check;
reg        acc_exp_resp;
reg [31:0] acc_addr;
reg [31:0] acc_exp_data;
reg [31:0] acc_rdata;
reg  [1:0] acc_size;
reg  [1:0] acc_mode;

initial
  begin
     tb_pprot_other = 2'b00;
     acc_pending    = 1'b0;
     acc_is_read    = 1'b0;
     acc_check      = 1'b0;
     acc_exp_resp   = OK;
     acc_addr       = 32'h0;
     acc_exp_data   = 32'h0;
     acc_rdata      = 32'h0;
     acc_size       = 2'b00;
     acc_mode       = 2'b00;
  end

// The expected response of an access, exp_resp_of(write, mode, addr), is
// the bench's (usb_tasks.v): it follows the MDELEG mirror.

// Byte-lane mask of an access
function [31:0] lane_mask;
   input [31:0] addr;
   input  [1:0] size;
   begin
      case (size)
        SZ_B   : lane_mask = 32'h000000FF << (8*addr[1:0]);
        SZ_H   : lane_mask = addr[1] ? 32'hFFFF0000 : 32'h0000FFFF;
        default: lane_mask = 32'hFFFFFFFF;
      endcase
   end
endfunction

// Value given in the low bits, placed on the addressed lanes
function [31:0] lane_place;
   input [31:0] addr;
   input  [1:0] size;
   input [31:0] data;
   begin
      case (size)
        SZ_B   : lane_place = {24'h000000, data[7:0]} << (8*addr[1:0]);
        SZ_H   : lane_place = addr[1] ? {data[15:0], 16'h0000} : {16'h0000, data[15:0]};
        default: lane_place = data;
      endcase
   end
endfunction

function [3:0] strb_of;
   input [31:0] addr;
   input  [1:0] size;
   reg   [31:0] m;
   begin
      m       = lane_mask(addr, size);
      strb_of = {m[24], m[16], m[8], m[0]};
   end
endfunction

//----------------------------------------------------------------------------
// Bus drive helpers
//----------------------------------------------------------------------------
task apb_idle;
   begin
      psel    = 1'b0;
      penable = 1'b0;
      paddr   = $urandom;
      pwrite  = $urandom;
      pwdata  = $urandom;
      pstrb   = $urandom;
      pprot   = $urandom;
      psmode  = $urandom;
   end
endtask

// Wait until the ACCESS cycle in progress has ended; returns one #1 after
// the edge that ends it (at once when none is in progress)
task apb_flush;
   begin
      if (acc_pending) wait (acc_pending == 1'b0);
   end
endtask

// SETUP cycle of a transfer: wait for the bus, drive it, return one #1
// after the edge that ends SETUP with PENABLE raised
task apb_setup;
   input        write;
   input  [1:0] mode;
   input [31:0] addr;
   input [31:0] wdata;
   input  [3:0] strb;
   begin
      apb_flush;
      psel    = 1'b1;
      penable = 1'b0;
      paddr   = addr[ADDRW-1:0];
      pwrite  = write;
      pwdata  = wdata;
      pstrb   = strb;
      pprot   = {tb_pprot_other, mode[1]};
      psmode  = mode[0];
      @(posedge free_clk);
      #1;
      penable = 1'b1;
   end
endtask

task acc_open;
   input        is_read;
   input  [1:0] mode;
   input [31:0] addr;
   input [31:0] exp_data;
   input  [1:0] size;
   input        check;
   input        exp_resp;
   begin
      acc_pending  = 1'b1;
      acc_is_read  = is_read;
      acc_check    = check;
      acc_exp_resp = exp_resp;
      acc_addr     = addr;
      acc_exp_data = exp_data;
      acc_size     = size;
      acc_mode     = mode;
   end
endtask

//----------------------------------------------------------------------------
// ACCESS-cycle checker (falling edge, mid-cycle) and completion (one #1
// after the rising edge that ends the ACCESS cycle)
//----------------------------------------------------------------------------
always @(negedge free_clk)
  if ((presetn === 1'b1) && acc_pending)
    begin
       if (pready !== 1'b1)
         begin
            $display("ERROR: APB -- PREADY low in ACCESS -- address: 0x%h %t ns", acc_addr, $time);
            error = error+1;
         end
       if (pslverr !== acc_exp_resp)
         begin
            $display("ERROR: APB response -- address: 0x%h -- PSLVERR=%b, expected %b -- mode: %0d %t ns", acc_addr, pslverr, acc_exp_resp, acc_mode, $time);
            error = error+1;
         end
       acc_rdata = prdata;
       if (acc_is_read && acc_check)
         begin
            if (prdata !== acc_exp_data)
              begin
                 $display("ERROR: APB read check -- address: 0x%h -- read: 0x%h / expected: 0x%h -- size: %0d -- mode: %0d %t ns", acc_addr, prdata, acc_exp_data, acc_size, acc_mode, $time);
                 error = error+1;
              end
            else
              $display("PASS:  APB read check -- address: 0x%h -- value: 0x%h -- size: %0d -- mode: %0d %t ns", acc_addr, prdata, acc_size, acc_mode, $time);
         end
    end

always @(posedge free_clk or negedge presetn)
  if (presetn !== 1'b1)
    acc_pending <= 1'b0;
  else if (acc_pending)
    begin
       #1;
       apb_idle;
       acc_pending = 1'b0;
    end

//============================================================================
// Write access
//============================================================================
task apb_write;
   input         blocking;      // 1: return at the end of ACCESS; 0: at the end of SETUP
   input   [1:0] mode;          // {pprot[0], psmode}
   input  [31:0] addr;          // byte address
   input  [31:0] data;          // value in the low bits (placed on the addressed lanes)
   input   [1:0] size;          // SZ_B / SZ_H / SZ_W
   input         expected_resp; // OK / ERROR
   reg    [31:0] lmask;
   reg    [31:0] junk;
   begin
      lmask = lane_mask(addr, size);
      junk  = $urandom;
      apb_setup(1'b1, mode, addr, (lane_place(addr, size, data) & lmask) | (junk & ~lmask), strb_of(addr, size));
      acc_open(1'b0, mode, addr, 32'h0, size, 1'b0, expected_resp);
      if (blocking) begin wait (acc_pending == 1'b0); end
   end
endtask

//============================================================================
// Read access
//============================================================================
task apb_read;
   input         blocking;      // 1: return at the end of ACCESS; 0: at the end of SETUP
   input   [1:0] mode;          // {pprot[0], psmode}
   input  [31:0] addr;          // byte address
   input  [31:0] expected_word; // full 32-bit word expected on PRDATA
   input   [1:0] size;          // SZ_B / SZ_H / SZ_W (no effect on a read: PSTRB is 0)
   input         check;         // compare PRDATA with expected_word
   input         expected_resp; // OK / ERROR
   begin
      apb_setup(1'b0, mode, addr, $urandom, 4'b0000);
      acc_open(1'b1, mode, addr, expected_word, size, check, expected_resp);
      if (blocking) begin wait (acc_pending == 1'b0); end
   end
endtask

// Blocking read returning the word read
task apb_read_val;
   input   [1:0] mode;
   input  [31:0] addr;
   input   [1:0] size;
   input         expected_resp;
   output [31:0] rdata;
   begin
      apb_read(1, mode, addr, 32'h0, size, 1'b0, expected_resp);
      rdata = acc_rdata;
   end
endtask

//============================================================================
// Shorthands: blocking Machine-mode word accesses
//============================================================================
task wr;
   input [31:0] addr;
   input [31:0] data;
   begin
      apb_write(1, MACHINE, addr, data, SZ_W, OK);
   end
endtask

task rd;
   input [31:0] addr;
   input [31:0] expected_word;
   begin
      apb_read(1, MACHINE, addr, expected_word, SZ_W, 1'b1, OK);
   end
endtask

task rdv;
   input  [31:0] addr;
   output [31:0] rdata;
   begin
      apb_read_val(MACHINE, addr, SZ_W, OK, rdata);
   end
endtask
