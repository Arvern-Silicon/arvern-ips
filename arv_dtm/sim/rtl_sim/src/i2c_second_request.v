//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    i2c_second_request
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : i2c_second_request
// Module Description : A second request written while the first op is held, and
//                      an RX-FIFO overrun on I2C.
//
//   doc/arv_dtm_i2c.md, DMI transaction: "One request per transaction, one
//   response per request. A second request written before the first's response
//   has been read is lost at the repeated START (which flushes the RX FIFO), and
//   the read returns the first response. The write phase always ACKs and never
//   stretches; the 8-byte RX FIFO holds one whole request".
//   Behaviour at a glance: "A second request before the first's response has
//   been read | Lost at the repeated START; the read returns the first response."
//   DTMSTS: "On I2C the flag can only be set by a host that writes past the
//   8-byte FIFO without reading a response [...] and it survives every resync
//   until the host clears it." / "a write (op = 2) with data bit 0 = 1 clears the
//   sticky rx_overrun (write-1-to-clear) and returns the status word as read
//   before the clear".
//   doc/arv_dtm_uart.md, DTMSTS table: "Bit 0 = 0 is a no-op."
//
//   Every leg holds the DMI slave (slave_hold) so the first op stays in flight,
//   and releases it only while the target is stretching the response read.
//   Throughout every write phase, each request byte must be ACKed and SCL must
//   never be held by the target after the master releases it (monitor below).
//
//   Part A1: req1 (read 0x11) and a whole req2 (write 0x12) in ONE write phase,
//            then Sr + {addr,R}: the read returns req1's result, req2 never
//            reaches the APB bus (one APB transfer in total, slave_mem[0x12]
//            unchanged), DTMSTS.rx_overrun stays 0 (7 queued bytes fit).
//   Part A2: same, with req2 sent after Sr + {addr,W}: same outcome.
//   Part B1: req1 + 8 bytes of 0x00 queued (exactly the FIFO size): no overrun.
//            (Boundary derived from "8-byte FIFO" / "writes past".)
//   Part B2: req1 + 9 bytes of 0x00 queued (one past the FIFO): DTMSTS reads
//            0x801; the flag survives a normal transaction, a STOP-truncated
//            request and a NACK-abandoned response; a write with bit 0 = 0 is a
//            no-op returning 0x801; a W1C returns 0x801 and then reads 0x800.
//            The held op's response after the overrun is still req1's result:
//            this is a CROSS-DOC INFERENCE from arv_dtm_uart.md ("An op already
//            in execution completes normally"); the I2C page does not say it.
//   0x00 is used as filler (not 0x55), so no spurious frame is parsed.
//----------------------------------------------------------------------------

integer psel_cnt;
initial psel_cnt = 0;
always @(posedge dmi_psel) psel_cnt = psel_cnt + 1;

// Write-phase stretch monitor: 1.5 clk_i after the master releases SCL, SCL must
// be high (the target never stretches during the write phase).
reg     wr_mon;
integer wr_stretch;
initial begin wr_mon = 1'b0; wr_stretch = 0; end
always @(negedge m_scl_pd) begin
   #15;
   if (wr_mon && (m_scl_pd === 1'b0) && (scl === 1'b0)) begin
      wr_stretch = wr_stretch + 1;
      $display("ERROR: target stretched SCL in the write phase  %0t ns", $time);
      error = error + 1;
   end
end

reg sq_all_ack;

task sq_wbyte;
   input [7:0] b;
   reg         ack;
   begin
      i2c_write_byte(b, ack);
      sq_all_ack = sq_all_ack & ack;
   end
endtask

task sq_req_bytes;                        // the 7 request bytes, no START
   input [6:0]  addr;
   input [1:0]  op;
   input [31:0] data;
   begin
      sq_wbyte(8'h55);
      sq_wbyte({1'b0, addr});
      sq_wbyte(data[31:24]);
      sq_wbyte(data[23:16]);
      sq_wbyte(data[15:8]);
      sq_wbyte(data[7:0]);
      sq_wbyte({6'b0, op});
   end
endtask

task sq_first_req;                        // hold the slave, START, {addr,W}, req1 (read 0x11)
   begin
      slave_hold = 1'b1;
      sq_all_ack = 1'b1;
      wr_mon     = 1'b1;
      i2c_start;
      sq_wbyte({I2C_ADDR, 1'b0});
      sq_req_bytes(7'h11, OP_READ, 32'h0);
      repeat (40) @(posedge free_clk);
      check_eq("req1_on_bus", dmi_psel, 1'b1);       // launched and held
   end
endtask

task sq_read_held;                        // Sr, {addr,R}, release during the stretch, read 5, STOP
   output [1:0]  status;
   output [31:0] rdata;
   reg   [7:0]   s, b3, b2, b1, b0;
   time          t0, t1;
   begin
      i2c_start;                                     // repeated START
      sq_wbyte({I2C_ADDR, 1'b1});
      wr_mon = 1'b0;
      check_eq("wr_all_acked", sq_all_ack, 1'b1);
      check_eq("still_held", dmi_psel, 1'b1);
      check_eq("rd_stretching", dut_scl_pd, 1'b1);     // response not ready: SCL held
      t0 = $time;
      fork
         begin
            #20000;
            slave_hold = 1'b0;
         end
         begin
            i2c_read_byte(s, 1'b1);
            t1 = $time;
         end
      join
      check_eq("rd_was_stretched", (t1 - t0) >= 20000, 1'b1);
      i2c_read_byte(b3, 1'b1);
      i2c_read_byte(b2, 1'b1);
      i2c_read_byte(b1, 1'b1);
      i2c_read_byte(b0, 1'b0);
      i2c_stop;
      status = s[1:0];
      rdata  = {b3, b2, b1, b0};
      check_eq("status_hi_zero", s[7:2], 6'd0);
      repeat (100) @(posedge free_clk);
   end
endtask

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;
      reg        ack;
      reg [7:0]  b;
      integer    pc;
      integer    k;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      slave_latency = 0;

      dmi_i2c(7'h11, OP_WRITE, 32'h1111_AAAA, st, rd);   // req1's read value
      dmi_i2c(7'h12, OP_WRITE, 32'h2222_BBBB, st, rd);   // req2 target, must stay intact

      $display(" ===============================================");
      $display("|  A1: second request in the same write phase   |");
      $display(" ===============================================");
      pc = psel_cnt;
      sq_first_req;
      sq_req_bytes(7'h12, OP_WRITE, 32'h5A5A_0012);      // whole req2, queued
      sq_read_held(st, rd);
      check_eq("a1_st",        st, OP_SUCCESS);
      check_eq("a1_rd_first",  rd, 32'h1111_AAAA);       // the FIRST response
      check_eq("a1_one_apb",   psel_cnt - pc, 1);         // req2 never executed
      check_eq("a1_req2_lost", slave_mem[7'h12], 32'h2222_BBBB);
      dmi_i2c(7'h7F, OP_READ, 32'h0, st, rd);
      check_eq("a1_dtmsts",    rd, 32'h0000_0800);       // 7 queued bytes: no overrun

      $display(" ===============================================");
      $display("|  A2: second request after Sr + {addr,W}      |");
      $display(" ===============================================");
      pc = psel_cnt;
      sq_first_req;
      i2c_start;                                         // repeated START
      sq_wbyte({I2C_ADDR, 1'b0});
      sq_req_bytes(7'h12, OP_WRITE, 32'h5A5A_0012);
      sq_read_held(st, rd);
      check_eq("a2_st",        st, OP_SUCCESS);
      check_eq("a2_rd_first",  rd, 32'h1111_AAAA);
      check_eq("a2_one_apb",   psel_cnt - pc, 1);
      check_eq("a2_req2_lost", slave_mem[7'h12], 32'h2222_BBBB);
      dmi_i2c(7'h7F, OP_READ, 32'h0, st, rd);
      check_eq("a2_dtmsts",    rd, 32'h0000_0800);

      $display(" ===============================================");
      $display("|  B1: 8 bytes queued behind the held op        |");
      $display(" ===============================================");
      pc = psel_cnt;
      sq_first_req;
      for (k = 0; k < 8; k = k + 1) sq_wbyte(8'h00);
      sq_read_held(st, rd);
      check_eq("b1_st",        st, OP_SUCCESS);
      check_eq("b1_rd_first",  rd, 32'h1111_AAAA);
      check_eq("b1_one_apb",   psel_cnt - pc, 1);
      dmi_i2c(7'h7F, OP_READ, 32'h0, st, rd);
      check_eq("b1_dtmsts_st", st, OP_SUCCESS);
      check_eq("b1_no_overrun", rd, 32'h0000_0800);

      // Independent of B1: clear the flag whatever B1 did, and confirm it is 0.
      dmi_i2c(7'h7F, OP_WRITE, 32'h0000_0001, st, rd);
      dmi_i2c(7'h7F, OP_READ,  32'h0,         st, rd);
      check_eq("b2_pre_clear", rd, 32'h0000_0800);

      $display(" ===============================================");
      $display("|  B2: 9 bytes queued -> rx_overrun             |");
      $display(" ===============================================");
      pc = psel_cnt;
      sq_first_req;
      for (k = 0; k < 9; k = k + 1) sq_wbyte(8'h00);
      sq_read_held(st, rd);
      check_eq("b2_st",        st, OP_SUCCESS);          // cross-doc inference (UART page)
      check_eq("b2_rd_first",  rd, 32'h1111_AAAA);
      check_eq("b2_one_apb",   psel_cnt - pc, 1);
      dmi_i2c(7'h7F, OP_READ, 32'h0, st, rd);
      check_eq("b2_dtmsts_st", st, OP_SUCCESS);
      check_eq("b2_overrun",   rd, 32'h0000_0801);

      // Survives a normal transaction ...
      dmi_i2c(7'h15, OP_WRITE, 32'h1515_1515, st, rd);
      dmi_i2c(7'h15, OP_READ,  32'h0,         st, rd);
      check_eq("b2_norm_rd",   rd, 32'h1515_1515);
      // ... a request truncated by STOP (resync) ...
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b0}, ack);
      i2c_write_byte(8'h55, ack);
      i2c_write_byte({1'b0, 7'h15}, ack);
      i2c_write_byte(8'hAA, ack);
      i2c_stop;
      // ... and a response abandoned by NACK + STOP (resync).
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b0}, ack);
      i2c_write_byte(8'h55, ack);
      i2c_write_byte({1'b0, 7'h15}, ack);
      i2c_write_byte(8'h00, ack);  i2c_write_byte(8'h00, ack);
      i2c_write_byte(8'h00, ack);  i2c_write_byte(8'h00, ack);
      i2c_write_byte({6'b0, OP_READ}, ack);
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b1}, ack);
      i2c_read_byte(b, 1'b1);
      i2c_read_byte(b, 1'b0);
      i2c_stop;
      dmi_i2c(7'h7F, OP_READ, 32'h0, st, rd);
      check_eq("b2_survives",  rd, 32'h0000_0801);

      // Bit 0 = 0: no-op, returns the current word.
      dmi_i2c(7'h7F, OP_WRITE, 32'h0000_0000, st, rd);
      check_eq("b2_w0_st",     st, OP_SUCCESS);
      check_eq("b2_w0_ret",    rd, 32'h0000_0801);
      dmi_i2c(7'h7F, OP_READ,  32'h0,         st, rd);
      check_eq("b2_w0_kept",   rd, 32'h0000_0801);

      // W1C: returns the word before the clear, then reads clear.
      dmi_i2c(7'h7F, OP_WRITE, 32'h0000_0001, st, rd);
      check_eq("b2_w1c_st",    st, OP_SUCCESS);
      check_eq("b2_w1c_ret",   rd, 32'h0000_0801);
      dmi_i2c(7'h7F, OP_READ,  32'h0,         st, rd);
      check_eq("b2_cleared",   rd, 32'h0000_0800);

      // Link healthy; req2 of A1/A2 never landed.
      dmi_i2c(7'h12, OP_READ, 32'h0, st, rd);
      check_eq("final_st",     st, OP_SUCCESS);
      check_eq("final_rd12",   rd, 32'h2222_BBBB);

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
