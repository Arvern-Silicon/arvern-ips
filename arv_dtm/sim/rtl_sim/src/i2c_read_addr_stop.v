//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    i2c_read_addr_stop
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : i2c_read_addr_stop
// Module Description : A read address byte ACKed and then abandoned (no data byte
//                      clocked), and a START issued around the read-side watchdog
//                      expiry: the target recovers with at most one NACK.
//
//   doc/arv_dtm_i2c.md, Behaviour at a glance: "STOP after the request, before the
//   response is read | ... A later START + {addr, R} with no new request stretches
//   SCL until the watchdog fires and then reads 0xFF bytes." "No SCL edge for
//   2^WD_BITS clk_i during a read (from the read address ACK to the final NACK) or
//   while the target holds SDA or SCL low | Bus released (both lines in the same
//   cycle), interpreter reset, any in-flight DMI transfer abandoned".
//   Parameters: "WD_BITS (I2C_WD_BITS on the wrapper) | 16" -- the bench does not
//   override it, so expiry is 2^16 clk_i after the last SCL edge.
//   Delimiter visibility: "STOP is masked for the whole read phase."
//   START/STOP detection margin: "A START needs >= 3 x T_clk to be decoded: observed
//   one cycle early ... takes a spurious first address bit, and the mismatched
//   address is NACKed."
//   Busy is hidden: "A byte that is ready before the stretch engages goes out at
//   once (the target presents SDA about 5 clk_i after the address ACK's falling
//   edge".
//
//   Leg 1 -- START + {addr, R} with no request pending; the target ACKs and then
//   stretches SCL (no response exists). The host attempts a STOP right away. Per
//   the doc the STOP cannot reach the bus before the watchdog releases SCL: SCL
//   must stay low (target) until 2^16 clk_i after the ACK's falling edge (window
//   65000..66000 clk_i), no DMI transfer happens, and the next START + request is
//   then served normally.
//   Leg 2 -- a READ request, repeated START + {addr, R}, ACK; the response is ready,
//   so the target drives status bit 7 = 0 on SDA. The host releases SCL high and
//   leaves it there; the watchdog releases SDA. A first pass measures that release
//   delay D (and checks it against 2^16 clk_i). Then, per offset in
//   {-5, -2, 0, +1, +3, +20} clk_i, the host pulls SDA low (a START) at
//   (SCL rise + D + offset) and drops SCL T_HIGH (20 clk_i) later -- every SCL
//   fall lands after the expiry, so only the START races it -- then clocks
//   {addr, W} and a write request: the address may be NACKed once (START hidden
//   under the target's own low SDA, or too close to the release); then STOP and
//   one retry, which must be ACKed. The write must land in the subordinate with
//   status 0, and a read-back must return it.
//----------------------------------------------------------------------------

localparam real IA_CLK = 2.0 * FREE_HALF;               // clk_i period (ns)

reg     ia_watch;
integer ia_rise;

initial begin
   ia_watch = 1'b0;
   ia_rise  = 0;
end

always @(posedge dmi_psel) if (ia_watch) ia_rise = ia_rise + 1;

// Request bytes after an ACKed {addr, W}; repeated START; 5-byte read; STOP.
task ia_req_tail;
   input  [ABITS-1:0] addr;
   input  [1:0]       op;
   input  [31:0]      data;
   output [1:0]       status;
   output [31:0]      rdata;
   output             all_ack;
   reg       ack;
   reg [7:0] s, b3, b2, b1, b0;
   begin
      all_ack = 1'b1;
      i2c_write_byte(8'h55, ack);                     all_ack = all_ack & ack;
      i2c_write_byte({{(8-ABITS){1'b0}}, addr}, ack); all_ack = all_ack & ack;
      i2c_write_byte(data[31:24], ack);               all_ack = all_ack & ack;
      i2c_write_byte(data[23:16], ack);               all_ack = all_ack & ack;
      i2c_write_byte(data[15:8],  ack);               all_ack = all_ack & ack;
      i2c_write_byte(data[7:0],   ack);               all_ack = all_ack & ack;
      i2c_write_byte({6'b0, op},  ack);               all_ack = all_ack & ack;
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b1}, ack);          all_ack = all_ack & ack;
      i2c_read_byte(s,  1'b1);
      i2c_read_byte(b3, 1'b1);
      i2c_read_byte(b2, 1'b1);
      i2c_read_byte(b1, 1'b1);
      i2c_read_byte(b0, 1'b0);
      i2c_stop;
      status = s[1:0];
      rdata  = {b3, b2, b1, b0};
   end
endtask

// Leg-2 set-up: READ request, repeated START + {addr, R} ACKed, SDA released by the
// host, then SCL released high and left there. Returns the SCL rise time.
task ia_hold_sda;
   output real t_rise;
   reg ack;
   begin
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b0}, ack);
      i2c_write_byte(8'h55, ack);
      i2c_write_byte(8'h41, ack);
      i2c_write_byte(8'h00, ack);  i2c_write_byte(8'h00, ack);
      i2c_write_byte(8'h00, ack);  i2c_write_byte(8'h00, ack);
      i2c_write_byte({6'b0, OP_READ}, ack);
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b1}, ack);
      check_eq("L2_raddr_ack", ack, 1'b1);
      m_sda_pd = 1'b0;                                    // target owns SDA
      repeat (20) @(posedge free_clk);
      check_eq("L2_sda_held", dut_sda_pd, 1'b1);          // status bit 7 = 0
      check_eq("L2_no_stretch", dut_scl_pd, 1'b0);
      m_scl_pd = 1'b0;                                    // SCL high, then static
      wait (scl === 1'b1);
      t_rise = $realtime;
   end
endtask

initial
   begin : test
      reg [1:0]  st;
      reg [31:0] rd;
      reg        ack;
      reg        aa;
      real       t_ack;
      real       t_rel;
      real       t_rise;
      real       dly;
      real       t_go;
      integer    j;
      integer    off;
      integer    nack;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      slave_latency = 0;
      dmi_i2c(7'h41, OP_WRITE, 32'h4141_0041, st, rd);
      dmi_i2c(7'h41, OP_READ,  32'h0,         st, rd);
      check_eq("seed_rd", rd, 32'h4141_0041);

      $display(" ===============================================");
      $display("|  Leg 1: {addr,R} ACKed, then a STOP attempt   |");
      $display(" ===============================================");
      ia_rise  = 0;
      ia_watch = 1'b1;
      i2c_start;
      i2c_write_byte({I2C_ADDR, 1'b1}, ack);
      t_ack = $realtime - T_LOW;                          // the ACK clock falling edge (i2c_write_byte ends T_LOW after it)
      check_eq("L1_addr_ack", ack, 1'b1);
      repeat (20) @(posedge free_clk);
      check_eq("L1_stretch", dut_scl_pd, 1'b1);
      m_sda_pd = 1'b1;  #(T_SU_STA);                      // STOP attempt: SDA low ...
      m_scl_pd = 1'b0;                                    // ... release SCL (held by target)
      wait (scl === 1'b1);
      t_rel = $realtime;
      dly   = (t_rel - t_ack) / IA_CLK;
      $display("  SCL released %0.1f clk_i after the ACK", dly);
      check_eq("L1_wd_min", (dly >= 65000.0), 1'b1);
      check_eq("L1_wd_max", (dly <= 66000.0), 1'b1);
      #(T_HIGH);
      m_sda_pd = 1'b0;  #(T_HIGH);                        // STOP
      ia_watch = 1'b0;
      check_eq("L1_no_dmi", ia_rise, 0);
      dmi_i2c(7'h42, OP_WRITE, 32'h4242_0042, st, rd);
      check_eq("L1_wr_st", st, OP_SUCCESS);
      dmi_i2c(7'h42, OP_READ, 32'h0, st, rd);
      check_eq("L1_rd_st", st, OP_SUCCESS);
      check_eq("L1_rd",    rd, 32'h4242_0042);

      $display(" ===============================================");
      $display("|  Leg 2: calibrate the SDA-hold watchdog       |");
      $display(" ===============================================");
      ia_hold_sda(t_rise);
      wait (dut_sda_pd === 1'b0);
      t_rel = $realtime;
      dly   = t_rel - t_rise;
      $display("  SDA released %0.1f clk_i after the SCL rise", dly / IA_CLK);
      check_eq("L2_wd_min", ((dly / IA_CLK) >= 65000.0), 1'b1);
      check_eq("L2_wd_max", ((dly / IA_CLK) <= 66000.0), 1'b1);
      check_eq("L2_scl_free", dut_scl_pd, 1'b0);
      #(T_HIGH);
      dmi_i2c(7'h41, OP_READ, 32'h0, st, rd);
      check_eq("L2_cal_rd_st", st, OP_SUCCESS);
      check_eq("L2_cal_rd",    rd, 32'h4141_0041);

      $display(" ===============================================");
      $display("|  Leg 2: START swept around the expiry         |");
      $display(" ===============================================");
      for (j = 0; j < 6; j = j + 1) begin
         off = (j == 0) ?  -5 : (j == 1) ? -2 : (j == 2) ? 0 :
               (j == 3) ?   1 : (j == 4) ?  3 : 20;
         $display("  offset %0d clk_i", off);
         ia_hold_sda(t_rise);
         t_go = t_rise + dly + off * IA_CLK;
         if (t_go > $realtime) #(t_go - $realtime);
         if (off <= -3) check_eq("L2_pre_held", dut_sda_pd, 1'b1);
         if (off >=  3) check_eq("L2_post_free", dut_sda_pd, 1'b0);
         m_sda_pd = 1'b1;  #(T_HIGH);                     // START (SDA low, SCL high)
         m_scl_pd = 1'b1;  #(T_LOW);
         i2c_write_byte({I2C_ADDR, 1'b0}, ack);
         nack = 0;
         if (!ack) begin
            nack = 1;
            i2c_stop;
            i2c_start;
            i2c_write_byte({I2C_ADDR, 1'b0}, ack);
            check_eq("L2_retry_ack", ack, 1'b1);
         end
         $display("  NACKs before the round trip: %0d", nack);
         ia_req_tail(7'h50 + j, OP_WRITE, 32'h5A5A_0050 + j, st, rd, aa);
         check_eq("L2_req_acks", aa, 1'b1);
         check_eq("L2_wr_st", st, OP_SUCCESS);
         repeat (20) @(posedge free_clk);
         check_eq("L2_mem", slave_mem[7'h50 + j], 32'h5A5A_0050 + j);
         dmi_i2c(7'h50 + j, OP_READ, 32'h0, st, rd);
         check_eq("L2_rd_st", st, OP_SUCCESS);
         check_eq("L2_rd",    rd, 32'h5A5A_0050 + j);
      end

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
