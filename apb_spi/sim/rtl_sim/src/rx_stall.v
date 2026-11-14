//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    rx_stall
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : rx_stall.v
// Module Description : Receive stall: a receive entry longer than the FIFO
//                      fills it and stalls between frames with the select
//                      held and SCK idle (STATUS.STALL), a pop lets one more
//                      frame through, a capturing entry at the head of the
//                      transmit FIFO waits for room before it starts; with
//                      1-bit frames and a long receive delay several frames
//                      are in flight and the FIFO never overflows.
//
// Doc "Transmit, receive and status".
//----------------------------------------------------------------------------

integer    i, nf, ovf;
integer    max_if = 0;                       // most frames in flight seen

always @(posedge pclk)
  if ((presetn === 1'b1) && (tb_inflight > max_if)) max_if = tb_inflight;
reg [31:0] v;

always @(posedge pclk)
  if ((RX_EN != 0) && tb_rst_done && apb_spi_inst0.rx_valid && (apb_spi_inst0.rx_level == RX_DEPTH) && !apb_spi_inst0.rx_flush && (presetn === 1'b1))
    begin
       $display("ERROR: a word pushed into a full receive FIFO %t ns", $time);
       error = error + 1;
    end

initial
   begin
      wait_reset_done(5);
      if (RX_EN == 0) tb_skip("needs the receive path");
      ent_drain = 0;
      cs_set(8'h00, 1, 1, 1);
      spi_setup(C_IDLE_HIGH, 1, 1);
      // a stall between frames
      for (i = 0; i < RX_DEPTH + 6; i = i + 1) rq_push($urandom);
      ent_rx(8, RX_DEPTH + 6, 1'b1);
      for (i = 0; i < 100000 && !apb_spi_inst0.core_stall; i = i + 1) @(posedge free_clk);
      chk(apb_spi_inst0.core_stall === 1'b1, "stall between frames");
      repeat (20) @(posedge free_clk);
      chk(apb_spi_inst0.rx_level == RX_DEPTH, "receive FIFO full");
      rdv(R_STATUS, v);
      chk(v[29] === 1'b1 && v[28] === 1'b1, "STATUS: STALL with the select held");
      nf = n_frames;
      repeat (100) @(posedge free_clk);
      chk(n_frames == nf, "no frame while stalled");
      rx_pop_chk(1);
      repeat (60) @(posedge free_clk);
      chk(n_frames == nf + 1, "one pop lets one frame through");
      rx_pop_chk(RX_DEPTH + 5);
      // a capturing entry waits at the head for room
      for (i = 0; i < RX_DEPTH; i = i + 1) rq_push($urandom);
      ent_rx(8, RX_DEPTH, 1'b1);
      wait_quiet(100000);
      rq_push($urandom);
      ent_rx(8, 1, 1'b0);
      repeat (100) @(posedge free_clk);
      chk(apb_spi_inst0.core_stall === 1'b1 && apb_spi_inst0.tx_level == 1, "a capturing entry waits for room");
      rx_pop_chk(RX_DEPTH + 1);
      wait_idle(100000);
      // 1-bit frames: several in flight (receive delay 3 cycles, frame 2 cycles)
      for (i = 0; i < 4 * RX_DEPTH; i = i + 1) rq_push($urandom);
      ent_rx(1, 4 * RX_DEPTH, 1'b0);
      repeat (300) @(posedge free_clk);
      ent_drain = 1;
      wait_idle(100000);
      rx_drain;
      // 1-bit frames at RX_DLY 15 (round trip 294 ns): up to nine frames in flight
      max_if = 0;
      dev_rt = 294.0;
      clk_set(1, 15);
      for (i = 0; i < 40; i = i + 1) rq_push($urandom);
      ent_rx(1, 40, 1'b0);
      wait_idle(100000);
      rx_drain;
      chk(max_if >= 8 || RX_DEPTH < 8, "eight or more frames in flight");
      dev_rt = 0.0;
      stimulus_done = 1;
   end
