//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    i2c_tasks
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : i2c_tasks
// Module Description : I2C-master bus-functional tasks for the arv_dtm_i2c DTM.
//                      Bit-banged open-drain master that HONOURS CLOCK-STRETCHING
//                      (after releasing SCL it waits for the line to actually rise,
//                      which the target holds low while a DMI op is in flight).
//
//   Builds the same DMI transaction as JTAG/UART: a WRITE transaction carries
//   [0x55][addr][d31:24..d7:0][op]; a repeated-START READ returns [status][d×4].
//----------------------------------------------------------------------------

//=============================================================================
// SCL helpers (clock-stretch aware)
//=============================================================================
task scl_release_high;                 // release SCL, wait for it to actually rise
    begin
        m_scl_pd = 1'b0;
        wait (scl === 1'b1);           // target may hold it low (clock stretch)
        #(T_HIGH);
    end
endtask

task scl_drive_low;
    begin
        m_scl_pd = 1'b1;
        #(T_LOW);
    end
endtask

//=============================================================================
// START / STOP (bus idle = both lines high)
//=============================================================================
task i2c_start;
    begin
        m_sda_pd = 1'b0;  m_scl_pd = 1'b0;  #(T_SU_STA);   // ensure both high (tSU;STA)
        m_sda_pd = 1'b1;  #(T_HIGH);                   // SDA low while SCL high = START
        m_scl_pd = 1'b1;  #(T_LOW);                    // SCL low
    end
endtask

task i2c_stop;
    begin
        m_sda_pd = 1'b1;  #(T_SU_STA);                 // SDA low while SCL low (tSU;STO)
        scl_release_high;                              // SCL high
        m_sda_pd = 1'b0;  #(T_HIGH);                   // SDA high while SCL high = STOP
    end
endtask

//=============================================================================
// Write one byte, return the target's ACK (1 = ACK).
//=============================================================================
task i2c_write_byte;
    input  [7:0] b;
    output       ack;
    integer i;
    begin
        for (i = 7; i >= 0; i = i - 1) begin
            m_sda_pd = ~b[i];          // drive bit while SCL low (0 -> pull low)
            #(T_SU);
            scl_release_high;
            scl_drive_low;
        end
        m_sda_pd = 1'b0;               // release SDA for ACK
        #(T_SU);
        scl_release_high;
        ack = ~sda;                    // ACK = SDA pulled low by target
        scl_drive_low;
    end
endtask

//=============================================================================
// Read one byte; send ACK (more to come) or NACK (last byte).
//=============================================================================
// Data setup seen by the master, checked on every bit the target transmits: the
// target's SDA must not change in the same instant SCL rises (a target that moves
// SDA as it releases a stretched SCL gives zero setup).
time    sda_last_t;
initial sda_last_t = 0;
always @(dut_sda_pd) if (dut.g_i2c.u_dtm.read_phase) sda_last_t = $time;   // target transmitting

task i2c_read_byte;
    output [7:0] b;
    input        ack;                  // 1 = ACK, 0 = NACK
    integer i;
    begin
        m_sda_pd = 1'b0;               // release SDA (target drives)
        for (i = 7; i >= 0; i = i - 1) begin
            m_scl_pd = 1'b0;
            wait (scl === 1'b1);       // target may hold it low (clock stretch)
            if ($time == sda_last_t) begin
                $display("ERROR: I2C SDA changed as SCL rose (bit %0d)  %0t ns", i, $time);
                error = error + 1;
            end
            #(T_HIGH);
            b[i] = sda;
            scl_drive_low;
        end
        m_sda_pd = ack ? 1'b1 : 1'b0;  // ACK = pull low / NACK = release
        #(T_SU);
        scl_release_high;
        scl_drive_low;
        m_sda_pd = 1'b0;
    end
endtask

//=============================================================================
// Full DMI transaction over I2C: write the request, repeated-START, read 5.
//=============================================================================
task dmi_i2c;
    input  [ABITS-1:0] addr;
    input  [1:0]       op;
    input  [31:0]      data;
    output [1:0]       status;
    output [31:0]      rdata;
    reg ack;
    reg [7:0] s, b3, b2, b1, b0;
    begin
        // ---- request (write) ----
        i2c_start;
        i2c_write_byte({I2C_ADDR, 1'b0}, ack);          // address + W
        i2c_write_byte(8'h55, ack);                     // SYNC
        i2c_write_byte({{(8-ABITS){1'b0}}, addr}, ack);
        i2c_write_byte(data[31:24], ack);
        i2c_write_byte(data[23:16], ack);
        i2c_write_byte(data[15:8],  ack);
        i2c_write_byte(data[7:0],   ack);
        i2c_write_byte({6'b0, op},  ack);
        // ---- response (repeated-START, read) ----
        i2c_start;
        i2c_write_byte({I2C_ADDR, 1'b1}, ack);          // address + R
        i2c_read_byte(s,  1'b1);                        // [status]   ACK
        i2c_read_byte(b3, 1'b1);                        // [d31:24]   ACK
        i2c_read_byte(b2, 1'b1);                        // [d23:16]   ACK
        i2c_read_byte(b1, 1'b1);                        // [d15:8]    ACK
        i2c_read_byte(b0, 1'b0);                        // [d7:0]     NACK (last)
        i2c_stop;
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
