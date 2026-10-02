//----------------------------------------------------------------------------
// File Name          : cjtag_act_cp_rso
// Module Description : CP_RSO (11) in the Check Packet body initiates a TAP.7
//                      controller reset instead of placing the node Online.
//
//   Cl. 11.7.9.1.3: "CP_RSO (11): Initiate a Type-3 TAP.7 Controller reset. The CP_END
//   and CP_RSO Directives terminate the CP after one additional bit follows these
//   directives." After a CP_RSO body (1,1) and its Postamble the node must be Offline,
//   must not drive TMSC while the host keeps clocking, and must still activate
//   normally afterwards. A decoder that reads 11 as a NOP pair keeps waiting for 00
//   and goes Online on the next two zero bits.
//----------------------------------------------------------------------------

integer k;

initial
   begin : test
      reg [31:0] id;
      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      $display(" ===============================================");
      $display("|  Check Packet CP_RSO -> reset, stays Offline |");
      $display(" ===============================================");
      cjtag_escape_sel;
      cjtag_send_actcode_body(16'b11, 2);              // body 1,1 = CP_RSO
      check_eq("offline_after_rso", dut.g_cjtag.u_dtm.online, 1'b0);
      for (k = 0; k < 12; k = k + 1) begin              // zeros a pair decoder would take as CP_END
         cjtag_act_bit(1'b0);
         check_eq("no_drive_after_rso", tmsc_dut_oe, 1'b0);
      end
      check_eq("still_offline", dut.g_cjtag.u_dtm.online, 1'b0);

      cjtag_escape_sel;                                // a normal activation still works
      cjtag_send_actcode;
      check_eq("online_after_rso", dut.g_cjtag.u_dtm.online, 1'b1);
      tap_reset;
      idcode_read(id);
      check_eq("idcode_after_rso", id, DUT_IDCODE);
      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
