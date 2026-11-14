//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    in_en_flush
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : in_en_flush.v
// Module Description : IN_EN: per-pin enable and flush.
//   A. Flush timing: enabling a high pin with IRQ_HIGH set raises the level
//      on irq_o exactly L pclk_aon edges after the IN_EN write (bus clock
//      gated meanwhile); the step from the held 0 is not latched as a rising
//      edge; INPUT reads 0 during the flush (SYNC_EN=1) and the pin after.
//   B. A pin change after the flush is reported normally.
//   C. Enabling one pin does not disturb another: its live level stays on
//      irq_o every cycle, and its edge one cycle after the write is latched
//      with the normal latency.
//   D. A disabled pin reads 0 and raises no edge, level or wake request,
//      whatever it does, with every mode bit, IRQ_EN and WAKE_EN set.
//   E. Clearing IN_EN stops the pin at once (its level leaves irq_o on the
//      edge ending the write) and INPUT reads 0.
//   F. A latched edge survives clearing IN_EN (every pin off) and a W1C with
//      every IN_EN bit 0 clears it, on the edge ending the write.
//
// Doc "Inputs": "A pin is sampled only while its IN_EN bit is 1." (Disabled
// pins) "While IN_EN[n]=0 the pin's input register is held at 0: INPUT[n]
// reads 0, and the pin raises no edge, no level and no wake request. ...
// A latched edge in IRQ_PEND[n] survives clearing IN_EN[n] and stays until
// software clears it." (Enabling a pin) "its first samples reach the input
// register after the stage depth (three pclk_aon_i cycles with SYNC_EN=1,
// one with SYNC_EN=0). Until then INPUT[n] reads 0 and no level is reported;
// edge detection starts one cycle later ... Enabling a pin therefore never
// reports the step from the held 0 to the pin's level, and a pin change
// after that is reported normally. Each pin flushes on its own: enabling one
// pin does not disturb the others. Clearing IN_EN[n] stops the pin at once."
// Doc "Clocks": the input-path clock gate is open "during a write to
// IRQ_PEND (so a latched edge can be cleared with every input off)".
// Timing anchor for A: the IN_EN write takes effect on the edge ending its
// ACCESS cycle (W); the level is expected after edge W+L (L = 3 / 1).
//----------------------------------------------------------------------------

integer    kk;
integer    p;
integer    q;
integer    bad;
integer    lat;
reg [31:0] pq;

// Clear every mode / enable register and IRQ_PEND, pins low
task clean;
   begin
      wr(R_IRQ_RISE, 32'h0);
      wr(R_IRQ_FALL, 32'h0);
      wr(R_IRQ_HIGH, 32'h0);
      wr(R_IRQ_LOW,  32'h0);
      wr(R_WAKE_EN,  32'h0);
      wr(R_IN_EN,    32'h0);
      gpio_ext = 32'h0;
      cycles(L_IN + 3);
      wr(R_IRQ_PEND, 32'hFFFFFFFF);
      wr(R_IRQ_EN,   32'h0);
      rd(R_IRQ_PEND, 32'h0);
   end
endtask

initial
   begin
      wait_reset_done(5);
      gpio_ext = 32'h0;
      p  = pick_pin(5);
      q  = pick_pin(2);
      pq = pbit(p) | pbit(q);

      $display(" ===============================================");
      $display("|   A. FLUSH TIMING (pin %2d)                    |", p);
      $display(" ===============================================");
      pins_set(pbit(p));
      wr(R_IRQ_HIGH, pbit(p));
      wr(R_IRQ_RISE, pbit(p));
      wr(R_IRQ_EN,   pbit(p));
      cycles(L_IN + 3);
      rd(R_INPUT,    32'h0);                 // disabled: reads 0
      rd(R_IRQ_PEND, 32'h0);                 // disabled: no level
      chk((irq32 & pbit(p)) == 0, "disabled pin: no level on irq_o");
      apb_write(0, MACHINE, R_IN_EN, pbit(p), SZ_W, OK);
      @(posedge free_clk);                   // W: IN_EN set
      #1;
      chk((irq32 & pbit(p)) == 0, "no level right after the IN_EN write");
      for (kk = 1; kk <= L_IN + 3; kk = kk + 1)
        begin
           @(posedge free_clk);
           #1;
           if (kk < L_IN)
             chk((irq32 & pbit(p)) == 0, "no level while the stage is flushing");
           else
             chk((irq32 & pbit(p)) != 0, "level reported once the first sample reaches the input register");
        end
      wr(R_IRQ_HIGH, 32'h0);
      rd(R_IRQ_PEND, 32'h0);                 // the step from the held 0 was not latched as an edge
      rd(R_INPUT, pbit(p));
      if (L_IN > 1)
        begin
           wr(R_IN_EN, 32'h0);
           cycles(2);
           wr(R_IN_EN, pbit(p));             // returns one #1 after W
           rd(R_INPUT, 32'h0);               // ACCESS cycle W+2..W+3: still flushing
           cycles(L_IN + 2);
           rd(R_INPUT, pbit(p));
           rd(R_IRQ_PEND, 32'h0);
        end

      $display(" ===============================================");
      $display("|   B. CHANGE AFTER THE FLUSH IS REPORTED       |");
      $display(" ===============================================");
      clean;
      wr(R_IRQ_RISE, pbit(p));
      wr(R_IRQ_EN,   pbit(p));
      wr(R_IN_EN,    pbit(p));               // pin low
      cycles(L_IN + 1);                      // pin rises after edge W+L+2
      pins_set(pbit(p));
      cycles(L_IN + 3);
      rd(R_IRQ_PEND, pbit(p));
      chk((irq32 & pbit(p)) != 0, "edge after the flush reported on irq_o");

      if (q != p)
        begin
           $display(" ===============================================");
           $display("|   C. ENABLING %2d DOES NOT DISTURB %2d          |", p, q);
           $display(" ===============================================");
           // C1: live level of q every cycle across p's enable and flush
           clean;
           pins_set(pq);
           wr(R_IRQ_HIGH, pbit(q));
           wr(R_IRQ_EN,   pbit(q));
           inputs_on(pbit(q));
           chk((irq32 & pbit(q)) != 0, "level of the running pin before");
           bad = 0;
           fork
              wr(R_IN_EN, pq);
              begin
                 repeat (2*L_IN + 8)
                   begin
                      @(negedge free_clk);
                      if ((irq32 & pbit(q)) == 0) bad = bad + 1;
                   end
              end
           join
           chk(bad == 0, "running pin's level undisturbed while another pin flushes");
           rd(R_INPUT, pq);
           // C2: edge of q one cycle after the write enabling p: normal latency
           clean;
           wr(R_IRQ_RISE, pbit(q));
           wr(R_IRQ_EN,   pbit(q));
           inputs_on(pbit(q));
           apb_write(0, MACHINE, R_IN_EN, pq, SZ_W, OK);
           @(posedge free_clk);              // W
           #10;
           gpio_ext = gpio_ext | pbit(q);
           lat = 0;
           for (kk = 1; kk <= L_IN + 4; kk = kk + 1)
             begin
                @(posedge free_clk);
                #1;
                if ((lat == 0) && ((irq32 & pbit(q)) != 0)) lat = kk;
             end
           if (lat != L_IN + 1)
             begin
                $display("ERROR: running pin's edge latched on edge %0d, expected %0d (another pin flushing) %t ns", lat, L_IN + 1, $time);
                error = error + 1;
             end
           else
             $display("PASS:  running pin's edge latched on edge %0d while another pin flushes", lat);
        end

      $display(" ===============================================");
      $display("|   D. DISABLED PIN: READS 0, RAISES NOTHING    |");
      $display(" ===============================================");
      clean;
      inputs_on(GPIO_MASK & ~pbit(p));
      wr(R_IRQ_RISE, 32'hFFFFFFFF);
      wr(R_IRQ_FALL, 32'hFFFFFFFF);
      wr(R_IRQ_HIGH, pbit(p));
      wr(R_IRQ_LOW,  pbit(p));
      wr(R_IRQ_EN,   32'hFFFFFFFF);
      wr(R_WAKE_EN,  32'hFFFFFFFF);
      rd(R_IRQ_PEND, 32'h0);
      bad = 0;
      fork
         begin
            repeat (6)
              begin
                 pins_set(gpio_ext ^ pbit(p));
                 cycles(L_IN + 2);
              end
            pins_set(gpio_ext ^ pbit(p));    // one-cycle pulse
            pins_set(gpio_ext ^ pbit(p));
            cycles(L_IN + 3);
         end
         begin
            repeat (6*(L_IN + 3) + 2*1 + L_IN + 6)
              begin
                 @(negedge free_clk);
                 if (((irq32 & pbit(p)) != 0) || (gpio_wake !== 1'b0)) bad = bad + 1;
              end
         end
      join
      chk(bad == 0, "disabled pin: no irq_o, no gpio_wake_o");
      rd(R_INPUT, 32'h0);
      rd(R_IRQ_PEND, 32'h0);

      $display(" ===============================================");
      $display("|   E. CLEARING IN_EN STOPS THE PIN AT ONCE     |");
      $display(" ===============================================");
      clean;
      pins_set(pbit(p));
      wr(R_IRQ_HIGH, pbit(p));
      wr(R_IRQ_EN,   pbit(p));
      inputs_on(pbit(p));
      chk((irq32 & pbit(p)) != 0, "level before clearing IN_EN");
      apb_write(0, MACHINE, R_IN_EN, 32'h0, SZ_W, OK);
      @(negedge free_clk);
      chk((irq32 & pbit(p)) != 0, "level still on during the IN_EN write ACCESS cycle");
      @(posedge free_clk);
      #1;
      chk((irq32 & pbit(p)) == 0, "level gone on the edge ending the IN_EN clear");
      rd(R_INPUT, 32'h0);
      rd(R_IRQ_PEND, 32'h0);

      $display(" ===============================================");
      $display("|   F. LATCHED EDGE SURVIVES CLEARING IN_EN     |");
      $display(" ===============================================");
      clean;
      wr(R_IRQ_RISE, pbit(p));
      wr(R_IRQ_EN,   pbit(p));
      inputs_on(pbit(p));
      pins_set(pbit(p));
      cycles(L_IN + 3);
      rd(R_IRQ_PEND, pbit(p));
      wr(R_IN_EN, 32'h0);                    // every input off
      cycles(10);
      rd(R_IRQ_PEND, pbit(p));
      chk((irq32 & pbit(p)) != 0, "latched edge kept on irq_o with IN_EN cleared");
      apb_write(0, MACHINE, R_IRQ_PEND, pbit(p), SZ_W, OK);
      @(negedge free_clk);
      chk((irq32 & pbit(p)) != 0, "irq_o still high during the W1C ACCESS cycle");
      @(posedge free_clk);
      #1;
      chk((irq32 & pbit(p)) == 0, "W1C with every IN_EN at 0 clears the latched edge");
      rd(R_IRQ_PEND, 32'h0);

      clean;
      cycles(20);
      stimulus_done = 1;
   end
