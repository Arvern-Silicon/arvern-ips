//----------------------------------------------------------------------------
// File Name          : dtmcs_errinfo
// Module Description : dtmcs.errinfo must report a device error and clear on dmireset.
//
//   errinfo (dtmcs[20:18], Debug Spec 6.1.4) is optional, but reporting 0 means "not
//   implemented" and tells the debugger nothing. This DTM implements it, because the
//   DMI master already distinguishes the one case the spec lets us name precisely:
//   PSLVERR from the Debug Module is "the DMI subordinate reported an error" = 3.
//
//   The spec ties it to op: "updated whenever op is updated by the hardware or when 1
//   is written to dmireset", and its reset value when implemented is 4 (unknown).
//   OpenOCD reads and decodes the field, so this is what a human sees when a link
//   misbehaves -- a wrong value here is actively misleading, not merely unhelpful.
//
//   Discriminator: 4 -> 3 on a genuine PSLVERR, then back to 4 on dmireset. A DTM that
//   hardcodes the field (either 0 or 4) fails the middle check.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] d;
      reg [31:0] rd;
      reg [1:0]  st;
      reg [31:0] dt;

      @(posedge dbgresetn);
      @(posedge trst_n);
      repeat (4) @(posedge tck);
      tap_reset;

      $display(" ===============================================");
      $display("|  errinfo: reset value                        |");
      $display(" ===============================================");
      dtmcs_read(d);
      check_eq("errinfo_reset", {29'd0, d[20:18]}, 32'd4);   // 4 = unknown / no error

      $display(" ===============================================");
      $display("|  errinfo: device error from PSLVERR          |");
      $display(" ===============================================");
      slave_fault_en   = 1'b1;
      slave_fault_addr = 7'h20;
      shift_ir(IR_DMI);                           // dmi_read requires IR=DMI
      dmi_read(7'h20, 8, rd, st);
      check_eq("op_failed", st, OP_FAILED);
      dtmcs_read(d);
      check_eq("errinfo_device", {29'd0, d[20:18]}, 32'd3);  // 3 = device error

      $display(" ===============================================");
      $display("|  errinfo: cleared by dmireset                |");
      $display(" ===============================================");
      slave_fault_en = 1'b0;
      dtmcs_write(32'h0001_0000);                 // dmireset = bit16
      dtmcs_read(d);
      check_eq("errinfo_cleared", {29'd0, d[20:18]}, 32'd4);
      check_eq("dmistat_cleared", {30'd0, d[11:10]}, 32'd0);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
