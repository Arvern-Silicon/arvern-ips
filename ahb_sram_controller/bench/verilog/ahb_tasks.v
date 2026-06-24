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

//============================================================================
// Simple Write access
//============================================================================
task ahb_write;
   input         blocking; // Block until end of data-phase if 1, else release at the end of address-phase
   input  [31:0] addr;     // Address
   input  [31:0] data;     // Data
   input   [1:0] size;     // Access size (0: 8-bit / 1: 16-bit / 2: 32-bit)

   begin
      haddr   = addr;
      htrans  = 2'b10;
      hwrite  = 1'b1;
      hsize   = {1'b0, size};

      @(posedge free_clk);
      while(~hready) @(posedge free_clk);
      #1;
      hwdata  = size==0 ? (haddr[1:0]==0 ? {24'h000000, data[8:0]            } :
                           haddr[1:0]==1 ? {16'h0000,   data[8:0], 8'h00     } :
                           haddr[1:0]==2 ? {8'h00,      data[8:0], 16'h0000  } :
                                           {            data[8:0], 24'h000000} ) :
                size==1 ? (haddr[1]==0   ? {16'h0000,   data[15:0]           } :
                                           {            data[15:0], 16'h0000 } ) :
                          data;

      haddr   = 32'h00000000;
      htrans  = 2'b00;
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

initial
  begin
     ahb_read_check_active =  1'b0;
     ahb_read_check_addr   = 32'h00000000;
     ahb_read_check_data   = 32'h00000000;
     ahb_read_check_mask   = 32'h00000000;
     ahb_read_check_size   =  2'b00;
     forever
       begin
	         @(posedge (ahb_read_check_active));
	         @(negedge (free_clk));
            if (~hready) begin
               @(posedge (hready));
	            @(negedge (free_clk));
            end
	         if ((ahb_read_check_data !== (ahb_read_check_mask & hrdata)) & hresetn)
	            begin
	               $display("ERROR: AHB read check -- address: 0x%h -- read: 0x%h / expected: 0x%h -- size: %d %t ns", ahb_read_check_addr, (ahb_read_check_mask & hrdata), ahb_read_check_data, ahb_read_check_size, $time);
                  error = error+1;
	            end
            else 
               begin
                  $display("PASS:  AHB read check -- address: 0x%h -- value: 0x%h -- size: %d %t ns", ahb_read_check_addr, ahb_read_check_data, ahb_read_check_size, $time);
               end
	         ahb_read_check_active =  1'b0;
       end
  end


////---------------------
//// Generic read task
////---------------------

task ahb_read;
   input         blocking;       // Block until end of data-phase if 1, else release at the end of address-phase
   input  [31:0] addr;           // Address
   input  [31:0] expected_data;  // Data
   input   [1:0] size;           // Access size (0: 8-bit / 1: 16-bit / 2: 32-bit)
   input         check;          // Enable/disable read value check

   begin
      haddr   = addr;
      htrans  = 2'b10;
      hwrite  = 1'b0;
      hsize   = {1'b0, size};

      @(posedge free_clk);
      while(~hready) @(posedge free_clk);
      #1;

      // Trigger read check
      ahb_read_check_active =  check;
      ahb_read_check_addr   =  addr;
      ahb_read_check_size   =  size;

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
      hwrite  = 1'b0;
      hsize   = 3'b000;
      //hwdata  = 32'h00000000;
      if (blocking==1) begin
         @(posedge free_clk);
         while(~hready & blocking) @(posedge free_clk);
      end

   end
endtask

