//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    i2c_dtmsts_reg
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : i2c_dtmsts_reg
// Module Description : The DTM-local DTMSTS register (DMI address 0x7F) over I2C.
//
//   doc/arv_dtm_i2c.md, DTMSTS: "a read (op = 1) returns {16'b0,
//   rx_fifo_depth[7:0], 7'b0, rx_overrun} with status 0, where rx_fifo_depth
//   reads 8; a write (op = 2) with data bit 0 = 1 clears the sticky rx_overrun
//   (write-1-to-clear) and returns the status word as read before the clear;
//   op = 0 / op = 3 at 0x7F are not intercepted."
//   Behaviour at a glance: "DMI address 0x7F (DTMSTS) | Answered locally, never
//   reaches the DMI bus".
//   doc/arv_dtm_uart.md, DTMSTS table: "Bit 0 = 0 is a no-op."
//
//   Checks (black-box: wire responses, dmi_psel, slave_mem):
//     - read 0x7F at reset: status 0, word == 0x0000_0800 exactly (depth 8,
//       overrun 0, every other bit 0). A sentinel planted in slave_mem[0x7F] is
//       not returned, and dmi_psel never rises during the access.
//     - write 0x7F, data bit 0 = 1 (nothing to clear) and bit 0 = 0 (no-op):
//       status 0, returned word = the status word before the write (0x800),
//       no APB access, slave_mem[0x7F] untouched; a read afterwards is still 0x800.
//     - op = 0 at 0x7F is an ordinary poll: it returns the result of the normal
//       read issued immediately before it, with no APB access.
//     - op = 3 at 0x7F is an ordinary dmihardreset: status 0, data 0.
//     - a normal transaction afterwards round-trips.
//   The overrun set/clear path is exercised by i2c_second_request.
//----------------------------------------------------------------------------

integer psel_cnt;
reg     psel_seen;
initial begin psel_cnt = 0; psel_seen = 1'b0; end
always @(posedge dmi_psel) psel_cnt = psel_cnt + 1;
always @(posedge free_clk) if (dmi_psel === 1'b1) psel_seen = 1'b1;

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;
      integer    pc;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      slave_latency = 0;

      // Sentinel behind 0x7F: an access that leaked to the DMI bus would read it
      // (or overwrite it).
      slave_mem[7'h7F] = 32'hDEAD_BEEF;

      $display(" ===============================================");
      $display("|  DTMSTS read at reset: depth 8, overrun 0     |");
      $display(" ===============================================");
      pc = psel_cnt; psel_seen = 1'b0;
      dmi_i2c(7'h7F, OP_READ, 32'h0, st, rd);
      check_eq("rst_st",       st, OP_SUCCESS);
      check_eq("rst_word",     rd, 32'h0000_0800);     // {16'b0, 8, 7'b0, 0}
      check_eq("rst_depth",    rd[15:8], 8'd8);
      check_eq("rst_no_psel",  psel_cnt - pc, 0);
      check_eq("rst_psel_idle", psel_seen, 1'b0);
      check_eq("rst_sentinel", slave_mem[7'h7F], 32'hDEAD_BEEF);

      $display(" ===============================================");
      $display("|  DTMSTS W1C write with nothing to clear       |");
      $display(" ===============================================");
      pc = psel_cnt; psel_seen = 1'b0;
      dmi_i2c(7'h7F, OP_WRITE, 32'h0000_0001, st, rd);
      check_eq("w1c_st",       st, OP_SUCCESS);
      check_eq("w1c_ret_word", rd, 32'h0000_0800);     // status word before the clear
      check_eq("w1c_no_psel",  psel_cnt - pc, 0);
      check_eq("w1c_psel_idle", psel_seen, 1'b0);
      check_eq("w1c_sentinel", slave_mem[7'h7F], 32'hDEAD_BEEF);

      // Bit 0 = 0 is a no-op; the other data bits are not a register image.
      pc = psel_cnt; psel_seen = 1'b0;
      dmi_i2c(7'h7F, OP_WRITE, 32'hFFFF_FFFE, st, rd);
      check_eq("w0_st",        st, OP_SUCCESS);
      check_eq("w0_ret_word",  rd, 32'h0000_0800);
      check_eq("w0_no_psel",   psel_cnt - pc, 0);
      check_eq("w0_sentinel",  slave_mem[7'h7F], 32'hDEAD_BEEF);

      pc = psel_cnt;
      dmi_i2c(7'h7F, OP_READ, 32'h0, st, rd);
      check_eq("rd2_st",       st, OP_SUCCESS);
      check_eq("rd2_word",     rd, 32'h0000_0800);
      check_eq("rd2_no_psel",  psel_cnt - pc, 0);

      $display(" ===============================================");
      $display("|  op=0 at 0x7F is an ordinary poll             |");
      $display(" ===============================================");
      dmi_i2c(7'h21, OP_WRITE, 32'h1234_ABCD, st, rd);
      dmi_i2c(7'h21, OP_READ,  32'h0,         st, rd);
      check_eq("seed_rd",      rd, 32'h1234_ABCD);
      pc = psel_cnt;
      dmi_i2c(7'h7F, OP_NOP,   32'h0,         st, rd);
      check_eq("poll_st",      st, OP_SUCCESS);
      check_eq("poll_rd",      rd, 32'h1234_ABCD);     // last completed result, not DTMSTS
      check_eq("poll_no_psel", psel_cnt - pc, 0);

      $display(" ===============================================");
      $display("|  op=3 at 0x7F is an ordinary dmihardreset     |");
      $display(" ===============================================");
      dmi_i2c(7'h7F, OP_HRST, 32'hFFFF_FFFF, st, rd);
      check_eq("hrst_st",      st, OP_SUCCESS);
      check_eq("hrst_rd",      rd, 32'h0);
      check_eq("hrst_sentinel", slave_mem[7'h7F], 32'hDEAD_BEEF);

      // Link healthy afterwards.
      dmi_i2c(7'h22, OP_WRITE, 32'h0F1E_2D3C, st, rd);
      dmi_i2c(7'h22, OP_READ,  32'h0,         st, rd);
      check_eq("after_st",     st, OP_SUCCESS);
      check_eq("after_rd",     rd, 32'h0F1E_2D3C);

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
