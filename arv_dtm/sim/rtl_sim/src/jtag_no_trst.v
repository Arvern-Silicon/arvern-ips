//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    jtag_no_trst
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : jtag_no_trst
// Module Description : The DTM must come up fully usable with TRST NOT WIRED.
//
//   IEEE 1149.1 makes TRST optional -- the TAP has to be resettable by TMS alone --
//   and this is the aRVern FPGA board's actual wiring (GPIO_1[3] pulled high, never
//   driven). Every other test drives trst_n; this one ties it high for the whole run
//   (+define+NO_TRST).
//
//   The TAP FSM self-heals: its next-state case has a default, so the state resolves
//   after one TCK, and 5x TMS=1 then reaches Test-Logic-Reset from anywhere. TLR in
//   turn forces IR=IDCODE. What does NOT self-heal is the rest of the TAP state --
//   sticky_err in particular -- so if the TAP is never actually reset, dtmcs.dmistat
//   comes up undefined and the first DMI ops answer with a stale/garbage status.
//
//   Discriminator: dtmcs.dmistat must read 0 after a TMS-only reset, WITHOUT the
//   debugger having to issue a dmireset first. That only holds if the TAP reset is
//   asserted at power-up by something other than TRST (dbgresetn = the debug-domain
//   POR, ANDed in by arv_dtm_jtag).
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] id;
      reg [31:0] dtmcs;
      reg [31:0] rd;
      reg [1:0]  st;

      // NOTE: trst_n is never driven here -- the bench holds it high.
      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      slave_latency = 2;

      $display(" ===============================================");
      $display("|   TMS-only reset reaches TLR (no TRST)        |");
      $display(" ===============================================");

      tap_reset;                                 // 5x TMS=1 -> TLR, then RTI
      idcode_read(id);
      check_eq("idcode_no_trst", id, DUT_IDCODE);   // TLR forced IR=IDCODE

      $display(" ===============================================");
      $display("|   TAP state is INITIALISED, not just settled  |");
      $display(" ===============================================");

      // dmistat must be clean without a dmireset. Undefined sticky state shows up
      // here as X and fails the compare -- which is exactly the bug this test exists
      // to catch (a TAP that was never reset because TRST never asserted).
      dtmcs_read(dtmcs);
      check_eq("dtmcs_version", dtmcs[3:0],   4'd1);
      check_eq("dtmcs_abits",   dtmcs[9:4],   6'd7);
      check_eq("dmistat_clean", dtmcs[11:10], 2'd0);

      $display(" ===============================================");
      $display("|   DMI works with no TRST and no dmireset      |");
      $display(" ===============================================");

      shift_ir(IR_DMI);
      dmi_write(7'h10, 32'hFEED_FACE, DTM_IDLE_N);
      dmi_read (7'h10, DTM_IDLE_N, rd, st);
      check_eq("no_trst_st", st, OP_SUCCESS);
      check_eq("no_trst_rd", rd, 32'hFEED_FACE);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
