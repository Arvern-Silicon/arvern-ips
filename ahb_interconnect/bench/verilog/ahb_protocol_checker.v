//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_protocol_checker
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_protocol_checker.v
// Module Description : Passive AHB-Lite address-phase stability monitor.
//----------------------------------------------------------------------------

module ahb_protocol_checker (
    bus_name_i,
    hclk_i,
    hresetn_i,
    haddr_i,
    htrans_i,
    hsize_i,
    hwrite_i,
    hburst_i,
    hready_i,
    hresp_i,
    checker_enable_i
);

input  [8*64-1:0] bus_name_i;          // human-readable bus label for messages
input             hclk_i;              // the master's launch clock (dut_hclk)
input             hresetn_i;
input      [31:0] haddr_i;
input       [1:0] htrans_i;            // 2'b00 IDLE, 2'b10 NONSEQ (this core)
input       [2:0] hsize_i;
input             hwrite_i;
input       [2:0] hburst_i;
input             hready_i;
input             hresp_i;
input             checker_enable_i;

// When 1, exempt mid-wait HADDR/HTRANS changes (documented instruction-bus
// deviation); HSIZE/HWRITE/HBURST stay enforced. Default 0 = fully strict.
parameter         ALLOW_HADDR_HTRANS_CHANGE_IN_WAIT = 1'b0;

localparam        HTRANS_IDLE = 2'b00;
localparam        VIOL_PRINT_CAP = 12;  // print this many in full, then summarise

integer           viol_cnt;
reg               armed;                // 0 for the first post-reset cycle (no valid prev yet)

reg        [31:0] prev_haddr;
reg         [1:0] prev_htrans;
reg         [2:0] prev_hsize;
reg               prev_hwrite;
reg         [2:0] prev_hburst;
reg               prev_hready;
reg               prev_hresp;

wire              enforce = armed
                          & checker_enable_i
                          & (prev_htrans != HTRANS_IDLE)   // a transfer was being presented
                          & (prev_hready == 1'b0)           // ... and the slave had not accepted it
                          & (prev_hresp  == 1'b0);          // ... and it was not an ERROR response

// HADDR/HTRANS terms are dropped when ALLOW_HADDR_HTRANS_CHANGE_IN_WAIT=1
// (documented instruction-bus deviation); HSIZE/HWRITE/HBURST always enforced.
wire              addr_ctrl_changed = (ALLOW_HADDR_HTRANS_CHANGE_IN_WAIT ? 1'b0 :
                                       ((haddr_i  != prev_haddr ) |
                                        (htrans_i != prev_htrans))) |
                                      (hsize_i  != prev_hsize ) |
                                      (hwrite_i != prev_hwrite) |
                                      (hburst_i != prev_hburst);

initial viol_cnt = 0;

always @(posedge hclk_i or negedge hresetn_i)
   if (!hresetn_i)
      begin
         armed       <= 1'b0;
         prev_haddr  <= haddr_i;
         prev_htrans <= htrans_i;
         prev_hsize  <= hsize_i;
         prev_hwrite <= hwrite_i;
         prev_hburst <= hburst_i;
         prev_hready <= hready_i;
         prev_hresp  <= hresp_i;
      end
   else
      begin
         if (enforce & addr_ctrl_changed)
            begin
               viol_cnt = viol_cnt + 1;
               tb_ahb_interconnect.error = tb_ahb_interconnect.error + 1;

               if (viol_cnt <= VIOL_PRINT_CAP)
                  begin
                     $display("ERROR-VERILOG: [AHB-Lite address-phase instability] %0s [%0d] (%t)",
                              bus_name_i, viol_cnt, $time);
                     $display("    master changed address/control while HREADY low (transfer not yet accepted, not an ERROR response):");
                     $display("      HADDR  : 0x%08x -> 0x%08x", prev_haddr,  haddr_i );
                     $display("      HTRANS :    %b    ->    %b   %s", prev_htrans, htrans_i,
                              ((prev_htrans!=HTRANS_IDLE)&&(htrans_i==HTRANS_IDLE)) ? "(NONSEQ retracted to IDLE before acceptance)" : "");
                     $display("      HSIZE  :    %b   ->    %b ;  HWRITE %b -> %b ;  HBURST %b -> %b",
                              prev_hsize, hsize_i, prev_hwrite, hwrite_i, prev_hburst, hburst_i);
                  end
               else if (viol_cnt == VIOL_PRINT_CAP + 1)
                  $display("ERROR-VERILOG: [AHB-Lite address-phase instability] %0s -- further violations suppressed in log, still counted (%t)",
                           bus_name_i, $time);
            end

         // Sample this cycle's bus state for the next-edge comparison, and
         // arm after the first post-reset cycle (so prev_* is always valid).
         armed       <= 1'b1;
         prev_haddr  <= haddr_i;
         prev_htrans <= htrans_i;
         prev_hsize  <= hsize_i;
         prev_hwrite <= hwrite_i;
         prev_hburst <= hburst_i;
         prev_hready <= hready_i;
         prev_hresp  <= hresp_i;
      end

endmodule
