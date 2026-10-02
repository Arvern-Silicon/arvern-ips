//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dtm_tasks (include)
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dtm_tasks.v
// Module Description : Transport dispatch for the unified arv_dtm testbench.
//
//   Pulls in the transport-specific host task library selected by the active
//   +define+ (DTM_UART / DTM_I2C / else JTAG), then defines a small
//   TRANSPORT-NEUTRAL API on top of it so a generic stimulus can drive any DTM:
//
//     dtm_init                                 : reset sync + put the DTM ready
//     dtm_settle(n)                            : idle n primary-clock periods
//     dtm_dmi_write(addr, data, out status)    : one DMI write transaction
//     dtm_dmi_read (addr, out data, out status): one DMI read  transaction
//     dtm_dmi_hardreset(out status)            : dmihardreset (forget FSM state)
//
//   The logical {address, op, data} transaction is identical across transports;
//   only the PHY differs. Transport-specific stimuli (idcode_bypass, dtmcs_fields,
//   dmi_busy_recover, dmi_hardreset, uart_dmi_busy, uart_autobaud, i2c_dmi_busy)
//   call the underlying jtag/uart/i2c tasks directly.
//----------------------------------------------------------------------------

`ifdef DTM_UART
    //-------------------------------------------------------------------------
    // UART transport
    //-------------------------------------------------------------------------
    `include "uart_tasks.v"

    task dtm_init;
        begin
            @(posedge dbgresetn);
            repeat (4) @(posedge free_clk);
            uart_autobaud_sync;                 // measure host baud from 0x80 + eat the echo
        end
    endtask

    task dtm_settle;
        input integer n;
        repeat (n) @(posedge free_clk);
    endtask

    task dtm_dmi_write;
        input [ABITS-1:0] addr;
        input [31:0]      data;
        output [1:0]      status;
        reg [31:0] rd;
        begin
            dmi_uart(addr, OP_WRITE, data, status, rd);
        end
    endtask

    task dtm_dmi_read;
        input  [ABITS-1:0] addr;
        output [31:0]      data;
        output [1:0]       status;
        begin
            dmi_uart(addr, OP_READ, 32'h0, status, data);
        end
    endtask

    task dtm_dmi_hardreset;
        output [1:0] status;
        reg [31:0] rd;
        begin
            dmi_uart({ABITS{1'b0}}, OP_HRST, 32'h0, status, rd);
        end
    endtask

`elsif DTM_I2C
    //-------------------------------------------------------------------------
    // I2C transport
    //-------------------------------------------------------------------------
    `include "i2c_tasks.v"

    task dtm_init;
        begin
            @(posedge dbgresetn);
            repeat (4) @(posedge free_clk);
        end
    endtask

    task dtm_settle;
        input integer n;
        repeat (n) @(posedge free_clk);
    endtask

    task dtm_dmi_write;
        input [ABITS-1:0] addr;
        input [31:0]      data;
        output [1:0]      status;
        reg [31:0] rd;
        begin
            dmi_i2c(addr, OP_WRITE, data, status, rd);
        end
    endtask

    task dtm_dmi_read;
        input  [ABITS-1:0] addr;
        output [31:0]      data;
        output [1:0]       status;
        begin
            dmi_i2c(addr, OP_READ, 32'h0, status, data);
        end
    endtask

    task dtm_dmi_hardreset;
        output [1:0] status;
        reg [31:0] rd;
        begin
            dmi_i2c({ABITS{1'b0}}, OP_HRST, 32'h0, status, rd);
        end
    endtask

`elsif DTM_CJTAG
    //-------------------------------------------------------------------------
    // cJTAG transport (IEEE 1149.7, OScan1) -- same TAP-level API as JTAG
    //-------------------------------------------------------------------------
    `include "cjtag_tasks.v"

    task dtm_init;
        begin
            @(posedge dbgresetn);
            repeat (4) @(posedge free_clk);
            tap_reset;                  // first tap_reset escapes + activates -> OScan1
            shift_ir(IR_DMI);
        end
    endtask

    task dtm_settle;
        input integer n;
        repeat (n) @(posedge free_clk);
    endtask

    task dtm_dmi_write;
        input [ABITS-1:0] addr;
        input [31:0]      data;
        output [1:0]      status;
        begin
            dmi_write(addr, data, DTM_IDLE_N);
            status = OP_SUCCESS;
        end
    endtask

    task dtm_dmi_read;
        input  [ABITS-1:0] addr;
        output [31:0]      data;
        output [1:0]       status;
        begin
            dmi_read(addr, DTM_IDLE_N, data, status);
        end
    endtask

    task dtm_dmi_hardreset;
        output [1:0] status;
        begin
            dtmcs_write(32'h0002_0000);
            shift_ir(IR_DMI);
            status = OP_SUCCESS;
        end
    endtask

`else
    //-------------------------------------------------------------------------
    // JTAG transport (default)
    //-------------------------------------------------------------------------
    `include "jtag_tasks.v"

    task dtm_init;
        begin
            @(posedge dbgresetn);
            @(posedge trst_n);
            repeat (4) @(posedge tck);
            tap_reset;
            shift_ir(IR_DMI);
        end
    endtask

    task dtm_settle;
        input integer n;
        repeat (n) @(posedge tck);
    endtask

    // JTAG writes carry no separate status field; a normal (unfaulted) write
    // always succeeds, so report OP_SUCCESS for a uniform cross-transport API.
    task dtm_dmi_write;
        input [ABITS-1:0] addr;
        input [31:0]      data;
        output [1:0]      status;
        begin
            dmi_write(addr, data, DTM_IDLE_N);
            status = OP_SUCCESS;
        end
    endtask

    task dtm_dmi_read;
        input  [ABITS-1:0] addr;
        output [31:0]      data;
        output [1:0]       status;
        begin
            dmi_read(addr, DTM_IDLE_N, data, status);
        end
    endtask

    // JTAG dmihardreset lives in dtmcs (bit 17); it forgets any in-flight DMI
    // state. Restore IR=DMI afterwards so the next dtm_dmi_* works.
    task dtm_dmi_hardreset;
        output [1:0] status;
        begin
            dtmcs_write(32'h0002_0000);
            shift_ir(IR_DMI);
            status = OP_SUCCESS;
        end
    endtask

`endif
