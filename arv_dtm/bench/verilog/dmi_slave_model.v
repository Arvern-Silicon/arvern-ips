//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    dmi_slave_model (include)
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : dmi_slave_model.v
// Module Description : Behavioral DMI-bus APB4 slave (stand-in for the arvern
//                      Debug Module), SHARED by every arv_dtm transport bench via
//                      `include. An APB slave backed by a 128-word memory, with
//                      TB-controllable knobs:
//                        slave_latency   : number of APB wait states (ACCESS cycles
//                                          before the one with PREADY): 0 = zero-wait
//                                          slave, 1 = the real arvern Debug Module
//                                          (registered PREADY), N = N wait states
//                        slave_hold      : hold PREADY low indefinitely (provoke the
//                                          TCK-side read-back-too-early / sticky path)
//                        slave_abort     : force back to idle (a slave that drops the transfer)
//                        slave_fault_en  : drive PSLVERR (failed) for slave_fault_addr
//
//   Requires the including TB to declare, in module scope:
//     wire  free_clk, dbgresetn;                               // bus clock + reset
//     wire  dmi_psel, dmi_penable, dmi_pwrite;               // DUT -> slave
//     wire  [ABITS+1:0] dmi_paddr; wire [31:0] dmi_pwdata;   // DUT -> slave
//     wire  dmi_pready, dmi_pslverr; wire [31:0] dmi_prdata; // slave -> DUT (driven here)
//   and the localparams ABITS, OP_READ, OP_WRITE, OP_SUCCESS, OP_FAILED.
//   (dmi_pprot, if present on the DUT, is ignored here.)
//----------------------------------------------------------------------------

reg [31:0] slave_mem [0:127];

integer    slave_latency;     // APB wait states (1 = the arvern Debug Module)
reg        slave_hold;        // 1 = hold PREADY low (provoke read-back-too-early / sticky)
reg        slave_abort;       // 1 = force the slave back to idle (drops the transfer)
reg        slave_fault_en;    // 1 = drive PSLVERR (failed) for slave_fault_addr
reg [ABITS-1:0] slave_fault_addr;

localparam [1:0] SL_IDLE = 2'd0, SL_WAIT = 2'd1, SL_RESP = 2'd2;
reg [1:0]        sl_state;
reg [ABITS-1:0]  sl_addr;
reg [1:0]        sl_op;
reg [31:0]       sl_rdata;
reg [1:0]        sl_status;
integer          sl_cnt;

reg              pready_r;
reg [31:0]       prdata_r;
reg              pslverr_r;

// Register index: byte address, reg number in PADDR[ABITS+1:2].
wire [ABITS-1:0] sl_index = dmi_paddr[ABITS+1:2];

// Zero wait states: the transfer completes combinationally in its first ACCESS cycle.
wire        sl_zws      = (sl_state == SL_IDLE) & dmi_psel & dmi_penable & (slave_latency == 0) &
                          ~slave_hold & ~slave_abort;
wire        sl_zws_fail = slave_fault_en & (sl_index == slave_fault_addr);

assign dmi_pready  = pready_r | sl_zws;
assign dmi_prdata  = pready_r ? prdata_r                                     :
                     sl_zws   ? (dmi_pwrite ? 32'b0 : slave_mem[sl_index])   :
                                32'hxxxx_xxxx;   // valid only with PREADY: a late capture reads X
assign dmi_pslverr = pslverr_r | (sl_zws & sl_zws_fail);

initial begin
    slave_latency    = 1;
    slave_hold       = 1'b0;
    slave_abort      = 1'b0;
    slave_fault_en   = 1'b0;
    slave_fault_addr = {ABITS{1'b0}};
end

always @(posedge free_clk or negedge dbgresetn) begin
    if (!dbgresetn) begin
        sl_state  <= SL_IDLE;
        pready_r  <= 1'b0;
        prdata_r  <= 32'b0;
        pslverr_r <= 1'b0;
        sl_cnt    <= 0;
    end else if (slave_abort) begin
        sl_state  <= SL_IDLE;
        pready_r  <= 1'b0;
        pslverr_r <= 1'b0;
    end else begin
        case (sl_state)
            SL_IDLE : begin
                pready_r <= 1'b0;
                // ACCESS phase (PSEL & PENABLE): latch the transfer, commit a write,
                // then hold PREADY low for slave_latency cycles. No SETUP-phase effect.
                if (dmi_psel && dmi_penable) begin
                    sl_addr   <= sl_index;
                    sl_op     <= dmi_pwrite ? OP_WRITE : OP_READ;
                    if (dmi_pwrite)
                        slave_mem[sl_index] <= dmi_pwdata;
                    sl_rdata  <= slave_mem[sl_index];
                    sl_status <= (slave_fault_en && (sl_index == slave_fault_addr))
                                 ? OP_FAILED : OP_SUCCESS;
                    if (sl_zws) begin
                        // completed combinationally this cycle: stay idle
                    end else if ((slave_latency == 1) && !slave_hold) begin
                        pready_r  <= 1'b1;                      // one wait state
                        prdata_r  <= dmi_pwrite ? 32'b0 : slave_mem[sl_index];
                        pslverr_r <= (slave_fault_en && (sl_index == slave_fault_addr));
                        sl_state  <= SL_RESP;
                    end else begin
                        sl_cnt    <= (slave_latency > 1) ? slave_latency - 2 : 0;
                        sl_state  <= SL_WAIT;
                    end
                end
            end
            SL_WAIT : begin
                if ((sl_cnt == 0) && !slave_hold) begin
                    pready_r  <= 1'b1;                          // complete the transfer
                    prdata_r  <= (sl_op == OP_READ) ? sl_rdata : 32'b0;
                    pslverr_r <= (sl_status == OP_FAILED) ? 1'b1 : 1'b0;
                    sl_state  <= SL_RESP;
                end else if (sl_cnt != 0) begin
                    sl_cnt <= sl_cnt - 1;
                end
                // slave_hold keeps PREADY low here indefinitely (master stays in ACCESS).
            end
            SL_RESP : begin
                // PREADY high for exactly one cycle; the master captures PRDATA and
                // completes, then we drop PREADY and return to idle.
                pready_r  <= 1'b0;
                pslverr_r <= 1'b0;
                sl_state  <= SL_IDLE;
            end
            default : sl_state <= SL_IDLE;
        endcase
    end
end
