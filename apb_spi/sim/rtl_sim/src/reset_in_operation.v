//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    reset_in_operation
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : reset_in_operation.v
// Module Description : Reset during each kind of entry (a transmit frame, a
//                      receive entry, a DUMMY, a POLL) and with a select
//                      held: the pins return to their reset levels, every
//                      register and FIFO to its reset value, and the next
//                      transaction runs normally, in both reset styles.
//
// Doc "Ports" (pins out of reset), "Register map".
//----------------------------------------------------------------------------

integer    k, i;

initial
   begin
      wait_reset_done(5);
      for (k = 0; k < 5; k = k + 1)
        begin
           cs_set(8'h00, 1, 1, 1);
           spi_setup(C_IDLE_HIGH | C_CPOL | C_IO23_REL, 4, 0);
           case (k)
             0: ent_tx(32, $urandom, 1'b0);
             1: if (RX_EN != 0) begin for (i = 0; i < 30; i = i + 1) rq_push($urandom); ent_rx(8, 30, 1'b0); end
                else ent_tx(32, $urandom, 1'b0);
             2: ent(xa(KDUMMY, 8, 1, 1'b0, 1'b0, 1'b0, 0), 99);
             3: if (POLL_USE) begin for (i = 0; i < 30; i = i + 1) rq_push(32'hFF); ent(xa(KPOLL, 8, 1, 1'b0, 1'b0, 1'b0, 0), {8'hFF, 8'hFF, 16'd29}); end
                else ent_tx(32, $urandom, 1'b0);
             default: ent_tx(8, $urandom, 1'b1);
           endcase
           repeat (150) @(posedge free_clk);
           tb_reset_pulse;
           rq_rd = rq_wr;
           repeat (5) @(posedge free_clk);
           chk((spi_sck === 1'b0) && (spi_cs === {CS_NR{1'b1}}) && (spi_io_oe === 4'b1101) && (spi_io_o === 4'b1101),
               "pins at their reset levels");
           rd(R_CTRL, 32'h10);
           rd(R_STATUS, 32'h4000_0000);
           rd(R_CLKDIV, 32'h0);
           chk(apb_spi_inst0.tx_level == 0 && apb_spi_inst0.rx_level == 0, "FIFOs empty");
           spi_setup(C_IDLE_HIGH, 1, 0);
           ent_tx(16, 32'hBEEF, 1'b0);
           if (RX_EN != 0) begin rq_push(32'h5A); ent_rx(8, 1, 1'b0); end
           wait_idle(100000);
           rx_drain;
        end
      stimulus_done = 1;
   end
