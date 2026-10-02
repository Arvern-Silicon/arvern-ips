//----------------------------------------------------------------------------
// File Name          : i2c_ack_wedge
// Module Description : A master that stops clocking mid-ACK must not wedge the bus.
//
//   ST_ADDR_ACK / ST_WRITE_ACK assert sda_pd on one scl_fall and release it on the
//   NEXT scl_fall. If the master stops clocking in between -- host killed, adapter
//   unplugged, SCL left high -- sda_pd is held and SDA stays low indefinitely. The PHY
//   then prevents its own escape: start_cond needs an SDA fall (already low) and
//   stop_cond needs an SDA rise, which the pull-down blocks. A spec-conforming new
//   master waiting for bus-free never sees it.
//
//   The read-side watchdog did NOT cover this: it armed on the read phase only, and
//   both ACK states sit outside that. It now arms wherever the TARGET holds a line
//   down, so the counter accumulates once the master stops toggling SCL.
//
//   Discriminator: probe sda_pd after the watchdog period. With the old
//   `wd_active = read_phase` the pull-down is still asserted and wd_cnt never left 0.
//----------------------------------------------------------------------------

initial
   begin : test
      reg ack;
      integer k;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      slave_latency = 2;

      $display(" ===============================================");
      $display("|  Master stops clocking during the ADDR ACK   |");
      $display(" ===============================================");

      // Address the target, but STOP INSIDE THE ACK BIT -- i2c_write_byte cannot be
      // used, because it completes the 9th clock and the target releases its ACK on
      // that falling edge. Drive the 8 address bits by hand, raise SCL for the ACK,
      // and then simply stop: SCL stays high, the target's sda_pd stays asserted.
      i2c_start;
      begin : addr_no_ack_clock
         reg [7:0] b;
         integer   i;
         b = {I2C_ADDR, 1'b0};
         for (i = 7; i >= 0; i = i - 1) begin
            m_sda_pd = ~b[i];
            #(T_SU);
            scl_release_high;
            scl_drive_low;
         end
         m_sda_pd = 1'b0;                  // release SDA so the target can ACK
         #(T_SU);
         scl_release_high;                 // 9th clock rises -- target pulls SDA low
      end
      check_eq("target_acked", {31'd0, dut_sda_pd}, 32'd1);   // wedge condition set up

      // Master now stops clocking entirely: SCL left HIGH, SDA held low by the target.
      // Wait out the watchdog (2^16 clk_i) with margin.
      for (k = 0; k < 80000; k = k + 1) @(posedge free_clk);

      // The target must have released the bus by itself.
      check_eq("sda_released", {31'd0, dut_sda_pd}, 32'd0);
      check_eq("scl_released", {31'd0, dut_scl_pd}, 32'd0);

      // ...and the link must still work afterwards.
      i2c_stop;
      begin : recheck
         reg [31:0] rd; reg [1:0] st;
         dmi_i2c(7'h10, OP_WRITE, 32'hA5A5_1234, st, rd);
         dmi_i2c(7'h10, OP_READ,  32'h0,         st, rd);
         check_eq("recovered_rdata", rd, 32'hA5A5_1234);
      end

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
