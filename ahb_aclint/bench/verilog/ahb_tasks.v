//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_tasks
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_tasks.v
// Module Description : Generic tasks performing AHB read/write transfers.
//                      Mirrors the BFM used by ahb_periph_example. ACLINT
//                      (with PRIV_CHECK_EN=1) consumes hprot/hsmode for its
//                      M-only access policy; the BFM drives these from the
//                      `mode` argument: USER -> hprot[1]=0, SUPERVISOR ->
//                      hprot[1]=1 + hsmode=1, MACHINE -> hprot[1]=1 +
//                      hsmode=0.
//----------------------------------------------------------------------------

localparam USER       = 2'b00;
localparam SUPERVISOR = 2'b01;
localparam MACHINE    = 2'b11;

localparam OK         = 1'b0;
localparam ERROR      = 1'b1;

//============================================================================
// Simple Write access
//============================================================================
task ahb_write;
   input         blocking;      // Block until end of data-phase if 1, else release at the end of address-phase
   input   [1:0] mode;          // Privilege mode
   input  [31:0] addr;          // Address
   input  [31:0] data;          // Data
   input   [1:0] size;          // Access size (0: 8-bit / 1: 16-bit / 2: 32-bit)
   input         expected_resp; // Expected response (0: OK / 1: ERROR)

   begin
      haddr    = addr;
      htrans   = 2'b10;
      hwrite   = 1'b1;
      hsize    = {1'b0, size};
      if (mode==2'b00) begin
         hprot = 4'h0;
      end else begin
         hprot = 4'h2;
         if (mode==2'b01) begin
            hsmode = 1'b1;
         end else begin
            hsmode = 1'b0;
         end
      end

      @(posedge free_clk);
      #1;
	   if (expected_resp !== hresp) begin
	      $display("ERROR: AHB write response check -- address: 0x%h -- hresp: 0x%h / expected: 0x%h %t ns", addr, hresp, expected_resp, $time);
         error = error+1;
	   end
      // AHB protocol: master must drive hwdata at the start of DPH and hold
      // it stable for the entire DPH, including any hready_i wait extensions.
      // The slave is allowed to sample hwdata at every clock edge during DPH.
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


//============================================================================
// Simple Read access
//============================================================================

//---------------------
// Read check process
//---------------------
reg        ahb_read_check_active;
reg [31:0] ahb_read_check_addr;
reg [31:0] ahb_read_check_data;
reg [31:0] ahb_read_check_mask;
reg  [1:0] ahb_read_check_size;
reg  [1:0] ahb_read_check_mode;

initial
  begin
     ahb_read_check_active =  1'b0;
     ahb_read_check_addr   = 32'h00000000;
     ahb_read_check_data   = 32'h00000000;
     ahb_read_check_mask   = 32'h00000000;
     ahb_read_check_size   =  2'b00;
     ahb_read_check_mode   =  2'b00;
     forever
       begin
	         @(negedge (free_clk & ahb_read_check_active));
	         if ((ahb_read_check_data !== (ahb_read_check_mask & hrdata)) & hresetn)
	            begin
	               $display("ERROR: AHB read check -- address: 0x%h -- read: 0x%h / expected: 0x%h -- size: %d -- mode: %d %t ns", ahb_read_check_addr, (ahb_read_check_mask & hrdata), ahb_read_check_data, ahb_read_check_size, ahb_read_check_mode, $time);
                  error = error+1;
	            end
            else
               begin
                  $display("PASS:  AHB read check -- address: 0x%h -- value: 0x%h -- size: %d -- mode: %d %t ns", ahb_read_check_addr, ahb_read_check_data, ahb_read_check_size, ahb_read_check_mode, $time);
               end
	         ahb_read_check_active =  1'b0;
       end
  end


////---------------------
//// Generic read task
////---------------------

task ahb_read;
   input         blocking;       // Block until end of data-phase if 1, else release at the end of address-phase
   input   [1:0] mode;           // Privilege mode
   input  [31:0] addr;           // Address
   input  [31:0] expected_data;  // Data
   input   [1:0] size;           // Access size (0: 8-bit / 1: 16-bit / 2: 32-bit)
   input         check;          // Enable/disable read value check
   input         expected_resp;  // Expected response (0: OK / 1: ERROR)

   begin
      haddr   = addr;
      htrans  = 2'b10;
      hwrite  = 1'b0;
      hsize   = {1'b0, size};
      if (mode==2'b00) begin
         hprot = 4'h0;
      end else begin
         hprot = 4'h2;
         if (mode==2'b01) begin
            hsmode = 1'b1;
         end else begin
            hsmode = 1'b0;
         end
      end

      @(posedge free_clk);
      #1;
   	if (expected_resp !== hresp) begin
	      $display("ERROR: AHB read response check -- address: 0x%h -- hresp: 0x%h / expected: 0x%h %t ns", addr, hresp, expected_resp, $time);
         error = error+1;
	   end
      while(~hready) @(posedge free_clk);
      #1;
      // Trigger read check
      ahb_read_check_active =  check;
      ahb_read_check_addr   =  addr;
      ahb_read_check_size   =  size;
      ahb_read_check_mode   =  mode;

      ahb_read_check_data   =  size==0 ? (addr[1:0]==3 ? {expected_data[7:0], 24'h000000                   } :
                                          addr[1:0]==2 ? {8'h00,              expected_data[7:0], 16'h0000 } :
                                          addr[1:0]==1 ? {16'h0000,           expected_data[7:0], 8'h00    } :
                                                         {24'h000000,         expected_data[7:0]           } ) :

                               size==1 ? (addr[1]      ? {expected_data[15:0], 16'h0000                    } :
                                                         {16'h0000,            expected_data[15:0]         } ) :

                                         expected_data;

      ahb_read_check_mask   =  size==0 ? (addr[1:0]==3 ? 32'hFF000000 :
                                          addr[1:0]==2 ? 32'h00FF0000 :
                                          addr[1:0]==1 ? 32'h0000FF00 :
                                                         32'h000000FF ) :
                               size==1 ? (addr[1]      ? 32'hFFFF0000 :
                                                         32'h0000FFFF ) :
                                         32'hFFFFFFFF;

      haddr   = 32'h00000000;
      htrans  = 2'b00;
      hprot   = 4'h0;
      hsmode  = 1'b0;
      hwrite  = 1'b0;
      hsize   = 3'b000;
      //hwdata  = 32'h00000000;
      if (blocking==1) begin
         @(posedge free_clk);
         while(~hready & blocking) @(posedge free_clk);
      end

   end
endtask


//============================================================================
// Raw single-beat AHB driver with an arbitrary htrans encoding (MACHINE mode)
//============================================================================
// Drives ONE address phase with the caller-supplied htrans so tests can probe
// the SEQ (2'b11) and BUSY (2'b01) encodings the standard ahb_read/ahb_write
// tasks never generate. The DUT keys only on htrans_i[1], so SEQ must behave
// like NONSEQ (access happens) and BUSY like IDLE (no access). No response
// check here -- the caller verifies the side effect (register state).
task ahb_drive_htrans;
   input  [1:0] htrans_val;   // 2'b10 NONSEQ, 2'b11 SEQ, 2'b01 BUSY, 2'b00 IDLE
   input [31:0] addr;
   input        write;        // 1 = write, 0 = read
   input [31:0] wdata;
   begin
      haddr  = addr;
      htrans = htrans_val;
      hwrite = write;
      hprot  = 4'h2;          // MACHINE (hprot[1]=1, hsmode=0)
      hsmode = 1'b0;
      hsize  = 3'b010;        // word

      @(posedge free_clk);
      #1;
      hwdata = wdata;         // hold for the data phase
      while (~hready) @(posedge free_clk);
      #1;
      haddr  = 32'h00000000;
      htrans = 2'b00;
      hwrite = 1'b0;
      hprot  = 4'h0;
      hsmode = 1'b0;
      hsize  = 3'b000;
      @(posedge free_clk);
   end
endtask


//============================================================================
// Zicntr time-port BFM
//============================================================================
// Models the aRVern core consuming a `csrr time` / `csrr timeh`:
//
//   1. asserts time_req on an otherwise-quiescent bus. With the AHB/SSWI idle,
//      mtimer_active_o -> hclk_en_o is driven ONLY by the Zicntr terms, so a
//      gated hclk_i is restarted purely by the request (exercises the
//      `time_req_i | time_req_pending` term of mtimer_active_o).
//   2. latches time_val_o on the cycle time_gnt_o pulses -- the RTL guarantees
//      the (time_gnt_o, time_val_o) pair is coherent on that edge.
//   3. deasserts time_req IN RESPONSE to the grant (i.e. combinationally on
//      ~time_gnt, the way the real core's time_req_o is generated). This is
//      the load-bearing detail: on the grant cycle the FSM has already
//      returned to IDLE and time_req/pending are low, so time_gnt_r is the
//      SOLE term holding mtimer_active_o high. If that term is missing from
//      mtimer_active_o, the SoC clock gate starves the cleanup edge and
//      time_gnt_o is stranded high forever. The caller checks for exactly
//      that (see mtimer_zicntr_time.v). See aclint_mtimer.v Section 11.
//
// Sampling is aligned to free_clk (the ungated reference). While the gate is
// open hclk_i is edge-aligned to free_clk, so the 1-cycle grant pulse is
// reliably observed at the following negedge; and if the handshake hangs the
// poll still advances on free_clk and fails with a message rather than only
// tripping the global timeout.
//============================================================================
task zicntr_time_read;
   output [63:0]   val;           // captured 64-bit time snapshot
   input  [40*8:0] tag;           // label for logging
   integer         gnt_wait;
   begin
      @(negedge free_clk);
      time_req = 1'b1;

      gnt_wait = 0;
      while (time_gnt !== 1'b1) begin
         @(negedge free_clk);
         gnt_wait = gnt_wait + 1;
         if (gnt_wait > 200) begin
            $display("ERROR: Zicntr %s -- time_gnt never asserted (handshake hung) %t ns", tag, $time);
            error    = error + 1;
            time_req = 1'b0;
            val      = 64'hx;
            disable zicntr_time_read;
         end
      end

      // Coherent latch on the grant cycle, then release the request the way
      // the core does: as a response to the grant.
      val      = time_val;
      time_req = 1'b0;

      $display("INFO:  Zicntr %s -- granted in %0d cycle(s), time_val = 0x%h_%h %t ns",
               tag, gnt_wait, val[63:32], val[31:0], $time);
   end
endtask


//============================================================================
// Check that time_gnt_o has returned to 0 after a grant.
//============================================================================
// time_gnt_o is contractually a <=1-cycle pulse. A stuck-high grant is the
// direct symptom of the clock gate dropping hclk_i before time_gnt_r could
// clear (mtimer_active_o missing its time_gnt_r term). This runs on free_clk,
// so it reports the failure even if hclk_i is frozen.
task zicntr_check_gnt_cleared;
   input [40*8:0] tag;
   begin
      repeat (4) @(negedge free_clk);
      if (time_gnt !== 1'b0) begin
         $display("ERROR: Zicntr %s -- time_gnt stuck high after grant (clock gate starved the time_gnt_r cleanup edge -- mtimer_active_o missing time_gnt_r?) %t ns", tag, $time);
         error = error + 1;
      end else begin
         $display("PASS:  Zicntr %s -- time_gnt returned low after the 1-cycle pulse %t ns", tag, $time);
      end
   end
endtask
