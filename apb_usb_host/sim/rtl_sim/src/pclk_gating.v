//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    pclk_gating
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : pclk_gating.v
// Module Description : The clock request. With CTRL.EN=0, the port OFF and no
//                      access, pclk_en_o is low and pclk does not toggle; one
//                      access requests exactly its two cycles and the next
//                      edge; nothing changes while gated (STATE, lines,
//                      IRQ_PEND), and STATUS.LINE shows the lines as sampled
//                      by an access (J of a device attached while OFF);
//                      CTRL.EN=1 holds the request; clearing EN during the
//                      bus reset and in RUN holds it until the port is OFF
//                      with the lines released; the request stays high while
//                      the port drives the bus. The bench checks the formula
//                      on every cycle; this test makes each term the only
//                      active one where the doc allows it and reports the
//                      others.
//
// Doc "Clock request", "Ports", "States".
//----------------------------------------------------------------------------

integer    pg_edges = 0;                     // pclk rising edges
integer    pg_n0;
reg [31:0] pg_v;
reg        pg_en = 1'b0;                     // CTRL.EN as last written by the test
reg        pg_hold = 1'b0;                   // pclk_en_o must stay high
real       pg_t0;
reg  [4:0] pg_only = 5'b0;                   // sole active term seen: {acc, oe, state, en, psel}

reg        pg_accq = 1'b0;                   // an ACCESS cycle ended on the last pclk edge

always @(posedge pclk)
  pg_edges = pg_edges + 1;

always @(posedge pclk or negedge presetn)
  if (presetn !== 1'b1) pg_accq <= 1'b0;
  else                  pg_accq <= psel & penable;

// Which term of the request is the only active one (doc "Clock request")
always @(negedge free_clk)
  if (tb_rst_done && (presetn === 1'b1))
    begin
       #2;
       case ({pg_accq, usb_oe, (tb_state != S_OFF), pg_en, psel})
         5'b00001: pg_only[0] = 1'b1;
         5'b00010: pg_only[1] = 1'b1;
         5'b00100: pg_only[2] = 1'b1;
         5'b01000: pg_only[3] = 1'b1;
         5'b10000: pg_only[4] = 1'b1;
         default:  ;
       endcase
       if (pg_hold && (pclk_en !== 1'b1))
         begin
            $display("ERROR: pclk_en_o low while it must be held (STATE %0s, OE %b) %t ns",
                     st_name(tb_state), usb_oe, $time);
            error = error + 1;
         end
    end

// Gated: no pclk edge, no request, nothing moving, over us microseconds
task pg_gated;
   input real          us;
   input [80*8-1:0]    msg;
   reg   [3:0]         s0;
   begin
      repeat (2) @(posedge free_clk);        // past the edge an access just ended requests
      #1;
      s0    = tb_state;
      pg_n0 = pg_edges;
      wait_ms(us / 1000.0);
      if (FREE_CLK == 0)
        chk(pg_edges == pg_n0, msg);
      chk(pclk_en === 1'b0,  "no clock request while gated");
      chk(tb_state === s0,   "STATE does not change while gated");
      chk(usb_oe === 1'b0,   "lines released while gated");
      chk(irq === 1'b0,      "irq_o low while gated");
   end
endtask

// One isolated access: SETUP edge, ACCESS edge and the edge after it
task pg_one_access;
   input              write;
   input [31:0]       addr;
   begin
      pg_n0 = pg_edges;
      if (write) wr(addr, 32'h0);
      else       rdv(addr, pg_v);
      repeat (10) @(posedge free_clk);
      #1;
      if (FREE_CLK == 0)
        begin
           if (pg_edges - pg_n0 != 3)
             begin
                $display("ERROR: %0d pclk edges for one access, expected 3 %t ns", pg_edges - pg_n0, $time);
                error = error + 1;
             end
        end
      chk(pclk_en === 1'b0, "request released after the access");
   end
endtask

// Wait for a quiet bus (no host or device drive for 100 us)
task pg_quiet;
   begin
      while (!((usb_oe === 1'b0) && (dev.drv_en === 1'b0) && ($realtime - tb_act_t >= 100.0e3)))
        #(10.0e3);
   end
endtask

// Clear CTRL.EN: the request holds until the port is OFF with the lines released
task pg_disable;
   reg to;
   begin
      to = 1'b0;
      wr(R_CTRL, C_BOOT | C_IDLE0);
      pg_en   = 1'b0;
      pg_hold = 1'b0;
      pg_t0   = $realtime;
      begin : wfall
         fork
            begin : wf_ev
               @(negedge free_clk);
               #2;
               while (pclk_en !== 1'b0)
                 begin
                    @(negedge free_clk);
                    #2;
                 end
               disable wf_to;
            end
            begin : wf_to
               #(1.0e6);
               to = 1'b1;
               disable wf_ev;
            end
         join
      end
      chk(!to, "clock request released within 1 ms of CTRL.EN=0");
      chk(tb_state === S_OFF, "port OFF when the request falls");
      chk(usb_oe === 1'b0,    "lines released when the request falls");
   end
endtask

initial
   begin
      wait_reset_done(5);

      // Out of reset: OFF, no access, no request
      @(negedge free_clk);
      #2;
      chk(pclk_en === 1'b0, "no clock request after reset");
      pg_gated(100.0, "pclk does not toggle with the port OFF and no access");

      // An access requests its cycles and one more
      pg_one_access(1'b0, R_INFO);
      pg_one_access(1'b1, 32'h3C);
      pg_one_access(1'b0, R_STATUS);
      pg_gated(50.0, "pclk gated again after the accesses");

      // A device attached while gated: nothing moves until an access samples
      // the lines; the second read shows them (the first one may still show the
      // synchroniser's earlier contents)
      dev.attach(dev.P_KBD);
      pg_gated(1000.0, "no pclk edge while a device attaches to a disabled port");
      rdv(R_STATUS, pg_v);
      rdv(R_STATUS, pg_v);
      chk32(pg_v, {26'h0, 2'b01, 4'd0}, "STATUS after attach, port OFF: LINE = J (D- high)");
      rd(R_IRQ_PEND, 32'h0);
      pg_gated(100.0, "gated after the STATUS reads");
      dev.detach;
      pg_gated(100.0, "no pclk edge while the device detaches");
      rdv(R_STATUS, pg_v);
      rdv(R_STATUS, pg_v);
      chk32(pg_v, 32'h0, "STATUS after detach, port OFF: LINE = SE0");

      // CTRL.EN = 1 holds the request; the bus reset drives the bus
      dev.attach(dev.P_KBD);
      wr(R_CTRL, C_EN | C_BOOT | C_IDLE0);
      pg_en   = 1'b1;
      pg_hold = 1'b1;
      wait_state(S_RESET, 150.0);
      wait_ms(5.0);
      chk(usb_oe === 1'b1 && usb_dp_o === 1'b0 && usb_dm_o === 1'b0, "bus reset drives SE0");
      chk(pclk_en === 1'b1, "request high while the port drives the bus");

      // Clearing EN during the bus reset cuts it short: legal here (software
      // disables the port), so the device's reset-length check is off until the
      // release has been seen
      dev.chk_enable(dev.C_RESET, 0);
      pg_disable;
      wait_ms(0.1);
      dev.chk_enable(dev.C_RESET, 1);
      pg_gated(200.0, "pclk gated once the port is OFF after a bus reset");
      wr(R_IRQ_PEND, I_ALL);
      pg_gated(50.0, "gated after the IRQ_PEND clear");

      // Enable again: enumeration to RUN with the request held throughout
      wr(R_CTRL, C_EN | C_BOOT | C_IDLE0 | (32'hFF << 8));
      pg_en   = 1'b1;
      pg_hold = 1'b1;
      wait_state(S_RUN, 600.0);
      wait_ms(5.0);

      // Clearing EN in RUN, at a quiet moment
      pg_quiet;
      pg_disable;
      pg_gated(200.0, "pclk gated once the port is OFF after RUN");
      status_chk(S_OFF, E_NONE, 4'd0);
      pg_gated(50.0, "gated after the STATUS read");

      chk(pg_only[0], "PSEL alone requested the clock");
      chk(pg_only[4], "the end-of-transfer edge alone requested the clock");
      $display("INFO: sole request terms seen: PSEL %b, CTRL.EN %b, STATE!=OFF %b, usb_oe %b, ACCESS end %b",
               pg_only[0], pg_only[1], pg_only[2], pg_only[3], pg_only[4]);

      stimulus_done = 1;
   end
