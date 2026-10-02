//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dtmcs_fields
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dtmcs_fields.v
// Module Description : Read dtmcs and check every static field against the RISC-V
//                      Debug Spec 1.0 layout: version=1, abits=ABITS, idle=hint,
//                      errinfo=4 (unknown = reset value of an IMPLEMENTED field, not 0
//                      which would mean not-implemented), dmistat=0 (idle). The W1 reset bits
//                      (dmireset/dmihardreset) must read back as 0.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] d;

      @(posedge dbgresetn);
      @(posedge trst_n);
      repeat (4) @(posedge tck);

      $display(" ===============================================");
      $display("|   dtmcs static field check                    |");
      $display(" ===============================================");
      tap_reset;
      dtmcs_read(d);
      $display("INFO:  dtmcs = 0x%08h", d);

      check_eq("version",  d[3:0],   4'd1);
      check_eq("abits",    d[9:4],   ABITS[5:0]);
      check_eq("dmistat",  d[11:10], 2'd0);          // idle -> 0
      check_eq("idle",     d[14:12], DUT_IDLE);
      check_eq("rsvd15",   d[15],    1'b0);
      check_eq("dmireset", d[16],    1'b0);          // W1, reads 0
      check_eq("dmihard",  d[17],    1'b0);          // W1, reads 0
      check_eq("errinfo",  d[20:18], 3'd4);          // 4 = unknown/no error. This DTM
                                                     // IMPLEMENTS errinfo, so 4 is its RESET
                                                     // value; 0 would mean not-implemented.
                                                     // Behaviour lives in dtmcs_errinfo.

      // A second read must be stable (no side effects from reading).
      dtmcs_read(d);
      check_eq("version2", d[3:0],   4'd1);
      check_eq("abits2",   d[9:4],   ABITS[5:0]);

      repeat (8) @(posedge tck);
      stimulus_done = 1'b1;
   end
