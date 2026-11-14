//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    gpio_model
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : gpio_model.v
// Module Description : Cycle-accurate reference model of apb_gpio, written
//                      from doc/apb_gpio.md and included into tb_apb_gpio.
//
// It runs on the bench's pclk_aon (the input path, edge detector, pending
// latch) and applies the bus side only on edges where the bus-clock ICG is
// open (pclk_en_latch), i.e. on the DUT's pclk_i edges. It always tracks; it
// compares only while model_check_en is set (a test turns it on), from the
// next cycle on.
//
// Timing taken from the document:
//   - per pin, while IN_EN[n]=1: two synchroniser stages + the input register
//     with SYNC_EN=1 (3 edges), the input register only with SYNC_EN=0 (1);
//     while IN_EN[n]=0 the input register is held at 0, INPUT[n] reads 0
//     and the pin raises no edge, level or wake (gated by the IN_EN register
//     at once);
//   - enabling a pin flushes its stage: the input register holds a real
//     sample L cycles after the IN_EN write edge (INPUT reads 0 and no level
//     until then), edges are detected one cycle later;
//   - edges compare the input register with its value one cycle earlier and
//     SET the latched pending bit on the following edge; a W1C on the same
//     edge as a new edge leaves the bit set;
//   - levels are live: IRQ_PEND = latched | (HIGH & in) | (LOW & ~in);
//   - irq_o = IRQ_PEND & IRQ_EN, irq_any_o = |irq_o;
//   - a write takes effect at the end of its ACCESS cycle; a mode-register
//     write committing on the same edge as a detected edge does not take part
//     in that edge's latch decision (registers update on the edge);
//   - gpio_wake_o = |(WAKE_EN & IN_EN & flushed & change), "flushed" read as
//     "the input register holds a real sample", where a change counts in the
//     direction the pin's modes report: gpio_i high over a low input register
//     with IRQ_RISE or IRQ_HIGH, low over a high one with IRQ_FALL or IRQ_LOW,
//     either way with no mode set. Not compared while any wake-enabled pin is
//     flushing in either reading;
//   - MDELEG (doc "Access protection"): reset MDELEG_RST; written by Machine
//     mode only, lane 0 the two gates (2'b10 stored as 2'b11), lane 1 RESP;
//     an access at any other offset is admitted when the requester's level
//     (U 0, S 1, M 3) is at least the gate's; MDELEG itself admits Machine
//     mode only; a refused access changes nothing, reads 0 and gets PSLVERR
//     when RESP=1;
//   - gpio_ie_o = IN_EN;
//   - reads return the register state of the ACCESS cycle, INPUT and
//     IRQ_PEND included (PRDATA is formed combinationally in that cycle);
//   - after a write that changes IN_EN, irq_o / IRQ_PEND / INPUT / wake are
//     not compared for 2*L_IN+3 cycles (m_fuzzy): the flush boundary is
//     modelled exactly but a test using the model keeps the pins still
//     around IN_EN writes (random_stress freezes them).
//   - a latched edge survives clearing IN_EN; a W1C applies with every
//     IN_EN bit 0 (doc "Clocks": the input-path gate opens during a write to
//     IRQ_PEND);
//   - the synchroniser of a disabled pin keeps sampling but nothing it holds
//     is used before the flush: modelled by the per-pin "real sample" flags,
//     which is observably the same as holding the whole stage.
//----------------------------------------------------------------------------

reg         model_check_en;
reg         m_check_q;          // model_check_en delayed by one cycle

reg  [31:0] m_s1, m_s2;         // synchroniser stages (SYNC_EN=1)
reg  [31:0] m_in;               // input register
reg  [31:0] m_prev;             // input register one cycle earlier
reg  [31:0] m_v1, m_v2, m_v3;   // per-pin "real sample" flags along the stage
reg  [31:0] m_pvalid;           // previous sample real
reg  [31:0] m_out, m_oe;
reg  [31:0] m_en, m_rise, m_fall, m_high, m_low;
reg  [31:0] m_in_en, m_wake_en;
reg  [31:0] m_alt_en, m_alt_sel0, m_alt_sel1;
reg  [31:0] m_latch;            // latched edge part of IRQ_PEND
reg   [1:0] m_md_wr;            // MDELEG.WR_PRIV
reg   [1:0] m_md_rd;            // MDELEG.RD_PRIV
reg         m_md_resp;          // MDELEG.RESP
integer     m_fuzzy;

reg  [31:0] m_wbm;
reg  [31:0] m_wdat;
reg  [31:0] m_w1c;
reg  [31:0] m_nin_en;
reg  [31:0] m_exp;
reg         m_bus;
integer     m_errors;

wire [31:0] m_ivalid = ((SYNC_EN != 0) ? m_v3 : m_v1) & m_in_en;
wire [31:0] m_input  = m_in & m_ivalid & GPIO_MASK;
wire [31:0] m_level  = ((m_high & m_in) | (m_low & ~m_in)) & m_ivalid;
wire [31:0] m_pend   = (m_latch | m_level) & GPIO_MASK;
wire [31:0] m_irq    = m_pend & m_en;
wire [31:0] m_rise_d = m_in & ~m_prev & m_ivalid & m_pvalid;
wire [31:0] m_fall_d = ~m_in & m_prev & m_ivalid & m_pvalid;
wire [31:0] m_pins   = gpio_in32 & GPIO_MASK;
wire [31:0] m_nomode = ~(m_rise | m_fall | m_high | m_low);
wire        m_wake   = |(m_wake_en & m_in_en & m_ivalid &
                         (( m_pins & ~m_in & (m_rise | m_high | m_nomode)) |
                          (~m_pins &  m_in & (m_fall | m_low  | m_nomode))));
wire        m_flushing_wk = |(m_wake_en & m_in_en & ~(m_ivalid & m_pvalid));

// The transfer on the bus: ACCESS cycle, offset, admission
wire        m_acc     = (psel === 1'b1) && (penable === 1'b1);
wire [31:0] m_acc_off = {{(32-ADDRW){1'b0}}, paddr} & ~32'h3;
wire        m_acc_m   = (pprot[0] === 1'b1) && (psmode === 1'b0);
wire  [1:0] m_acc_lvl = m_acc_m ? 2'b11 : ((pprot[0] === 1'b1) ? 2'b01 : 2'b00);
wire        m_acc_ok  = (m_acc_off == 32'h60) ? m_acc_m :
                        (m_acc_lvl >= ((pwrite === 1'b1) ? m_md_wr : m_md_rd));
wire [31:0] m_mdeleg  = {23'h0, m_md_resp, 4'h0, m_md_rd, m_md_wr};

// Privilege level of a bench mode ({pprot[0], psmode})
function [1:0] priv_of;
   input [1:0] mode;
   begin
      priv_of = (mode == MACHINE) ? 2'b11 : (mode == SUPERVISOR) ? 2'b01 : 2'b00;
   end
endfunction

// Admission of an access by the current MDELEG (window offset or full address)
function acc_admitted;
   input        write;
   input  [1:0] mode;
   input [31:0] addr;
   begin
      if (((addr & (WIN_SIZE - 1)) & ~32'h3) == 32'h60)
        acc_admitted = (mode == MACHINE);
      else
        acc_admitted = (priv_of(mode) >= (write ? m_md_wr : m_md_rd));
   end
endfunction

// Expected PSLVERR of an access in the given mode, by the current MDELEG
function exp_resp_of;
   input        write;
   input  [1:0] mode;
   input [31:0] addr;
   begin
      exp_resp_of = m_md_resp && !acc_admitted(write, mode, addr);
   end
endfunction

// MDELEG priv field as stored (the reserved 2'b10 is stored as 2'b11)
function [1:0] md_coerce;
   input [1:0] v;
   begin
      md_coerce = (v == 2'b10) ? 2'b11 : v;
   end
endfunction

// Alternate functions (doc "Alternate functions"): function k owns pin n while
// ALT_EN[n]=1, {ALT_SEL1[n], ALT_SEL0[n]} = k and k < ALT_NR
wire [31:0] m_act0   = m_alt_en & ~m_alt_sel1 & ~m_alt_sel0 & {32{ALT_NR > 0}};
wire [31:0] m_act1   = m_alt_en & ~m_alt_sel1 &  m_alt_sel0 & {32{ALT_NR > 1}};
wire [31:0] m_act2   = m_alt_en &  m_alt_sel1 & ~m_alt_sel0 & {32{ALT_NR > 2}};
wire [31:0] m_act3   = m_alt_en &  m_alt_sel1 &  m_alt_sel0 & {32{ALT_NR > 3}};
wire [31:0] m_gpio_o = ((m_out & ~m_alt_en) | (tb_alt_o[0]  & m_act0) | (tb_alt_o[1]  & m_act1) |
                        (tb_alt_o[2]  & m_act2) | (tb_alt_o[3]  & m_act3)) & GPIO_MASK;
wire [31:0] m_gpio_oe = ((m_oe & ~m_alt_en) | (tb_alt_oe[0] & m_act0) | (tb_alt_oe[1] & m_act1) |
                        (tb_alt_oe[2] & m_act2) | (tb_alt_oe[3] & m_act3)) & GPIO_MASK;

initial
  begin
     model_check_en = 1'b0;
     m_check_q      = 1'b0;
     m_errors       = 0;
  end

function [31:0] m_read;
   input [31:0] off;
   input [31:0] in_v;
   input [31:0] pend_v;
   begin
      case (off)
        32'h0C : m_read = in_v;
        32'h10 : m_read = m_out;
        32'h08 : m_read = m_oe;
        32'h20 : m_read = m_en;
        32'h30 : m_read = m_rise;
        32'h34 : m_read = m_fall;
        32'h38 : m_read = m_high;
        32'h3C : m_read = m_low;
        32'h24 : m_read = pend_v;
        32'h00 : m_read = INFO_VALUE;
        32'h04 : m_read = m_in_en;
        32'h28 : m_read = m_wake_en;
        32'h40 : m_read = (ALT_NR >= 1) ? m_alt_en   : 32'h0;
        32'h44 : m_read = (ALT_NR >= 2) ? m_alt_sel0 : 32'h0;
        32'h48 : m_read = (ALT_NR >= 3) ? m_alt_sel1 : 32'h0;
        32'h2C : m_read = CFG_VALUE;
        32'h4C : m_read = pend_v & m_en;
        32'h60 : m_read = m_mdeleg;
        default: m_read = 32'h00000000;     // OUT_SET/CLR/TGL read 0, unmapped read 0
      endcase
   end
endfunction

//----------------------------------------------------------------------------
// State update on the always-on clock; bus side on bus-clock edges only
//----------------------------------------------------------------------------
always @(posedge pclk_aon or negedge presetn)
  if (presetn !== 1'b1)
    begin
       m_s1 <= 32'h0; m_s2 <= 32'h0; m_in <= 32'h0; m_prev <= 32'h0;
       m_v1 <= 32'h0; m_v2 <= 32'h0; m_v3 <= 32'h0; m_pvalid <= 32'h0;
       m_out <= 32'h0; m_oe <= 32'h0; m_en <= 32'h0;
       m_rise <= 32'h0; m_fall <= 32'h0; m_high <= 32'h0; m_low <= 32'h0;
       m_in_en <= 32'h0; m_wake_en <= 32'h0;
       m_alt_en <= 32'h0; m_alt_sel0 <= 32'h0; m_alt_sel1 <= 32'h0;
       m_latch <= 32'h0;
       m_md_wr <= MDELEG_RST[1:0]; m_md_rd <= MDELEG_RST[3:2]; m_md_resp <= MDELEG_RST[8];
       m_fuzzy = 0;
    end
  else
    begin
       m_bus = (pclk_en_latch === 1'b1);

       // Input stage (per pin, held at 0 while IN_EN is 0)
       if (SYNC_EN != 0)
         begin
            m_s1 <= gpio_in32 & GPIO_MASK & m_in_en;
            m_s2 <= m_s1 & m_in_en;
            m_in <= m_s2 & m_in_en;
         end
       else
         m_in <= gpio_in32 & GPIO_MASK & m_in_en;
       m_prev   <= m_in & m_in_en;
       m_v1     <= m_in_en & GPIO_MASK;
       m_v2     <= m_v1 & m_in_en;
       m_v3     <= m_v2 & m_in_en;
       m_pvalid <= m_ivalid;

       // ACCESS cycle completing on this edge
       m_w1c     = 32'h0;
       m_nin_en  = m_in_en;
       m_wbm     = {{8{pstrb[3]}}, {8{pstrb[2]}}, {8{pstrb[1]}}, {8{pstrb[0]}}};
       m_wdat    = pwdata & m_wbm & GPIO_MASK;
       if (m_bus)
         begin
            if (m_acc && (pwrite === 1'b1) && m_acc_ok)
              begin
                 case (m_acc_off)
                   32'h10 : m_out     <= (m_out     & ~m_wbm) | m_wdat;
                   32'h08 : m_oe      <= (m_oe      & ~m_wbm) | m_wdat;
                   32'h14 : m_out     <=  m_out     |  m_wdat;
                   32'h18 : m_out     <=  m_out     & ~m_wdat;
                   32'h1C : m_out     <=  m_out     ^  m_wdat;
                   32'h20 : m_en      <= (m_en      & ~m_wbm) | m_wdat;
                   32'h30 : m_rise    <= (m_rise    & ~m_wbm) | m_wdat;
                   32'h34 : m_fall    <= (m_fall    & ~m_wbm) | m_wdat;
                   32'h38 : m_high    <= (m_high    & ~m_wbm) | m_wdat;
                   32'h3C : m_low     <= (m_low     & ~m_wbm) | m_wdat;
                   32'h24 : m_w1c      = m_wdat;
                   32'h04 : m_nin_en   = (m_in_en   & ~m_wbm) | m_wdat;
                   32'h28 : m_wake_en <= (m_wake_en & ~m_wbm) | m_wdat;
                   32'h40 : if (ALT_NR >= 1) m_alt_en   <= (m_alt_en   & ~m_wbm) | m_wdat;
                   32'h44 : if (ALT_NR >= 2) m_alt_sel0 <= (m_alt_sel0 & ~m_wbm) | m_wdat;
                   32'h48 : if (ALT_NR >= 3) m_alt_sel1 <= (m_alt_sel1 & ~m_wbm) | m_wdat;
                   32'h50 : m_oe      <=  m_oe      |  m_wdat;
                   32'h54 : m_oe      <=  m_oe      & ~m_wdat;
                   32'h58 : m_en      <=  m_en      |  m_wdat;
                   32'h5C : m_en      <=  m_en      & ~m_wdat;
                   32'h60 : begin
                               if (pstrb[0]) begin m_md_wr <= md_coerce(pwdata[1:0]); m_md_rd <= md_coerce(pwdata[3:2]); end
                               if (pstrb[1]) m_md_resp <= pwdata[8];
                            end
                   default: ;
                 endcase
              end
         end
       m_in_en <= m_nin_en;

       // Latched edges: a new edge wins over a W1C on the same edge
       m_latch <= ((m_latch & ~m_w1c) | (m_rise_d & m_rise) | (m_fall_d & m_fall)) & GPIO_MASK;

       if (m_nin_en != m_in_en) m_fuzzy = 2*L_IN + 3;
       else if (m_fuzzy > 0)    m_fuzzy = m_fuzzy - 1;
    end

//----------------------------------------------------------------------------
// Comparison, mid-cycle
//----------------------------------------------------------------------------
always @(negedge free_clk)
  begin
     if ((presetn === 1'b1) && model_check_en && m_check_q)
       begin
          if ((gpio_o32 !== m_gpio_o) || (gpio_oe32 !== m_gpio_oe) || (gpio_ie32 !== (m_in_en & GPIO_MASK)) ||
              (alt_act32[0] !== m_act0) || (alt_act32[1] !== m_act1) ||
              (alt_act32[2] !== m_act2) || (alt_act32[3] !== m_act3) ||
              ((m_fuzzy == 0) && ((irq32 !== m_irq) || (irq_any !== (|m_irq)))))
            begin
               $display("ERROR: model mismatch -- gpio_o 0x%h/0x%h gpio_oe_o 0x%h/0x%h gpio_ie_o 0x%h/0x%h irq_o 0x%h/0x%h irq_any_o %b/%b alt_act 0x%h_%h_%h_%h/0x%h_%h_%h_%h (dut/model) %t ns",
                        gpio_o32, m_gpio_o, gpio_oe32, m_gpio_oe, gpio_ie32, m_in_en & GPIO_MASK, irq32, m_irq, irq_any, |m_irq,
                        alt_act32[3], alt_act32[2], alt_act32[1], alt_act32[0], m_act3, m_act2, m_act1, m_act0, $time);
               error = error+1;
               m_errors = m_errors+1;
            end
          if ((m_fuzzy == 0) && !m_flushing_wk && (gpio_wake !== m_wake))
            begin
               $display("ERROR: model mismatch -- gpio_wake_o %b/%b (dut/model) %t ns", gpio_wake, m_wake, $time);
               error = error+1;
               m_errors = m_errors+1;
            end
          if (m_acc)
            begin
               if (!m_acc_ok)
                 begin
                    if (pslverr !== m_md_resp)
                      begin
                         $display("ERROR: model -- refused access expects PSLVERR=%b (RESP), got %b %t ns", m_md_resp, pslverr, $time);
                         error = error+1; m_errors = m_errors+1;
                      end
                    if ((pwrite !== 1'b1) && (prdata !== 32'h0))
                      begin
                         $display("ERROR: model -- refused read returned 0x%h, expected 0 %t ns", prdata, $time);
                         error = error+1; m_errors = m_errors+1;
                      end
                 end
               else
                 begin
                    if (pslverr !== 1'b0)
                      begin
                         $display("ERROR: model -- admitted access expects PSLVERR=0, got %b %t ns", pslverr, $time);
                         error = error+1; m_errors = m_errors+1;
                      end
                    if (pwrite !== 1'b1)
                      begin
                         m_exp = m_read(m_acc_off, m_input, m_pend);
                         if (((m_acc_off == 32'h0C) || (m_acc_off == 32'h24) || (m_acc_off == 32'h4C)) && (m_fuzzy != 0))
                           ;  // INPUT / IRQ_PEND / IRQ_STAT right after an IN_EN change: not compared
                         else if (prdata !== m_exp)
                           begin
                              $display("ERROR: model -- read offset 0x%h returned 0x%h, expected 0x%h %t ns", m_acc_off, prdata, m_exp, $time);
                              error = error+1; m_errors = m_errors+1;
                           end
                      end
                 end
            end
       end
     m_check_q <= model_check_en;
  end
