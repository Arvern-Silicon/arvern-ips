//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mdeleg_access
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mdeleg_access.v
// Module Description : MDELEG privilege gates: for every WR_PRIV / RD_PRIV
//                      pair and RESP, Machine, Supervisor and User accesses
//                      to a RW register are admitted or refused (PSLVERR or
//                      silent drop) as the gates say; a refused TXDATA write
//                      pushes nothing, a refused RXDATA read pops nothing;
//                      MDELEG itself is Machine only, the reserved code
//                      stores Machine, and PSTRB selects the fields.
//
// Doc "Access protection" (the apb_periph_example model).
//----------------------------------------------------------------------------

reg  [1:0] modes [0:3];
integer    wp, rp, rs, mi, l0;

initial
   begin
      wait_reset_done(5);
      modes[0] = MACHINE; modes[1] = SUPERVISOR; modes[2] = USER; modes[3] = USER_S;
      for (rs = 0; rs < 2; rs = rs + 1)
        for (wp = 0; wp < 4; wp = wp + 1)
          for (rp = 0; rp < 4; rp = rp + 1)
            begin
               apb_write(1, MACHINE, R_MDELEG, {23'h0, rs[0], 4'h0, rp[1:0], wp[1:0]}, SZ_W, OK);
               for (mi = 0; mi < 4; mi = mi + 1)
                 begin
                    apb_write(1, modes[mi], R_THRESH, 32'h0000_0005, SZ_W, exp_resp_of(1'b1, modes[mi], R_THRESH));
                    apb_read(1, modes[mi], R_THRESH, admitted(1'b0, modes[mi], R_THRESH) ? {7'h0, m_thresh_rx, 7'h0, m_thresh_tx} : 32'h0,
                             SZ_W, 1'b1, exp_resp_of(1'b0, modes[mi], R_THRESH));
                    apb_write(1, MACHINE, R_THRESH, 32'h0, SZ_W, OK);
                 end
            end
      apb_write(1, MACHINE, R_MDELEG, 32'h0000_010F, SZ_W, OK);
      rd(R_MDELEG, 32'h0000_010F);
      // reserved code stores Machine
      apb_write(1, MACHINE, R_MDELEG, 32'h0000_000A, SZ_W, OK);
      rd(R_MDELEG, 32'h0000_000F);
      // lanes: PSTRB[1] = RESP only
      apb_write(1, MACHINE, R_MDELEG + 1, 32'h01, SZ_B, OK);
      rd(R_MDELEG, 32'h0000_010F);
      // MDELEG refuses Supervisor and User
      apb_write(1, SUPERVISOR, R_MDELEG, 32'h0, SZ_W, ERROR);
      apb_write(1, USER, R_MDELEG, 32'h0, SZ_W, ERROR);
      apb_read(1, SUPERVISOR, R_MDELEG, 32'h0, SZ_W, 1'b1, ERROR);
      rd(R_MDELEG, 32'h0000_010F);
      // refused data-register accesses have no side effect
      apb_write(1, USER, R_TXDATA, 32'h1234_5678, SZ_W, ERROR);
      chk(apb_spi_inst0.tx_level == 0, "refused TXDATA write pushes nothing");
      if (RX_EN != 0)
        begin
           spi_setup(C_IDLE_HIGH, 1, 0);
           ent_rx(8, 2, 1'b0);
           wait_idle(10000);
           l0 = apb_spi_inst0.rx_level;
           apb_read(1, USER, R_RXDATA, 32'h0, SZ_W, 1'b1, ERROR);
           chk(apb_spi_inst0.rx_level == l0, "refused RXDATA read pops nothing");
           rx_drain;
        end
      apb_write(1, MACHINE, R_MDELEG, {23'h0, MDELEG_RST}, SZ_W, OK);
      stimulus_done = 1;
   end
