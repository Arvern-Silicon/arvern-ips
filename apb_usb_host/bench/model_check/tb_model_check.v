//----------------------------------------------------------------------------
//          _    _           Family:    aRVern System IPs
//         / \__/ \          Module:    tb_model_check
//        /   /\   \         --------------------------------------------
//    ===/   /=========      Copyright: (c) 2026, aRVern-dev
//      /   / RV \   \       Contact:   arvernsilicon@gmail.com
//     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
//
// SPDX-License-Identifier: BSD-3-Clause
// Full license text is available in the LICENSE file at the repository root.
//----------------------------------------------------------------------------
// File Name          : tb_model_check.v
// Module Description : Validates the usb_ls_dev device model against an
//                      independent low-speed host: the third-party
//                      nand2mario usb_hid_host core used on the Tang Console
//                      138K, hooked up as in its APB wrapper there
//                      (apb_usb_hid_host.v): 33.333 MHz clock, 12 MHz clock
//                      enable from a 9/25 phase accumulator, D+/D- split into
//                      _i/_o/oe, inputs through a two-flop synchroniser.
//
//  Scenario (+SCEN=<name>):
//    kbd    boot keyboard, 8-byte reports           (typ 1)
//    mouse  boot mouse, 3- and 4-byte reports       (typ 2)
//    pad    DragonRise-style pad, 8-byte reports    (typ 3)
//    fast   keyboard, device bit rate +1.5 %
//    slow   keyboard, device bit rate -1.5 %
//    delay  keyboard, response delay 6.5 bit times on every packet
//  +DUMP writes tb_model_check.vcd; +VERB=<n> sets the model verbosity
//  (2: every packet, 3: line edges and timing); +SEED=<n> reseeds the
//  model's response delays.
//
//  PASS: the core reports the expected device type, and every report the
//  model sends on its interrupt endpoint arrives on the core's outputs
//  (dbg_hid_report and the decoded key / mouse / gamepad outputs). The
//  model's host checkers run throughout and are reported, not judged: the
//  old core has known protocol gaps (no status stage after the configuration
//  read, 1 ms SET_ADDRESS recovery, J driven for two bit times after each
//  EOP), so some checkers fire by design.
//----------------------------------------------------------------------------
`include "timescale.v"
`default_nettype none

module tb_model_check;

localparam NREP = 4;

//----------------------------------------------------------------------------
// Clock, reset, 12 MHz clock enable
//----------------------------------------------------------------------------
reg        clk;
reg        rst_n;
reg  [7:0] ce_acc;
reg        usbce;

initial clk = 1'b0;
always #15 clk = ~clk;                       // 33.333 MHz

always @(posedge clk)
  if (!rst_n)
    begin
       ce_acc <= 8'd0;
       usbce  <= 1'b0;
    end
  else if ((ce_acc + 8'd9) >= 8'd25)
    begin
       ce_acc <= ce_acc + 8'd9 - 8'd25;
       usbce  <= 1'b1;
    end
  else
    begin
       ce_acc <= ce_acc + 8'd9;
       usbce  <= 1'b0;
    end

//----------------------------------------------------------------------------
// USB bus: host pads, pull-downs, device model
//----------------------------------------------------------------------------
wire       dp;
wire       dm;
wire       h_dp_o;
wire       h_dm_o;
wire       h_oe;

assign dp = h_oe ? h_dp_o : 1'bz;
assign dm = h_oe ? h_dm_o : 1'bz;
assign (weak0, highz1) dp = 1'b0;          // host 15 kOhm pull-downs, weaker than the device's 1.5 kOhm pull-up
assign (weak0, highz1) dm = 1'b0;

// Pad input buffers read an unresolved level as 0; two-flop synchroniser
reg  [1:0] dp_s;
reg  [1:0] dm_s;

always @(posedge clk)
  if (!rst_n)
    begin
       dp_s <= 2'b00;
       dm_s <= 2'b00;
    end
  else
    begin
       dp_s <= {dp_s[0], (dp === 1'b1)};
       dm_s <= {dm_s[0], (dm === 1'b1)};
    end

wire        d_attached;
wire        d_suspended;
wire  [6:0] d_address;
wire        d_configured;
wire  [2:0] d_state;
wire [31:0] d_errors;

usb_ls_dev #(
    .NAME         ("dev"),
    .VERBOSE      (1),
    .SEED         (7),
    .RATE_GRID_NS (30)                       // host edges on the 33.333 MHz grid
) dev (
    .dp           (dp),
    .dm           (dm),
    .host_oe      (h_oe),
    .attached     (d_attached),
    .suspended    (d_suspended),
    .address      (d_address),
    .configured   (d_configured),
    .dev_state    (d_state),
    .err_count    (d_errors)
);

//----------------------------------------------------------------------------
// Host under test
//----------------------------------------------------------------------------
wire  [1:0] typ;
wire        report;
wire        conerr;
wire  [7:0] key_mod, key1, key2, key3, key4;
wire  [7:0] mouse_btn, mouse_dx, mouse_dy;
wire        game_l, game_r, game_u, game_d, game_a, game_b, game_x, game_y, game_sel, game_sta;
wire [63:0] dbg_hid_report;

usb_hid_host u_host (
    .usbclk         (clk),
    .usbce          (usbce),
    .usbrst_n       (rst_n),
    .usb_dm_i       (dm_s[1]),
    .usb_dp_i       (dp_s[1]),
    .usb_dm_o       (h_dm_o),
    .usb_dp_o       (h_dp_o),
    .usb_oe_o       (h_oe),
    .typ            (typ),
    .report         (report),
    .conerr         (conerr),
    .key_modifiers  (key_mod),
    .key1           (key1),
    .key2           (key2),
    .key3           (key3),
    .key4           (key4),
    .mouse_btn      (mouse_btn),
    .mouse_dx       (mouse_dx),
    .mouse_dy       (mouse_dy),
    .game_l         (game_l),
    .game_r         (game_r),
    .game_u         (game_u),
    .game_d         (game_d),
    .game_a         (game_a),
    .game_b         (game_b),
    .game_x         (game_x),
    .game_y         (game_y),
    .game_sel       (game_sel),
    .game_sta       (game_sta),
    .dbg_hid_report (dbg_hid_report));

//----------------------------------------------------------------------------
// Scenario data
//----------------------------------------------------------------------------
reg [8*8-1:0] scen;
integer       profile;
integer       exp_typ;
integer       rep_len [0:NREP-1];
reg    [63:0] rep_dat [0:NREP-1];
integer       n_ok;
integer       n_bad;
integer       n_pushed;
integer       seen_cnt;
reg           pass;

// Gamepad outputs expected from the core's decode for a valid record
// (d[0][1:0] != 2'b10): directions from d[0]/d[1] (00/FF) then d[3]/d[4]
// (top bits 00/11), X A B Y from d[5][7:4], Select Start from d[6][5:4]
function [9:0] pad_exp;                      // {sta, sel, y, x, b, a, d, u, r, l}
   input [63:0] d;
   reg l, r, u, dn;
   begin
      l = 1'b0; r = 1'b0; u = 1'b0; dn = 1'b0;
      if (d[7:0]   == 8'h00) begin l = 1'b1; r  = 1'b0; end
      if (d[7:0]   == 8'hFF) begin l = 1'b0; r  = 1'b1; end
      if (d[15:8]  == 8'h00) begin u = 1'b1; dn = 1'b0; end
      if (d[15:8]  == 8'hFF) begin u = 1'b0; dn = 1'b1; end
      if (d[31:30] == 2'b00) begin l = 1'b1; r  = 1'b0; end
      if (d[31:30] == 2'b11) begin l = 1'b0; r  = 1'b1; end
      if (d[39:38] == 2'b00) begin u = 1'b1; dn = 1'b0; end
      if (d[39:38] == 2'b11) begin u = 1'b0; dn = 1'b1; end
      pad_exp = {d[53], d[52], d[47], d[44], d[46], d[45], dn, u, r, l};
   end
endfunction

initial
  begin
     scen = "kbd";
     if ($value$plusargs("SCEN=%s", scen)) ;
     profile = dev.P_KBD;
     exp_typ = 1;
     // Boot keyboard: a, shift+b c, release, ctrl+1234
     rep_len[0] = 8; rep_dat[0] = 64'h0000_0000_0004_0000;
     rep_len[1] = 8; rep_dat[1] = 64'h0000_0000_0605_0002;
     rep_len[2] = 8; rep_dat[2] = 64'h0000_0000_0000_0000;
     rep_len[3] = 8; rep_dat[3] = 64'h0000_2120_1F1E_0001;
     if (scen == "mouse")
       begin
          profile = dev.P_MOUSE;
          exp_typ = 2;
          rep_len[0] = 4; rep_dat[0] = 64'h0000_0000_00FB_0501;
          rep_len[1] = 3; rep_dat[1] = 64'h0000_0000_007F_8002;
          rep_len[2] = 4; rep_dat[2] = 64'h0000_0000_01FF_0104;
          rep_len[3] = 3; rep_dat[3] = 64'h0000_0000_0000_0000;
       end
     else if (scen == "pad")
       begin
          // DragonRise-style: X Y 00 80 80 {YBAX,F} {Start Select .. R L} 00
          profile = dev.P_GAMEPAD;
          exp_typ = 3;
          rep_len[0] = 8; rep_dat[0] = 64'h0000_0F80_8000_7F7F;   // idle
          rep_len[1] = 8; rep_dat[1] = 64'h0000_2F80_8000_7F00;   // left + A
          rep_len[2] = 8; rep_dat[2] = 64'h0010_1F80_8000_00FF;   // right + up + X + Select
          rep_len[3] = 8; rep_dat[3] = 64'h0020_CF80_8000_FF7F;   // down + B + Y + Start
       end
  end

//----------------------------------------------------------------------------
// Report check: every rising edge of the core's report pulse that follows a
// new interrupt data packet from the model
//----------------------------------------------------------------------------
reg [63:0] ck_d;
integer    ck_len;
integer    k;
reg        ck_ok;

always @(posedge report)
  begin
     #1;
     if (dev.int_sent_cnt != seen_cnt)
       begin
          seen_cnt = dev.int_sent_cnt;
          ck_d     = dev.int_sent_data;
          ck_len   = dev.int_sent_len;
          ck_ok    = (typ == exp_typ);
          // the core's outputs are checked against what the model actually sent: a
          // report repeated after a lost ACK is sent again, not skipped
          for (k = 0; k < ck_len; k = k + 1)
            if (dbg_hid_report[8*k +: 8] !== ck_d[8*k +: 8]) ck_ok = 1'b0;
          case (typ)
            2'd1: if ((key_mod !== ck_d[7:0])   || (key1 !== ck_d[23:16]) || (key2 !== ck_d[31:24]) ||
                      (key3    !== ck_d[39:32]) || (key4 !== ck_d[47:40])) ck_ok = 1'b0;
            2'd2: if ((mouse_btn !== ck_d[7:0]) || (mouse_dx !== ck_d[15:8]) || (mouse_dy !== ck_d[23:16])) ck_ok = 1'b0;
            2'd3: if ({game_sta, game_sel, game_y, game_x, game_b, game_a, game_d, game_u, game_r, game_l} !==
                      pad_exp(ck_d)) ck_ok = 1'b0;
            default: ck_ok = 1'b0;
          endcase
          if (ck_ok)
            begin
               n_ok = n_ok + 1;
               $display("[%0t] tb: report %0d delivered: %0d bytes %h", $time, n_ok + n_bad, ck_len, ck_d);
            end
          else
            begin
               n_bad = n_bad + 1;
               $display("[%0t] tb: REPORT MISMATCH: typ %0d, model sent %0d bytes %h, core dbg %h, key %h %h%h%h%h, mouse %h %h %h, pad %b",
                        $time, typ, ck_len, ck_d, dbg_hid_report, key_mod, key1, key2, key3, key4,
                        mouse_btn, mouse_dx, mouse_dy,
                        {game_sta, game_sel, game_y, game_x, game_b, game_a, game_d, game_u, game_r, game_l});
            end
       end
  end

//----------------------------------------------------------------------------
// Stimulus
//----------------------------------------------------------------------------
integer i, w, pa;

initial
  begin
     if ($test$plusargs("DUMP"))
       begin
          $dumpfile("tb_model_check.vcd");
          $dumpvars(0, tb_model_check);
       end
     n_ok = 0; n_bad = 0; n_pushed = 0; seen_cnt = 0; pass = 1'b0;
     rst_n = 1'b0;
     #1;                                     // scenario set up at time 0
     if (scen == "fast")  dev.set_rate_ppm(15000);
     if (scen == "slow")  dev.set_rate_ppm(-15000);
     if (scen == "delay") dev.set_resp_delay(650, 650);
     dev.set_addr_recovery(0);
     if ($value$plusargs("VERB=%d", pa)) dev.set_verbosity(pa);
     if ($value$plusargs("SEED=%d", pa)) dev.set_seed(pa);
     $display("[%0t] tb: scenario %0s, profile %0d, expected typ %0d", $time, scen, profile, exp_typ);
     #2000;
     @(posedge clk) rst_n <= 1'b1;
     #5000000;
     dev.attach(profile);

     // Enumeration: the core needs ~200 ms debounce, two 100 ms reset sequences
     w = 0;
     while (((typ != exp_typ) || !d_configured) && (w < 1500))
       begin
          #1000000;
          w = w + 1;
       end
     $display("[%0t] tb: core typ %0d, model configured %0d, address %0d", $time, typ, d_configured, d_address);

     if ((typ == exp_typ) && d_configured)
       for (i = 0; i < NREP; i = i + 1)
         begin
            dev.push_report(rep_len[i], rep_dat[i]);
            n_pushed = n_pushed + 1;
            w = 0;
            while (((n_ok + n_bad) < n_pushed) && (w < 200))
              begin
                 #1000000;
                 w = w + 1;
              end
         end

     #20000000;
     dev.dump_summary;
     pass = (typ == exp_typ) && d_configured && (n_ok == NREP) && (n_bad == 0);
     $display("");
     $display("MODEL_CHECK %0s: %0s (typ %0d/%0d, reports %0d ok, %0d bad of %0d, model checker hits %0d)",
              scen, pass ? "PASS" : "FAIL", typ, exp_typ, n_ok, n_bad, NREP, d_errors);
     $finish;
  end

endmodule

`default_nettype wire
