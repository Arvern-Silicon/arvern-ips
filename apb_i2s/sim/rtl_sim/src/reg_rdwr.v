//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    reg_rdwr
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : reg_rdwr.v
// Module Description : Register file: every RW field written and read back,
//                      whole words and byte lanes, the WARL fields (RATIO
//                      5-7, RX_MONO_SEL 3), the fields of an absent path
//                      (TX_EN / RX_EN = 0) read 0, LOOPBACK needs both paths,
//                      DBG_POP needs a receive path; CLKDIV and FORMAT
//                      ignored while the engine runs; the write-only and
//                      unmapped offsets of the whole window read 0 and
//                      ignore writes.
//
// Doc "Register map", "CTRL", "Byte lanes".
//----------------------------------------------------------------------------

reg [31:0] v, m_ctrl, m_thr;
integer    a, i;

initial
   begin
      wait_reset_done(5);
      // CTRL (EN left at 0): every bit but EN, then byte lanes
      m_ctrl = {18'h0, (RX_EN != 0) & 1'b1, (TX_EN != 0) & (RX_EN != 0), 2'b00, (RX_EN != 0) ? 2'b10 : 2'b00,
                1'b0, (RX_EN != 0), (TX_EN != 0), 1'b0, 1'b1, (RX_EN != 0), (TX_EN != 0), 1'b0};
      wr(R_CTRL, 32'hFFFF_FFFE & ~32'h0100);       // RX_MONO_SEL = 2
      rd(R_CTRL, m_ctrl);
      wr(R_CTRL, 32'h0);                            // clears TX_ON / RX_ON; the mono fields stay (locked)
      rd(R_CTRL, m_ctrl & 32'h0000_0360);
      wr(R_CTRL, 32'h0);                            // now the mono fields clear
      rd(R_CTRL, 32'h0);
      wr(R_CTRL, 32'h0000_0300);                    // RX_MONO_SEL = 3 stores 0
      rd(R_CTRL, 32'h0);
      apb_write(1, MACHINE, R_CTRL + 1, 32'h31, SZ_B, OK);   // lane 1: LOOPBACK, DBG_POP, RX_MONO_SEL 1
      rd(R_CTRL, {18'h0, (RX_EN != 0), (TX_EN != 0) & (RX_EN != 0), 2'b00, 1'b0, (RX_EN != 0), 8'h00});
      apb_write(1, MACHINE, R_CTRL, 32'h08, SZ_B, OK);       // lane 0: MCLK_EN only
      rd(R_CTRL, {18'h0, (RX_EN != 0), (TX_EN != 0) & (RX_EN != 0), 2'b00, 1'b0, (RX_EN != 0), 8'h08});
      wr(R_CTRL, 32'h0);

      // CLKDIV: MDIV, RATIO (WARL), RX_DLY (receive path only)
      wr(R_CLKDIV, 32'hFFFF_F4A5);
      rd(R_CLKDIV, {16'h0, (RX_EN != 0) ? 4'hF : 4'h0, 1'b0, 3'd4, 8'hA5});
      wr(R_CLKDIV, 32'h0000_0600);                  // RATIO 6 stores 0
      rd(R_CLKDIV, 32'h0);
      apb_write(1, MACHINE, R_CLKDIV + 1, 32'h53, SZ_B, OK);
      rd(R_CLKDIV, {16'h0, (RX_EN != 0) ? 4'h5 : 4'h0, 1'b0, 3'd3, 8'h00});
      wr(R_CLKDIV, 32'h0);

      // FORMAT (the device model follows, for the idle levels)
      wr(R_FORMAT, 32'hFFFF_FFFF);
      d_fmt = 6'h3F;
      rd(R_FORMAT, 32'h3F);
      wr(R_FORMAT, 32'h2);
      d_fmt = F_I2S;
      rd(R_FORMAT, 32'h2);

      // THRESH: 9-bit fields, byte lanes
      wr(R_THRESH, 32'hFFFF_FFFF);
      m_thr = {7'h0, (RX_EN != 0) ? 9'h1FF : 9'h0, 7'h0, (TX_EN != 0) ? 9'h1FF : 9'h0};
      rd(R_THRESH, m_thr);
      apb_write(1, MACHINE, R_THRESH + 2, 32'h12, SZ_B, OK);
      rd(R_THRESH, {7'h0, (RX_EN != 0) ? 9'h112 : 9'h0, 7'h0, (TX_EN != 0) ? 9'h1FF : 9'h0});
      apb_write(1, MACHINE, R_THRESH, 32'h0034, SZ_H, OK);
      rd(R_THRESH, {7'h0, (RX_EN != 0) ? 9'h112 : 9'h0, 7'h0, (TX_EN != 0) ? 9'h034 : 9'h0});
      wr(R_THRESH, 32'h0);

      // IRQ_EN
      wr(R_IRQ_EN, 32'hFFFF_FFFF);
      rd(R_IRQ_EN, {26'h0, (RX_EN != 0), (TX_EN != 0), (RX_EN != 0), (TX_EN != 0), (RX_EN != 0), (TX_EN != 0)});
      wr(R_IRQ_EN, 32'h0);

      // Locked while running
      i2s_setup(1, 3'd0, F_I2S, 1'b0);
      i2s_start(0);
      wr(R_CLKDIV, 32'h0000_0203);
      rd(R_CLKDIV, 32'h0);
      wr(R_FORMAT, 32'h08);
      rd(R_FORMAT, 32'h02);
      i2s_stop;
      wr(R_CLKDIV, 32'h0000_0203);
      rd(R_CLKDIV, 32'h0000_0203);
      wr(R_CLKDIV, 32'h0);

      // Write-only and unmapped offsets read 0; writes there change nothing
      rd(R_TXDATA, 32'h0);
      rd(R_CMD, 32'h0);
      for (a = 32'h2C; a < WIN_SIZE; a = a + 4)
        if (a != 32'h40)
          begin
             wr(I2S_BASE + a, 32'hFFFF_FFFF);
             rd(I2S_BASE + a, 32'h0);
             if (a > 32'h100) a = a + (WIN_SIZE / 16);
          end
      rd(R_CTRL, 32'h0);
      rd(R_THRESH, 32'h0);
      rd(R_IRQ_EN, 32'h0);
      rd(R_FORMAT, 32'h2);
      rd(R_INFO, INFO_VALUE);
      stimulus_done = 1;
   end
