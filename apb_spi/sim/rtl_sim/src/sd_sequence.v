//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    sd_sequence
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : sd_sequence.v
// Module Description : An SD card in SPI mode (sd_card.v) driven the way the
//                      driver does it, with entries only: power-up clocks
//                      with no select and data in high, CMD0, CMD8, CMD55 /
//                      ACMD41 until ready, CMD58 at 396.8 kHz; then, at
//                      pclk / 2 with RX_DLY = 1, a single-block write
//                      (CMD24, token, 128 byte-swapped words, CRC, data
//                      response, busy poll), its read back (CMD17, R1 poll,
//                      token poll, 128 words, CRC), a two-block write
//                      (CMD25, 0xFC tokens, stop-tran 0xFD, two-step busy
//                      poll) and its read back (CMD18, CMD12, stuff byte,
//                      R1b). Every block read must equal what was written.
//
// Doc "Integration examples", "Software"; SD_PLS_v6.00 chapter 7.
//----------------------------------------------------------------------------

integer    i, cur, tries, blk, w;
reg [31:0] v;
reg  [7:0] wbuf [0:1535];

// A command: six bytes under the select, then the R1 poll (POLLMASK 0x80)
task sd_cmd_send;
   input  [5:0] idx;
   input [31:0] arg;
   input  [7:0] crc;
   input        hold;                         // keep the select after R1
   begin
      ent_tx(8, {26'h0, 2'b01, idx}, 1'b1);
      ent_tx(8, arg[31:24], 1'b1);
      ent_tx(8, arg[23:16], 1'b1);
      ent_tx(8, arg[15:8],  1'b1);
      ent_tx(8, arg[7:0],   1'b1);
      ent_tx(8, crc,        1'b1);
            ent_poll(8, 16, hold, 8'h80, 8'h80);
   end
endtask

task sd_trail;                                // eight clocks with the select released
   begin
      ent(xa(KDUMMY, 8, 1, 1'b0, 1'b0, 1'b1, 0), 7);
   end
endtask

task sd_done;                                 // wait, drain, return the first word of the command
   begin
      wait_idle(2000000);
      rx_drain;
   end
endtask

initial
   begin
      wait_reset_done(5);
      if (RX_EN == 0 || !POLL_USE) tb_skip("needs the receive path and POLL");
      dev_mode = 1;
      ent_drain = 1'b1;
      // identification clock: 50 MHz / (2 * 63) = 396.8 kHz
      clk_set(63, 1);
      cs_set(8'h00, 1, 1, 1);
      ctrl_wr(C_EN | C_IDLE_HIGH | C_BSWAP);
      // power-up: 80 clocks with no select and data in high
      ent(xa(KDUMMY, 8, 1, 1'b0, 1'b0, 1'b1, 0), 79);
      // CMD0
      cur = x_rd;
      sd_cmd_send(6'd0, 32'h0, 8'h95, 1'b0); sd_trail; sd_done;
      chk32(rx_got[cur], 32'h01, "CMD0 R1 (idle)");
      // CMD8
      cur = x_rd;
      sd_cmd_send(6'd8, 32'h1AA, 8'h87, 1'b1);
      ent_rx(32, 1, 1'b0); sd_trail; sd_done;
      chk32(rx_got[cur], 32'h01, "CMD8 R1");
      chk32(rx_got[cur + 1], 32'hAA010000, "CMD8 R7 tail (byte-swapped)");
      // ACMD41 until ready
      tries = 0; v = 32'h01;
      while (v != 32'h00 && tries < 10)
        begin
           cur = x_rd + 1;
           sd_cmd_send(6'd55, 32'h0, 8'hFF, 1'b0); sd_trail;
           sd_cmd_send(6'd41, 32'h40000000, 8'hFF, 1'b0); sd_trail; sd_done;
           v = rx_got[cur];
           tries = tries + 1;
        end
      chk(v == 32'h00, "ACMD41 reaches ready");
      chk(tries == sd_acmd_busy, "ACMD41 tries");
      // CMD58: OCR with CCS
      cur = x_rd;
      sd_cmd_send(6'd58, 32'h0, 8'hFF, 1'b1);
      ent_rx(32, 1, 1'b0); sd_trail; sd_done;
      chk32(rx_got[cur + 1], 32'h0080FFC0, "CMD58 OCR (byte-swapped)");
      // full speed
      clk_set(1, 1);
      // CMD24: one block
      for (i = 0; i < 512; i = i + 1) wbuf[i] = $urandom;
      cur = x_rd;
      sd_cmd_send(6'd24, 32'd3, 8'hFF, 1'b1);
      ent_tx(8, 32'hFE, 1'b1);
      for (w = 0; w < 128; w = w + 1)
        ent(xa(KTX, 32, 1, 1'b0, 1'b1, 1'b0, 0), {wbuf[4*w+3], wbuf[4*w+2], wbuf[4*w+1], wbuf[4*w]});
      ent_tx(16, 32'hFFFF, 1'b1);
      ent_rx(8, 1, 1'b1);
            ent_poll(8, 4000, 1'b0, 8'hFF, 8'h00);
      sd_trail; sd_done;
      chk32(rx_got[cur + 1] & 32'h1F, 32'h05, "CMD24 data response: accepted");
      chk32(rx_got[cur + 2], 32'hFF, "CMD24 busy ends");
      for (i = 0; i < 512; i = i + 1)
        if (sd_mem[3 * 512 + i] !== wbuf[i]) begin
           $display("ERROR: CMD24 byte %0d: card 0x%h, written 0x%h %t ns", i, sd_mem[3 * 512 + i], wbuf[i], $time);
           error = error + 1;
        end
      // CMD17: read it back
      cur = x_rd;
      sd_cmd_send(6'd17, 32'd3, 8'hFF, 1'b1);
            ent_poll(8, 1000, 1'b1, 8'hFF, 8'hFF);
      ent(xa(KRX, 32, 1, 1'b0, 1'b1, 1'b0, 0), 127);
      ent_rx(16, 1, 1'b0);
      sd_trail; sd_done;
      chk32(rx_got[cur], 32'h00, "CMD17 R1");
      chk32(rx_got[cur + 1], 32'hFE, "CMD17 start-block token");
      for (w = 0; w < 128; w = w + 1)
        chk32(rx_got[cur + 2 + w], {wbuf[4*w+3], wbuf[4*w+2], wbuf[4*w+1], wbuf[4*w]}, "CMD17 data word");
      // CMD25: blocks 5 and 6
      for (i = 0; i < 1024; i = i + 1) wbuf[512 + i] = $urandom;
      cur = x_rd;
      sd_cmd_send(6'd25, 32'd5, 8'hFF, 1'b1);
      for (blk = 0; blk < 2; blk = blk + 1)
        begin
           ent_tx(8, 32'hFC, 1'b1);
           for (w = 0; w < 128; w = w + 1)
             ent(xa(KTX, 32, 1, 1'b0, 1'b1, 1'b0, 0),
                 {wbuf[512+512*blk+4*w+3], wbuf[512+512*blk+4*w+2], wbuf[512+512*blk+4*w+1], wbuf[512+512*blk+4*w]});
           ent_tx(16, 32'hFFFF, 1'b1);
           ent_rx(8, 1, 1'b1);
                      ent_poll(8, 4000, 1'b1, 8'hFF, 8'h00);
        end
      ent_tx(8, 32'hFD, 1'b1);
            ent_poll(8, 16, 1'b1, 8'hFF, 8'hFF);                  // busy may start one byte late
            ent_poll(8, 4000, 1'b0, 8'hFF, 8'h00);
      sd_trail; sd_done;
      chk32(rx_got[cur + 1] & 32'h1F, 32'h05, "CMD25 block 0 accepted");
      chk32(rx_got[cur + 3] & 32'h1F, 32'h05, "CMD25 block 1 accepted");
      chk32(rx_got[cur + 6], 32'hFF, "CMD25 stop: busy ends");
      for (i = 0; i < 1024; i = i + 1)
        if (sd_mem[5 * 512 + i] !== wbuf[512 + i]) begin
           $display("ERROR: CMD25 byte %0d: card 0x%h, written 0x%h %t ns", i, sd_mem[5 * 512 + i], wbuf[512 + i], $time);
           error = error + 1;
        end
      // CMD18: read both, CMD12 to stop
      cur = x_rd;
      sd_cmd_send(6'd18, 32'd5, 8'hFF, 1'b1);
      for (blk = 0; blk < 2; blk = blk + 1)
        begin
                      ent_poll(8, 1000, 1'b1, 8'hFF, 8'hFF);
           ent(xa(KRX, 32, 1, 1'b0, 1'b1, 1'b0, 0), 127);
           ent_rx(16, 1, 1'b1);
        end
      // CMD12: six bytes, one frame for the stuff byte, R1 poll, busy poll
      ent_tx(8, 32'h4C, 1'b1);
      for (i = 0; i < 4; i = i + 1) ent_tx(8, 32'h00, 1'b1);
      ent_tx(8, 32'hFF, 1'b1);
      ent_rx(8, 1, 1'b1);
            ent_poll(8, 16, 1'b1, 8'h80, 8'h80);
            ent_poll(8, 4000, 1'b0, 8'hFF, 8'h00);
      sd_trail; sd_done;
      chk32(rx_got[cur + 1 + 2 * 130], 32'h3C, "CMD12 stuff byte skipped");
      chk32(rx_got[cur + 2 + 2 * 130], 32'h00, "CMD12 R1");
      chk32(rx_got[cur + 3 + 2 * 130], 32'hFF, "CMD12 busy ends");
      for (blk = 0; blk < 2; blk = blk + 1)
        for (w = 0; w < 128; w = w + 1)
          chk32(rx_got[cur + 1 + blk * 130 + 1 + w],
                {wbuf[512+512*blk+4*w+3], wbuf[512+512*blk+4*w+2], wbuf[512+512*blk+4*w+1], wbuf[512+512*blk+4*w]},
                "CMD18 data word");
      stimulus_done = 1;
   end
