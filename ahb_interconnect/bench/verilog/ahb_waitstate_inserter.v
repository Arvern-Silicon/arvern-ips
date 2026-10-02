//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    ahb_waitstate_inserter
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : ahb_waitstate_inserter.v
// Module Description : Configurable wait-state injector for AHB testbench stimulus.
//----------------------------------------------------------------------------

module ahb_waitstate_inserter (

// AHB CLOCK & RESET
    hclk_i,
    hresetn_i,
    
    number_wait_state,
    random_wait_state_enable,

// AHB INTERFACE (TO FABRIC OR DRIVER)
    haddr_i,
    hauser_i,
    hprot_i,
    hready_i,
    hsize_i,
    htrans_i,
    hwdata_i,
    hwrite_i,
    hsel_i,
    hrdata_o,
    hreadyout_o,
    hresp_o,

// AHB INTERFACE (TO AHB SUBORDINATE)
    s_haddr_o,
    s_hauser_o,
    s_hprot_o,
    s_hready_o,
    s_hsize_o,
    s_htrans_o,
    s_hwdata_o,
    s_hwrite_o,
    s_hsel_o,
    s_hrdata_i,
    s_hreadyout_i,
    s_hresp_i
 );

// PARAMETERs
//======================================
parameter              HAUSER_W = 1;              // Width of the HAUSER bus (min value is 1)

// HREADY_HOLDS_APH selects how the buffered address phase reacts to the
// bus HREADY handed to this subordinate (hready_i):
//
//   1 (default) - AHB-Lite reference style (IHI0033C slave example): the
//                 address-phase register is clocked by HREADY. A cycle with
//                 HREADY=1 and no valid transfer (hsel=0 or IDLE) clears the
//                 held transfer. Behind a compliant fabric this is a no-op,
//                 because HREADY is 0 for the whole of our own wait state.
//                 Behind a fabric that hands us HREADY=1 while we stall, the
//                 transfer being served is forgotten and the read returns
//                 garbage -- which is exactly what the regression must see.
//   0           - Legacy self-timed style: capture on hsel & hready & htrans[1]
//                 only, never cleared. Immune to a wrong HREADY by
//                 construction (ahb_rom_controller / ahb_sram_controller
//                 style).
parameter              HREADY_HOLDS_APH = 1;

// AHB CLOCK & RESET
//======================================
input                  hclk_i;
input                  hresetn_i;

input           [31:0] number_wait_state;
input                  random_wait_state_enable;

// AHB INTERFACE (TO FABRIC OR MANAGER)
//======================================
input           [31:0] haddr_i;
input   [HAUSER_W-1:0] hauser_i;
input            [3:0] hprot_i;
input                  hready_i;
input            [2:0] hsize_i;
input            [1:0] htrans_i;
input           [31:0] hwdata_i;
input                  hwrite_i;
input                  hsel_i;
output          [31:0] hrdata_o;
output                 hreadyout_o;
output                 hresp_o;

// AHB INTERFACE (TO AHB SUBORDINATE)
//======================================
output          [31:0] s_haddr_o;
output  [HAUSER_W-1:0] s_hauser_o;
output           [3:0] s_hprot_o;
output                 s_hready_o;
output           [2:0] s_hsize_o;
output           [1:0] s_htrans_o;
output          [31:0] s_hwdata_o;
output                 s_hwrite_o;
output                 s_hsel_o;
input           [31:0] s_hrdata_i;
input                  s_hreadyout_i;
input                  s_hresp_i;


//=============================================================================
// 1)  INTERNAL WIRES/REGISTERS/PARAMETERS DECLARATION
//=============================================================================

wire                   enable_wait_states;

wire                   aph_valid;
reg              [3:0] aph_wait_nxt;
reg              [3:0] aph_wait_cnt;

wire                   ahb_buffer_sel;
wire                   aph_transparent;
wire                   dph_transparent;

reg             [31:0] buf_haddr;
reg              [3:0] buf_hprot;
reg                    buf_hready;
reg              [2:0] buf_hsize;
reg     [HAUSER_W-1:0] buf_hauser;
reg              [1:0] buf_htrans;
reg                    buf_hwrite;
reg                    buf_hsel;

// Error injection, off unless a test raises err_req: each increment makes the
// next NONSEQ/SEQ taken here a two-cycle ERROR (hrdata 0) that the subordinate
// behind never sees.
integer                err_req;
integer                err_ack;
wire                   err_arm;
wire                   err_take;
reg              [1:0] err_st;


//=============================================================================
// 2)  DETECT IF WAIT STATE AND BUFFER SIGNALS
//=============================================================================

assign enable_wait_states = (number_wait_state!=0);

// Detect end of address phase
assign  aph_valid         = hsel_i && hready_i && htrans_i[1];

assign  err_arm           = (err_req != err_ack);
assign  err_take          = err_arm & aph_valid;

initial begin
    err_req = 0;
    err_ack = 0;
end

always @(posedge hclk_i or negedge hresetn_i) begin
    if (!hresetn_i)             err_st <= 2'd0;
    else if (err_take)          err_st <= 2'd1;
    else if (err_st == 2'd1)    err_st <= 2'd2;
    else if (err_st == 2'd2)    err_st <= 2'd0;
end

always @(posedge hclk_i)
    if (hresetn_i && err_take) err_ack <= err_ack + 1;

// Wait state control
always @(posedge hclk_i or negedge hresetn_i) begin
    if (!hresetn_i) begin
        aph_wait_nxt    <= enable_wait_states ? (random_wait_state_enable ? $urandom_range(0, number_wait_state+1) : number_wait_state) : 0;
        aph_wait_cnt    <= 0;
    
    end else if (aph_valid) begin
        aph_wait_nxt    <= enable_wait_states ? (random_wait_state_enable ? $urandom_range(0, number_wait_state+1) : number_wait_state) : 0;
        aph_wait_cnt    <= err_arm ? 4'd0 : aph_wait_nxt;

    end else if (aph_wait_cnt!=0) begin
        aph_wait_cnt    <= aph_wait_cnt-1;
    end
end

// Control the address phase muxes and data phase muxes
assign  ahb_buffer_sel   = (aph_wait_cnt==1);
assign  aph_transparent  = (aph_wait_cnt==0) && (aph_wait_nxt==0);
assign  dph_transparent  = (aph_wait_cnt==0);

// State register
always @(posedge hclk_i or negedge hresetn_i) begin
    if (!hresetn_i) begin
        buf_haddr       <=  32'h00000000; 
        buf_hprot       <=   4'b0000;
        buf_hready      <=   1'b1;
        buf_hsize       <=   3'b000;
        buf_hauser      <= {HAUSER_W{1'b0}};
        buf_htrans      <=   2'b00;
        buf_hwrite      <=   1'b0;
        buf_hsel        <=   1'b0;
    end else if (aph_valid) begin
        buf_haddr       <=  haddr_i; 
        buf_hprot       <=  hprot_i;
        buf_hready      <=  hready_i;
        buf_hsize       <=  hsize_i;
        buf_hauser      <=  hauser_i;
        buf_htrans      <=  htrans_i;
        buf_hwrite      <=  hwrite_i;
        buf_hsel        <=  hsel_i & ~err_arm;
    end else if (HREADY_HOLDS_APH && hready_i) begin
        // Reference-style subordinate: HREADY=1 with no transfer presented
        // loads "no transfer" into the address-phase register.
        buf_hsel        <=  1'b0;
        buf_htrans      <=  2'b00;
    end
end


//=============================================================================
// 2b) PROTOCOL CHECK: A STALLING SUBORDINATE MUST SEE HREADY=0
//=============================================================================
// IHI0033C: the HREADY input of a subordinate is the combined bus HREADY,
// and the subordinate holding the data phase with HREADYOUT=0 *is* the bus.
// So whenever this model drives hreadyout_o=0, the HREADY the fabric hands
// back on hready_i must be 0 in the same cycle. Independent of the
// HREADY_HOLDS_APH style above.

integer hready_viol_cnt;
initial hready_viol_cnt = 0;

always @(posedge hclk_i) begin
    if (hresetn_i && !hreadyout_o && hready_i) begin
        hready_viol_cnt = hready_viol_cnt + 1;
        if (hready_viol_cnt <= 8)
            $display("ERROR: %m: subordinate stalling (hreadyout_o=0) but fabric drives hready_i=1 %t", $time);
        else if (hready_viol_cnt == 9)
            $display("ERROR: %m: ... further hready_i violations not printed");
    end
end


//=============================================================================
// 3)  CONTROL MUXES FOR ADDRESS/DATA PHASE SIGNALS
//=============================================================================

// Address Phase signals
assign   s_haddr_o       =  (aph_transparent ?  haddr_i       :  (ahb_buffer_sel ?  buf_haddr   :  32'h00000000   )); 
assign   s_hprot_o       =  (aph_transparent ?  hprot_i       :  (ahb_buffer_sel ?  buf_hprot   :   4'b0000       ));
// HREADY into the subordinate: the bus HREADY whenever the subordinate may be in a data
// phase (dph_transparent) -- a multi-cycle response such as the two-cycle ERROR depends
// on it -- and the buffered value only while the delayed address phase is replayed.
assign   s_hready_o      =  (dph_transparent ?  hready_i      :  (ahb_buffer_sel ?  buf_hready  :   1'b1          ));
assign   s_hsize_o       =  (aph_transparent ?  hsize_i       :  (ahb_buffer_sel ?  buf_hsize   :   3'b000        ));
assign   s_hauser_o      =  (aph_transparent ?  hauser_i      :  (ahb_buffer_sel ?  buf_hauser  : {HAUSER_W{1'b0}}));
assign   s_htrans_o      =  (aph_transparent ?  htrans_i      :  (ahb_buffer_sel ?  buf_htrans  :   2'b00         ));
assign   s_hwrite_o      =  (aph_transparent ?  hwrite_i      :  (ahb_buffer_sel ?  buf_hwrite  :   1'b0          ));
assign   s_hsel_o        =  (aph_transparent ? (hsel_i & ~err_arm) :  (ahb_buffer_sel ?  buf_hsel    :   1'b0          ));  

// Data Phase signals
assign   s_hwdata_o      =  (dph_transparent ?  hwdata_i      :   32'h00000000   );
assign   hrdata_o        =  (err_st != 2'd0) ? 32'h00000000 : (dph_transparent ?  s_hrdata_i    :   32'h00000000   );
assign   hresp_o         =  (err_st != 2'd0) ?  1'b1         : (dph_transparent ?  s_hresp_i     :    1'b0          );
assign   hreadyout_o     =  (err_st == 2'd1) ?  1'b0         :
                            (err_st == 2'd2) ?  1'b1         : (dph_transparent ?  s_hreadyout_i :    1'b0          );


endmodule
