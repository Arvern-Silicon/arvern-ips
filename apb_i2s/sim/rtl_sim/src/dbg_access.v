//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dbg_access
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dbg_access.v
// Module Description : Debugger reads of RXDATA (PMASTER with a
//                      DBG_PMASTER_MASK bit): with DBG_POP 0 the head word
//                      is returned without a pop and without RX_UDF (0 when
//                      empty), with DBG_POP 1 the read pops like a core
//                      read; a read refused by MDELEG neither pops nor sets
//                      RX_UDF; other registers read the same for the
//                      debugger; with DBG_PMASTER_MASK 0 every read is the
//                      core's.
//
// Doc "Debugger accesses", "Register map" (INFO[10]).
//----------------------------------------------------------------------------

integer txl, rxl, l0;
reg [31:0] v, h, c;
reg        is_dbg;

initial
   begin
      wait_reset_done(5);
      if (RX_EN == 0) tb_skip("no receive path");
      is_dbg = |(4'h9 & DBG_MASK);
      i2s_setup(1, 3'd0, F_I2S, 1'b0);
      rx_fill((RX_DEPTH < 4) ? RX_DEPTH : 4);
      rd_levels(txl, l0);
      // debugger peek
      tb_pmaster = 4'h9;
      rdv(R_RXDATA, h);
      rdv(R_RXDATA, v);
      rd_levels(txl, rxl);
      if (is_dbg)
        begin
           chk(rxl == l0, "debugger read does not pop with DBG_POP = 0");
           chk32(v, h, "debugger reads return the head word");
        end
      else
        chk(rxl == l0 - 2, "reads pop when PMASTER is not a debugger");
      rdv(R_CTRL, c);
      // DBG_POP = 1
      ctrl_wr(t_ctrl | C_DBG_POP);
      rd_levels(txl, l0);
      rdv(R_RXDATA, v);
      rd_levels(txl, rxl);
      chk(rxl == l0 - 1, "debugger read pops with DBG_POP = 1");
      // a debugger read refused by MDELEG neither pops nor sets RX_UDF
      wr(R_MDELEG, 32'h10C);
      apb_read(1, USER, R_RXDATA, 32'h0, SZ_W, 1'b0, ERROR);
      rd_levels(txl, l0);
      chk(l0 == rxl, "refused debugger read does not pop");
      wr(R_MDELEG, MDELEG_RST_WORD);
      ctrl_wr(t_ctrl & ~C_DBG_POP);
      tb_pmaster = 4'h1;
      // drain as the core, then peek an empty FIFO as the debugger
      while (rxl > 0) begin rdv(R_RXDATA, v); rxl = rxl - 1; end
      tb_pmaster = 4'h9;
      ctrl_wr(t_ctrl | C_DBG_POP);
      wr(R_MDELEG, 32'h10C);
      apb_read(1, USER, R_RXDATA, 32'h0, SZ_W, 1'b0, ERROR);
      wr(R_MDELEG, MDELEG_RST_WORD);
      rdv(R_IRQ_PEND, v);
      chk(v[5] === 1'b0, "refused read of an empty FIFO sets no RX_UDF");
      ctrl_wr(t_ctrl & ~C_DBG_POP);
      rd(R_RXDATA, 32'h0);
      rdv(R_IRQ_PEND, v);
      chk(v[5] === !is_dbg, "RX_UDF set by an empty read only for a core read");
      tb_pmaster = 4'h1;
      wr(R_IRQ_PEND, I_RX_UDF);
      stimulus_done = 1;
   end
