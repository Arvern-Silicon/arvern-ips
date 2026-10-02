//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dtmsts_reg
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dtmsts_reg
// Module Description : The DTM-local DTMSTS status register at DMI address 0x7F.
//
//   0x7F is intercepted locally by the DTM -- it never reaches the DMI bus/slave:
//     READ  0x7F -> { bits[15:8] = RX_FIFO_DEPTH, bit[0] = rx_overrun(sticky) }, rest 0
//     WRITE 0x7F -> data[0]=1 clears rx_overrun (write-1-to-clear)
//   Both complete with status=success and perform NO DMI bus access.
//
//   The bench builds the UART DTM with RX_FIFO_DEPTH=`UART_FIFO_DEPTH (default 32, see tb_arv_dtm.v), so
//   a correct READ 0x7F must report that depth in bits[15:8]. That field is also the
//   strongest INTERCEPT proof: had the read gone to the DMI bus it would return
//   slave_mem[0x7F] (never written = 0), not 0x20 -- so depth==32 can only come from
//   the local composer.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      uart_autobaud_sync();                             // open the link: measure baud + eat echo

      slave_latency = 0;                                // = arvern Debug Module timing

      $display(" ===============================================");
      $display("|  DTMSTS read: depth field + overrun at reset  |");
      $display(" ===============================================");

      // READ 0x7F at reset: depth=32 (built param), overrun=0, status=success.
      dmi_uart(7'h7F, OP_READ, 32'h0, st, rd);
      check_eq("rd_st",       st,        OP_SUCCESS);
      check_eq("depth_field", rd[15:8],  `UART_FIFO_DEPTH); // == RX_FIFO_DEPTH (param honored)
      check_eq("overrun_rst", rd[0],     1'b0);         // sticky bit clear at reset
      check_eq("other_bits",  rd & 32'hFFFF_00FE, 32'h0); // all non-depth/overrun bits 0

      $display(" ===============================================");
      $display("|  0x7F is intercepted: DMI bus is undisturbed  |");
      $display(" ===============================================");

      // Seed a sentinel at a normal address, read 0x7F (must not touch the bus),
      // then re-read the normal address: it must be unchanged.
      dmi_uart(7'h10, OP_WRITE, 32'hA5A5_1234, st, rd);
      dmi_uart(7'h7F, OP_READ,  32'h0,         st, rd);
      check_eq("intercept_st",    st,       OP_SUCCESS);
      check_eq("intercept_depth", rd[15:8], `UART_FIFO_DEPTH);// local value, not slave_mem[0x7F]
      dmi_uart(7'h10, OP_READ,  32'h0,         st, rd);
      check_eq("sentinel_intact", rd, 32'hA5A5_1234);   // 0x7F access left 0x10 alone

      $display(" ===============================================");
      $display("|  W1C write path: success, overrun stays clear |");
      $display(" ===============================================");

      // WRITE 0x7F data[0]=1 (clear-overrun) when none occurred: success, no-op.
      dmi_uart(7'h7F, OP_WRITE, 32'h0000_0001, st, rd);
      check_eq("w1c_st", st, OP_SUCCESS);
      dmi_uart(7'h7F, OP_READ,  32'h0, st, rd);
      check_eq("w1c_rd_st",      st,    OP_SUCCESS);
      check_eq("overrun_still0", rd[0], 1'b0);          // nothing to clear -> still 0

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
