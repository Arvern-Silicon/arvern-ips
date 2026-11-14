//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          File:      spi_flash.v (included in tb_apb_spi)
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// A quad SPI NOR flash of the S25FL128S class (dev_mode 2), on chip select
// fl_cs (active low), modes 0 and 3: samples on the rising clock edge,
// launches on the falling one. Commands, from the instruction byte on IO0:
//
//   06h WREN    write enable
//   05h RDSR1   status register 1 ({6'b0, WEL, WIP}) on IO1, repeated
//   03h READ    24-bit address on IO0, data on IO1
//   32h QPP     quad page program: 24-bit address on IO0, data on IO0-IO3
//               (needs WEL; WIP then reads 1 for fl_busy status reads)
//   EBh QIOR    quad I/O read: 24-bit address and the 8-bit mode on
//               IO0-IO3, fl_dummy dummy clocks, data on IO0-IO3; mode bits
//               Axh keep the flash in continuous read mode, where the next
//               transaction starts with the address (S25FL128S §10.9)
//
// The flash checks the transaction ends on a byte boundary for commands and
// write data (§4.2), and that HOLD# (IO3) is high whenever it samples IO0
// in single-lane phases (§3.9).
//----------------------------------------------------------------------------

reg   [7:0] fl_mem [0:255];                    // 256-byte array (addresses wrap)
integer     fl_cs;                             // the flash's select
integer     fl_dummy;                          // QIOR dummy clocks
integer     fl_busy;                           // status reads with WIP after a program
reg         fl_sel;
reg         fl_wel;
integer     fl_wip;                            // status reads left with WIP set
reg         fl_cont;                           // continuous read mode
integer     fl_ph;                             // 0 instruction, 1 address, 2 mode, 3 dummy, 4 data out, 5 data in, 6 status, 7 ignore
reg   [7:0] fl_ins;
reg  [23:0] fl_addr;
reg   [7:0] fl_modeb;
integer     fl_n;                              // clocks of the phase
reg   [7:0] fl_byte;                           // byte being shifted
integer     fl_clks;                           // clocks of the transaction
reg         fl_quad;                           // the data phase is quad
reg   [7:0] fl_ob;                             // byte being sent
integer     fl_obit;                           // bits of it left
integer     i_fl;

initial
  begin
     for (i_fl = 0; i_fl < 256; i_fl = i_fl + 1) fl_mem[i_fl] = i_fl ^ 8'h5A;
     fl_cs = 0; fl_dummy = 1; fl_busy = 3;
     fl_sel = 0; fl_wel = 0; fl_wip = 0; fl_cont = 0;
  end

task fl_cs_assert;
   begin
      if (!t_none && (t_sel == fl_cs))
        begin
           fl_sel  = 1;
           fl_clks = 0;
           fl_n    = 0;
           fl_byte = 8'h0;
           fl_ph   = fl_cont ? 1 : 0;
           fl_ins  = fl_cont ? 8'hEB : 8'h00;
           fl_addr = 24'h0;
           dev_drive(4'h0, 4'h0);
        end
   end
endtask

task fl_cs_release;
   begin
      if (fl_sel)
        begin
           if (((fl_ph == 0) || (fl_ph == 5) || (fl_ph == 1)) && (fl_clks % 8 != 0) && (fl_ins != 8'hEB)) begin
              $display("ERROR: spi_flash: select released after %0d clocks, not a byte boundary %t ns", fl_clks, $time);
              error = error + 1;
           end
           if (fl_ins == 8'h32 && fl_ph == 5 && fl_wel) begin fl_wip = fl_busy; fl_wel = 0; end
           if (fl_ins == 8'hEB && fl_ph >= 3) fl_cont = (fl_modeb[7:4] == 4'hA);
        end
      fl_sel = 0;
      dev_drive(4'h0, 4'h0);
   end
endtask

// Rising edge
task fl_sample;
   reg [3:0] nib;
   begin
      if (fl_sel)
        begin
           fl_clks = fl_clks + 1;
           nib = spi_pad;
           case (fl_ph)
             0: begin
                   if (spi_pad[3] !== 1'b1) begin
                      $display("ERROR: spi_flash: HOLD# (IO3) %b during the instruction %t ns", spi_pad[3], $time);
                      error = error + 1;
                   end
                   fl_byte = {fl_byte[6:0], nib[0]};
                   fl_n = fl_n + 1;
                   if (fl_n == 8)
                     begin
                        fl_ins = fl_byte; fl_n = 0;
                        case (fl_byte)
                          8'h06: begin fl_wel = 1; fl_ph = 7; end
                          8'h05: begin fl_ph = 6; fl_ob = {6'h0, fl_wel, fl_wip != 0}; fl_obit = 8;
                                       if (fl_wip > 0) fl_wip = fl_wip - 1; end
                          8'h03, 8'h32, 8'hEB: fl_ph = 1;
                          default: fl_ph = 7;
                        endcase
                     end
                end
             1: begin
                   if (fl_ins == 8'hEB) begin fl_addr = {fl_addr[19:0], nib}; fl_n = fl_n + 4; end
                   else                 begin fl_addr = {fl_addr[22:0], nib[0]}; fl_n = fl_n + 1; end
                   if (fl_n == 24)
                     begin
                        fl_n = 0;
                        if (fl_ins == 8'hEB) fl_ph = 2;
                        else if (fl_ins == 8'h03) begin fl_ph = 4; fl_quad = 0; fl_ob = fl_mem[fl_addr[7:0]]; fl_obit = 8; end
                        else begin fl_ph = 5; fl_byte = 8'h0; end
                     end
                end
             2: begin
                   fl_modeb = {fl_modeb[3:0], nib}; fl_n = fl_n + 4;
                   if (fl_n == 8)
                     begin
                        fl_n = 0;
                        fl_ph = (fl_dummy == 0) ? 4 : 3;
                        fl_quad = 1; fl_ob = fl_mem[fl_addr[7:0]]; fl_obit = 8;
                     end
                end
             3: begin
                   fl_n = fl_n + 1;
                   if (fl_n == fl_dummy) begin fl_n = 0; fl_ph = 4; end
                end
             5: begin
                   fl_byte = {fl_byte[3:0], nib}; fl_n = fl_n + 4;
                   if (fl_n == 8)
                     begin
                        fl_n = 0;
                        if (fl_wel) fl_mem[fl_addr[7:0]] = fl_mem[fl_addr[7:0]] & fl_byte;
                        fl_addr[7:0] = fl_addr[7:0] + 8'd1;
                     end
                end
             default: ;
           endcase
        end
   end
endtask

// Falling edge
task fl_launch;
   begin
      if (fl_sel)
        case (fl_ph)
          4: begin
                if (fl_quad)
                  begin
                     dev_drive(4'hF, (fl_obit == 8) ? fl_ob[7:4] : fl_ob[3:0]);
                     fl_obit = fl_obit - 4;
                  end
                else
                  begin
                     dev_drive(4'h2, {2'b00, fl_ob[fl_obit - 1], 1'b0});
                     fl_obit = fl_obit - 1;
                  end
                if (fl_obit == 0) begin fl_addr[7:0] = fl_addr[7:0] + 8'd1; fl_ob = fl_mem[fl_addr[7:0]]; fl_obit = 8; end
             end
          6: begin
                dev_drive(4'h2, {2'b00, fl_ob[fl_obit - 1], 1'b0});
                fl_obit = fl_obit - 1;
                if (fl_obit == 0) begin fl_ob = {6'h0, fl_wel, fl_wip != 0}; fl_obit = 8; if (fl_wip > 0) fl_wip = fl_wip - 1; end
             end
          default: dev_drive(4'h0, 4'h0);
        endcase
   end
endtask
