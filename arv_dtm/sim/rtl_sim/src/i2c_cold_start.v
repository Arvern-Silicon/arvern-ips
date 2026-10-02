//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    i2c_cold_start
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : i2c_cold_start
// Module Description : Coming out of reset onto a MID-TRANSACTION bus must NOT
//                      synthesize a phantom START.
//
//   scl_dly/sda_dly reset HIGH (idle-bus assumption). If the DUT is reset while
//   another master already holds the bus mid-transaction (SDA low, SCL high), the
//   first sda_lvl 1->0 as the synchroniser pipeline captures the real low level looks
//   exactly like a START (SDA falling while SCL high) -- so the target would wrongly
//   enter ST_ADDR and (re)address off traffic it never saw the START of. The RTL
//   masks START/STOP detection until the sync/majority/dly pipeline has primed with the
//   genuine bus level, so no artificial edge appears and the target stays in ST_IDLE.
//
//   The bus is driven SDA-low/SCL-high WHILE dbgresetn is asserted (so no edge is
//   detected during setup); on release the check is that the FSM is still ST_IDLE
//   (a phantom START would leave it in ST_ADDR). A normal transaction afterwards
//   proves the settle mask does not break ordinary operation.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [1:0]  st;
      reg [31:0] rd;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      // Prove the target is alive on a clean idle bus first.
      dmi_i2c(7'h12, OP_WRITE, 32'hC0FF_EE00, st, rd);
      dmi_i2c(7'h12, OP_READ,  32'h0,         st, rd);
      check_eq("alive_rd", rd, 32'hC0FF_EE00);

      $display(" ===================================================");
      $display("|  I2C cold-start onto a mid-transaction bus        |");
      $display("|  reset with SDA low / SCL high -> no phantom START |");
      $display(" ===================================================");

      // Establish the mid-transaction bus (SDA low, SCL high) WHILE the DUT is held in
      // reset, so the setup itself creates no detectable edge. The bench reg driving
      // dbgresetn_i is owned by the test after the initial reset (as in dmi_reset_cross).
      dbgresetn = 1'b0;                      // hold the target in reset
      repeat (2) @(posedge free_clk);
      m_scl_pd  = 1'b0;                       // SCL released high
      m_sda_pd  = 1'b1;                       // SDA pulled low  (another master, mid-transaction)
      repeat (4) @(posedge free_clk);
      dbgresetn = 1'b1;                      // release onto the non-idle bus

      // Let the settle window elapse and the phantom (if any) latch into the FSM.
      repeat (20) @(posedge free_clk);

      // The target must NOT have taken the phantom START into ST_ADDR, and must not be
      // driving the bus.
      check_eq("cs_state_idle", dut.g_i2c.u_dtm.state, 3'd0);   // 3'd0 = ST_IDLE
      check_eq("cs_no_drive",   dut_sda_pd,      1'b0);

      // Release the bus (SDA rises while SCL high = STOP; the idle target just stays
      // idle) and confirm ordinary transactions still round-trip.
      m_sda_pd = 1'b0;  #(T_HIGH);
      i2c_stop;

      dmi_i2c(7'h34, OP_WRITE, 32'h1357_9BDF, st, rd);
      dmi_i2c(7'h34, OP_READ,  32'h0,         st, rd);
      check_eq("recov_st", st, OP_SUCCESS);
      check_eq("recov_rd", rd, 32'h1357_9BDF);

      repeat (8) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
