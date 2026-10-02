//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    i2c_dmi_busy
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : i2c_dmi_busy
// Module Description : The serial DTM HIDES busy: arv_dtm_cmd blocks the response
//                      until the DMI op completes. On I2C the target enforces this
//                      by CLOCK-STRETCHING (holding SCL low) until inflight drops,
//                      so the host never sees a busy code -- the read just returns
//                      late, with correct data.
//
//   Discriminator: the DMI master holds a *previous* read's data. We stall the
//   slave's response (slave_hold) for a held read, release it mid-flight, and
//   require the returned data to be the CORRECT held-read value -- NOT the stale
//   prior value. If arv_dtm_cmd did not wait for inflight to drop (i.e. if the
//   target did not clock-stretch), it would serialise the stale data and this
//   check would fail.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      slave_latency = 3;

      // Prime the master's read-data register with a DISTINCT stale value.
      dmi_i2c(7'h20, OP_WRITE, 32'hAAAA_BBBB, st, rd);
      dmi_i2c(7'h20, OP_READ,  32'h0,         st, rd);
      check_eq("prime", rd, 32'hAAAA_BBBB);     // master rdata now = 0xAAAABBBB

      // Seed the value we will read under a stalled response.
      dmi_i2c(7'h10, OP_WRITE, 32'hC0DE_1234, st, rd);

      $display(" ===============================================");
      $display("|  Stalled response: busy hidden by clk-stretch |");
      $display(" ===============================================");

      // Stall the slave, then issue a read. dmi_i2c() blocks in scl_release_high
      // because the target clock-stretches SCL low until the DMI op completes --
      // which only happens after we release the stall, by which point
      // arv_dtm_cmd has waited out inflight.
      slave_hold = 1'b1;
      fork
         begin : releaser
            #80000;                 // well after the request + repeated-START read begins
            slave_hold = 1'b0;
         end
         begin : doit
            dmi_i2c(7'h10, OP_READ, 32'h0, st, rd);
         end
      join

      check_eq("busy_hidden_st", st, OP_SUCCESS);          // never a busy code to the host
      check_eq("busy_hidden_rd", rd, 32'hC0DE_1234);       // correct value, NOT stale 0xAAAABBBB

      // Bus is healthy afterwards.
      dmi_i2c(7'h10, OP_READ, 32'h0, st, rd);
      check_eq("after_rd", rd, 32'hC0DE_1234);
      check_eq("after_st", st, OP_SUCCESS);

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
