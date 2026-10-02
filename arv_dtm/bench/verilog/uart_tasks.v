//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    uart_tasks
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : uart_tasks
// Module Description : UART host-side bus-functional tasks for the arv_dtm_uart
//                      DTM. Black-box: drives only uart_rx, samples only uart_tx,
//                      at the (deliberately slightly off-nominal) host bit period
//                      BIT_NS so the DUT's async RX sampling + 2-FF synchroniser
//                      are exercised. 8-N-1, LSB-first.
//
//   Builds the SAME logical DMI transaction the JTAG DTM uses, just byte-framed:
//     Request  : [0x55][addr][d31:24][d23:16][d15:8][d7:0][op]
//     Response : [status][d31:24][d23:16][d15:8][d7:0]
//----------------------------------------------------------------------------

// All host timing uses host_bit_ns (a live tb variable = BIT_NS by default). An
// auto-baud test retunes host_bit_ns to an off-nominal baud; the DUT measures it
// and, being half-duplex-symmetric, replies at the same baud, so RX tracks too.

//=============================================================================
// Send one byte (host -> DUT), 8-N-1, LSB first.
//=============================================================================
task uart_send_byte;
    input [7:0] b;
    integer i;
    begin
        uart_rx = 1'b0;  #(host_bit_ns);       // start bit
        for (i = 0; i < 8; i = i + 1) begin
            uart_rx = b[i]; #(host_bit_ns);
        end
        uart_rx = 1'b1;  #(host_bit_ns);       // stop bit
    end
endtask

//=============================================================================
// Auto-baud sync handshake: send the single 0x80 char the DUT measures to learn
// the host baud (start + d0..d6 low = 8 bit-times), then consume the 0x80 the DUT
// echoes back at the measured baud as its sync ACK. A matching echo confirms the
// baud round-trip; a mismatch would flag a mis-measured sync frame. Every UART
// session opens with this handshake (the DTM is self-calibrating). fifo_pop
// blocks until the echo arrives, which also serialises the host before commands.
//=============================================================================
task uart_autobaud_sync;
    reg [7:0] echo;
    begin
        uart_send_byte(8'h80);
        fifo_pop(echo);                        // DTM echoes 0x80 at the measured baud
        check_eq("sync_echo", echo, 8'h80);
        #(2.0 * host_bit_ns);
    end
endtask

//=============================================================================
// Host recovery loop: after the host baud changes (or a mis-lock), the DTM is
// locked on the wrong baud. Resend 0x80 several times -- the first few frame-error
// against the stale lock and trip the DTM's re-arm (AB_FERR_LIM consecutive framing
// errors), a later one re-measures and re-locks. Then settle and drain the FIFO
// (the re-lock echo + any framing junk) so the next transaction starts clean.
//=============================================================================
task uart_resync;
    integer k;
    begin
        for (k = 0; k < 8; k = k + 1) begin
            uart_send_byte(8'h80);
            #(2.0 * host_bit_ns);
        end
        #(40.0 * host_bit_ns);                 // let the re-lock echo / junk settle
        while (rx_wr !== rx_rd) rx_rd = (rx_rd + 1) & 255;
    end
endtask

//=============================================================================
// Break / long-low reconnect: hold RX low past the DUT's break threshold
// (AB_BREAK_CLKS system clocks, a FIXED clock count independent of baud) to force a
// locked DTM to UNLOCK its baud AND flush its command interpreter. Unlike uart_resync
// (which needs a baud CHANGE to trip framing errors), this reconnects even at the SAME
// baud and even when a crashed host left the interpreter stranded mid-frame -- and it
// works even from a wildly-corrupt lock, since the watchdog counts clocks, not baud
// periods. The low duration is absolute (not baud-scaled): 1400 clks here, 2x the bench
// AB_BREAK_CLKS=700. Follow with uart_autobaud_sync() to re-lock; drains any RX junk.
//=============================================================================
task uart_break;
    begin
        uart_rx = 1'b0;  #(1400.0 * (FREE_HALF * 2.0));  // long low > break threshold (700 clks)
        uart_rx = 1'b1;  #(4.0  * host_bit_ns);          // release to idle; let the unlock settle
        while (rx_wr !== rx_rd) rx_rd = (rx_rd + 1) & 255;
    end
endtask

//=============================================================================
// Receive one byte (DUT -> host): wait for the start edge, sample mid-bit.
//=============================================================================
task uart_recv_byte;
    output [7:0] b;
    integer i;
    begin
        @(negedge uart_tx);                    // start bit
        #(host_bit_ns + host_bit_ns/2.0);      // advance to the middle of bit 0
        for (i = 0; i < 8; i = i + 1) begin
            b[i] = uart_tx;
            #(host_bit_ns);
        end
    end
endtask

//=============================================================================
// Continuous background receiver: a real host UART is full-duplex and is always
// listening, so it cannot miss an early response (e.g. a fast op=3 reply that
// starts before the request's stop bit finishes). This monitor captures every
// byte the DUT transmits into a FIFO; transactions pop from it.
//=============================================================================
reg [7:0] rx_fifo [0:255];
integer   rx_wr;
integer   rx_rd;

initial begin
    rx_wr = 0;
    rx_rd = 0;
end

initial begin : rx_monitor
    reg [7:0] b;
    forever begin
        uart_recv_byte(b);
        rx_fifo[rx_wr] = b;
        rx_wr = (rx_wr + 1) & 255;
    end
end

task fifo_pop;
    output [7:0] b;
    begin
        wait (rx_wr !== rx_rd);               // block until a byte is available
        b     = rx_fifo[rx_rd];
        rx_rd = (rx_rd + 1) & 255;
    end
endtask

//=============================================================================
// One full DMI transaction over UART.
//   op: 1=read, 2=write, 3=dmihardreset, 0=poll
//=============================================================================
task dmi_uart;
    input  [ABITS-1:0] addr;
    input  [1:0]       op;
    input  [31:0]      data;
    output [1:0]       status;
    output [31:0]      rdata;
    reg [7:0] s, b3, b2, b1, b0;
    begin
        uart_send_byte(8'h55);                          // SYNC
        uart_send_byte({{(8-ABITS){1'b0}}, addr});
        uart_send_byte(data[31:24]);
        uart_send_byte(data[23:16]);
        uart_send_byte(data[15:8]);
        uart_send_byte(data[7:0]);
        uart_send_byte({6'b0, op});
        fifo_pop(s);                                    // [status]
        fifo_pop(b3);                                   // [d31:24]
        fifo_pop(b2);                                   // [d23:16]
        fifo_pop(b1);                                   // [d15:8]
        fifo_pop(b0);                                   // [d7:0]
        status = s[1:0];
        rdata  = {b3, b2, b1, b0};
    end
endtask

//=============================================================================
// Simple pass/fail checker.
//=============================================================================
task check_eq;
    input [127:0] name;
    input [63:0]  got;
    input [63:0]  exp;
    begin
        if (got !== exp) begin
            $display("ERROR: %0s expected 0x%0h got 0x%0h  %0t ns", name, exp, got, $time);
            error = error + 1;
        end else begin
            $display("PASS:  %0s == 0x%0h  %0t ns", name, got, $time);
        end
    end
endtask
