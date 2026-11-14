//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    unmapped_info
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : unmapped_info.v
// Module Description : INFO value and read-only behaviour; every unmapped
//                      offset of the window reads 0 and ignores writes, and
//                      no address bit above the register map aliases a
//                      register (each register offset ORed with each address
//                      bit 6..ADDRW-1).
//
// Doc "Register map": the map ends with MDELEG (0x60), the alternate-function
// registers 0x40-0x48 exist per ALT_NR; INFO (0x00) RO "Pin mask: bits
// [GPIO_NR-1:0] set, other bits 0"; "Offsets not listed read 0 and ignore
// writes." Doc "Parameters": ADDRW "the register window is 1 << ADDRW bytes".
// Unmapped accesses from Machine mode are admitted (no PSLVERR): the document
// reserves PSLVERR for accesses MDELEG refuses (doc "Access protection").
//----------------------------------------------------------------------------

`define LONG_TIMEOUT

integer    ii;
integer    bb;
integer    rr;
reg [31:0] off;
reg [31:0] snap_out, snap_oe, snap_en, snap_rise, snap_fall, snap_high, snap_low, snap_pend, snap_inen, snap_wake;
integer    n_walk;

// All-ones writes (word, byte, half) then full-word reads (word, byte, half)
task poke_unmapped;
   input [31:0] o;
   begin
      apb_write(1, MACHINE, GPIO_BASE + o,     32'hFFFFFFFF, SZ_W, OK);
      apb_write(1, MACHINE, GPIO_BASE + o + 1, 32'hFF,       SZ_B, OK);
      apb_write(1, MACHINE, GPIO_BASE + o + 2, 32'hFFFF,     SZ_H, OK);
      apb_read (1, MACHINE, GPIO_BASE + o,     32'h0, SZ_W, 1'b1, OK);
      apb_read (1, MACHINE, GPIO_BASE + o + 3, 32'h0, SZ_B, 1'b1, OK);
      apb_read (1, MACHINE, GPIO_BASE + o + 2, 32'h0, SZ_H, 1'b1, OK);
      n_walk = n_walk + 1;
   end
endtask

task check_snapshot;
   begin
      rd(R_OUTPUT,   snap_out);
      rd(R_OE,       snap_oe);
      rd(R_IRQ_EN,   snap_en);
      rd(R_IRQ_RISE, snap_rise);
      rd(R_IRQ_FALL, snap_fall);
      rd(R_IRQ_HIGH, snap_high);
      rd(R_IRQ_LOW,  snap_low);
      rd(R_IRQ_PEND, snap_pend);
      rd(R_IN_EN,    snap_inen);
      rd(R_WAKE_EN,  snap_wake);
      rd(R_CFG,      CFG_VALUE);
      rd(R_MDELEG,   MDELEG_RST_WORD);
      chk32(gpio_o32,  snap_out,             "gpio_o unchanged by unmapped writes");
      chk32(gpio_oe32, snap_oe,              "gpio_oe_o unchanged by unmapped writes");
      chk32(irq32,     snap_pend & snap_en,  "irq_o unchanged by unmapped writes");
   end
endtask

initial
   begin
      wait_reset_done(5);
      n_walk = 0;

      $display(" ===============================================");
      $display("|   INFO                                        |");
      $display(" ===============================================");
      rd(R_INFO, INFO_VALUE);
      apb_read(1, MACHINE, R_INFO + 0, INFO_VALUE, SZ_B, 1'b1, OK);
      apb_read(1, MACHINE, R_INFO + 3, INFO_VALUE, SZ_B, 1'b1, OK);
      apb_read(1, MACHINE, R_INFO + 2, INFO_VALUE, SZ_H, 1'b1, OK);
      wr(R_INFO, 32'h00000000);
      apb_write(1, MACHINE, R_INFO + 2, 32'hFFFF, SZ_H, OK);
      rd(R_INFO, INFO_VALUE);

      $display(" ===============================================");
      $display("|   KNOWN STATE IN EVERY REGISTER               |");
      $display(" ===============================================");
      snap_out  = 32'h3C3C5A5A & GPIO_MASK;
      snap_oe   = 32'hC3C3A5A5 & GPIO_MASK;
      snap_en   = 32'h0F0F0F0F & GPIO_MASK;
      wr(R_OUTPUT, snap_out);
      wr(R_OE,     snap_oe);
      wr(R_IRQ_EN, snap_en);
      // Latch a rising edge on every pin, then keep a non-trivial mode set
      snap_inen = GPIO_MASK;
      snap_wake = 32'h00FF00FF & GPIO_MASK;
      inputs_on(snap_inen);
      wr(R_WAKE_EN, snap_wake);
      wr(R_IRQ_RISE, 32'hFFFFFFFF);
      pins_set(32'hFFFFFFFF);
      cycles(L_IN + 3);
      snap_rise = 32'h00000001;
      snap_fall = 32'h00000000;
      snap_high = 32'h00000000;
      snap_low  = 32'h00000000;
      snap_pend = GPIO_MASK;
      wr(R_IRQ_RISE, snap_rise);
      check_snapshot;

      $display(" ===============================================");
      $display("|   UNMAPPED OFFSETS                            |");
      $display(" ===============================================");
      // Every word offset above IRQ_LOW up to 0x1FC (the whole window for
      // ADDRW<=9), except the alternate-function registers this ALT_NR
      // provides and the registers 0x4C-0x60
      for (off = 32'h40; (off < WIN_SIZE) && (off < 32'h200); off = off + 4)
        if (!alt_reg_present(off) && !((off >= 32'h4C) && (off <= 32'h60)))
          poke_unmapped(off);
      // Larger windows: every register offset with each upper address bit
      // set, and the last word of the window
      for (bb = 9; bb < ADDRW; bb = bb + 1)
        begin
           for (rr = 0; rr < REG_NR; rr = rr + 1)
             poke_unmapped((32'h1 << bb) | (reg_addr(rr) - GPIO_BASE));
           poke_unmapped((32'h1 << bb) | 32'h60);
        end
      if (WIN_SIZE > 32'h200)
        poke_unmapped(WIN_SIZE - 4);
      $display("unmapped words poked: %0d", n_walk);
      check_snapshot;

      cycles(20);
      stimulus_done = 1;
   end
