//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_rx_glitch
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_rx_glitch
// Module Description : A single-sample glitch on RX must not corrupt the byte --
//                      the 3-tap majority filter outvotes it.
//
//   `uart_autobaud_glitch` sounds like it covers this and does not: its glitch is a
//   pre-sync disturbance aimed at the auto-baud arming FSM, and its own comment says it
//   is deliberately "wide enough to pass the 3-tap majority filter". So the filter
//   itself had no test, and bypassing it changed nothing observable.
//
//   Two things ride on it. A glitch that reaches rxd_maj is sampled as data, and it
//   also raises rxd_edge -- which re-centres the bit counter mid-byte, so the damage is
//   not limited to the bit that was hit.
//
//   The glitch is one clk period wide (one of three taps, so always outvoted) and its
//   position is SWEPT across a whole bit, because the sample instant is one clk wide
//   and a coarser placement can step straight over it.
//
//   BOTH polarities are swept, and that is not symmetry for its own sake: the filter
//   can degrade asymmetrically. Dropping its third term leaves a function that still
//   outvotes a HIGH glitch but passes a LOW one straight through, so a sweep on a
//   0-valued bit alone reports a healthy filter. 0x55 gives adjacent bits of each
//   value -- bit 3 = 0 (high glitch), bit 2 = 1 (low glitch) -- and its alternating
//   pattern means a corrupted sample changes the byte instead of being masked by an
//   identical neighbour.
//
//   Non-vacuity is established by mutation, not by an internal precondition: with
//   `rxd_maj_nxt` reduced to `rx_sync` this test fails. If the glitch ever stopped
//   landing inside the bit, that mutation would start surviving again.
//----------------------------------------------------------------------------

reg [7:0] last_rx;
reg [7:0] rx_count;

initial begin
   last_rx  = 8'h00;
   rx_count = 8'h00;
end

always @(posedge free_clk)
   if (dut.g_uart.u_dtm.rx_valid) begin
      last_rx  <= dut.g_uart.u_dtm.rx_data;
      rx_count <= rx_count + 8'd1;
   end

// One byte, with a one-clk inversion at a chosen offset into a chosen data bit.
task uart_send_byte_glitch;
    input [7:0]   b;
    input integer gbit;
    input real    goff_ns;
    integer i;
    begin
        uart_rx = 1'b0;  #(host_bit_ns);                       // start bit
        for (i = 0; i < 8; i = i + 1) begin
            uart_rx = b[i];
            if (i == gbit) begin
                #(goff_ns);
                uart_rx = ~b[i];                               // exactly one clk period
                #(FREE_HALF * 2.0);
                uart_rx = b[i];
                #(host_bit_ns - goff_ns - (FREE_HALF * 2.0));
            end else
                #(host_bit_ns);
        end
        uart_rx = 1'b1;  #(host_bit_ns);                       // stop bit
    end
endtask

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;
      reg [7:0]  prev;
      reg        all_ok;
      integer    k, p, gbit;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);

      // 24 clk/bit exactly. The default host baud carries a seed-derived +/-2 ns jitter
      // term, which would smear the swept glitch position against the clock.
      host_bit_ns   = 24.0 * (FREE_HALF * 2.0);
      slave_latency = 0;

      $display(" ===================================================");
      $display("|  UART: 1-sample RX glitch swept across a bit      |");
      $display(" ===================================================");

      uart_autobaud_sync();

      // The sweep is checked at the byte-assembly boundary (rx_data/rx_valid), upstream
      // of the command interpreter. The interpreter still consumes the stream: 0x55 is
      // SYNC, and the six bytes after it form a command whose op is 0x55 & 3 = READ, so
      // the traffic is benign but it does queue responses and can end mid-frame. Hence
      // the break/re-sync before the link-health check below.
      all_ok = 1'b1;
      for (p = 0; p < 2; p = p + 1) begin
         gbit = p ? 2 : 3;                      // bit3 = 0 -> high glitch, bit2 = 1 -> low
         for (k = 0; k < 23; k = k + 1) begin
            prev = rx_count;
            uart_send_byte_glitch(8'h55, gbit, k * 10.0);
            #(2.0 * host_bit_ns);
            if ((rx_count !== (prev + 8'd1)) || (last_rx !== 8'h55)) begin
               all_ok = 1'b0;
               $display("  bit%0d glitch@%0d ns: count %0d->%0d, byte 0x%02h (expected +1, 0x55)",
                        gbit, k * 10, prev, rx_count, last_rx);
            end
         end
      end
      check_eq("glitch_sweep", all_ok, 1'b1);

      // The link is still usable after 23 disturbed bytes. Flush the interpreter and
      // re-lock first, so this checks recovery rather than the sweep's leftovers.
      uart_break;
      uart_autobaud_sync();

      dmi_uart(7'h10, OP_WRITE, 32'hDEAD_BEEF, st, rd);
      check_eq("post_wst", st, OP_SUCCESS);
      dmi_uart(7'h10, OP_READ,  32'h0,         st, rd);
      check_eq("post_rd",  rd, 32'hDEAD_BEEF);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
