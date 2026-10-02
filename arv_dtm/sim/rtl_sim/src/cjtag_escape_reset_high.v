//----------------------------------------------------------------------------
// File Name          : cjtag_escape_reset_high
// Module Description : First escape after a dbgresetn_i release with TCKC and TMSC
//                      both parked HIGH is classified by its own change count.
//
//   IEEE 1149.7 Tbl 10-9: 6-7 TMSC changes while TCKC is high are a selection
//   escape, 4-5 a deselection. The release must not count as a change: a 7-change
//   selection escape then arms activation (link online after the code), and a
//   5-change deselection escape does not (the code that follows is ignored).
//----------------------------------------------------------------------------

task reset_parked_high;
   begin
      host_tmsc_oe = 1'b1;  host_tmsc = 1'b1;  tckc = 1'b1;
      repeat (2) @(posedge free_clk);
      dbgresetn = 1'b0;
      repeat (8) @(posedge free_clk);
      dbgresetn = 1'b1;
      repeat (8) @(posedge free_clk);          // TCKC still high, TMSC still high
   end
endtask

task escape_from_high;                        // n changes, TCKC already high, then the terminating fall
   input integer n;
   integer k;
   begin
      for (k = 0; k < n; k = k + 1) begin
         host_tmsc = ~host_tmsc;
         repeat (CJHALF) @(posedge free_clk);
      end
      tckc = 1'b0;  repeat (CJHALF) @(posedge free_clk);
   end
endtask

initial
   begin : test
      reg [31:0] id;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      $display(" ===============================================");
      $display("|  7-change selection after a high-parked reset |");
      $display(" ===============================================");
      reset_parked_high;
      check_eq("offline_rst", dut.g_cjtag.u_dtm.online, 1'b0);
      escape_from_high(7);
      cjtag_send_actcode;
      check_eq("online_sel7", dut.g_cjtag.u_dtm.online, 1'b1);
      tap_reset;
      idcode_read(id);
      check_eq("idcode_sel7", id, DUT_IDCODE);

      $display(" ===============================================");
      $display("|  5-change deselection after a high-parked reset|");
      $display(" ===============================================");
      reset_parked_high;
      escape_from_high(5);
      cjtag_send_actcode;
      check_eq("offline_desel5", dut.g_cjtag.u_dtm.online, 1'b0);

      $display(" ===============================================");
      $display("|  ...a normal activation still works           |");
      $display(" ===============================================");
      tckc = 1'b0;  host_tmsc = 1'b1;
      repeat (4) @(posedge free_clk);
      cjtag_active_done = 1'b0;
      cjtag_activate;
      check_eq("online_again", dut.g_cjtag.u_dtm.online, 1'b1);
      tap_reset;
      idcode_read(id);
      check_eq("idcode_again", id, DUT_IDCODE);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
