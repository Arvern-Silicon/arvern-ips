//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    addr_walk_contended
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : addr_walk_contended.v
// Module Description : addr_walk with the three managers issuing pipelined
//                      transfers at the same time, so the walking address
//                      phases are cached and replayed by the fabric. All
//                      variants.
//
//   Each manager streams, for every bit b of 2..31, a read and a write at the
//   walking-one and at the walking-zero unmapped address (the addr_walk
//   addresses: bit 24 added where the walking one would land on the bench
//   map), each answered by exactly one two-cycle ERROR. Interleaved with it,
//   for b = 2..10, every manager walks the same bit inside a mapped window,
//   whose data proves the replayed address:
//     M1  SRAM word write + read back at base + (1 << b) and base + (0x7FC & ~(1 << b))
//     M2  ROM reads at the same offsets
//     M0  ROM reads at the same offsets (fused: Port A against M2's Port B)
//   The managers never wait for a data phase before presenting the next
//   transfer; M1 and M2 share the non-executable bus on every variant and M0
//   shares the generic bus.
//
// Checks: per manager, the completions arrive in issue order, one per
// transfer, each unmapped one an ERROR with hrdata 0 and every mapped one OKAY
// with the expected data; the ERROR shape is two cycles; cached address phases
// seen on M1 and M2 (and M0 on generic); SRAM contents at the end.
//
// Basis (quoted)
//  ahb_interconnect.md, Overview: "A transfer whose address matches no bit of
//    the decoder that serves its bus is routed to it and answered with the AHB
//    two-cycle ERROR response, so a manager never hangs on an unmapped
//    address."
//  ahb_interconnect.md, Building blocks: ahb_manager_if "Detects an address
//    phase, caches it when the bus is busy, asks the arbiter for the bus,
//    replays the cached address phase when granted"; ahb_default_subordinate
//    "(hreadyout low then high, hresp = 1, hrdata = 0)".
//  ahb_interconnect.md, Arbitrated grant switch: "manager 1's address phase is
//    cached in its ahb_manager_if and replayed the next cycle."
//  IHI0033C 3.2 / 5.1.3: "the Subordinate ... must use a two-cycle response";
//    "The two-cycle response provides sufficient time for the Manager to
//    cancel this next access" (optional: the managers here do not cancel).
//----------------------------------------------------------------------------

localparam [31:0] AC_ROM  = 32'h00400000;
localparam [31:0] AC_SRAM = 32'h00401000;

integer    ac_i;
integer    ac_m;
reg [31:0] ac_sram [0:511];


//----------------------------------------------------------------------------
// Manager-side response recorder (see sideband_hsmode.v)
//----------------------------------------------------------------------------
reg        rc_out  [0:2];
reg        rc_err1 [0:2];
integer    rc_n    [0:2];
reg        rc_resp [0:767];
reg [31:0] rc_data [0:767];
integer    rc_k;

initial
   for (rc_k = 0; rc_k < 3; rc_k = rc_k + 1)
      begin
         rc_out[rc_k]  = 1'b0;
         rc_err1[rc_k] = 1'b0;
         rc_n[rc_k]    = 0;
      end

task rc_sample;
   input integer m;
   input         aph;
   input         rdy;
   input         rsp;
   input  [31:0] rd;
   integer       idx;
   begin
      if (rc_out[m])
         begin
            if (!rdy)
               begin
                  if (rsp & rc_err1[m])
                     begin
                        $display("ERROR: M%0d ERROR response first cycle lasted more than one cycle %t", m, $time);
                        error = error + 1;
                     end
                  else if (!rsp & rc_err1[m])
                     begin
                        $display("ERROR: M%0d wait state after the first ERROR cycle %t", m, $time);
                        error = error + 1;
                     end
                  rc_err1[m] = rsp;
               end
            else
               begin
                  idx          = m*256 + (rc_n[m] % 256);
                  rc_resp[idx] = rsp;
                  rc_data[idx] = rd;
                  if (rsp & ~rc_err1[m])
                     begin
                        $display("ERROR: M%0d ERROR completed without its first (hready=0) cycle %t", m, $time);
                        error = error + 1;
                     end
                  if (~rsp & rc_err1[m])
                     begin
                        $display("ERROR: M%0d first ERROR cycle followed by OKAY %t", m, $time);
                        error = error + 1;
                     end
                  rc_n[m]    = rc_n[m] + 1;
                  rc_out[m]  = 1'b0;
                  rc_err1[m] = 1'b0;
               end
         end
      else if (rsp !== 1'b0)
         begin
            $display("ERROR: M%0d hresp=%b with no transfer outstanding %t", m, rsp, $time);
            error = error + 1;
         end
      if (aph & rdy) rc_out[m] = 1'b1;
   end
endtask

always @(posedge free_clk)
   if (!hresetn)
      begin
         for (rc_k = 0; rc_k < 3; rc_k = rc_k + 1)
            begin
               rc_out[rc_k]  = 1'b0;
               rc_err1[rc_k] = 1'b0;
            end
      end
   else if (tb_rst_done)
      begin
         rc_sample(0, m0_htrans_d[1], m0_hready, m0_hresp, m0_hrdata);
         rc_sample(1, m1_htrans_d[1], m1_hready, m1_hresp, m1_hrdata);
         rc_sample(2, m2_htrans_d[1], m2_hready, m2_hresp, m2_hrdata);
      end


//----------------------------------------------------------------------------
// Expected completions per manager
//----------------------------------------------------------------------------
reg        ex_resp [0:767];
reg        ex_chk  [0:767];
reg [31:0] ex_data [0:767];
reg [31:0] ex_addr [0:767];
integer    ex_n    [0:2];

initial
   for (ac_i = 0; ac_i < 3; ac_i = ac_i + 1)
      ex_n[ac_i] = 0;

task automatic ac_xfer;
   input integer m;
   input         wr;
   input  [31:0] a;
   input  [31:0] d;          // write data, or expected read data
   input         resp;
   integer       idx;
   begin
      idx          = m*256 + (ex_n[m] % 256);
      ex_resp[idx] = resp;
      ex_chk[idx]  = !wr;
      ex_data[idx] = resp ? 32'h0 : d;
      ex_addr[idx] = a;
      ex_n[m]      = ex_n[m] + 1;
      if (wr) ahb_write(m, 0, a, d, 2);
      else    ahb_read (m, 0, a, d, 2, 0);
   end
endtask


//----------------------------------------------------------------------------
// Cached address phases
//----------------------------------------------------------------------------
wire ac_m0_pend;
wire ac_m1_pend;
wire ac_m2_pend;
`ifdef FUSED
assign ac_m0_pend = 1'b0;
assign ac_m1_pend = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_aph_pending;
assign ac_m2_pend = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_aph_pending;
`elsif HIPERF
assign ac_m0_pend = 1'b0;
assign ac_m1_pend = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_aph_pending;
assign ac_m2_pend = dut.ahb_manager_mux_inst_nx.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_aph_pending;
`else
assign ac_m0_pend = dut.ahb_manager_mux_inst.AHB_MANAGER_IF[0].ahb_manager_if_inst.m_aph_pending;
assign ac_m1_pend = dut.ahb_manager_mux_inst.AHB_MANAGER_IF[1].ahb_manager_if_inst.m_aph_pending;
assign ac_m2_pend = dut.ahb_manager_mux_inst.AHB_MANAGER_IF[2].ahb_manager_if_inst.m_aph_pending;
`endif

integer ac_pc0, ac_pc1, ac_pc2;
integer ac_wait0;
initial
   begin
      ac_pc0   = 0;
      ac_pc1   = 0;
      ac_pc2   = 0;
      ac_wait0 = 0;
   end

always @(posedge free_clk)
   if (hresetn && tb_rst_done)
      begin
         if (ac_m0_pend === 1'b1) ac_pc0 = ac_pc0 + 1;
         if (ac_m1_pend === 1'b1) ac_pc1 = ac_pc1 + 1;
         if (ac_m2_pend === 1'b1) ac_pc2 = ac_pc2 + 1;
         if ((m0_htrans_d[1] === 1'b1) && (m0_hready === 1'b0) && (m0_hresp === 1'b0)) ac_wait0 = ac_wait0 + 1;
      end


//----------------------------------------------------------------------------
// Per-manager walk
//----------------------------------------------------------------------------
task automatic ac_walk;
   input integer m;
   integer       b;
   integer       wi;
   reg    [31:0] a;
   reg    [31:0] d;
   reg    [31:0] off;
   begin
      for (b = 2; b < 32; b = b + 1)
         begin
            a = 32'h1 << b;
            if ((a >= 32'h0040_0000) && (a < 32'h0040_4000))
               a = a | 32'h0100_0000;
            d = (32'h1 << b) | (32'h1 << (b - 2)) | (m << 30);
            ac_xfer(m, 1'b0, a, 32'h0, 1'b1);
            ac_xfer(m, 1'b1, a, d,     1'b1);
            if (b <= 10)
               begin
                  off = 32'h1 << b;
                  if (m == 1)
                     begin
                        wi          = off >> 2;
                        d           = 32'hE1000000 | (b << 16) | off;
                        ac_sram[wi] = d;
                        ac_xfer(m, 1'b1, AC_SRAM + off, d, 1'b0);
                        ac_xfer(m, 1'b0, AC_SRAM + off, d, 1'b0);
                     end
                  else
                     ac_xfer(m, 1'b0, AC_ROM + off, rom_inst0.mem[off >> 2], 1'b0);
               end
            a = ~(32'h1 << b) & 32'hFFFF_FFFC;
            d = ~((32'h1 << b) | (32'h1 << (b - 2)));
            ac_xfer(m, 1'b0, a, 32'h0, 1'b1);
            ac_xfer(m, 1'b1, a, d,     1'b1);
            if (b <= 10)
               begin
                  off = 32'h7FC & ~(32'h1 << b);
                  if (m == 1)
                     begin
                        wi          = off >> 2;
                        d           = 32'hE2000000 | (b << 16) | off;
                        ac_sram[wi] = d;
                        ac_xfer(m, 1'b1, AC_SRAM + off, d, 1'b0);
                        ac_xfer(m, 1'b0, AC_SRAM + off, d, 1'b0);
                     end
                  else
                     ac_xfer(m, 1'b0, AC_ROM + off, rom_inst0.mem[off >> 2], 1'b0);
               end
         end
      @(posedge free_clk);
      while (((m == 0) ? m0_hready : (m == 1) ? m1_hready : m2_hready) !== 1'b1) @(posedge free_clk);
   end
endtask


//----------------------------------------------------------------------------
// Stimulus
//----------------------------------------------------------------------------
integer    ac_bad;
integer    ac_idx;
integer    ac_j;

initial
   begin
      @(posedge free_clk);
      @(posedge hresetn);
      repeat(10) @(posedge free_clk);

      for (ac_i = 0; ac_i < 512; ac_i = ac_i + 1)
         begin
            rom_inst0.mem[ac_i]  = 32'h7A000000 + (ac_i * 32'h00010009);
            sram_inst0.mem[ac_i] = 32'h13000000 + (ac_i * 32'h00000307);
            ac_sram[ac_i]        = sram_inst0.mem[ac_i];
         end

      $display(" =====================================================");
      $display("|  WALKING ADDRESSES, THREE MANAGERS AT ONCE          |");
      $display(" =====================================================");

      fork
         ac_walk(0);
         begin @(posedge free_clk); ac_walk(1); end
         begin repeat(2) @(posedge free_clk); ac_walk(2); end
      join
      repeat(20) @(posedge free_clk);

      for (ac_m = 0; ac_m < 3; ac_m = ac_m + 1)
         begin
            ac_bad = 0;
            if (rc_n[ac_m] != ex_n[ac_m])
               begin
                  $display("ERROR: M%0d completed %0d transfers, %0d issued", ac_m, rc_n[ac_m], ex_n[ac_m]);
                  error  = error + 1;
                  ac_bad = 1;
               end
            else
               for (ac_j = 0; ac_j < ex_n[ac_m]; ac_j = ac_j + 1)
                  begin
                     ac_idx = ac_m*256 + (ac_j % 256);
                     if (rc_resp[ac_idx] !== ex_resp[ac_idx])
                        begin
                           $display("ERROR: M%0d transfer %0d (0x%h): %0s, expected %0s", ac_m, ac_j, ex_addr[ac_idx],
                                    rc_resp[ac_idx] ? "ERROR" : "OKAY", ex_resp[ac_idx] ? "ERROR" : "OKAY");
                           error  = error + 1;
                           ac_bad = 1;
                        end
                     else if (ex_chk[ac_idx] && (rc_data[ac_idx] !== ex_data[ac_idx]))
                        begin
                           $display("ERROR: M%0d transfer %0d (0x%h): hrdata 0x%h, expected 0x%h", ac_m, ac_j,
                                    ex_addr[ac_idx], rc_data[ac_idx], ex_data[ac_idx]);
                           error  = error + 1;
                           ac_bad = 1;
                        end
                  end
            if (!ac_bad)
               $display("PASS:  M%0d %0d transfers in order, one response each, ERROR exactly on the unmapped ones",
                        ac_m, ex_n[ac_m]);
         end

      $display("INFO:  cached-APH cycles: M0 %0d  M1 %0d  M2 %0d; M0 address-phase wait cycles %0d",
               ac_pc0, ac_pc1, ac_pc2, ac_wait0);
      if ((ac_pc1 == 0) || (ac_pc2 == 0))
         begin
            $display("ERROR: no cached address phase on M1 / M2");
            error = error + 1;
         end
`ifdef GENERIC
      if (ac_pc0 == 0)
         begin
            $display("ERROR: no cached address phase on M0");
            error = error + 1;
         end
`endif

      for (ac_i = 0; ac_i < 512; ac_i = ac_i + 1)
         if (sram_inst0.mem[ac_i] !== ac_sram[ac_i])
            begin
               $display("ERROR: SRAM word %0d = 0x%h, expected 0x%h", ac_i, sram_inst0.mem[ac_i], ac_sram[ac_i]);
               error = error + 1;
            end

      // The fabric still works afterwards.
      ahb_write(1, 1, AC_SRAM + 32'h010, 32'h1234_5678, 2);
      ahb_read (1, 1, AC_SRAM + 32'h010, 32'h1234_5678, 2, 1);
      ahb_read (2, 1, AC_ROM  + 32'h020, rom_inst0.mem[8], 2, 1);
      ahb_read (0, 1, AC_ROM  + 32'h024, rom_inst0.mem[9], 2, 1);

      repeat(10) @(posedge free_clk);
      stimulus_done = 1;
   end
