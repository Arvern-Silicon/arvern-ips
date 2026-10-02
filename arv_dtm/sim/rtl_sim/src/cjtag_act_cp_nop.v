//----------------------------------------------------------------------------
// File Name          : cjtag_act_cp_nop
// Module Description : The Check Packet is VARIABLE length -- activation must still
//                      complete when the DTS pads the body with CP_NOP directives.
//
//   Cl. 11.7.9.1.3 / Rule 11.9.6.2 e): beginning with the second body bit, the last
//   two body bits are the directive -- a sliding window, not a sequence of pairs.
//   CP_NOP (01/10) extends the body by one bit; CP_END (00) is followed by one
//   Postamble bit, after which the node is Online.
//
//   Discriminator: bodies with an ODD number of bits up to the first 00 window
//   (1,0,0 and 1,0,1,0,1,0,0). A decoder that evaluates non-overlapping pairs ends
//   the body one bit later, takes the first Scan Packet bit as the Postamble, and
//   misframes every packet after it -- the IDCODE read then fails. The even body
//   (0,1,0,0) ends on the same bit under both readings and is kept as a control.
//----------------------------------------------------------------------------

task act_and_check;
   input [15:0] body;
   input integer len;
   input [8*24-1:0] name;
   reg   [31:0] id;
   begin
      cjtag_escape_sel;
      cjtag_send_actcode_body(body, len);
      check_eq(name, dut.g_cjtag.u_dtm.online, 1'b1);
      tap_reset;
      idcode_read(id);
      check_eq(name, id, DUT_IDCODE);
   end
endtask

initial
   begin : test
      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      $display(" ===============================================");
      $display("|  Activation with CP_NOPs before CP_END       |");
      $display(" ===============================================");
      act_and_check(16'b0000_0000_0000_0100,   3, "cp_body_1_0_0");          // body[0] first: 1,0,0
      act_and_check(16'b0000_0000_0000_0010,   4, "cp_body_0_1_0_0");        // 0,1,0,0
      act_and_check(16'b0000_0000_0001_0101,   7, "cp_body_1010100");        // 1,0,1,0,1,0,0
      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
