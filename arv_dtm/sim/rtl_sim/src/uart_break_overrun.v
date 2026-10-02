//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_break_overrun
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_break_overrun
// Module Description : rx_overrun stickiness across a break/abort resync.
//
//   rx_overrun records that the host outran the RX FIFO -- the host must be able to
//   discover WHY it lost sync AFTER recovering. So a break (which flushes the FIFO's
//   queued bytes and re-arms the link) must NOT clear rx_overrun; only the DTMSTS
//   write-1-to-clear may. This test causes an overrun, does a break + auto-baud
//   resync, and requires DTMSTS to STILL read overrun=1 -- while a normal transaction
//   after the break proves the framing/FIFO flushed clean. Then W1C clears it to 0.
//----------------------------------------------------------------------------

//=============================================================================
// Send a request frame WITHOUT popping its response (dmi_uart's request half).
//=============================================================================
task uart_send_req;
    input [ABITS-1:0] addr;
    input [1:0]       op;
    input [31:0]      data;
    begin
        uart_send_byte(8'h55);                          // SYNC
        uart_send_byte({{(8-ABITS){1'b0}}, addr});
        uart_send_byte(data[31:24]);
        uart_send_byte(data[23:16]);
        uart_send_byte(data[15:8]);
        uart_send_byte(data[7:0]);
        uart_send_byte({6'b0, op});
    end
endtask

task uart_pop_resp;
    output [1:0]  status;
    output [31:0] rdata;
    reg [7:0] s, b3, b2, b1, b0;
    begin
        fifo_pop(s);
        fifo_pop(b3);
        fifo_pop(b2);
        fifo_pop(b1);
        fifo_pop(b0);
        status = s[1:0];
        rdata  = {b3, b2, b1, b0};
    end
endtask

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;
      integer    k;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      uart_autobaud_sync();                             // open the link: measure baud + eat echo

      slave_latency = 0;                                // = arvern Debug Module timing

      // Seed a persistent DM value (must survive the break) and the stalled-read addr.
      dmi_uart(7'h14, OP_WRITE, 32'hCAFE_F00D, st, rd);
      dmi_uart(7'h10, OP_WRITE, 32'hC0DE_1234, st, rd);

      $display(" =====================================================");
      $display("|  Cause an RX-FIFO overrun (flood > depth stalled)   |");
      $display(" =====================================================");

      slave_hold = 1'b1;
      uart_send_req(7'h10, OP_READ, 32'h0);             // launches the DMI read, then stalls
      #(3.0 * host_bit_ns);
      for (k = 0; k < 48; k = k + 1)                    // 48 > built depth 32 -> overrun
         uart_send_byte(8'h00);
      slave_hold = 1'b0;                                // release; in-flight op completes
      uart_pop_resp(st, rd);                            // pop the stalled READ's reply first
      check_eq("stalled_rd", rd, 32'hC0DE_1234);
      repeat (200) @(posedge free_clk);                 // let the FIFO drain the 0x00 flood

      $display(" =====================================================");
      $display("|  Break + resync: rx_overrun must SURVIVE the flush  |");
      $display(" =====================================================");

      uart_break();                                     // long low -> unlock + flush queued FIFO bytes
      uart_autobaud_sync();                             // 0x80 -> re-lock + echo

      // The break flushed the FIFO/interpreter, but the sticky overrun must remain.
      dmi_uart(7'h7F, OP_READ, 32'h0, st, rd);
      check_eq("ovr_rd_st",   st,    OP_SUCCESS);
      check_eq("survived",    rd[0], 1'b1);             // overrun survived the break
      check_eq("depth_ok",    rd[15:8], 8'd32);

      // Framing is clean after the break: a full transaction round-trips, and the
      // pre-break DM state is intact.
      dmi_uart(7'h28, OP_WRITE, 32'h5A5A_A5A5, st, rd);
      dmi_uart(7'h28, OP_READ,  32'h0,         st, rd);
      check_eq("post_break_rd", rd, 32'h5A5A_A5A5);
      dmi_uart(7'h14, OP_READ,  32'h0,         st, rd);
      check_eq("dm_persist",    rd, 32'hCAFE_F00D);

      $display(" =====================================================");
      $display("|  W1C clears the sticky overrun -> reads back 0      |");
      $display(" =====================================================");

      dmi_uart(7'h7F, OP_WRITE, 32'h0000_0001, st, rd);
      check_eq("w1c_st", st, OP_SUCCESS);
      dmi_uart(7'h7F, OP_READ, 32'h0, st, rd);
      check_eq("cleared_st", st,    OP_SUCCESS);
      check_eq("cleared",    rd[0], 1'b0);

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
