//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    mdeleg_wo_error
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : mdeleg_wo_error.v
// Module Description : Privilege-delegation test for the AHB peripheral
//                      example, exercising the MDELEG register's access
//                      control without error-response handling.
//----------------------------------------------------------------------------

integer ii;
integer jj;
reg     read_resp;
reg     write_resp;
reg [1:0] stored_ii;          // W1: coerced ii  (2'b10 -> 2'b11 by RTL)
reg [1:0] stored_jj;          // W1: coerced jj  (2'b10 -> 2'b11 by RTL)

localparam REGOUT_00 = 32'h00400000;
localparam REGOUT_01 = 32'h00400004;
localparam REGOUT_02 = 32'h00400008;
localparam REGOUT_03 = 32'h0040000C;
localparam REGOUT_04 = 32'h00400010;
localparam REGOUT_05 = 32'h00400014;
localparam REGOUT_06 = 32'h00400018;
localparam REGOUT_07 = 32'h0040001C;

localparam REGIN_08  = 32'h00400020;
localparam REGIN_09  = 32'h00400024;
localparam REGIN_10  = 32'h00400028;
localparam REGIN_11  = 32'h0040002C;
localparam REGIN_12  = 32'h00400030;
localparam REGIN_13  = 32'h00400034;
localparam REGIN_14  = 32'h00400038;
localparam REGIN_15  = 32'h0040003C;

localparam MDELEG    = 32'h00400040;

task init_peripheral;
   begin
      // MDELEG registers
      ahb_write(1, MACHINE, MDELEG,    32'h0000000F, 2, OK);

      // Init REGOUT registers with some random values
      ahb_write(1, MACHINE, REGOUT_00, 32'hA3F29C7B, 2, OK);
      ahb_write(1, MACHINE, REGOUT_01, 32'h4D8E10F2, 2, OK);
      ahb_write(1, MACHINE, REGOUT_02, 32'hB7C51A39, 2, OK);
      ahb_write(1, MACHINE, REGOUT_03, 32'h08D4E6AC, 2, OK);
      ahb_write(1, MACHINE, REGOUT_04, 32'hF13B72D5, 2, OK);
      ahb_write(1, MACHINE, REGOUT_05, 32'h9C84A1E0, 2, OK);
      ahb_write(1, MACHINE, REGOUT_06, 32'h27D5C8F4, 2, OK);
      ahb_write(1, MACHINE, REGOUT_07, 32'h6A3E9B12, 2, OK);

      // Init REGIN registers with some random values
      periph0_reg_08_in  =             32'hD14F87C3        ;
      periph0_reg_09_in  =             32'h52AC39E8        ;
      periph0_reg_10_in  =             32'h7F20D4B1        ;
      periph0_reg_11_in  =             32'h3AE98F65        ;
      periph0_reg_12_in  =             32'hC9B47E0D        ;
      periph0_reg_13_in  =             32'h15D23A97        ;
      periph0_reg_14_in  =             32'h84F6912B        ;
      periph0_reg_15_in  =             32'hE7305C48        ;
   end
endtask

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);

      $display("");
      $display(" ==================================================================");
      $display("|    W4: MDELEG POST-RESET STATE (M-mode-locked, RESP=1)           |");
      $display(" ==================================================================");

      // MDELEG resets to 0x0000_010F: WR_PRIV=11, RD_PRIV=11, RESP=1.
      // Verify that BEFORE the wo_error test clears RESP.
      ahb_read(1, MACHINE, MDELEG,    32'h0000010F, 2, 1, OK);

      $display("");
      $display(" ==================================================================");
      $display("|    W5: MDELEG RESERVED-BITS RAZ / WRITE-IGNORE                   |");
      $display(" ==================================================================");

      // Writing 0xFFFFFFFF must only set the defined fields. Reserved bits
      // [7:4] and [31:9] read as zero.
      ahb_write(1, MACHINE, MDELEG,    32'hFFFFFFFF, 2,    OK);
      ahb_read( 1, MACHINE, MDELEG,    32'h0000010F, 2, 1, OK);

      $display("");
      $display(" ==================================================================");
      $display("|    W1: RESERVED PRIV ENCODING 2'b10 COERCED TO 2'b11 AT WR TIME  |");
      $display(" ==================================================================");

      ahb_write(1, MACHINE, MDELEG,    32'h00000102, 2,    OK);   // WR=10
      ahb_read( 1, MACHINE, MDELEG,    32'h00000103, 2, 1, OK);   // -> WR=11
      ahb_write(1, MACHINE, MDELEG,    32'h00000108, 2,    OK);   // RD=10
      ahb_read( 1, MACHINE, MDELEG,    32'h0000010C, 2, 1, OK);   // -> RD=11
      ahb_write(1, MACHINE, MDELEG,    32'h0000010A, 2,    OK);   // both=10
      ahb_read( 1, MACHINE, MDELEG,    32'h0000010F, 2, 1, OK);   // -> both=11

      $display("");
      $display(" ==================================================================");
      $display("|    W2: MDELEG BYTE / HALF-WORD WRITES                            |");
      $display(" ==================================================================");

      // Start from a known state: WR=01, RD=01, RESP=1.
      ahb_write(1, MACHINE, MDELEG,    32'h00000105, 2,    OK);
      // Byte 0 only: changes WR/RD_PRIV without touching RESP.
      ahb_write(1, MACHINE, MDELEG,    32'h00000009, 0,    OK);  // WR=01, RD=10
      ahb_read( 1, MACHINE, MDELEG,    32'h0000010D, 2, 1, OK);  // RD coerced to 11, RESP=1 preserved
      // Byte 1 only: changes RESP without touching WR/RD_PRIV.
      ahb_write(1, MACHINE, MDELEG+1,  32'h00000000, 0,    OK);  // clear RESP
      ahb_read( 1, MACHINE, MDELEG,    32'h0000000D, 2, 1, OK);  // priv preserved, RESP=0
      // Bytes 2/3 only: reserved bytes — must be no-op.
      ahb_write(1, MACHINE, MDELEG+2,  32'hFFFFFFFF, 1,    OK);
      ahb_read( 1, MACHINE, MDELEG,    32'h0000000D, 2, 1, OK);  // unchanged

      $display("");
      $display(" =========================================================");
      $display("|    MDELEG ACCESS CHECK (only possible in Machine mode)  |");
      $display(" =========================================================");
      $display("");

      ahb_write(1, MACHINE,    MDELEG,    32'h0000000F, 2,    OK);
      ahb_write(1, SUPERVISOR, MDELEG,    32'h00000000, 2,    OK);
      ahb_write(1, USER,       MDELEG,    32'h00000000, 2,    OK);
      repeat(5) @(posedge free_clk);

      ahb_read( 1, MACHINE,    MDELEG,    32'h0000000F, 2, 1, OK);
      ahb_read( 1, SUPERVISOR, MDELEG,    32'h00000000, 2, 1, OK);
      ahb_read( 1, USER,       MDELEG,    32'h00000000, 2, 1, OK);
      repeat(5) @(posedge free_clk);


      repeat(20) @(posedge free_clk);
      $display("");
      $display(" ==========================================================================");
      $display("|    MACHINE MODE: READ/WRITE-CHECK WITHOUT-ERROR RESPONSE (always works)  |");
      $display(" ==========================================================================");

      for (ii = 0; ii < 4; ii = ii + 1) begin
         for (jj = 0; jj < 4; jj = jj + 1) begin
            $display("");
            $display("------------   MDELEG Config:  read=%d     write=%d    ------------", ii[1:0], jj[1:0]);
            $display("");

            init_peripheral;

            // Configure MDELEG register
            ahb_write(0, MACHINE, MDELEG,   {28'h0000000, ii[1:0], jj[1:0]}, 2, OK);

            // Read REGIN registers
            ahb_read( 0, MACHINE, REGIN_08,  32'hD14F87C3, 2, 1, OK);
            ahb_read( 0, MACHINE, REGIN_09,  32'h52AC39E8, 2, 1, OK);
            ahb_read( 0, MACHINE, REGIN_10,  32'h7F20D4B1, 2, 1, OK);
            ahb_read( 0, MACHINE, REGIN_11,  32'h3AE98F65, 2, 1, OK);
            ahb_read( 0, MACHINE, REGIN_12,  32'hC9B47E0D, 2, 1, OK);
            ahb_read( 0, MACHINE, REGIN_13,  32'h15D23A97, 2, 1, OK);
            ahb_read( 0, MACHINE, REGIN_14,  32'h84F6912B, 2, 1, OK);
            ahb_read( 0, MACHINE, REGIN_15,  32'hE7305C48, 2, 1, OK);

            // Read REGOUT registers
            ahb_read( 0, MACHINE, REGOUT_00, 32'hA3F29C7B, 2, 1, OK);
            ahb_read( 0, MACHINE, REGOUT_01, 32'h4D8E10F2, 2, 1, OK);
            ahb_read( 0, MACHINE, REGOUT_02, 32'hB7C51A39, 2, 1, OK);
            ahb_read( 0, MACHINE, REGOUT_03, 32'h08D4E6AC, 2, 1, OK);
            ahb_read( 0, MACHINE, REGOUT_04, 32'hF13B72D5, 2, 1, OK);
            ahb_read( 0, MACHINE, REGOUT_05, 32'h9C84A1E0, 2, 1, OK);
            ahb_read( 0, MACHINE, REGOUT_06, 32'h27D5C8F4, 2, 1, OK);
            ahb_read( 0, MACHINE, REGOUT_07, 32'h6A3E9B12, 2, 1, OK);

            // Write REGOUT registers
            ahb_write(0, MACHINE, REGOUT_00, 32'h11111111, 2,    OK);
            ahb_write(0, MACHINE, REGOUT_01, 32'h22222222, 2,    OK);
            ahb_write(0, MACHINE, REGOUT_02, 32'h33333333, 2,    OK);
            ahb_write(0, MACHINE, REGOUT_03, 32'h44444444, 2,    OK);
            ahb_write(0, MACHINE, REGOUT_04, 32'h55555555, 2,    OK);
            ahb_write(0, MACHINE, REGOUT_05, 32'h66666666, 2,    OK);
            ahb_write(0, MACHINE, REGOUT_06, 32'h77777777, 2,    OK);
            ahb_write(0, MACHINE, REGOUT_07, 32'h88888888, 2,    OK);

            // Read REGOUT registers
            ahb_read( 0, MACHINE, REGOUT_00, 32'h11111111, 2, 1, OK);
            ahb_read( 0, MACHINE, REGOUT_01, 32'h22222222, 2, 1, OK);
            ahb_read( 0, MACHINE, REGOUT_02, 32'h33333333, 2, 1, OK);
            ahb_read( 0, MACHINE, REGOUT_03, 32'h44444444, 2, 1, OK);
            ahb_read( 0, MACHINE, REGOUT_04, 32'h55555555, 2, 1, OK);
            ahb_read( 0, MACHINE, REGOUT_05, 32'h66666666, 2, 1, OK);
            ahb_read( 0, MACHINE, REGOUT_06, 32'h77777777, 2, 1, OK);
            ahb_read( 0, MACHINE, REGOUT_07, 32'h88888888, 2, 1, OK);

            repeat(5) @(posedge free_clk);
         end
      end

      repeat(20) @(posedge free_clk);
      $display("");
      $display(" ===============================================================");
      $display("|    SUPERVISOR MODE: READ/WRITE-CHECK WITHOUT-ERROR RESPONSE   |");
      $display(" ===============================================================");

      for (ii = 0; ii < 4; ii = ii + 1) begin
         for (jj = 0; jj < 4; jj = jj + 1) begin
            $display("");
            $display("------------   MDELEG Config:  read=%d     write=%d    ------------", ii[1:0], jj[1:0]);
            $display("");

            init_peripheral;

            // Configure MDELEG register
            ahb_write(0, MACHINE,    MDELEG,   {28'h0000000, ii[1:0], jj[1:0]}, 2, OK);

            // W1: the RTL coerces 2'b10 (reserved) to 2'b11 at write time.
            // (RESP=0 here, so the response will be OK regardless — but the
            // stored gate still controls whether the access succeeds or is
            // silently dropped.)
            stored_ii  = (ii[1:0] == 2'b10) ? MACHINE : ii[1:0];
            stored_jj  = (jj[1:0] == 2'b10) ? MACHINE : jj[1:0];

            read_resp  = (stored_ii==MACHINE) ? ERROR : OK;
            write_resp = (stored_jj==MACHINE) ? ERROR : OK;

            // Read REGIN registers
            if (read_resp==ERROR) begin
               ahb_read( 0, SUPERVISOR, REGIN_08,  32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGIN_09,  32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGIN_10,  32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGIN_11,  32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGIN_12,  32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGIN_13,  32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGIN_14,  32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGIN_15,  32'h00000000, 2, 1, OK);
            end else begin
               ahb_read( 0, SUPERVISOR, REGIN_08,  32'hD14F87C3, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGIN_09,  32'h52AC39E8, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGIN_10,  32'h7F20D4B1, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGIN_11,  32'h3AE98F65, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGIN_12,  32'hC9B47E0D, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGIN_13,  32'h15D23A97, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGIN_14,  32'h84F6912B, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGIN_15,  32'hE7305C48, 2, 1, OK);
            end

            // Read REGOUT registers
            if (read_resp==ERROR) begin
               ahb_read( 0, SUPERVISOR, REGOUT_00, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_01, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_02, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_03, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_04, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_05, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_06, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_07, 32'h00000000, 2, 1, OK);
            end else begin
               ahb_read( 0, SUPERVISOR, REGOUT_00, 32'hA3F29C7B, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_01, 32'h4D8E10F2, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_02, 32'hB7C51A39, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_03, 32'h08D4E6AC, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_04, 32'hF13B72D5, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_05, 32'h9C84A1E0, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_06, 32'h27D5C8F4, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_07, 32'h6A3E9B12, 2, 1, OK);
            end

            // Write REGOUT registers
            ahb_write(0, SUPERVISOR, REGOUT_00, 32'h11111111, 2, OK);
            ahb_write(0, SUPERVISOR, REGOUT_01, 32'h22222222, 2, OK);
            ahb_write(0, SUPERVISOR, REGOUT_02, 32'h33333333, 2, OK);
            ahb_write(0, SUPERVISOR, REGOUT_03, 32'h44444444, 2, OK);
            ahb_write(0, SUPERVISOR, REGOUT_04, 32'h55555555, 2, OK);
            ahb_write(0, SUPERVISOR, REGOUT_05, 32'h66666666, 2, OK);
            ahb_write(0, SUPERVISOR, REGOUT_06, 32'h77777777, 2, OK);
            ahb_write(0, SUPERVISOR, REGOUT_07, 32'h88888888, 2, OK);

            // Read REGOUT registers
            if ((read_resp==ERROR) && (write_resp==ERROR)) begin
               ahb_read( 0, SUPERVISOR, REGOUT_00, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_01, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_02, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_03, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_04, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_05, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_06, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_07, 32'h00000000, 2, 1, OK);

               ahb_read( 0, MACHINE,    REGOUT_00, 32'hA3F29C7B, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_01, 32'h4D8E10F2, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_02, 32'hB7C51A39, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_03, 32'h08D4E6AC, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_04, 32'hF13B72D5, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_05, 32'h9C84A1E0, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_06, 32'h27D5C8F4, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_07, 32'h6A3E9B12, 2, 1, OK);

            end else if ((read_resp==ERROR) && (write_resp==OK   )) begin
               ahb_read( 0, SUPERVISOR, REGOUT_00, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_01, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_02, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_03, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_04, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_05, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_06, 32'h00000000, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_07, 32'h00000000, 2, 1, OK);

               ahb_read( 0, MACHINE,    REGOUT_00, 32'h11111111, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_01, 32'h22222222, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_02, 32'h33333333, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_03, 32'h44444444, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_04, 32'h55555555, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_05, 32'h66666666, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_06, 32'h77777777, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_07, 32'h88888888, 2, 1, OK);

            end else if ((read_resp==OK)    && (write_resp==ERROR)) begin
               ahb_read( 0, SUPERVISOR, REGOUT_00, 32'hA3F29C7B, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_01, 32'h4D8E10F2, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_02, 32'hB7C51A39, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_03, 32'h08D4E6AC, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_04, 32'hF13B72D5, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_05, 32'h9C84A1E0, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_06, 32'h27D5C8F4, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_07, 32'h6A3E9B12, 2, 1, OK);

               ahb_read( 0, MACHINE,    REGOUT_00, 32'hA3F29C7B, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_01, 32'h4D8E10F2, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_02, 32'hB7C51A39, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_03, 32'h08D4E6AC, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_04, 32'hF13B72D5, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_05, 32'h9C84A1E0, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_06, 32'h27D5C8F4, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_07, 32'h6A3E9B12, 2, 1, OK);

            end else if ((read_resp==OK)    && (write_resp==OK   )) begin
               ahb_read( 0, SUPERVISOR, REGOUT_00, 32'h11111111, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_01, 32'h22222222, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_02, 32'h33333333, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_03, 32'h44444444, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_04, 32'h55555555, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_05, 32'h66666666, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_06, 32'h77777777, 2, 1, OK);
               ahb_read( 0, SUPERVISOR, REGOUT_07, 32'h88888888, 2, 1, OK);

               ahb_read( 0, MACHINE,    REGOUT_00, 32'h11111111, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_01, 32'h22222222, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_02, 32'h33333333, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_03, 32'h44444444, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_04, 32'h55555555, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_05, 32'h66666666, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_06, 32'h77777777, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_07, 32'h88888888, 2, 1, OK);
            end

            repeat(5) @(posedge free_clk);
         end
      end

      repeat(20) @(posedge free_clk);
      $display("");
      $display(" ===============================================================");
      $display("|    USER MODE: READ/WRITE-CHECK WITHOUT-ERROR RESPONSE         |");
      $display(" ===============================================================");

      for (ii = 0; ii < 4; ii = ii + 1) begin
         for (jj = 0; jj < 4; jj = jj + 1) begin
            $display("");
            $display("------------   MDELEG Config:  read=%d     write=%d    ------------", ii[1:0], jj[1:0]);
            $display("");

            init_peripheral;

            // Configure MDELEG register
            ahb_write(0, MACHINE,    MDELEG,   {28'h0000000, ii[1:0], jj[1:0]}, 2, OK);

            // W1: the RTL coerces 2'b10 (reserved) to 2'b11 at write time.
            stored_ii  = (ii[1:0] == 2'b10) ? MACHINE : ii[1:0];
            stored_jj  = (jj[1:0] == 2'b10) ? MACHINE : jj[1:0];

            read_resp  = ((stored_ii==MACHINE) || (stored_ii==SUPERVISOR)) ? ERROR : OK;
            write_resp = ((stored_jj==MACHINE) || (stored_jj==SUPERVISOR)) ? ERROR : OK;

            // Read REGIN registers
            if (read_resp==ERROR) begin
               ahb_read( 0, USER, REGIN_08,  32'h00000000, 2, 1, OK);
               ahb_read( 0, USER, REGIN_09,  32'h00000000, 2, 1, OK);
               ahb_read( 0, USER, REGIN_10,  32'h00000000, 2, 1, OK);
               ahb_read( 0, USER, REGIN_11,  32'h00000000, 2, 1, OK);
               ahb_read( 0, USER, REGIN_12,  32'h00000000, 2, 1, OK);
               ahb_read( 0, USER, REGIN_13,  32'h00000000, 2, 1, OK);
               ahb_read( 0, USER, REGIN_14,  32'h00000000, 2, 1, OK);
               ahb_read( 0, USER, REGIN_15,  32'h00000000, 2, 1, OK);
            end else begin
               ahb_read( 0, USER, REGIN_08,  32'hD14F87C3, 2, 1, OK);
               ahb_read( 0, USER, REGIN_09,  32'h52AC39E8, 2, 1, OK);
               ahb_read( 0, USER, REGIN_10,  32'h7F20D4B1, 2, 1, OK);
               ahb_read( 0, USER, REGIN_11,  32'h3AE98F65, 2, 1, OK);
               ahb_read( 0, USER, REGIN_12,  32'hC9B47E0D, 2, 1, OK);
               ahb_read( 0, USER, REGIN_13,  32'h15D23A97, 2, 1, OK);
               ahb_read( 0, USER, REGIN_14,  32'h84F6912B, 2, 1, OK);
               ahb_read( 0, USER, REGIN_15,  32'hE7305C48, 2, 1, OK);
            end

            // Read REGOUT registers
            if (read_resp==ERROR) begin
               ahb_read( 0, USER, REGOUT_00, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER, REGOUT_01, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER, REGOUT_02, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER, REGOUT_03, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER, REGOUT_04, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER, REGOUT_05, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER, REGOUT_06, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER, REGOUT_07, 32'h00000000, 2, 1, OK);
            end else begin
               ahb_read( 0, USER, REGOUT_00, 32'hA3F29C7B, 2, 1, OK);
               ahb_read( 0, USER, REGOUT_01, 32'h4D8E10F2, 2, 1, OK);
               ahb_read( 0, USER, REGOUT_02, 32'hB7C51A39, 2, 1, OK);
               ahb_read( 0, USER, REGOUT_03, 32'h08D4E6AC, 2, 1, OK);
               ahb_read( 0, USER, REGOUT_04, 32'hF13B72D5, 2, 1, OK);
               ahb_read( 0, USER, REGOUT_05, 32'h9C84A1E0, 2, 1, OK);
               ahb_read( 0, USER, REGOUT_06, 32'h27D5C8F4, 2, 1, OK);
               ahb_read( 0, USER, REGOUT_07, 32'h6A3E9B12, 2, 1, OK);
            end

            // Write REGOUT registers
            ahb_write(0, USER, REGOUT_00, 32'h11111111, 2,  OK);
            ahb_write(0, USER, REGOUT_01, 32'h22222222, 2,  OK);
            ahb_write(0, USER, REGOUT_02, 32'h33333333, 2,  OK);
            ahb_write(0, USER, REGOUT_03, 32'h44444444, 2,  OK);
            ahb_write(0, USER, REGOUT_04, 32'h55555555, 2,  OK);
            ahb_write(0, USER, REGOUT_05, 32'h66666666, 2,  OK);
            ahb_write(0, USER, REGOUT_06, 32'h77777777, 2,  OK);
            ahb_write(0, USER, REGOUT_07, 32'h88888888, 2,  OK);

            // Read REGOUT registers
            if ((read_resp==ERROR) && (write_resp==ERROR)) begin
               ahb_read( 0, USER,       REGOUT_00, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_01, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_02, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_03, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_04, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_05, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_06, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_07, 32'h00000000, 2, 1, OK);

               ahb_read( 0, MACHINE,    REGOUT_00, 32'hA3F29C7B, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_01, 32'h4D8E10F2, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_02, 32'hB7C51A39, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_03, 32'h08D4E6AC, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_04, 32'hF13B72D5, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_05, 32'h9C84A1E0, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_06, 32'h27D5C8F4, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_07, 32'h6A3E9B12, 2, 1, OK);

            end else if ((read_resp==ERROR) && (write_resp==OK   )) begin
               ahb_read( 0, USER,       REGOUT_00, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_01, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_02, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_03, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_04, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_05, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_06, 32'h00000000, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_07, 32'h00000000, 2, 1, OK);

               ahb_read( 0, MACHINE,    REGOUT_00, 32'h11111111, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_01, 32'h22222222, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_02, 32'h33333333, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_03, 32'h44444444, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_04, 32'h55555555, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_05, 32'h66666666, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_06, 32'h77777777, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_07, 32'h88888888, 2, 1, OK);

            end else if ((read_resp==OK)    && (write_resp==ERROR)) begin
               ahb_read( 0, USER,       REGOUT_00, 32'hA3F29C7B, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_01, 32'h4D8E10F2, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_02, 32'hB7C51A39, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_03, 32'h08D4E6AC, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_04, 32'hF13B72D5, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_05, 32'h9C84A1E0, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_06, 32'h27D5C8F4, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_07, 32'h6A3E9B12, 2, 1, OK);

               ahb_read( 0, MACHINE,    REGOUT_00, 32'hA3F29C7B, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_01, 32'h4D8E10F2, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_02, 32'hB7C51A39, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_03, 32'h08D4E6AC, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_04, 32'hF13B72D5, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_05, 32'h9C84A1E0, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_06, 32'h27D5C8F4, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_07, 32'h6A3E9B12, 2, 1, OK);

            end else if ((read_resp==OK)    && (write_resp==OK   )) begin
               ahb_read( 0, USER,       REGOUT_00, 32'h11111111, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_01, 32'h22222222, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_02, 32'h33333333, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_03, 32'h44444444, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_04, 32'h55555555, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_05, 32'h66666666, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_06, 32'h77777777, 2, 1, OK);
               ahb_read( 0, USER,       REGOUT_07, 32'h88888888, 2, 1, OK);

               ahb_read( 0, MACHINE,    REGOUT_00, 32'h11111111, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_01, 32'h22222222, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_02, 32'h33333333, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_03, 32'h44444444, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_04, 32'h55555555, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_05, 32'h66666666, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_06, 32'h77777777, 2, 1, OK);
               ahb_read( 0, MACHINE,    REGOUT_07, 32'h88888888, 2, 1, OK);
            end

            repeat(5) @(posedge free_clk);
         end
      end


      //---------------------------------------------------------------
      //------------------ END OF TEST --------------------------------
      //---------------------------------------------------------------
      repeat(21) @(posedge free_clk);
      $display("");
      $display("");
      stimulus_done = 1;
   end
