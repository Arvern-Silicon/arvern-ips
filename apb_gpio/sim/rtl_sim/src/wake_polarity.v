//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    wake_polarity
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : wake_polarity.v
// Module Description : The wake follows the pin's interrupt modes. For a
//                      wake-enabled pin and each mode set (none, RISE, FALL,
//                      HIGH, LOW, RISE+FALL), a rising and a falling pin
//                      change raise gpio_wake_o only in the direction the
//                      modes report (rise: RISE or HIGH; fall: FALL or LOW);
//                      with no mode set, either change wakes. Checked with
//                      the clock running (the request lasts until the input
//                      register catches up) and with the oscillator off (it
//                      holds until the clock is back). The reference model
//                      checks gpio_wake_o every cycle as well.
//
// Doc "Wake": the wake condition and its mode terms.
//----------------------------------------------------------------------------

integer    cc;
integer    pp;
integer    p;
reg [31:0] pm;
reg        exp_r;
reg        exp_f;

// Mode set n -> registers RISE, FALL, HIGH, LOW for pin bit pm
task set_modes;
   input integer n;
   begin
      wr(R_IRQ_RISE, ((n == 1) || (n == 5)) ? pm : 32'h0);
      wr(R_IRQ_FALL, ((n == 2) || (n == 5)) ? pm : 32'h0);
      wr(R_IRQ_HIGH, (n == 3) ? pm : 32'h0);
      wr(R_IRQ_LOW,  (n == 4) ? pm : 32'h0);
      exp_r = (n == 0) || (n == 1) || (n == 3) || (n == 5);
      exp_f = (n == 0) || (n == 2) || (n == 4) || (n == 5);
   end
endtask

// Pin p changes to 'level' with the clock running: the wake request is
// seen at once if expected, and drops once the input register has caught up
task change_running;
   input level;
   input exp_wk;
   begin
      pins_set(level ? (gpio_ext | pm) : (gpio_ext & ~pm));
      #1;
      chk(gpio_wake === exp_wk, exp_wk ? "wake raised by a reported change" : "no wake for an unreported change");
      cycles(L_IN + 2);
      chk(gpio_wake === 1'b0, "wake low once the input register caught up");
   end
endtask

// The same with the oscillator off: the request holds while the clock is off
task change_osc_off;
   input level;
   input exp_wk;
   begin
      osc_stop;
      pins_set(level ? (gpio_ext | pm) : (gpio_ext & ~pm));
      #1;
      chk(gpio_wake === exp_wk, exp_wk ? "osc off: wake raised by a reported change" : "osc off: no wake for an unreported change");
      cycles(5);
      chk(gpio_wake === exp_wk, exp_wk ? "osc off: wake held while the clock is off" : "osc off: still no wake");
      osc_start;
      cycles(L_IN + 3);
      chk(gpio_wake === 1'b0, "wake low once the clock is back and the input caught up");
   end
endtask

initial
   begin
      wait_reset_done(5);
      gpio_ext = 32'h0;
      cycles(2);
      model_check_en = 1'b1;

      for (pp = 0; pp < 3; pp = pp + 1)
        begin
           p  = pick_pin(pp * 4);
           pm = pbit(p);
           wr(R_WAKE_EN, pm);
           inputs_on(pm);
           for (cc = 0; cc < 6; cc = cc + 1)
             begin
                $display("---- pin %0d, mode set %0d", p, cc);
                // freeze around the mode writes, pin low
                set_modes(cc);
                cycles(2);
                change_running(1'b1, exp_r);
                change_running(1'b0, exp_f);
                change_osc_off(1'b1, exp_r);
                change_osc_off(1'b0, exp_f);
             end
           wr(R_IRQ_PEND, 32'hFFFFFFFF);
           wr(R_IN_EN, 32'h0);
           wr(R_WAKE_EN, 32'h0);
           cycles(L_IN + 3);
        end

      cycles(5);
      model_check_en = 1'b0;
      cycles(20);
      stimulus_done = 1;
   end
