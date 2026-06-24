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
