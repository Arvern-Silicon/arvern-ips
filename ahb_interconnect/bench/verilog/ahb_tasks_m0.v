//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_tasks_m0
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_tasks_m0.v
// Module Description : AHB master-0 task wrappers.
//----------------------------------------------------------------------------

task automatic m0_ahb_write;
   input         blocking; // Block until end of data-phase if 1, else release at the end of address-phase
   input  [31:0] addr;     // Address
   input  [31:0] data;     // Data
   input   [1:0] size;     // Access size (0: 8-bit / 1: 16-bit / 2: 32-bit)

   begin
      m0_haddr   = addr;
      m0_htrans  = 2'b10;
      m0_hwrite  = 1'b1;
      m0_hsize   = {1'b0, size};

      @(posedge free_clk);
      while(~m0_hready) @(posedge free_clk);
      #1;
      m0_hwdata  = size==0 ? (m0_haddr[1:0]==0 ? {24'h000000, data[7:0]            } :
                              m0_haddr[1:0]==1 ? {16'h0000,   data[7:0], 8'h00     } :
                              m0_haddr[1:0]==2 ? {8'h00,      data[7:0], 16'h0000  } :
                                                 {            data[7:0], 24'h000000} ) :
                   size==1 ? (m0_haddr[1]==0   ? {16'h0000,   data[15:0]           } :
                                                 {            data[15:0], 16'h0000 } ) :
                              data;

      m0_haddr   = 32'h00000000;
      m0_htrans  = 2'b00;
      m0_hwrite  = 1'b0;
      m0_hsize   = 3'b000;

      if (blocking == 1) begin
         $display("INFO:  M0 AHB write           -- address: 0x%h -- value: 0x%h -- size: %d %t ns", addr, data, size, $time);
      end else begin
         $display("INFO:  M0 Pipe AHB write      -- address: 0x%h -- value: 0x%h -- size: %d %t ns", addr, data, size, $time);
      end

      if (blocking==1) begin
         @(posedge free_clk);
         while(~m0_hready & blocking) @(posedge free_clk);
      end

   end
endtask


//============================================================================
// Simple Read access
//============================================================================

//---------------------
// Read-check dispatcher (queue-driven)
//---------------------
// Each m0_ahb_read call enqueues its expected (data, mask, addr, size,
// blocking) into a small circular buffer; the dispatcher pops one entry per
// data phase and compares against m0_hrdata at the corresponding negedge.
// Replaces an earlier shared-flag handshake whose @(posedge ...) trigger
// could be missed when a check was still pending from a prior pipelined read.
parameter M0_CHK_DEPTH = 16;

reg [31:0] m0_chk_addr  [0:M0_CHK_DEPTH-1];
reg [31:0] m0_chk_data  [0:M0_CHK_DEPTH-1];
reg [31:0] m0_chk_mask  [0:M0_CHK_DEPTH-1];
reg  [1:0] m0_chk_size  [0:M0_CHK_DEPTH-1];
reg        m0_chk_block [0:M0_CHK_DEPTH-1];
reg [31:0] m0_chk_wr_ptr;
reg [31:0] m0_chk_rd_ptr;

integer    m0_chk_idx;
reg [31:0] m0_chk_addr_q;
reg [31:0] m0_chk_data_q;
reg [31:0] m0_chk_mask_q;
reg  [1:0] m0_chk_size_q;
reg        m0_chk_block_q;

initial
  begin
     m0_chk_wr_ptr = 0;
     m0_chk_rd_ptr = 0;
     forever
       begin
          wait (m0_chk_wr_ptr !== m0_chk_rd_ptr);
          @(negedge free_clk);
          while (~m0_hready) begin
             @(posedge m0_hready);
             @(negedge free_clk);
          end

          m0_chk_idx     = m0_chk_rd_ptr % M0_CHK_DEPTH;
          m0_chk_addr_q  = m0_chk_addr [m0_chk_idx];
          m0_chk_data_q  = m0_chk_data [m0_chk_idx];
          m0_chk_mask_q  = m0_chk_mask [m0_chk_idx];
          m0_chk_size_q  = m0_chk_size [m0_chk_idx];
          m0_chk_block_q = m0_chk_block[m0_chk_idx];

          if ((m0_chk_data_q !== (m0_chk_mask_q & m0_hrdata)) & hresetn)
            begin
               if (m0_chk_block_q)
                 $display("ERROR: M0 AHB read check      -- address: 0x%h -- read: 0x%h / expected: 0x%h -- size: %d %t ns", m0_chk_addr_q, (m0_chk_mask_q & m0_hrdata), m0_chk_data_q, m0_chk_size_q, $time);
               else
                 $display("ERROR: M0 Pipe AHB read check -- address: 0x%h -- read: 0x%h / expected: 0x%h -- size: %d %t ns", m0_chk_addr_q, (m0_chk_mask_q & m0_hrdata), m0_chk_data_q, m0_chk_size_q, $time);
               error = error+1;
            end
          else
            begin
               if (m0_chk_block_q)
                 $display("PASS:  M0 AHB read check      -- address: 0x%h -- value: 0x%h -- size: %d %t ns", m0_chk_addr_q, m0_chk_data_q, m0_chk_size_q, $time);
               else
                 $display("PASS:  M0 Pipe AHB read check -- address: 0x%h -- value: 0x%h -- size: %d %t ns", m0_chk_addr_q, m0_chk_data_q, m0_chk_size_q, $time);
            end

          m0_chk_rd_ptr = m0_chk_rd_ptr + 1;
       end
  end


////---------------------
//// Generic read task
////---------------------

task automatic m0_ahb_read;
   input         blocking;       // Block until end of data-phase if 1, else release at the end of address-phase
   input  [31:0] addr;           // Address
   input  [31:0] expected_data;  // Data
   input   [1:0] size;           // Access size (0: 8-bit / 1: 16-bit / 2: 32-bit)
   input         check;          // Enable/disable read value check

   reg    [31:0] check_data;
   reg    [31:0] check_mask;
   integer       q_idx;

   begin
      m0_haddr   = addr;
      m0_htrans  = 2'b10;
      m0_hwrite  = 1'b0;
      m0_hsize   = {1'b0, size};

      @(posedge free_clk);
      while(~m0_hready) @(posedge free_clk);
      #1;

      check_data =  size==0 ? (addr[1:0]==3 ? {expected_data[7:0], 24'h000000                   } :
                               addr[1:0]==2 ? {8'h00,              expected_data[7:0], 16'h0000 } :
                               addr[1:0]==1 ? {16'h0000,           expected_data[7:0], 8'h00    } :
                                              {24'h000000,         expected_data[7:0]           } ) :

                    size==1 ? (addr[1]      ? {expected_data[15:0], 16'h0000                    } :
                                              {16'h0000,            expected_data[15:0]         } ) :

                                              expected_data;

      check_mask =  size==0 ? (addr[1:0]==3 ? 32'hFF000000 :
                               addr[1:0]==2 ? 32'h00FF0000 :
                               addr[1:0]==1 ? 32'h0000FF00 :
                                              32'h000000FF ) :
                    size==1 ? (addr[1]      ? 32'hFFFF0000 :
                                              32'h0000FFFF ) :
                                              32'hFFFFFFFF;

      // Enqueue this check into the dispatcher's circular buffer
      if (check) begin
         q_idx = m0_chk_wr_ptr % M0_CHK_DEPTH;
         m0_chk_addr [q_idx] = addr;
         m0_chk_data [q_idx] = check_data;
         m0_chk_mask [q_idx] = check_mask;
         m0_chk_size [q_idx] = size;
         m0_chk_block[q_idx] = blocking;
         m0_chk_wr_ptr       = m0_chk_wr_ptr + 1;
      end

      m0_haddr   = 32'h00000000;
      m0_htrans  = 2'b00;
      m0_hwrite  = 1'b0;
      m0_hsize   = 3'b000;
      //m0_hwdata  = 32'h00000000;
      if (blocking==1) begin
         @(posedge free_clk);
         while(~m0_hready & blocking) @(posedge free_clk);
      end

   end
endtask
