//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dmi_walk
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dmi_walk
// Module Description : TRANSPORT-NEUTRAL walking-ones / walking-zeros over the
//                      7-bit DMI address and the 32-bit write data (runsim -dtm
//                      jtag | cjtag | uart | i2c).
//
//   doc/arv_dtm.md: "The DMI address width is fixed at 7 ... The APB address port is
//   dmi_paddr_o[8:0] (byte address, PADDR = reg << 2)." "All four are DMI-native:
//   the payload is the {address, op, data} DMI transaction ... so the logical
//   transaction is identical across transports".
//   doc/arv_dtm.md, DMI over serial: "Address 0x7F is a DTM-local status register,
//   DTMSTS ... it never reaches the DMI bus" -- so 0x7F (all ones) is not walked;
//   neither walking set contains it.
//   doc/arv_dtm_jtag.md, dmi: "the Capture-DR value carries the address of the last
//   launched op, its data (read data) and its op status -- after a successful read,
//   address is the address that was read from (Debug 1.0 Sec 6.1.5)."
//
//   Addresses: walking ones 0x01..0x40 and walking zeros 0x7E..0x3F (14).
//   Data: walking ones 1<<0..1<<31 and walking zeros ~(1<<0)..~(1<<31) (64).
//   Five rounds (14, 14, 14, 14, 8 values). Each round writes a DIFFERENT value to
//   every address of the round first, then checks the subordinate's memory at
//   PADDR[8:2] directly, then reads every address back -- a stuck or bridged
//   address bit makes two addresses alias and one of them reads the other's value.
//   Every data pattern is written and read back once. On JTAG / cJTAG the read
//   collects its result with a nop scan whose captured address field must be the
//   address read from.
//----------------------------------------------------------------------------

reg [ABITS-1:0] dw_addr [0:13];
reg      [31:0] dw_data [0:63];

task dw_read;
   input  [ABITS-1:0] addr;
   output [31:0]      data;
   output [1:0]       status;
`ifdef DTM_UART
   begin
      dtm_dmi_read(addr, data, status);
   end
`elsif DTM_I2C
   begin
      dtm_dmi_read(addr, data, status);
   end
`else
   reg [31:0] d0;
   reg  [1:0] s0;
   reg [63:0] cap;
   begin
      dmi_scan(addr, 32'b0, OP_READ, d0, s0);
      idle_cycles(DTM_IDLE_N);
      shift_dr(64'b0, DMI_DR_W, cap);                     // nop, collects the result
      status = cap[1:0];
      data   = cap[33:2];
      check_eq("cap_addr", cap[ABITS+33:34], addr);
   end
`endif
endtask

initial
   begin : test
      reg [31:0] rd;
      reg  [1:0] st;
      integer    i;
      integer    r;
      integer    n;
      integer    base;

      for (i = 0; i < 7; i = i + 1) begin
         dw_addr[i]     = 7'h01 << i;                     // walking ones
         dw_addr[i + 7] = ~(7'h01 << i);                  // walking zeros
      end
      for (i = 0; i < 32; i = i + 1) begin
         dw_data[i]      = 32'h1 << i;                    // walking ones
         dw_data[i + 32] = ~(32'h1 << i);                 // walking zeros
      end
      for (i = 0; i < 128; i = i + 1) slave_mem[i] = 32'h0BAD_0000 | i;

      dtm_init;
      slave_latency = 3;

      $display(" ===============================================");
      $display("|  Walking address / data (any transport)       |");
      $display(" ===============================================");
      for (r = 0; r < 5; r = r + 1) begin
         base = r * 14;
         n    = (r == 4) ? 8 : 14;
         for (i = 0; i < n; i = i + 1) begin
            dtm_dmi_write(dw_addr[i], dw_data[base + i], st);
            check_eq("wr_status", st, OP_SUCCESS);
         end
         dtm_settle(8);
         repeat (20) @(posedge free_clk);
         for (i = 0; i < n; i = i + 1)
            check_eq("slave_mem", slave_mem[dw_addr[i]], dw_data[base + i]);
         for (i = 0; i < n; i = i + 1) begin
            dw_read(dw_addr[i], rd, st);
            if ((st !== OP_SUCCESS) || (rd !== dw_data[base + i]))
               $display("  round %0d addr 0x%02h", r, dw_addr[i]);
            check_eq("rd_status", st, OP_SUCCESS);
            check_eq("rd_data",   rd, dw_data[base + i]);
         end
      end

      dtm_settle(8);
      stimulus_done = 1'b1;
   end
