//----------------------------------------------------------------------------
// File Name          : i2c_setup_margin
// Module Description : START/STOP detection must survive data setup landing close to
//                      the SCL rise -- the synchroniser-jitter case.
//
//   start_cond/stop_cond used to qualify the SDA edge on the SAME-CYCLE scl_lvl. SCL and
//   SDA travel independent 4-deep pipelines (2-FF sync + 2-cycle majority) whose
//   metastability aperture can delay one and not the other, always late. The guaranteed
//   observed separation is therefore floor(tSU;DAT / T_clk) - 1, so at the declared
//   f_clk >= 40 x f_SCL floor the margin is EXACTLY ONE CYCLE -- and one cycle of
//   resolution jitter consumes all of it. A normal 1->0 data bit then decodes as a START
//   and knocks the FSM out of frame.
//
//   RTL simulation does not model that jitter, so this test emulates it the same way the
//   original analysis did: by shrinking tSU;DAT until the data change lands inside the
//   window. The fix (requiring SCL high for TWO consecutive cycles, scl_lvl & scl_dly)
//   buys back a full cycle.
//
//   The bench already runs AT the floor: 200 ns half-periods = 20 clk at 100 MHz.
//
//   Discriminator: a full DMI write/read at tight setup. Without the fix the spurious
//   delimiters desync the frame and the readback is wrong.
//----------------------------------------------------------------------------

initial
   begin : test
      reg [31:0] rd;
      reg [1:0]  st;

      @(posedge dbgresetn);
      repeat (4) @(posedge free_clk);
      slave_latency = 2;

      $display(" ===============================================");
      $display("|  Baseline: relaxed setup (50 ns = 5 clk)     |");
      $display(" ===============================================");
      dmi_i2c(7'h10, OP_WRITE, 32'h1234_ABCD, st, rd);
      dmi_i2c(7'h10, OP_READ,  32'h0,          st, rd);
      check_eq("relaxed_setup_rdata", rd, 32'h1234_ABCD);

      $display(" ===============================================");
      $display("|  Tight setup: 6 ns  (< 1 clk -> same cycle)  |");
      $display(" ===============================================");
      // The data change and the SCL rise must land in the SAME clk_i cycle, which needs
      // tSU;DAT < one clock period (10 ns here) -- RTL sim has no pipeline skew of its
      // own, so that coincidence is the only way to reproduce what one cycle of
      // synchroniser jitter does in silicon. SCL timing is untouched: still exactly at
      // the documented 40x floor, and tSU;STA is untouched so real STARTs stay legal.
      T_SU = 6.0;

      dmi_i2c(7'h11, OP_WRITE, 32'hFACE_5678, st, rd);
      dmi_i2c(7'h11, OP_READ,  32'h0,          st, rd);
      check_eq("tight_setup_status", {30'd0, st}, 32'd0);
      check_eq("tight_setup_rdata",  rd,          32'hFACE_5678);

      // The earlier transaction must be untouched -- a spurious START mid-frame would
      // have written somewhere else.
      dmi_i2c(7'h10, OP_READ, 32'h0, st, rd);
      check_eq("prior_txn_intact", rd, 32'h1234_ABCD);

      repeat (20) @(posedge free_clk);
      stimulus_done = 1'b1;
   end
