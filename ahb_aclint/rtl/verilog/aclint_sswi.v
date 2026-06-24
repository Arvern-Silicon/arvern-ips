//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    aclint_sswi
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : aclint_sswi.v
// Module Description : ACLINT Supervisor-Software-Interrupt (SSWI)
//                      One 32-bit SETSSIP register per hart at offset 4*hart
//----------------------------------------------------------------------------
`default_nettype none

module  aclint_sswi #(
    parameter                      NUM_HARTS =  1,     // Number of harts (1..16)
    parameter                      REG_AW    = 12,     // Reg-bank byte-address width (SSWI window)
    parameter                      ARST_EN   = 1'b1    // Reset style: 1=asynchronous, 0=synchronous
) (

// CLOCK & RESET (hclk DOMAIN ONLY)
    input  wire                    hclk_i,             // AHB clock
    input  wire                    hresetn_i,          // Active-low async reset (sync-deassert)

// GENERIC REGISTER-BANK INTERFACE
    input  wire                    reg_sel_i,          // Access in flight to this sub-component
    input  wire       [REG_AW-1:0] reg_addr_i,         // Byte address inside the SSWI window
    input  wire                    reg_wr_en_i,        // 1 = write, 0 = read
    input  wire             [31:0] reg_wr_data_i,      // Write data
    output wire             [31:0] reg_rd_data_o,      // Read data -- always 0x0 (LSB-reads-0 + reserved upper bits)
    output wire                    reg_ready_o,        // Always 1 (single-cycle)

// PER-HART SSIP EDGE OUTPUT
    output wire    [NUM_HARTS-1:0] irq_s_software_o,   // 1-hclk_i cycle pulse per SETSSIP write (edge, NOT a level). Consumer MUST sample on hclk_i; routing through a 2-FF level synchronizer to another clock domain will miss the pulse.

// SOC-LEVEL CLOCK-GATE ADVISORY
    output wire                    sswi_active_o       // HIGH while any per-hart SETSSIP 1-cycle pulse is still asserted
);


//=============================================================================
// 1)  ADDRESS DECODE
//=============================================================================
// Per-hart SETSSIP register at offset 4*hart. Hart index = reg_addr_i[2 +: 4].

localparam [31:0]       NUM_HARTS_INT   = NUM_HARTS;
localparam [REG_AW-1:0] NUM_HARTS_CAST  = NUM_HARTS_INT[REG_AW-1:0];

wire       [REG_AW-1:0] hart_word_index = (reg_addr_i >> 2);
wire              [3:0] hart_idx        =  hart_word_index[3:0];
wire                    addr_in_range   = (hart_word_index < NUM_HARTS_CAST);

wire [NUM_HARTS-1:0] hart_sel;
genvar gh;
generate
    for (gh = 0; gh < NUM_HARTS; gh = gh + 1) begin : G_HART_SEL
        assign hart_sel[gh] = addr_in_range & (hart_idx == gh[3:0]);
    end
endgenerate


//=============================================================================
// 2)  PER-HART EDGE GENERATOR
//=============================================================================

wire [NUM_HARTS-1:0] ssoftware_pulse_r;

generate
    for (gh = 0; gh < NUM_HARTS; gh = gh + 1) begin : G_SSWI_EDGE
        wire bus_set_one = reg_sel_i & reg_wr_en_i & hart_sel[gh] & reg_wr_data_i[0];

        arv_ipdff #(.WIDTH(1), .ARST_EN(ARST_EN)) u_ssoftware_pulse (
                               .clk_i(hclk_i), .rst_n_i (hresetn_i), .en_i(1'b1),
                                                                     .d_i (bus_set_one),
                                                                     .q_o (ssoftware_pulse_r[gh]));
    end
endgenerate

assign irq_s_software_o = ssoftware_pulse_r;

// Clock-gate advisory: while any per-hart SETSSIP pulse is high, hclk_i must
// stay alive for one more edge so the flop can drop back to 0.
assign sswi_active_o    = |ssoftware_pulse_r;


//=============================================================================
// 3)  READ MUX
//=============================================================================
// Per ACLINT 1.0-rc4 Section 4.2: "The least significant bit of a SETSSIP
// register always reads 0" and "the upper 31 bits are wired to zero"
// So the SSWI device returns 0x0 for every read, regardless of address.

assign reg_rd_data_o = 32'h0;
assign reg_ready_o   =  1'b1;


//=============================================================================
// 4)  PARAMETER RANGE CHECK
//=============================================================================
// pragma translate_off
generate
    if ((NUM_HARTS < 1) || (NUM_HARTS > 16)) begin : CHECK_NUM_HARTS
        initial $fatal(1, "aclint_sswi: NUM_HARTS (%0d) must be 1..16.", NUM_HARTS);
    end
    if (REG_AW < 6) begin : CHECK_REG_AW
        initial $fatal(1, "aclint_sswi: REG_AW (%0d) must be >= 6.", REG_AW);
    end
endgenerate
// pragma translate_on


//=============================================================================
// 5)  LINT CLEANUP
//=============================================================================

wire        hart_word_index_unused;
assign      hart_word_index_unused = |hart_word_index[REG_AW-1:4];

wire [30:0] reg_wr_data_unused;
assign      reg_wr_data_unused     =  reg_wr_data_i[31:1];

endmodule // aclint_sswi

`default_nettype wire
