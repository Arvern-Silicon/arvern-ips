//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    i2c_stretch_later_byte
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : i2c_stretch_later_byte
// Module Description : Stretching and pauses beyond the first response byte, and
//                      the bus watchdog firing while the target holds SCL or SDA
//                      around the response hand-off.
//
//   doc/arv_dtm_i2c.md:
//   - Behaviour at a glance: "SCL is held low until the response is ready (busy
//     hidden), then [status][d31:24][d23:16][d15:8][d7:0] is clocked out".
//   - Busy is hidden: "While the DMI op is in flight the target holds SCL low
//     (scl_pd_o) at the first byte of the read".
//   - Timing: "From the ACK of the read address byte to the NACK of the last
//     response byte the master must therefore never leave SCL static (high or
//     low) for longer than 2^WD_BITS / f_clk [...] or the target releases both
//     lines mid-read and the remaining bytes read 0xFF."
//   - Busy is hidden: "the DMI access must complete within about 2^WD_BITS clk_i
//     of the address byte's ACK, or the bus is released and the host reads 0xFF."
//   - Behaviour at a glance: "No SCL edge for 2^WD_BITS clk_i while the target
//     holds SDA or SCL low | Bus released (both lines in the same cycle),
//     interpreter reset, any in-flight DMI transfer abandoned."
//   - Host protocol contract: "re-issue the request (a 0 poll retrieves a
//     completed result)."
//   doc/arv_dtm.md: dmihardreset "drops psel/penable mid-ACCESS".
//
//   The doc defines a target stretch only at the FIRST response byte: the whole
//   response exists once the DMI op completes, so raising slave_hold after byte 1
//   cannot delay bytes 2..5. The test pins exactly that:
//   Part 1a: slave held -> byte 1 is stretched (observed); slave_hold is raised
//            again after byte 1 -> bytes 2..5 are NOT stretched, the byte
//            sequence is intact, and only one APB transfer occurred.
//   Part 1b: master-side pauses below the watchdog bound (150 us SCL low after an
//            ACK, 100 us SCL high inside a bit, 150 us SCL low mid-byte): the byte
//            sequence is intact (a watchdog would have turned it into 0xFF).
//   Part 2 : slave held past the watchdog while the target stretches SCL at byte
//            1: SCL is released 2^16 clk_i (the bench does not override
//            I2C_WD_BITS, default 16) after the last SCL edge, SDA is released by
//            the same clk_i edge, dmi_psel drops (transfer abandoned), and the five
//            bytes read 0xFF (status 3). The slave is then aborted (slave_abort)
//            so its orphan PREADY cannot complete a later transfer.
//   Part 3 : hand-off with SDA held: the response becomes ready while the master
//            itself keeps SCL low after the address ACK. The target presents the
//            status MSB (0) on SDA and releases its own SCL hold; the master never
//            clocks, so after 2^16 clk_i the watchdog releases SDA; the five bytes
//            then read 0xFF, and a poll retrieves the completed read's result.
//   Each part ends with a normal transaction that round-trips.
//   All response reads use a local bit-level reader that keeps the bench's
//   "SDA changed as SCL rose" check (disabled only on the byte whose SCL release
//   is the watchdog's, where the doc requires both lines to move together).
//----------------------------------------------------------------------------

localparam integer WD_CLKS = 65536;      // 2^I2C_WD_BITS, wrapper default 16 (not overridden by the bench)
localparam integer CLK_NS  = 10;         // 100 MHz clk_i

integer psel_cnt;
initial psel_cnt = 0;
always @(posedge dmi_psel) psel_cnt = psel_cnt + 1;

time t_scl_fall;
initial t_scl_fall = 0;
always @(negedge scl) t_scl_fall = $time;

task sl_send_req;                        // START, {addr,W}, 7-byte request
   input [6:0]  addr;
   input [1:0]  op;
   input [31:0] data;
   reg          ack;
   begin
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b0}, ack);
      i2c_write_byte(8'h55, ack);
      i2c_write_byte({1'b0, addr}, ack);
      i2c_write_byte(data[31:24], ack);  i2c_write_byte(data[23:16], ack);
      i2c_write_byte(data[15:8],  ack);  i2c_write_byte(data[7:0],   ack);
      i2c_write_byte({6'b0, op},  ack);
   end
endtask

task sl_addr_read;                       // repeated START, {addr,R}
   reg ack;
   begin
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b1}, ack);
      check_eq("addr_r_acked", ack, 1'b1);
   end
endtask

// Bit-level response read. pause_bit >= 0 inserts pause_ns in that bit: with SCL
// high before sampling (pause_high = 1) or with SCL low after the bit (0).
// stretched = 1 if SCL rose more than 1.5 clk_i after the master released it.
task sl_read_byte;
   output [7:0]  b;
   input         ack;
   input integer pause_bit;
   input         pause_high;
   input integer pause_ns;
   input         chk_race;
   output        stretched;
   integer       i;
   time          t_rel;
   begin
      stretched = 1'b0;
      m_sda_pd  = 1'b0;
      for (i = 7; i >= 0; i = i - 1) begin
         m_scl_pd = 1'b0;
         t_rel    = $time;
         wait (scl === 1'b1);
         if (($time - t_rel) > 15) stretched = 1'b1;
         if (chk_race && ($time == sda_last_t)) begin
            $display("ERROR: I2C SDA changed as SCL rose (bit %0d)  %0t ns", i, $time);
            error = error + 1;
         end
         if ((i == pause_bit) && pause_high) #(pause_ns);
         #(T_HIGH);
         b[i] = sda;
         scl_drive_low;
         if ((i == pause_bit) && !pause_high) #(pause_ns);
      end
      m_sda_pd = ack ? 1'b1 : 1'b0;
      #(T_SU);
      scl_release_high;
      scl_drive_low;
      m_sda_pd = 1'b0;
   end
endtask

task sl_check_wd_time;
   input [127:0] name;
   input time    t_rel;
   input time    t_edge;                       // last SCL edge before the watchdog
   time          dt;
   begin
      dt = t_rel - t_edge;
      $display("INFO:  %0s watchdog release %0d ns after the last SCL edge (%0d clk)", name, dt, dt / CLK_NS);
      if ((dt < (WD_CLKS - 16) * CLK_NS) || (dt > (WD_CLKS + 128) * CLK_NS)) begin
         $display("ERROR: %0s watchdog release outside [2^16-16, 2^16+128] clk  %0t ns", name, $time);
         error = error + 1;
      end
   end
endtask

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;
      reg [7:0]  s, b3, b2, b1, b0;
      reg        str0, str1, str2, str3, str4;
      integer    pc;
      time       t_rel;
      time       t_sfall;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      slave_latency = 0;

      // Alternating MSBs byte to byte, so every hand-off moves SDA.
      dmi_i2c(7'h16, OP_WRITE, 32'h00FF_7F80, st, rd);
      dmi_i2c(7'h18, OP_WRITE, 32'h0123_4567, st, rd);

      $display(" ===============================================");
      $display("|  1a: stretch on byte 1, hold raised after it  |");
      $display(" ===============================================");
      pc = psel_cnt;
      slave_hold = 1'b1;
      sl_send_req(7'h16, OP_READ, 32'h0);
      sl_addr_read;
      fork
         begin #20000 slave_hold = 1'b0; end
         sl_read_byte(s, 1'b1, -1, 1'b0, 0, 1'b1, str0);
      join
      slave_hold = 1'b1;                                     // no op in flight: no effect
      sl_read_byte(b3, 1'b1, -1, 1'b0, 0, 1'b1, str1);
      sl_read_byte(b2, 1'b1, -1, 1'b0, 0, 1'b1, str2);
      sl_read_byte(b1, 1'b1, -1, 1'b0, 0, 1'b1, str3);
      sl_read_byte(b0, 1'b0, -1, 1'b0, 0, 1'b1, str4);
      i2c_stop;
      slave_hold = 1'b0;
      check_eq("1a_byte1_stretch", str0, 1'b1);
      check_eq("1a_later_stretch", {str1, str2, str3, str4}, 4'b0000);
      check_eq("1a_status",   s, 8'h00);
      check_eq("1a_data",     {b3, b2, b1, b0}, 32'h00FF_7F80);
      check_eq("1a_one_apb",  psel_cnt - pc, 1);

      dmi_i2c(7'h16, OP_READ, 32'h0, st, rd);
      check_eq("1a_after_st", st, OP_SUCCESS);
      check_eq("1a_after_rd", rd, 32'h00FF_7F80);

      $display(" ===============================================");
      $display("|  1b: master pauses below the watchdog bound   |");
      $display(" ===============================================");
      sl_send_req(7'h16, OP_READ, 32'h0);
      sl_addr_read;
      sl_read_byte(s,  1'b1, -1, 1'b0, 0,      1'b1, str0);
      #150000;                                               // SCL low after byte 1's ACK
      sl_read_byte(b3, 1'b1,  2, 1'b1, 100000, 1'b1, str1);  // SCL high 100 us in bit 2
      sl_read_byte(b2, 1'b1,  4, 1'b0, 150000, 1'b1, str2);  // SCL low 150 us after bit 4
      sl_read_byte(b1, 1'b1, -1, 1'b0, 0,      1'b1, str3);
      sl_read_byte(b0, 1'b0, -1, 1'b0, 0,      1'b1, str4);
      i2c_stop;
      check_eq("1b_status",   s, 8'h00);
      check_eq("1b_data",     {b3, b2, b1, b0}, 32'h00FF_7F80);
      check_eq("1b_no_stretch", {str1, str2, str3, str4}, 4'b0000);

      $display(" ===============================================");
      $display("|  2: watchdog while the target stretches SCL   |");
      $display(" ===============================================");
      slave_hold = 1'b1;
      sl_send_req(7'h16, OP_READ, 32'h0);
      sl_addr_read;
      check_eq("2_stretching", dut_scl_pd, 1'b1);            // SCL held: response not ready
      t_sfall = t_scl_fall;
      fork
         sl_read_byte(s, 1'b1, -1, 1'b0, 0, 1'b0, str0);     // SCL release is the watchdog's
         begin
            @(negedge dut_scl_pd);
            t_rel = $time;
            check_eq("2_no_scl_edge", t_scl_fall, t_sfall);  // nothing but the target moved SCL
            @(negedge free_clk);
            check_eq("2_sda_released", dut_sda_pd, 1'b0);    // both lines, same cycle
            repeat (20) @(posedge free_clk);
            check_eq("2_psel_dropped", dmi_psel, 1'b0);      // in-flight transfer abandoned
         end
      join
      sl_check_wd_time("part2", t_rel, t_sfall);
      sl_read_byte(b3, 1'b1, -1, 1'b0, 0, 1'b1, str1);
      sl_read_byte(b2, 1'b1, -1, 1'b0, 0, 1'b1, str2);
      sl_read_byte(b1, 1'b1, -1, 1'b0, 0, 1'b1, str3);
      sl_read_byte(b0, 1'b0, -1, 1'b0, 0, 1'b1, str4);
      i2c_stop;
      check_eq("2_status_ff", s, 8'hFF);
      check_eq("2_data_ff",   {b3, b2, b1, b0}, 32'hFFFF_FFFF);

      slave_abort = 1'b1;                                    // drop the orphan transfer
      repeat (3) @(posedge free_clk);
      slave_abort = 1'b0;
      slave_hold  = 1'b0;
      repeat (10) @(posedge free_clk);

      dmi_i2c(7'h17, OP_WRITE, 32'h1717_A0A0, st, rd);
      check_eq("2_rec_wr_st", st, OP_SUCCESS);
      dmi_i2c(7'h17, OP_READ,  32'h0,         st, rd);
      check_eq("2_rec_rd_st", st, OP_SUCCESS);
      check_eq("2_rec_rd",    rd, 32'h1717_A0A0);

      $display(" ===============================================");
      $display("|  3: watchdog while the target holds SDA       |");
      $display(" ===============================================");
      slave_hold = 1'b1;
      sl_send_req(7'h18, OP_READ, 32'h0);
      sl_addr_read;                                          // master keeps SCL low from here
      t_sfall = t_scl_fall;
      #5000;
      slave_hold = 1'b0;                                     // response becomes ready
      #2000;
      check_eq("3_sda_msb_low", dut_sda_pd, 1'b1);           // status MSB 0 presented
      check_eq("3_scl_let_go",  dut_scl_pd, 1'b0);           // target's stretch released
      @(negedge dut_sda_pd);
      t_rel = $time;
      check_eq("3_no_scl_edge", t_scl_fall, t_sfall);
      sl_check_wd_time("part3", t_rel, t_sfall);
      check_eq("3_scl_pd_off",  dut_scl_pd, 1'b0);
      #(T_SU);                                               // data setup before the first clock
      sl_read_byte(s,  1'b1, -1, 1'b0, 0, 1'b1, str0);
      sl_read_byte(b3, 1'b1, -1, 1'b0, 0, 1'b1, str1);
      sl_read_byte(b2, 1'b1, -1, 1'b0, 0, 1'b1, str2);
      sl_read_byte(b1, 1'b1, -1, 1'b0, 0, 1'b1, str3);
      sl_read_byte(b0, 1'b0, -1, 1'b0, 0, 1'b1, str4);
      i2c_stop;
      check_eq("3_status_ff", s, 8'hFF);
      check_eq("3_data_ff",   {b3, b2, b1, b0}, 32'hFFFF_FFFF);

      // The read completed before the watchdog: a poll retrieves it.
      pc = psel_cnt;
      dmi_i2c(7'h00, OP_NOP, 32'h0, st, rd);
      check_eq("3_poll_st",   st, OP_SUCCESS);
      check_eq("3_poll_rd",   rd, 32'h0123_4567);
      check_eq("3_poll_noapb", psel_cnt - pc, 0);

      dmi_i2c(7'h17, OP_WRITE, 32'h5A5A_1717, st, rd);
      dmi_i2c(7'h17, OP_READ,  32'h0,         st, rd);
      check_eq("3_rec_rd_st", st, OP_SUCCESS);
      check_eq("3_rec_rd",    rd, 32'h5A5A_1717);

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
