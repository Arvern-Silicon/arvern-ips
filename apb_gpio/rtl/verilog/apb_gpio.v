//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    apb_gpio
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : apb_gpio.v
// Module Description : APB4 general-purpose I/O, up to 32 pins:
//                        + output value and output enable per pin, with
//                          set / clear / toggle write aliases
//                        + per-pin enabled, synchronised input sampling on
//                          the always-on clock (pclk_aon_i, internally gated
//                          while no input is enabled)
//                        + per-pin rising / falling edge (latched) and
//                          high / low level (live) interrupt conditions
//                        + per-pin interrupt lines and one combined line
//                        + asynchronous wake request on a pin change the
//                          pin's interrupt modes would report
//                        + up to four alternate functions per pin (ALT_NR)
//                        + MDELEG privilege gate (minimum write and read
//                          privilege, PSLVERR or silent drop), reset value
//                          MDELEG_RST
//
// CLOCKS: pclk_aon_i and pclk_i are the same clock before and after the bus
// ICG. The bus interface and the registers run on pclk_i; the input stage,
// edge detector and pending latch run on the gated pclk_aon_i.
//
// REGISTER MAP (word offsets of the 1<<ADDRW byte window, bit n = pin n):
//   0x00 INFO      RO     0x10 OUTPUT    RW     0x20 IRQ_EN    RW     0x30 IRQ_RISE  RW
//   0x04 IN_EN     RW     0x14 OUT_SET   WO     0x24 IRQ_PEND  RW1C   0x34 IRQ_FALL  RW
//   0x08 OE        RW     0x18 OUT_CLR   WO     0x28 WAKE_EN   RW     0x38 IRQ_HIGH  RW
//   0x0C INPUT     RO     0x1C OUT_TGL   WO     0x2C CFG       RO     0x3C IRQ_LOW   RW
//   0x40 ALT_EN    RW     (ALT_NR >= 1)         0x50 OE_SET    WO
//   0x44 ALT_SEL0  RW     (ALT_NR >= 2)         0x54 OE_CLR    WO
//   0x48 ALT_SEL1  RW     (ALT_NR >= 3)         0x58 IRQ_EN_SET WO
//   0x4C IRQ_STAT  RO                           0x5C IRQ_EN_CLR WO
//   0x60 MDELEG    RW     (M-mode only)
//----------------------------------------------------------------------------
`default_nettype none

module  apb_gpio #(
    parameter                 GPIO_NR       = 32,     // Number of pins (1..32)
    parameter                 ADDRW         = 7,      // APB address width (window = 1<<ADDRW bytes, 7..16)
    parameter                 SYNC_EN       = 1,      // 1 => two-stage synchroniser per gpio_i bit; 0 => gpio_i is pclk_aon_i-synchronous
    parameter           [8:0] MDELEG_RST    = 9'h10F, // MDELEG[8:0] reset value (default: M-mode only, PSLVERR)
    parameter                 ALT_NR        = 0,      // Alternate functions per pin (0..4); functions ALT_NR..3 are absent
    parameter                 INP_CGATE_EN  = 1,      // 1 => input path on pclk_aon_i through an internal clock gate; 0 => ungated (FPGA)
    parameter                 ASYNC_RST_EN  = 1       // Reset style: 1=async active-low reset, 0=synchronous reset
) (

// APB CLOCK & RESET
    input  wire               pclk_i,                 // bus clock (gated by pclk_en_o at the SoC-level ICG)
    input  wire               pclk_aon_i,             // always-on clock: pclk_i before its ICG
    input  wire               presetn_i,              // active-low reset, style per ASYNC_RST_EN (sync de-assert required at IP boundary)
    output wire               pclk_en_o,              // bus clock-gate enable; must drive an external ICG cell
    input  wire               scan_mode_i,            // 1 = scan/test mode: forces the input-path clock gate open. Tie LOW functionally.

// APB INTERFACE
    input  wire               psel_i,                 // completer select
    input  wire               penable_i,              // ACCESS phase
    input  wire   [ADDRW-1:0] paddr_i,                // byte address
    input  wire               pwrite_i,               // write
    input  wire        [31:0] pwdata_i,               // write data
    input  wire         [3:0] pstrb_i,                // write strobes (0 for reads)
    input  wire         [2:0] pprot_i,                // protection ([0] privileged; [2:1] not used)
    input  wire               psmode_i,               // aRVern S-mode sideband (with the timing of pprot)
    output wire        [31:0] prdata_o,               // read data
    output wire               pready_o,               // ready (no wait states)
    output wire               pslverr_o,              // error (access refused by MDELEG with RESP=1)

// PINS
    input  wire [GPIO_NR-1:0] gpio_i,                 // pin input values (asynchronous when SYNC_EN=1, else pclk_aon_i-synchronous)
    output wire [GPIO_NR-1:0] gpio_o,                 // pin output values (OUTPUT, or the selected alternate function)
    output wire [GPIO_NR-1:0] gpio_oe_o,              // pin output enables (OE, or the selected alternate function), 1 = drive
    output wire [GPIO_NR-1:0] gpio_ie_o,              // pin input enables (IN_EN), for a pad receiver enable; 1 = receive

// ALTERNATE FUNCTIONS (bit n = pin n; tie the inputs of absent or unused functions to 0)
    input  wire [GPIO_NR-1:0] alt0_o_i,               // alternate function 0: output values
    input  wire [GPIO_NR-1:0] alt0_oe_i,              // alternate function 0: output enables
    output wire [GPIO_NR-1:0] alt0_act_o,             // alternate function 0 owns the pin
    input  wire [GPIO_NR-1:0] alt1_o_i,               // alternate function 1: output values
    input  wire [GPIO_NR-1:0] alt1_oe_i,              // alternate function 1: output enables
    output wire [GPIO_NR-1:0] alt1_act_o,             // alternate function 1 owns the pin
    input  wire [GPIO_NR-1:0] alt2_o_i,               // alternate function 2: output values
    input  wire [GPIO_NR-1:0] alt2_oe_i,              // alternate function 2: output enables
    output wire [GPIO_NR-1:0] alt2_act_o,             // alternate function 2 owns the pin
    input  wire [GPIO_NR-1:0] alt3_o_i,               // alternate function 3: output values
    input  wire [GPIO_NR-1:0] alt3_oe_i,              // alternate function 3: output enables
    output wire [GPIO_NR-1:0] alt3_act_o,             // alternate function 3 owns the pin

// INTERRUPTS
    output wire [GPIO_NR-1:0] irq_o,                  // per-pin interrupt: IRQ_PEND & IRQ_EN
    output wire               irq_any_o,              // OR of irq_o

// WAKE
    output wire               gpio_wake_o             // asynchronous wake request: combinational from gpio_i, may glitch
 );


//=============================================================================
// 1)  PARAMETER DECLARATION
//=============================================================================

// pragma translate_off
generate
    if ((GPIO_NR < 1) || (GPIO_NR > 32)) begin : CHECK_GPIO_NR
        initial $fatal(1, "apb_gpio: GPIO_NR (%0d) must be 1..32.", GPIO_NR);
    end
    if ((ADDRW < 7) || (ADDRW > 16)) begin : CHECK_ADDRW
        initial $fatal(1, "apb_gpio: ADDRW (%0d) must be 7..16.", ADDRW);
    end
    if ((SYNC_EN != 0) && (SYNC_EN != 1)) begin : CHECK_SYNC_EN
        initial $fatal(1, "apb_gpio: SYNC_EN (%0d) must be 0 or 1.", SYNC_EN);
    end
    // A reset value must be one a write could store: no reserved privilege
    // code (2'b10) in WR_PRIV / RD_PRIV, and the reserved bits [7:4] zero.
    if ((MDELEG_RST[1:0] == 2'b10) || (MDELEG_RST[3:2] == 2'b10) || (MDELEG_RST[7:4] != 4'h0)) begin : CHECK_MDELEG_RST
        initial $fatal(1, "apb_gpio: MDELEG_RST (9'h%03h) holds a reserved privilege code or a reserved bit.", MDELEG_RST);
    end
    if ((ALT_NR < 0) || (ALT_NR > 4)) begin : CHECK_ALT_NR
        initial $fatal(1, "apb_gpio: ALT_NR (%0d) must be 0..4.", ALT_NR);
    end
    if ((INP_CGATE_EN != 0) && (INP_CGATE_EN != 1)) begin : CHECK_INP_CGATE_EN
        initial $fatal(1, "apb_gpio: INP_CGATE_EN (%0d) must be 0 or 1.", INP_CGATE_EN);
    end
    if ((ASYNC_RST_EN != 0) && (ASYNC_RST_EN != 1)) begin : CHECK_ASYNC_RST_EN
        initial $fatal(1, "apb_gpio: ASYNC_RST_EN (%0d) must be 0 or 1.", ASYNC_RST_EN);
    end
endgenerate
// pragma translate_on


// Decoder bit width (word address within the window)
localparam              DEC_WD        =  ADDRW-2;

// Alternate-function registers present
localparam              ALT_EN_USE    =  (ALT_NR > 0);
localparam              ALT_SEL0_USE  =  (ALT_NR > 1);
localparam              ALT_SEL1_USE  =  (ALT_NR > 2);

// INFO register: pin mask, bits [GPIO_NR-1:0] set
localparam       [31:0] INFO_VAL      =  {32{1'b1}} >> (32-GPIO_NR);

// CFG register: build parameters software cannot otherwise see
localparam        [3:0] CFG_VERSION   =  4'h1;
localparam        [2:0] CFG_ALT_NR    =  ALT_NR[2:0];
localparam              CFG_SYNC      =  (SYNC_EN      == 1);
localparam              CFG_CGATE     =  (INP_CGATE_EN == 1);
localparam       [31:0] CFG_VAL       =  {CFG_VERSION, 22'h000000, CFG_CGATE, CFG_SYNC, 1'b0, CFG_ALT_NR};

// MDELEG register reset values, the fields of MDELEG_RST
localparam        [1:0] MDELEG_WR_PRIV_RST = MDELEG_RST[1:0];
localparam        [1:0] MDELEG_RD_PRIV_RST = MDELEG_RST[3:2];
localparam              MDELEG_RESP_RST    = MDELEG_RST[8];

// MDELEG priv-field reserved encoding (treated as "Machine-mode only")
localparam        [1:0] MDELEG_PRIV_RSVD   = 2'b10;

// Register word offsets
localparam [DEC_WD-1:0] REG_INFO       = 'h00,
                        REG_IN_EN      = 'h01,
                        REG_OE         = 'h02,
                        REG_INPUT      = 'h03,
                        REG_OUTPUT     = 'h04,
                        REG_OUT_SET    = 'h05,
                        REG_OUT_CLR    = 'h06,
                        REG_OUT_TGL    = 'h07,
                        REG_IRQ_EN     = 'h08,
                        REG_IRQ_PEND   = 'h09,
                        REG_WAKE_EN    = 'h0A,
                        REG_CFG        = 'h0B,
                        REG_IRQ_RISE   = 'h0C,
                        REG_IRQ_FALL   = 'h0D,
                        REG_IRQ_HIGH   = 'h0E,
                        REG_IRQ_LOW    = 'h0F,
                        REG_ALT_EN     = 'h10,
                        REG_ALT_SEL0   = 'h11,
                        REG_ALT_SEL1   = 'h12,
                        REG_IRQ_STAT   = 'h13,
                        REG_OE_SET     = 'h14,
                        REG_OE_CLR     = 'h15,
                        REG_IRQ_EN_SET = 'h16,
                        REG_IRQ_EN_CLR = 'h17,
                        REG_MDELEG     = 'h18;


//=============================================================================
// 2)  INTERNAL WIRES/REGISTERS/PARAMETERS DECLARATION
//=============================================================================

wire                    acc_valid;            // APB ACCESS phase
wire                    acc_write;            // APB write ACCESS phase
wire                    acc_read;             // APB read ACCESS phase
wire       [DEC_WD-1:0] acc_addr;             // register word address
wire                    acc_allowed;          // Access admitted by MDELEG
wire                    machine_mode;         // Machine mode detected
wire                    supervisor_mode;      // Supervisor mode detected
wire              [1:0] privilege_mode;       // Current privilege mode (11: Machine; 01: Supervisor; 00: User)
wire              [1:0] mdeleg_wr_priv;       // MDELEG.WR_PRIV
wire              [1:0] mdeleg_rd_priv;       // MDELEG.RD_PRIV
wire                    mdeleg_resp;          // MDELEG.RESP
wire             [31:0] mdeleg;               // MDELEG read value

wire                    reg_wr;               // Admitted write ACCESS phase
wire                    reg_rd;               // Admitted read ACCESS phase
wire             [31:0] lane_mask;            // Byte mask expanded to bits
wire      [GPIO_NR-1:0] wmask;                // Written bits of the pin field
wire      [GPIO_NR-1:0] wdata;                // Write data of the pin field

wire                    clk_inp;              // Input-path clock: gated pclk_aon_i
wire                    clk_inp_en;           // Input-path clock request
wire      [GPIO_NR-1:0] gpio_sync;            // Input stage: synchroniser output (or gpio_i)
wire      [GPIO_NR-1:0] gpio_in;              // Input register, held at 0 while IN_EN=0
wire      [GPIO_NR-1:0] gpio_in_prev;         // Input register one cycle earlier
wire      [GPIO_NR-1:0] in_flushed;           // Input register holds a sample taken with IN_EN=1
wire      [GPIO_NR-1:0] in_prev_vld;          // Previous sample is valid too
wire                    in_vld_any;           // A valid bit of the flush pipeline is set
wire      [GPIO_NR-1:0] in_ok;                // Input register valid and pin enabled
wire      [GPIO_NR-1:0] prev_ok;              // Previous sample valid and pin enabled
wire      [GPIO_NR-1:0] gpio_rise;            // Rising edge detected
wire      [GPIO_NR-1:0] gpio_fall;            // Falling edge detected

wire      [GPIO_NR-1:0] out_q;                // OUTPUT
wire      [GPIO_NR-1:0] oe_q;                 // OE
wire      [GPIO_NR-1:0] irq_en_q;             // IRQ_EN
wire      [GPIO_NR-1:0] irq_rise_q;           // IRQ_RISE
wire      [GPIO_NR-1:0] irq_fall_q;           // IRQ_FALL
wire      [GPIO_NR-1:0] irq_high_q;           // IRQ_HIGH
wire      [GPIO_NR-1:0] irq_low_q;            // IRQ_LOW
wire      [GPIO_NR-1:0] in_en_q;              // IN_EN
wire      [GPIO_NR-1:0] wake_en_q;            // WAKE_EN
wire      [GPIO_NR-1:0] alt_en_q;             // ALT_EN
wire      [GPIO_NR-1:0] alt_sel0_q;           // ALT_SEL0
wire      [GPIO_NR-1:0] alt_sel1_q;           // ALT_SEL1
wire    [4*GPIO_NR-1:0] alt_o_all;            // Alternate functions 3..0: output values
wire    [4*GPIO_NR-1:0] alt_oe_all;           // Alternate functions 3..0: output enables
wire    [4*GPIO_NR-1:0] alt_act;              // Alternate function k owns pin n (bit k*GPIO_NR+n)
wire    [4*GPIO_NR-1:0] alt_o_fn;             // Output values routed by each function
wire    [4*GPIO_NR-1:0] alt_oe_fn;            // Output enables routed by each function
wire      [GPIO_NR-1:0] irq_latch_q;          // IRQ_PEND latched edge bits
wire      [GPIO_NR-1:0] irq_pend;             // IRQ_PEND read value (latched edges | live levels)
wire      [GPIO_NR-1:0] wake_rise;            // Wake-enabled pin rises and would report it
wire      [GPIO_NR-1:0] wake_fall;            // Wake-enabled pin falls and would report it
wire      [GPIO_NR-1:0] wake_any;             // Wake-enabled pin with no mode set changes

wire      [GPIO_NR-1:0] rd_pins;              // Read mux, pin-field registers
wire             [31:0] rd_pins_ext;          // Read mux, pin field zero-extended to 32 bits
wire                    rst_clk_req;          // Clock request during a synchronous reset


//=============================================================================
// 3)  APB ACCESS PHASE DETECTION
//=============================================================================
// APB holds the address, control and write data stable from SETUP to the end
// of ACCESS: the transfer is decoded straight from the bus. Writes take effect
// at the end of the ACCESS cycle; every transfer completes in that cycle.

assign acc_valid    =  psel_i & penable_i;
assign acc_write    =  acc_valid &  pwrite_i;
assign acc_read     =  acc_valid & ~pwrite_i;
assign acc_addr     =  paddr_i[ADDRW-1:2];

// Admitted accesses only: a denied write changes nothing, a denied read returns 0
assign reg_wr       =  acc_write & acc_allowed;
assign reg_rd       =  acc_read  & acc_allowed;

assign lane_mask    =  {{8{pstrb_i[3]}}, {8{pstrb_i[2]}}, {8{pstrb_i[1]}}, {8{pstrb_i[0]}}};
assign wmask        =  lane_mask[GPIO_NR-1:0];
assign wdata        =  pwdata_i[GPIO_NR-1:0];

assign pready_o     =  1'b1;


//=============================================================================
// 4)  PRIVILEGE DECODE
//=============================================================================
// {pprot[0], psmode} = 1,0 -> Machine, 1,1 -> Supervisor, 0,x -> User.

assign machine_mode    =  pprot_i[0] & ~psmode_i;
assign supervisor_mode =  pprot_i[0] &  psmode_i;
assign privilege_mode  =  machine_mode     ? 2'b11 :
                          supervisor_mode  ? 2'b01 :
                                             2'b00 ;


//=============================================================================
// 5)  REGISTER DECODER
//=============================================================================
// The full word address is compared, so a window wider than the register map
// leaves every other offset unmapped (reads 0, writes ignored).

wire                sel_output   = (acc_addr == REG_OUTPUT  );
wire                sel_oe       = (acc_addr == REG_OE      );
wire                sel_out_set  = (acc_addr == REG_OUT_SET );
wire                sel_out_clr  = (acc_addr == REG_OUT_CLR );
wire                sel_out_tgl  = (acc_addr == REG_OUT_TGL );
wire                sel_irq_en   = (acc_addr == REG_IRQ_EN  );
wire                sel_irq_rise = (acc_addr == REG_IRQ_RISE);
wire                sel_irq_fall = (acc_addr == REG_IRQ_FALL);
wire                sel_irq_high = (acc_addr == REG_IRQ_HIGH);
wire                sel_irq_low  = (acc_addr == REG_IRQ_LOW );
wire                sel_irq_pend = (acc_addr == REG_IRQ_PEND);
wire                sel_input    = (acc_addr == REG_INPUT   );
wire                sel_info     = (acc_addr == REG_INFO    );
wire                sel_in_en    = (acc_addr == REG_IN_EN   );
wire                sel_wake_en  = (acc_addr == REG_WAKE_EN );
wire                sel_alt_en   = (acc_addr == REG_ALT_EN  );
wire                sel_alt_sel0 = (acc_addr == REG_ALT_SEL0);
wire                sel_alt_sel1 = (acc_addr == REG_ALT_SEL1);
wire                sel_cfg      = (acc_addr == REG_CFG     );
wire                sel_irq_stat = (acc_addr == REG_IRQ_STAT);
wire                sel_oe_set   = (acc_addr == REG_OE_SET  );
wire                sel_oe_clr   = (acc_addr == REG_OE_CLR  );
wire                sel_ien_set  = (acc_addr == REG_IRQ_EN_SET);
wire                sel_ien_clr  = (acc_addr == REG_IRQ_EN_CLR);
wire                sel_mdeleg   = (acc_addr == REG_MDELEG  );

// Per-register written-bit masks (byte lanes of the access)
wire  [GPIO_NR-1:0] wr_output    = wmask & {GPIO_NR{reg_wr & sel_output  }};
wire  [GPIO_NR-1:0] wr_oe        = wmask & {GPIO_NR{reg_wr & sel_oe      }};
wire  [GPIO_NR-1:0] wr_out_set   = wmask & {GPIO_NR{reg_wr & sel_out_set }};
wire  [GPIO_NR-1:0] wr_out_clr   = wmask & {GPIO_NR{reg_wr & sel_out_clr }};
wire  [GPIO_NR-1:0] wr_out_tgl   = wmask & {GPIO_NR{reg_wr & sel_out_tgl }};
wire  [GPIO_NR-1:0] wr_irq_en    = wmask & {GPIO_NR{reg_wr & sel_irq_en  }};
wire  [GPIO_NR-1:0] wr_irq_rise  = wmask & {GPIO_NR{reg_wr & sel_irq_rise}};
wire  [GPIO_NR-1:0] wr_irq_fall  = wmask & {GPIO_NR{reg_wr & sel_irq_fall}};
wire  [GPIO_NR-1:0] wr_irq_high  = wmask & {GPIO_NR{reg_wr & sel_irq_high}};
wire  [GPIO_NR-1:0] wr_irq_low   = wmask & {GPIO_NR{reg_wr & sel_irq_low }};
wire  [GPIO_NR-1:0] wr_irq_pend  = wmask & {GPIO_NR{reg_wr & sel_irq_pend}};
wire  [GPIO_NR-1:0] wr_in_en     = wmask & {GPIO_NR{reg_wr & sel_in_en   }};
wire  [GPIO_NR-1:0] wr_wake_en   = wmask & {GPIO_NR{reg_wr & sel_wake_en }};
wire  [GPIO_NR-1:0] wr_oe_set    = wmask & {GPIO_NR{reg_wr & sel_oe_set  }};
wire  [GPIO_NR-1:0] wr_oe_clr    = wmask & {GPIO_NR{reg_wr & sel_oe_clr  }};
wire  [GPIO_NR-1:0] wr_ien_set   = wmask & {GPIO_NR{reg_wr & sel_ien_set }};
wire  [GPIO_NR-1:0] wr_ien_clr   = wmask & {GPIO_NR{reg_wr & sel_ien_clr }};


//=============================================================================
// 6)  MDELEG REGISTER AND ERROR RESPONSE
//=============================================================================
//
//      31                9     8    7         4    3    2    1    0
//     +--------------------+------+-------------+---------+----------+
//     |      reserved      | RESP |   reserved  | RD_PRIV | WR_PRIV  |
//     +--------------------+------+-------------+---------+----------+
//
// WR_PRIV: minimum privilege level for a write at any other offset
// RD_PRIV: minimum privilege level for a read at any other offset
//          (0: User-Mode; 1: Supervisor-Mode; 2: reserved; 3: Machine-Mode)
// RESP   : response to a refused access (0: ignore it; 1: PSLVERR)
//
// MDELEG itself is Machine-mode only, whatever the gates say.

// This register can only be changed when in Machine-Mode
wire                mdeleg_priv_wr       = acc_write & sel_mdeleg & pstrb_i[0] & machine_mode;
wire                mdeleg_resp_wr       = acc_write & sel_mdeleg & pstrb_i[1] & machine_mode;

// Coerce the reserved 2'b10 encoding to Machine-mode only (2'b11) at write
// time, so the register never holds or reads back a reserved code.
wire          [1:0] mdeleg_wr_priv_wdata = (pwdata_i[1:0] == MDELEG_PRIV_RSVD) ? 2'b11 : pwdata_i[1:0];
wire          [1:0] mdeleg_rd_priv_wdata = (pwdata_i[3:2] == MDELEG_PRIV_RSVD) ? 2'b11 : pwdata_i[3:2];

arv_ipdff #(.WIDTH(2), .RST_VAL(MDELEG_WR_PRIV_RST), .ARST_EN(ASYNC_RST_EN)) u_mdeleg_wr_priv (
                           .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(mdeleg_priv_wr), .d_i(mdeleg_wr_priv_wdata), .q_o(mdeleg_wr_priv));

arv_ipdff #(.WIDTH(2), .RST_VAL(MDELEG_RD_PRIV_RST), .ARST_EN(ASYNC_RST_EN)) u_mdeleg_rd_priv (
                           .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(mdeleg_priv_wr), .d_i(mdeleg_rd_priv_wdata), .q_o(mdeleg_rd_priv));

arv_ipdff #(.WIDTH(1), .RST_VAL(MDELEG_RESP_RST), .ARST_EN(ASYNC_RST_EN))    u_mdeleg_resp (
                           .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(mdeleg_resp_wr), .d_i(pwdata_i[8]),          .q_o(mdeleg_resp));

assign mdeleg       =  {23'h000000, mdeleg_resp, 4'h0, mdeleg_rd_priv, mdeleg_wr_priv};

// An access is admitted if the requester's privilege is at least the gate's;
// MDELEG itself admits Machine mode only.
wire                wr_allowed   = sel_mdeleg ? machine_mode : (privilege_mode >= mdeleg_wr_priv);
wire                rd_allowed   = sel_mdeleg ? machine_mode : (privilege_mode >= mdeleg_rd_priv);

assign acc_allowed  =  pwrite_i ? wr_allowed : rd_allowed;

// A refused access gets PSLVERR in its ACCESS cycle when RESP=1, at any offset
assign pslverr_o    =  acc_valid & mdeleg_resp & ~acc_allowed;


//=============================================================================
// 7)  BUS-SIDE REGISTERS (pclk_i)
//=============================================================================
// OUTPUT, OUT_SET, OUT_CLR and OUT_TGL are distinct offsets, so at most one
// of their masks is non-zero in a cycle; likewise OE / OE_SET / OE_CLR and
// IRQ_EN / IRQ_EN_SET / IRQ_EN_CLR.

wire  [GPIO_NR-1:0] out_nxt      = ((((out_q & ~wr_output) | (wdata & wr_output)) |
                                      (wdata & wr_out_set))                         &
                                    ~(wdata & wr_out_clr))                          ^
                                     (wdata & wr_out_tgl);

wire  [GPIO_NR-1:0] oe_nxt       = (((oe_q     & ~wr_oe      ) | (wdata & wr_oe      ))  |
                                      (wdata & wr_oe_set))                             &
                                    ~(wdata & wr_oe_clr);
wire  [GPIO_NR-1:0] irq_en_nxt   = (((irq_en_q & ~wr_irq_en  ) | (wdata & wr_irq_en  ))  |
                                      (wdata & wr_ien_set))                            &
                                    ~(wdata & wr_ien_clr);
wire  [GPIO_NR-1:0] irq_rise_nxt = (irq_rise_q & ~wr_irq_rise) | (wdata & wr_irq_rise);
wire  [GPIO_NR-1:0] irq_fall_nxt = (irq_fall_q & ~wr_irq_fall) | (wdata & wr_irq_fall);
wire  [GPIO_NR-1:0] irq_high_nxt = (irq_high_q & ~wr_irq_high) | (wdata & wr_irq_high);
wire  [GPIO_NR-1:0] irq_low_nxt  = (irq_low_q  & ~wr_irq_low ) | (wdata & wr_irq_low );
wire  [GPIO_NR-1:0] in_en_nxt    = (in_en_q    & ~wr_in_en   ) | (wdata & wr_in_en   );
wire  [GPIO_NR-1:0] wake_en_nxt  = (wake_en_q  & ~wr_wake_en ) | (wdata & wr_wake_en );

arv_ipdff #(.WIDTH(GPIO_NR), .ARST_EN(ASYNC_RST_EN)) u_out (
                           .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(out_nxt),      .q_o(out_q));

arv_ipdff #(.WIDTH(GPIO_NR), .ARST_EN(ASYNC_RST_EN)) u_oe (
                           .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(oe_nxt),       .q_o(oe_q));

arv_ipdff #(.WIDTH(GPIO_NR), .ARST_EN(ASYNC_RST_EN)) u_irq_en (
                           .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(irq_en_nxt),   .q_o(irq_en_q));

arv_ipdff #(.WIDTH(GPIO_NR), .ARST_EN(ASYNC_RST_EN)) u_irq_rise (
                           .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(irq_rise_nxt), .q_o(irq_rise_q));

arv_ipdff #(.WIDTH(GPIO_NR), .ARST_EN(ASYNC_RST_EN)) u_irq_fall (
                           .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(irq_fall_nxt), .q_o(irq_fall_q));

arv_ipdff #(.WIDTH(GPIO_NR), .ARST_EN(ASYNC_RST_EN)) u_irq_high (
                           .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(irq_high_nxt), .q_o(irq_high_q));

arv_ipdff #(.WIDTH(GPIO_NR), .ARST_EN(ASYNC_RST_EN)) u_irq_low (
                           .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(irq_low_nxt),  .q_o(irq_low_q));

arv_ipdff #(.WIDTH(GPIO_NR), .ARST_EN(ASYNC_RST_EN)) u_in_en (
                           .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(in_en_nxt),    .q_o(in_en_q));

arv_ipdff #(.WIDTH(GPIO_NR), .ARST_EN(ASYNC_RST_EN)) u_wake_en (
                           .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(wake_en_nxt),  .q_o(wake_en_q));



//=============================================================================
// 8)  ALTERNATE FUNCTIONS
//=============================================================================
// A pin with ALT_EN=1 is driven by alternate function {ALT_SEL1, ALT_SEL0};
// a function number at or above ALT_NR drives nothing (gpio_oe_o=0).
// Absent registers read 0 and ignore writes.

generate
    if (ALT_EN_USE) begin : G_ALT_EN
        wire  [GPIO_NR-1:0] wr_alt_en    = wmask & {GPIO_NR{reg_wr & sel_alt_en  }};
        wire  [GPIO_NR-1:0] alt_en_nxt   = (alt_en_q   & ~wr_alt_en  ) | (wdata & wr_alt_en  );

        arv_ipdff #(.WIDTH(GPIO_NR), .ARST_EN(ASYNC_RST_EN)) u_alt_en (
                           .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(alt_en_nxt),   .q_o(alt_en_q));
    end else begin : G_NO_ALT_EN
        assign alt_en_q = {GPIO_NR{1'b0}};
    end

    if (ALT_SEL0_USE) begin : G_ALT_SEL0
        wire  [GPIO_NR-1:0] wr_alt_sel0  = wmask & {GPIO_NR{reg_wr & sel_alt_sel0}};
        wire  [GPIO_NR-1:0] alt_sel0_nxt = (alt_sel0_q & ~wr_alt_sel0) | (wdata & wr_alt_sel0);

        arv_ipdff #(.WIDTH(GPIO_NR), .ARST_EN(ASYNC_RST_EN)) u_alt_sel0 (
                           .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(alt_sel0_nxt), .q_o(alt_sel0_q));
    end else begin : G_NO_ALT_SEL0
        assign alt_sel0_q = {GPIO_NR{1'b0}};
    end

    if (ALT_SEL1_USE) begin : G_ALT_SEL1
        wire  [GPIO_NR-1:0] wr_alt_sel1  = wmask & {GPIO_NR{reg_wr & sel_alt_sel1}};
        wire  [GPIO_NR-1:0] alt_sel1_nxt = (alt_sel1_q & ~wr_alt_sel1) | (wdata & wr_alt_sel1);

        arv_ipdff #(.WIDTH(GPIO_NR), .ARST_EN(ASYNC_RST_EN)) u_alt_sel1 (
                           .clk_i(pclk_i), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(alt_sel1_nxt), .q_o(alt_sel1_q));
    end else begin : G_NO_ALT_SEL1
        assign alt_sel1_q = {GPIO_NR{1'b0}};
    end
endgenerate

assign alt_o_all    =  {alt3_o_i,  alt2_o_i,  alt1_o_i,  alt0_o_i };
assign alt_oe_all   =  {alt3_oe_i, alt2_oe_i, alt1_oe_i, alt0_oe_i};

genvar              gk;
generate
    for (gk = 0; gk < 4; gk = gk + 1) begin : G_ALT_FN
        if (gk < ALT_NR) begin : G_FN
            assign alt_act  [gk*GPIO_NR +: GPIO_NR] = alt_en_q                                   &
                                                      (((gk & 2) != 0) ? alt_sel1_q : ~alt_sel1_q) &
                                                      (((gk & 1) != 0) ? alt_sel0_q : ~alt_sel0_q);
            assign alt_o_fn [gk*GPIO_NR +: GPIO_NR] = alt_o_all [gk*GPIO_NR +: GPIO_NR] & alt_act[gk*GPIO_NR +: GPIO_NR];
            assign alt_oe_fn[gk*GPIO_NR +: GPIO_NR] = alt_oe_all[gk*GPIO_NR +: GPIO_NR] & alt_act[gk*GPIO_NR +: GPIO_NR];
        end else begin : G_NO_FN
            assign alt_act  [gk*GPIO_NR +: GPIO_NR] = {GPIO_NR{1'b0}};
            assign alt_o_fn [gk*GPIO_NR +: GPIO_NR] = {GPIO_NR{1'b0}};
            assign alt_oe_fn[gk*GPIO_NR +: GPIO_NR] = {GPIO_NR{1'b0}};
            wire                  alt_fn_unused     = |{alt_o_all [gk*GPIO_NR +: GPIO_NR],
                                                        alt_oe_all[gk*GPIO_NR +: GPIO_NR]};
        end
    end
endgenerate

assign alt0_act_o   =  alt_act[0*GPIO_NR +: GPIO_NR];
assign alt1_act_o   =  alt_act[1*GPIO_NR +: GPIO_NR];
assign alt2_act_o   =  alt_act[2*GPIO_NR +: GPIO_NR];
assign alt3_act_o   =  alt_act[3*GPIO_NR +: GPIO_NR];

assign gpio_o       =  (out_q & ~alt_en_q)            |
                        alt_o_fn [0*GPIO_NR +: GPIO_NR] | alt_o_fn [1*GPIO_NR +: GPIO_NR] |
                        alt_o_fn [2*GPIO_NR +: GPIO_NR] | alt_o_fn [3*GPIO_NR +: GPIO_NR];
assign gpio_oe_o    =  (oe_q  & ~alt_en_q)            |
                        alt_oe_fn[0*GPIO_NR +: GPIO_NR] | alt_oe_fn[1*GPIO_NR +: GPIO_NR] |
                        alt_oe_fn[2*GPIO_NR +: GPIO_NR] | alt_oe_fn[3*GPIO_NR +: GPIO_NR];

// The pad receiver may follow IN_EN; a peripheral input then needs it too
assign gpio_ie_o    =  in_en_q;


//=============================================================================
// 9)  CLOCKS
//=============================================================================
// Bus clock: requested while the completer is selected (the reset generator
// requests it during a synchronous reset). Input-path clock: pclk_aon_i gated
// open while an input is enabled, while the flush pipeline still holds a
// valid bit (one edge clears it after IN_EN drops, so a re-enable never sees
// a stale one), for an IRQ_PEND clear, and during a synchronous reset.

wire                irq_pend_clr = reg_wr & sel_irq_pend;

generate
    if (ASYNC_RST_EN == 0) begin : G_RST_CLK_REQ
        assign rst_clk_req = ~presetn_i;
    end else begin : G_NO_RST_CLK_REQ
        assign rst_clk_req = 1'b0;
    end
endgenerate

assign pclk_en_o    =  psel_i;

assign clk_inp_en   =  (|in_en_q) | in_vld_any | irq_pend_clr | rst_clk_req;

// INP_CGATE_EN=0 runs the input path on pclk_aon_i directly: the logic never relies on
// the gate (disabled pins and the flush state are cleared by logic), so only power changes.
generate
    if (INP_CGATE_EN == 1) begin : G_INP_CGATE
        arv_cgate u_inp_cgate (
                           .clk_i(pclk_aon_i), .en_i(clk_inp_en), .test_en_i(scan_mode_i), .clk_o(clk_inp));
    end else begin : G_NO_INP_CGATE
        assign clk_inp = pclk_aon_i;
        wire   clk_inp_en_unused  = clk_inp_en;
        wire   scan_mode_unused   = scan_mode_i;
    end
endgenerate


//=============================================================================
// 10) INPUT STAGE (clk_inp)
//=============================================================================
// SYNC_EN=1: gpio_i -> 2-FF synchroniser -> input register (3 edges)
// SYNC_EN=0: gpio_i -> input register (1 edge)
// The input register is held at 0 while IN_EN=0. A per-pin valid pipeline of
// the same depth, fed and cleared by IN_EN, marks when the input register
// holds a real sample (in_flushed) and, one edge later, when the previous
// sample does too (in_prev_vld). Nothing is reported from a pin until then,
// and clearing IN_EN masks it at once.

genvar g;
generate
    if (SYNC_EN == 1) begin : G_SYNC
        wire [GPIO_NR-1:0] vld_s1;
        wire [GPIO_NR-1:0] vld_s2;

        for (g = 0; g < GPIO_NR; g = g + 1) begin : g_bit
            arv_synchronizer #(.W(1), .RST_VAL(1'b0), .ARST_EN(ASYNC_RST_EN)) u_gpio_sync (
                           .clk_i(clk_inp), .rst_n_i(presetn_i), .async_i(gpio_i[g]), .sync_o(gpio_sync[g]));
        end

        arv_ipdff #(.WIDTH(GPIO_NR), .ARST_EN(ASYNC_RST_EN)) u_vld_s1 (
                           .clk_i(clk_inp), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(in_en_q),           .q_o(vld_s1));

        arv_ipdff #(.WIDTH(GPIO_NR), .ARST_EN(ASYNC_RST_EN)) u_vld_s2 (
                           .clk_i(clk_inp), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(in_en_q & vld_s1),  .q_o(vld_s2));

        arv_ipdff #(.WIDTH(GPIO_NR), .ARST_EN(ASYNC_RST_EN)) u_vld_in (
                           .clk_i(clk_inp), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(in_en_q & vld_s2),  .q_o(in_flushed));

        assign in_vld_any = |{vld_s1, vld_s2, in_flushed, in_prev_vld};

    end else begin : G_NO_SYNC
        assign gpio_sync  = gpio_i;

        arv_ipdff #(.WIDTH(GPIO_NR), .ARST_EN(ASYNC_RST_EN)) u_vld_in (
                           .clk_i(clk_inp), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(in_en_q),           .q_o(in_flushed));

        assign in_vld_any = |{in_flushed, in_prev_vld};
    end
endgenerate

assign in_ok        =  in_en_q & in_flushed;
assign prev_ok      =  in_en_q & in_prev_vld;

arv_ipdff #(.WIDTH(GPIO_NR), .ARST_EN(ASYNC_RST_EN)) u_gpio_in (
                           .clk_i(clk_inp), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(gpio_sync & in_en_q), .q_o(gpio_in));

arv_ipdff #(.WIDTH(GPIO_NR), .ARST_EN(ASYNC_RST_EN)) u_gpio_in_prev (
                           .clk_i(clk_inp), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(gpio_in),             .q_o(gpio_in_prev));

arv_ipdff #(.WIDTH(GPIO_NR), .ARST_EN(ASYNC_RST_EN)) u_vld_prev (
                           .clk_i(clk_inp), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(in_ok),               .q_o(in_prev_vld));

assign gpio_rise    =  in_ok & prev_ok &  gpio_in & ~gpio_in_prev;
assign gpio_fall    =  in_ok & prev_ok & ~gpio_in &  gpio_in_prev;

// Wake: a flushed, wake-enabled pin differs from its last sample in the
// direction its modes would report (rise: IRQ_RISE or IRQ_HIGH; fall:
// IRQ_FALL or IRQ_LOW); a pin with no mode set wakes on any change.
wire  [GPIO_NR-1:0] wake_pin      = wake_en_q & in_ok;
wire  [GPIO_NR-1:0] mode_none     = ~(irq_rise_q | irq_fall_q | irq_high_q | irq_low_q);

assign wake_rise    =  wake_pin &  gpio_i & ~gpio_in & (irq_rise_q | irq_high_q);
assign wake_fall    =  wake_pin & ~gpio_i &  gpio_in & (irq_fall_q | irq_low_q );
assign wake_any     =  wake_pin & (gpio_i ^ gpio_in) & mode_none;

assign gpio_wake_o  =  |(wake_rise | wake_fall | wake_any);


//=============================================================================
// 11) INTERRUPT PENDING (clk_inp)
//=============================================================================

// Edge latch: a detected edge sets the bit, a W1C write clears it; a new edge
// in the same cycle as the clear wins.
wire  [GPIO_NR-1:0] irq_edge      = (gpio_rise & irq_rise_q) | (gpio_fall & irq_fall_q);
wire  [GPIO_NR-1:0] irq_latch_nxt = (irq_latch_q & ~(wdata & wr_irq_pend)) | irq_edge;

arv_ipdff #(.WIDTH(GPIO_NR), .ARST_EN(ASYNC_RST_EN)) u_irq_latch (
                           .clk_i(clk_inp), .rst_n_i(presetn_i), .en_i(1'b1), .d_i(irq_latch_nxt), .q_o(irq_latch_q));

// Levels are live, not latched
assign irq_pend     =  irq_latch_q | (in_ok & ((gpio_in & irq_high_q) | (~gpio_in & irq_low_q)));

assign irq_o        =  irq_pend & irq_en_q;
assign irq_any_o    =  |irq_o;


//=============================================================================
// 12) READ MUX
//=============================================================================

assign rd_pins      =  (gpio_in    & {GPIO_NR{reg_rd & sel_input   }} & in_ok) |
                       (out_q      & {GPIO_NR{reg_rd & sel_output  }}) |
                       (oe_q       & {GPIO_NR{reg_rd & sel_oe      }}) |
                       (irq_en_q   & {GPIO_NR{reg_rd & sel_irq_en  }}) |
                       (irq_rise_q & {GPIO_NR{reg_rd & sel_irq_rise}}) |
                       (irq_fall_q & {GPIO_NR{reg_rd & sel_irq_fall}}) |
                       (irq_high_q & {GPIO_NR{reg_rd & sel_irq_high}}) |
                       (irq_low_q  & {GPIO_NR{reg_rd & sel_irq_low }}) |
                       (irq_pend   & {GPIO_NR{reg_rd & sel_irq_pend}}) |
                       (in_en_q    & {GPIO_NR{reg_rd & sel_in_en   }}) |
                       (wake_en_q  & {GPIO_NR{reg_rd & sel_wake_en }}) |
                       (alt_en_q   & {GPIO_NR{reg_rd & sel_alt_en  }}) |
                       (alt_sel0_q & {GPIO_NR{reg_rd & sel_alt_sel0}}) |
                       (alt_sel1_q & {GPIO_NR{reg_rd & sel_alt_sel1}}) |
                       (irq_o      & {GPIO_NR{reg_rd & sel_irq_stat}});

// Bits above GPIO_NR-1 read 0 and their write data is ignored
generate
    if (GPIO_NR < 32) begin : G_PIN_PAD
        assign rd_pins_ext = {{(32-GPIO_NR){1'b0}}, rd_pins};

        wire   upper_unused = |{pwdata_i[31:GPIO_NR], lane_mask[31:GPIO_NR]};
    end else begin : G_NO_PIN_PAD
        assign rd_pins_ext = rd_pins;
    end
endgenerate

assign prdata_o     =  rd_pins_ext |
                       (INFO_VAL & {32{reg_rd & sel_info  }}) |
                       (CFG_VAL  & {32{reg_rd & sel_cfg   }}) |
                       (mdeleg   & {32{reg_rd & sel_mdeleg}});


//-------------------------------------------------
// Lint cleanup
//-------------------------------------------------
wire  [1:0] paddr_unused     = paddr_i[1:0];
wire  [1:0] pprot_unused     = pprot_i[2:1];


endmodule // apb_gpio

`default_nettype wire
