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
// Module Description : Register read / write: random byte, half-word and
//                      word writes to every RW register and to the _SET /
//                      _CLR aliases, then every register read back against
//                      the bench's register model (byte lanes, the bits a
//                      build stores, XFER[7] storing 0, the absent receive
//                      fields reading 0); writes to CFG, STATUS and to
//                      unmapped offsets change nothing.
//
// Doc "Register map".
//----------------------------------------------------------------------------

integer    i, r;
reg [31:0] addr, d;
reg  [1:0] sz;
reg [31:0] targets [0:12];

task check_all;
   begin
      rd(R_CFG,    CFG_VALUE);
      rd(R_CTRL,   {21'h0, m_ctrl});
      rd(R_CLKDIV, {12'h0, m_clkdiv[15:12], 4'h0, m_clkdiv[11:0]});
      rd(R_CSCFG,  {12'h0, m_cscfg});
      rd(R_XFER,   {16'h0, m_xfer});
      rd(R_THRESH, {7'h0, m_thresh_rx, 7'h0, m_thresh_tx});
      rd(R_IRQ_EN, {25'h0, m_irq_en});
      rd(R_CTRL_SET, 32'h0);
      rd(R_IRQ_EN_CLR, 32'h0);
      rd(SPI_BASE + 32'h40, 32'h0);
   end
endtask

initial
   begin
      wait_reset_done(5);
      targets[0]  = R_CTRL;    targets[1]  = R_CTRL_SET;   targets[2]  = R_CTRL_CLR;
      targets[3]  = R_CLKDIV;  targets[4]  = R_CSCFG;      targets[5]  = R_XFER;
      targets[6]  = R_THRESH;  targets[7]  = R_IRQ_EN;     targets[8]  = R_IRQ_EN_SET;
      targets[9]  = R_IRQ_EN_CLR; targets[10] = R_CFG;     targets[11] = R_STATUS;
      targets[12] = SPI_BASE + 32'h48;
      for (i = 0; i < 300; i = i + 1)
        begin
           r  = $urandom % 13;
           sz = $urandom % 3;
           addr = targets[r] + ((sz == SZ_B) ? ($urandom % 4) : (sz == SZ_H) ? 2 * ($urandom % 2) : 0);
           d  = $urandom;
           // keep EN clear: no transfer starts, the pins follow the idle levels
           if (r <= 2 && addr[1:0] == 2'b00) d[0] = (r == 2) ? 1'b1 : 1'b0;
           apb_write(1, MACHINE, addr, d, sz, OK);
           if (i % 10 == 0) check_all;
        end
      check_all;
      // PENABLE without PSEL is not a transfer
      apb_flush;
      @(negedge free_clk); penable = 1'b1; pwrite = 1'b1; paddr = R_CTRL[ADDRW-1:0]; pwdata = 32'h7FF; pstrb = 4'hF;
      @(negedge free_clk); penable = 1'b0;
      check_all;
      // the aliases on single bits
      wr(R_CTRL, 32'h0);
      wr(R_CTRL_SET, 32'h402);  rd(R_CTRL, {21'h0, m_ctrl});
      chk(m_ctrl == 11'h402, "CTRL_SET sets CPOL and BSWAP");
      wr(R_CTRL_CLR, 32'h002);  rd(R_CTRL, {21'h0, m_ctrl});
      apb_write(1, MACHINE, R_CTRL_SET + 1, 32'h04, SZ_B, OK); rd(R_CTRL, {21'h0, m_ctrl});
      chk(m_ctrl == 11'h400, "a byte write to CTRL_SET's lane 1 sets bit 10");
      wr(R_IRQ_EN, 32'h0);
      apb_write(1, MACHINE, R_IRQ_EN_SET, 32'h7F, SZ_W, OK); rd(R_IRQ_EN, {25'h0, m_irq_en});
      apb_write(1, MACHINE, R_IRQ_EN_CLR + 1, 32'hFF, SZ_B, OK); rd(R_IRQ_EN, {25'h0, m_irq_en});
      chk(m_irq_en == IRQ_MASK_TB, "IRQ_EN_CLR lane 1 changes nothing");
      wr(R_IRQ_EN, 32'h0);
      wr(R_CTRL, 32'h10);
      stimulus_done = 1;
   end
