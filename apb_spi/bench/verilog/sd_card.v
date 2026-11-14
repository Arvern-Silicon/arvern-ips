//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          File:      sd_card.v (included in tb_apb_spi)
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// An SD memory card in SPI mode (dev_mode 1), byte oriented as the card is
// (SD Physical Layer Simplified Specification, chapter 7): chip select
// spi_cs[0] active low, data in on IO0 (CMD), data out on IO1 (DAT0),
// sampled on the rising clock edge, launched on the falling one.
//
//   - Power-up: counts the clocks with the select high and data in high
//     before the first command; the first CMD0 needs at least 74 (§6.4.1.1).
//   - Bytes are counted from the select's assertion; a release that is not
//     on a byte boundary is an error (§7.2: "Every command or data token
//     shall be aligned with 8-clock cycle boundary").
//   - CMD0 (CRC 0x95 required), CMD8 (R7, CRC 0x87 required), CMD55 and
//     ACMD41 (idle for sd_acmd_busy tries), CMD58 (R3, CCS = 1), CMD17 /
//     CMD18 (block reads: sd_nac bytes of 0xFF, then 0xFE, 512 bytes, CRC),
//     CMD12 (one stuff byte with MSB 0, R1, busy), CMD24 / CMD25 (token 0xFE
//     / 0xFC, data, CRC, data response 0xE5, sd_busy busy bytes; 0xFD stops
//     a multi-block write, busy starting one byte later), any other command
//     answers R1 with the illegal-command bit. Every response comes after
//     sd_ncr bytes of 0xFF.
//   - 16 blocks of 512 bytes, block-addressed (an SDHC card).
//----------------------------------------------------------------------------

localparam SD_BLKS = 16;
localparam SD_QN   = 8192;

reg   [7:0] sd_mem [0:SD_BLKS*512-1];
reg   [7:0] sd_q   [0:SD_QN-1];                // bytes to send
integer     sd_qw, sd_qr;
integer     sd_ncr, sd_nac, sd_busy, sd_acmd_busy;
integer     sd_init_clks;                      // power-up clocks counted
reg         sd_spi;                            // in SPI mode
reg         sd_idle;                           // R1 idle bit
reg         sd_app;                            // the next command is an ACMD
integer     sd_acmd_n;                         // ACMD41 tries
reg   [7:0] sd_ob;                             // byte on the data-out line
integer     sd_obit;                           // its bit on the line
reg   [7:0] sd_rb;                             // byte being received
integer     sd_rbit;                           // its bits received
reg  [47:0] sd_cmd;                            // command being received
integer     sd_cmdn;                           // its bytes received
integer     sd_mode;                           // 0 commands, 1 command bytes, 2 write token, 3 write data, 4 multi-block read
reg         sd_multi;                          // multi-block write
integer     sd_blk;                            // block of a read or write
integer     sd_wn;                             // write data bytes received
reg         sd_sel;                            // selected
integer     sd_ncmd;                           // commands received
integer     i_sd;

initial
  begin
     for (i_sd = 0; i_sd < SD_BLKS * 512; i_sd = i_sd + 1)
       sd_mem[i_sd] = (i_sd * 7 + (i_sd >> 9) * 13) & 8'hFF;
     sd_reset_card;
  end

task sd_reset_card;
   begin
      sd_qw = 0; sd_qr = 0;
      sd_ncr = 2; sd_nac = 5; sd_busy = 6; sd_acmd_busy = 3;
      sd_init_clks = 0;
      sd_spi = 0; sd_idle = 1; sd_app = 0; sd_acmd_n = 0;
      sd_ob = 8'hFF; sd_obit = 7;
      sd_rb = 8'h0; sd_rbit = 0;
      sd_cmdn = 0; sd_mode = 0; sd_multi = 0; sd_blk = 0; sd_wn = 0;
      sd_sel = 0; sd_ncmd = 0;
   end
endtask

task sd_put;
   input [7:0] b;
   begin
      sd_q[sd_qw % SD_QN] = b;
      sd_qw = sd_qw + 1;
   end
endtask

task sd_fill;
   input integer n;
   integer i;
   begin
      for (i = 0; i < n; i = i + 1) sd_put(8'hFF);
   end
endtask

task sd_r1;
   input [7:0] flags;
   begin
      sd_fill(sd_ncr);
      sd_put({7'h0, sd_idle} | flags);
   end
endtask

task sd_block;
   input integer blk;
   integer i;
   begin
      sd_fill(sd_nac);
      sd_put(8'hFE);
      for (i = 0; i < 512; i = i + 1) sd_put(sd_mem[(blk % SD_BLKS) * 512 + i]);
      sd_put(8'h00); sd_put(8'h00);           // CRC16 (CRC-off mode: not checked)
   end
endtask

// A whole command received
task sd_command;
   reg [5:0]  idx;
   reg [31:0] arg;
   reg [7:0]  crc;
   begin
      idx = sd_cmd[45:40];
      arg = sd_cmd[39:8];
      crc = sd_cmd[7:0];
      sd_ncmd = sd_ncmd + 1;
      if (!sd_spi && idx != 6'd0)
        begin
           $display("ERROR: sd_card: CMD%0d before CMD0 %t ns", idx, $time);
           error = error + 1;
        end
      if (sd_app && idx == 6'd41)
        begin
           sd_acmd_n = sd_acmd_n + 1;
           if (sd_acmd_n >= sd_acmd_busy) sd_idle = 0;
           sd_r1(8'h00);
        end
      else
        case (idx)
          6'd0: begin
                   if (!sd_spi && sd_init_clks < 74) begin
                      $display("ERROR: sd_card: CMD0 after %0d power-up clocks, at least 74 %t ns", sd_init_clks, $time);
                      error = error + 1;
                   end
                   if (crc !== 8'h95) begin
                      $display("ERROR: sd_card: CMD0 CRC 0x%h, expected 0x95 %t ns", crc, $time);
                      error = error + 1;
                   end
                   sd_spi = 1; sd_idle = 1; sd_acmd_n = 0;
                   sd_r1(8'h00);
                end
          6'd8: begin
                   if (crc !== 8'h87) begin
                      $display("ERROR: sd_card: CMD8 CRC 0x%h, expected 0x87 %t ns", crc, $time);
                      error = error + 1;
                   end
                   sd_r1(8'h00);
                   sd_put(8'h00); sd_put(8'h00); sd_put({4'h0, arg[11:8]}); sd_put(arg[7:0]);
                end
          6'd55: sd_r1(8'h00);
          6'd58: begin
                    sd_r1(8'h00);
                    sd_put(8'hC0); sd_put(8'hFF); sd_put(8'h80); sd_put(8'h00);
                 end
          6'd17: begin sd_r1(8'h00); sd_block(arg); end
          6'd18: begin sd_r1(8'h00); sd_blk = arg; sd_block(sd_blk); sd_blk = sd_blk + 1; sd_mode = 4; end
          6'd12: begin
                    // the byte in progress ends, one stuff byte, then R1b
                    sd_qr = sd_qw;
                    sd_put(8'h3C);
                    sd_r1(8'h00);
                    sd_fill(0);
                    repeat (sd_busy) sd_put(8'h00);
                    sd_mode = 0;
                 end
          6'd24: begin sd_r1(8'h00); sd_blk = arg; sd_multi = 0; sd_mode = 2; end
          6'd25: begin sd_r1(8'h00); sd_blk = arg; sd_multi = 1; sd_mode = 2; end
          default: sd_r1(8'h04);
        endcase
      sd_app = (idx == 6'd55);
   end
endtask

// A byte received on data in
task sd_byte;
   input [7:0] b;
   begin
      case (sd_mode)
        0, 4: if (b[7:6] == 2'b01) begin sd_cmd = {40'h0, b}; sd_cmdn = 1; sd_mode = (sd_mode == 4) ? 5 : 1; end
              else if (sd_mode == 4 && (sd_qw - sd_qr) < 600) begin sd_block(sd_blk); sd_blk = sd_blk + 1; end
        1, 5: begin
                 sd_cmd  = {sd_cmd[39:0], b};
                 sd_cmdn = sd_cmdn + 1;
                 if (sd_cmdn == 6)
                   begin
                      if (sd_mode == 5 && sd_cmd[45:40] != 6'd12) sd_mode = 4; else sd_mode = 0;
                      if (sd_mode == 4) begin
                         $display("ERROR: sd_card: CMD%0d during a multi-block read %t ns", sd_cmd[45:40], $time);
                         error = error + 1;
                      end else sd_command;
                   end
                 else if (sd_mode == 5 && (sd_qw - sd_qr) < 600) begin sd_block(sd_blk); sd_blk = sd_blk + 1; end
              end
        2:    if ((!sd_multi && b == 8'hFE) || (sd_multi && b == 8'hFC)) begin sd_mode = 3; sd_wn = 0; end
              else if (sd_multi && b == 8'hFD) begin sd_put(8'hFF); repeat (sd_busy) sd_put(8'h00); sd_mode = 0; end
              else if (b != 8'hFF) begin
                 $display("ERROR: sd_card: byte 0x%h while waiting for a data token %t ns", b, $time);
                 error = error + 1;
              end
        3:    begin
                 if (sd_wn < 512) sd_mem[(sd_blk % SD_BLKS) * 512 + sd_wn] = b;
                 sd_wn = sd_wn + 1;
                 if (sd_wn == 514)
                   begin
                      sd_put(8'hE5);
                      repeat (sd_busy) sd_put(8'h00);
                      sd_blk = sd_blk + 1;
                      sd_mode = sd_multi ? 2 : 0;
                   end
              end
        default: ;
      endcase
   end
endtask

// The next byte to send
task sd_next_byte;
   begin
      if (sd_qr < sd_qw) begin sd_ob = sd_q[sd_qr % SD_QN]; sd_qr = sd_qr + 1; end
      else sd_ob = 8'hFF;
      sd_obit = 7;
   end
endtask

task sd_cs_assert;
   begin
      if (!t_none && (t_sel == 3'd0))
        begin
           sd_sel  = 1;
           sd_rbit = 0;
           sd_next_byte;
           dev_drive(4'h2, {2'b00, sd_ob[sd_obit], 1'b0});
        end
   end
endtask

task sd_cs_release;
   begin
      if (sd_sel && sd_rbit != 0) begin
         $display("ERROR: sd_card: select released after %0d bits of a byte %t ns", sd_rbit, $time);
         error = error + 1;
      end
      sd_sel = 0;
      dev_drive(4'h0, 4'h0);
   end
endtask

// Falling edge: next bit out
task sd_launch;
   begin
      if (sd_sel)
        begin
           if (sd_obit == 0) sd_next_byte; else sd_obit = sd_obit - 1;
           dev_drive(4'h2, {2'b00, sd_ob[sd_obit], 1'b0});
        end
   end
endtask

// Rising edge: one bit in
task sd_sample;
   begin
      if (!sd_sel)
        begin
           if (!sd_spi && spi_pad[0] === 1'b1) sd_init_clks = sd_init_clks + 1;
        end
      else
        begin
           sd_rb   = {sd_rb[6:0], spi_pad[0]};
           sd_rbit = sd_rbit + 1;
           if (sd_rbit == 8) begin sd_rbit = 0; sd_byte(sd_rb); end
        end
   end
endtask
