//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    reset_values
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : reset_values.v
// Module Description : Every register and every unlisted word of the window
//                      reads its reset value (Machine mode); the lines are
//                      released, irq_o is low, and the clock request is low
//                      once the port is OFF and the bus idle.
//
// Doc "Ports", "Register map", "Clock request".
//----------------------------------------------------------------------------

integer    a;
reg [31:0] exp;

initial
   begin
      wait_reset_done(3);
      chk(usb_oe === 1'b0 && usb_dp_o === 1'b0 && usb_dm_o === 1'b0, "lines released out of reset");
      chk(irq === 1'b0, "irq_o low out of reset");
      @(negedge free_clk);
      chk(pclk_en === 1'b0, "no clock request with the port OFF and the bus idle");

      for (a = 0; a < WIN_SIZE; a = a + 4)
        begin
           case (a)
             R_INFO:      exp = INFO_VALUE;
             R_CTRL:      exp = CTRL_RST;
             R_MDELEG:    exp = MDELEG_RST_WORD;
             default:     exp = 32'h0;
           endcase
           if (admitted(1'b0, MACHINE, a) || (a == R_MDELEG))
             apb_read(1, MACHINE, a, exp, SZ_W, 1'b1, OK);
           // Long windows: the unlisted words above 0x100 are sampled
           if (a >= 32'h100) a = a + 4 * ($urandom % 64);
        end

      // Reads have no side effect: the same values again
      rd(R_STATUS, 32'h0);
      rd(R_IRQ_PEND, 32'h0);
      rd(R_CTRL, CTRL_RST);
      chk(usb_oe === 1'b0, "lines still released");
      stimulus_done = 1;
   end
