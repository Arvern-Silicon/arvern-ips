//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_overrun_misframe
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_overrun_misframe
// Module Description : An RX FIFO overrun must not let later bytes complete the
//                      truncated frame into a DMI operation nobody sent.
//
//   The DMI slave is held so the command layer blocks on frame 1; frames 2-6
//   (35 bytes) overflow the 32-byte FIFO part-way through frame 6. After the
//   release, frame 7 is sent; without a resync on the overrun its first bytes
//   complete frame 6, whose op slot then holds frame 7's d31:24 (0x02, a write).
//   Every DMI write that reaches the APB must be one the host sent, with the
//   data the host sent for that address; frames lost to the overrun are fine.
//----------------------------------------------------------------------------
reg [31:0] sent_data [0:127];
reg        sent_ok   [0:127];
integer    bad_ops;
integer    i;

initial begin
   bad_ops = 0;
   for (i = 0; i < 128; i = i + 1) sent_ok[i] = 1'b0;
end

always @(posedge free_clk)
   if (dmi_psel & dmi_penable & dmi_pready & dmi_pwrite) begin
      if (!sent_ok[dmi_paddr[ABITS+1:2]] || (dmi_pwdata !== sent_data[dmi_paddr[ABITS+1:2]])) begin
         $display("ERROR: DMI write nobody sent: addr 0x%h data 0x%h  %0t ns", dmi_paddr[ABITS+1:2], dmi_pwdata, $time);
         bad_ops = bad_ops + 1;
      end
   end

task send_frame;
   input [ABITS-1:0] addr;
   input [31:0]      data;
   begin
      sent_ok[addr]   = 1'b1;
      sent_data[addr] = data;
      uart_send_byte(8'h55);
      uart_send_byte({{(8-ABITS){1'b0}}, addr});
      uart_send_byte(data[31:24]);
      uart_send_byte(data[23:16]);
      uart_send_byte(data[15:8]);
      uart_send_byte(data[7:0]);
      uart_send_byte({6'b0, OP_WRITE});
   end
endtask

initial
   begin : test
      reg [1:0] st;
      reg [31:0] rd;
      dtm_init;
      $display(" ===============================================");
      $display("|  RX FIFO overrun mid-frame, then a new frame  |");
      $display(" ===============================================");
      slave_hold = 1'b1;
      send_frame(7'h31, 32'h3131_0001);                  // blocks the command layer
      send_frame(7'h32, 32'h3232_0002);
      send_frame(7'h33, 32'h3333_0003);
      send_frame(7'h34, 32'h3434_0004);
      send_frame(7'h35, 32'h3535_0005);
      send_frame(7'h36, 32'h3636_0006);                  // truncated by the overrun
      repeat (50) @(posedge free_clk);
      slave_hold = 1'b0;
      repeat (60000) @(posedge free_clk);                 // frames 2-5 execute and answer
      send_frame(7'h37, 32'h0237_0007);                  // d31:24 = 0x02 = write in op slot
      repeat (60000) @(posedge free_clk);
      check_eq("no_unsent_dmi_write", bad_ops, 0);
      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
