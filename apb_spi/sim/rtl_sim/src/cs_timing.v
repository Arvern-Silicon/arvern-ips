//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    cs_timing
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : cs_timing.v
// Module Description : Chip-select timing: every SETUP, HOLD and INACT value
//                      1 to 16 at HALF 1 and 3, both clock phases, measured
//                      exactly (the first edge SETUP half-periods after the
//                      assertion, the release HOLD after the last edge, the
//                      next assertion INACT after the release with the entry
//                      waiting); every select, random polarities; a held
//                      select released for an entry on another select and
//                      for a CS_NONE entry.
//
// Doc "Chip selects".
//----------------------------------------------------------------------------

integer    v, h, ph, which, s;
real       hp;

initial
   begin
      wait_reset_done(5);
      for (ph = 0; ph < 2; ph = ph + 1)
        for (h = 1; h <= 3; h = h + 2)
          for (which = 0; which < 3; which = which + 1)
            for (v = 1; v <= 16; v = v + 1)
              begin
                 clk_set(h, 0);
                 cs_set(8'h00, (which == 0) ? v : 1, (which == 1) ? v : 1, (which == 2) ? v : 1);
                 ctrl_wr(C_EN | C_IDLE_HIGH | (ph ? C_CPHA : 0));
                 hp = h * PCLK_P;
                 ent_tx(8, $urandom, 1'b0);
                 ent_tx(8, $urandom, 1'b0);              // waits for the inactive time
                 wait_idle(100000);
                 if (t_meas_setup < v * hp - 0.01 && which == 0 || ((which == 0) && (t_meas_setup > v * hp + 0.01)))
                   begin $display("ERROR: SETUP %0d: %0.1f ns %t ns", v, t_meas_setup, $time); error = error + 1; end
                 if ((which == 1) && ((t_meas_hold < v * hp - 0.01) || (t_meas_hold > v * hp + 0.01)))
                   begin $display("ERROR: HOLD %0d: %0.1f ns %t ns", v, t_meas_hold, $time); error = error + 1; end
                 if ((which == 2) && ((t_meas_inact < v * hp - 0.01) || (t_meas_inact > v * hp + 0.01)))
                   begin $display("ERROR: INACT %0d: %0.1f ns %t ns", v, t_meas_inact, $time); error = error + 1; end
                 if (which == 2) cv_inact_q = 1;
              end
      // every select, random polarity, switches
      clk_set(1, 0);
      for (s = 0; s < CS_NR; s = s + 1)
        begin
           cs_set($urandom, 1, 1, 2);
           ent(xa(KTX, 8, 1, 1'b0, 1'b1, 1'b0, s), $urandom);
           ent(xa(KTX, 8, 1, 1'b0, 1'b1, 1'b0, (s + 1) % CS_NR), $urandom);    // held: released, then the other
           ent(xa(KTX, 8, 1, 1'b0, 1'b1, 1'b1, 0), $urandom);                  // held: released for CS_NONE
           ent(xa(KTX, 8, 1, 1'b0, 1'b0, 1'b0, s), $urandom);
           wait_idle(100000);
           if (CS_NR > 1) cv_hold_switch = 1;
           cv_hold_none = 1;
        end
      cs_set(8'h00, 1, 1, 1);
      stimulus_done = 1;
   end
