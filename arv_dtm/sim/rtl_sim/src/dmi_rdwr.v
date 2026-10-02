//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dmi_rdwr
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dmi_rdwr
// Module Description : TRANSPORT-NEUTRAL end-to-end DMI write/read. Uses only the
//                      common dtm_* API (dtm_tasks.v), so the SAME stimulus runs
//                      over JTAG, UART, or I2C -- runsim -dtm <transport> (or
//                      run_all) selects which DTM is compiled in. Covers several
//                      addresses, overwrite (no stale latch), the real-DM 1-cycle
//                      response latency, dmihardreset, and a failed-status read.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;

      dtm_init;
      slave_latency = 3;

      $display(" ===============================================");
      $display("|   DMI write then read-back (any transport)    |");
      $display(" ===============================================");

      dtm_dmi_write(7'h10, 32'hDEAD_BEEF, st);
      dtm_dmi_read (7'h10, rd, st);
      check_eq("rd@10", rd, 32'hDEAD_BEEF);
      check_eq("st@10", st, OP_SUCCESS);

      // 0x7E: a high DMI scratch address that exercises the wide address path.
      // (0x7F is intercepted locally as the DTMSTS register -- see the dedicated
      // DTMSTS test -- so it never reaches the DMI bus and cannot loop back here.)
      dtm_dmi_write(7'h7E, 32'hA5A5_5A5A, st);
      dtm_dmi_read (7'h7E, rd, st);
      check_eq("rd@7E", rd, 32'hA5A5_5A5A);

      // Overwrite and re-read to make sure the path isn't latching stale data.
      dtm_dmi_write(7'h10, 32'h1234_5678, st);
      dtm_dmi_read (7'h10, rd, st);
      check_eq("rd@10b", rd, 32'h1234_5678);

      $display(" ===============================================");
      $display("|   Real-DM 1-cycle response latency            |");
      $display(" ===============================================");
      // slave_latency=1 = the arvern arv_debug_dm's single wait state.
      slave_latency = 1;
      dtm_dmi_write(7'h20, 32'h0FF1_CE05, st);
      dtm_dmi_read (7'h20, rd, st);
      check_eq("rd@20", rd, 32'h0FF1_CE05);
      check_eq("st@20", st, OP_SUCCESS);

      $display(" ===============================================");
      $display("|   dmihardreset, bus still works afterwards    |");
      $display(" ===============================================");
      slave_latency = 3;
      dtm_dmi_hardreset(st);
      check_eq("hrst_st", st, OP_SUCCESS);
      dtm_dmi_write(7'h11, 32'hCAFE_F00D, st);
      dtm_dmi_read (7'h11, rd, st);
      check_eq("rd@11", rd, 32'hCAFE_F00D);

      $display(" ===============================================");
      $display("|   Failed status is carried back verbatim      |");
      $display(" ===============================================");
      // Do this LAST: on JTAG a failed op is sticky (cleared only by dmireset/
      // dmihardreset); the serial transports report it per-transaction. Either
      // way the end-of-test needs no further DMI ops after the failed read.
      slave_fault_en   = 1'b1;
      slave_fault_addr = 7'h30;
      dtm_dmi_read(7'h30, rd, st);
      check_eq("failed", st, OP_FAILED);
      slave_fault_en   = 1'b0;

      dtm_settle(8);
      stimulus_done = 1'b1;
   end
