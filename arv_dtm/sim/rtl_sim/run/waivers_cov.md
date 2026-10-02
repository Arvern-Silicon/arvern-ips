# Coverage waivers — arv_dtm

Every entry here removes a coverage point from the report. Read this before adding
one; the tooling checks the *syntax*, but nothing can check the *argument*, and a
wrong argument is how a real hole gets hidden.

## THE RULE

> Waive only what is **UNREACHABLE**, and state the mechanism that makes it so.

| you wrote | what it actually is |
|---|---|
| "no test covers it" | a **gap** — write the test |
| "never reached in this regression" | an **observation**, and a circular one: that is what the report just told you |

Waived points **leave the denominator**, so waiving an uncovered point *does* raise
the reported percentage. Nothing in the tooling prevents that — this rule is the
only thing keeping the number honest. A good reason names the signal, line or
parameter that makes the code impossible to reach, so a reviewer can re-check it
without re-deriving it.

## Before you waive: three traps

Each of these cost real time, and each *looked* like a missing test.

**1. A config tie-off looks exactly like a test gap.**
`tdata1_or`/`tdata2_or` showed 446 uncovered points — apparently the biggest test
opportunity in the design. 256 of them were trigger slots 4–7, which
`DM_TRIGGER_NR=4` ties to `32'h0`; another 72 were reserved bits, constant by
construction. The real gap was ~118. **Check the logic is even elaborated before
writing a test.**

**2. A bench parameter can cap what the DUT accepts.**
The UART baud counters only ever used 6 bits, which read as weak stimulus. The
cause was the bench passing `AB_BREAK_CLKS=700`; since
`AB_DIV_CEIL = AB_BREAK_CLKS >> 4`, autobaud *rejected* anything slower than
43 clk/bit — with a perfectly correct measurement. No test could have moved those
bits. The fix was a bench define. **If a counter's high bits never toggle, find its
bound before blaming the tests.**

**3. A default value can hide a whole datapath.**
`dr_idcode` sat at 9/32 because the default IDCODE `0x000001F7` has 23 leading
zeros, so the upper shift-register bits never carried a 1 — a stuck bit there would
have read back correctly and passed. Fixed with a second elaboration
(`+define+IDCODE_ALT`), not a waiver. **Mostly-zero is not the same as unreachable.**

## Format

Waivers live in ```json fences; everything outside a fence is prose. Prose may
use `sh`/`text`/`verilog` fences freely — but a fence whose first character is
`[` or `{` and which is *not* labelled `json` is an **error**, not a skip. That
is the one silent-loss case: its waivers would vanish and the report would just
look worse.

| field | meaning |
|---|---|
| `file` | source file basename |
| `at` | line number, `"/literal substring/"`, or `"re/regex/"`. **Prefer the literal** — Verilog is full of `( ) [ ]` and a regex silently mismatches; a line number drifts when the file is edited above it |
| `type` | `line` \| `branch` \| `toggle` \| `all` |
| `sig` | optional fnmatch glob. **`[..]` is a character class**, so a whole bus is `foo[[]*` — `foo[*]` matches a literal asterisk and therefore nothing |
| `why` | **mandatory.** The generated `<MECHANISM>` placeholder is rejected by the loader |

Do not hand-write entries. Generate them:

```sh
../bin/cov_report.py cov/dats --suggest <file>:<line> [type]
```

or press **waiver** / **+ section** on a hole in `./cov_view`. Both derive the
anchor from source, escape the glob, fold bit ranges (verified to match only the
uncovered bits), and refuse to propose anything already covered.

Then validate:

```sh
../bin/cov_report.py cov/dats --lint
```

`STALE` means it matches nothing — investigate, do not delete. `BROAD` means it
also swallows **covered** points, hiding real coverage; narrow it with `sig=`.

---
## Waivers

### selector / FSM defaults over encodings that cannot occur


```json
[
{"file": "arv_dtm_cmd.v", "at": "/default : ;/", "type": "line", "why": "unreachable: rxcnt is [2:0] but only incremented while != 3'd5 and reset to 0 elsewhere, so 6 and 7 never occur"},
{"file": "arv_dtm_cmd.v", "at": "/default : state_nxt = S_SYNC;/", "type": "line", "why": "unreachable: 5 states in a [2:0] register, every assignment uses a named state, so 3'd5..7 never occur"},
{"file": "arv_dtm_dmi_master.v", "at": "/default  : state_nxt = S_IDLE;/", "type": "line", "why": "unreachable: 3 states in a [1:0] register, every assignment uses a named state, so 2'd3 never occurs"}
]
```

### elaboration-time helper, never executed as runtime logic

```json
[
{"file": "arv_dtm_rxfifo.v", "at": "/function integer clog2;/", "type": "line", "why": "unreachable at runtime: constant function, evaluated during elaboration only"},
{"file": "arv_dtm_rxfifo.v", "at": "/for (i = value - 1; i > 0; i = i >> 1)/", "type": "line", "why": "unreachable at runtime: loop body of that same elaboration-time constant function"}
]
```

### guard whose condition is invariant in every reachable state

```json
[
{"file": "arv_dtm_uart.v", "at": "/else if (rxd_lvl)/", "type": "branch", "sig": "else", "why": "unreachable: ab_hold_nxt=1 occurs only under ab_re (a rising edge), and any 1->0 on the filtered line asserts rxd_fe which clears ab_hold that same cycle, so rxd_lvl is invariably 1 inside this block"}
]
```

### design invariant, kept as a loud failure if it ever breaks

```json
[
{"file": "arv_dtm_cmd.v", "at": "/end else if (inflight_i && ((op_r == OP_READ) || (op_r == OP_WRITE))) begin/", "type": "line", "sig": "if", "why": "unreachable: S_WAIT blocks a second op and abort_i drops any outstanding one via hardreset_o, so inflight_i cannot be set on entry here"}
]
```

### NOT waived, deliberately -- these are gaps, not unreachable code:

```text
arv_dtm_tap.v:365  branch  -- SECONDARY busy (a DMI op requested while one is in
flight) is real Debug-spec behaviour with no test.
arv_ipdff.v:48     branch  -- en_i never false in the negedge variant. Needs a
check of whether any instance can actually disable
it; if none can that is a waiver, otherwise a gap.


TAP: secondary busy at Update-DR is shadowed by the Capture-DR setter

arv_dtm_tap.v:364 needs (dmi_op_active & dm_inflight & sticky_err==0) at
Update-DR. It cannot hold:
* The TAP FSM reaches Update-DR only THROUGH Capture-DR of the same DR
scan, and a DMI op is launched only at an Update-DR (dmi_launch, :290).
* So if dm_inflight is true at Update-DR, the op was launched by an EARLIER
Update-DR and was therefore already in flight at this scan's Capture-DR.
* That Capture-DR runs the PRIMARY busy setter at :339-340, which has NO
sticky_err==0 guard and sets sticky_err = OP_BUSY unconditionally.
* By Update-DR sticky_err is therefore non-zero and the guard fails.

Measured (dmi_busy_secondary, which issues a REAL write while an op is in
flight -- the tightest case the protocol allows): :339 if = 8, :364 if = 0.
The functional behaviour is still correct and IS tested there: the rejected
op is dropped and the seeded value survives.
```

```json
[
{"file": "arv_dtm_tap.v", "at": "/dmi_op_active & dm_inflight/", "type": "branch", "sig": "if", "why": "unreachable: Capture-DR (:339) always sets sticky_err first, so the sticky_err==0 guard cannot hold at Update-DR"}
]
```

### Negedge flop hold path: every negedge instance hardwires the enable

```text

arv_ipdff.v:48 is the `else if (en_i)` of the negedge/async-reset variant;
its not-taken path is the register HOLDING. All three negedge instances in
this IP tie en_i high, so the hold can never occur:
arv_dtm_tap.v:438   u_tdo_neg      .en_i(1'b1)
arv_dtm_tap.v:441   u_tdo_oe_neg   .en_i(1'b1)
arv_dtm_cjtag.v:210 u_esc_type_ng  .en_i(1'b1)
Scoped to this IP on purpose: arv_ipdff is a shared primitive and another
consumer may well instantiate a negedge flop with a live enable.
```

```json
[
{"file": "arv_ipdff.v", "at": "48", "type": "branch", "sig": "else", "why": "unreachable: all three negedge instances in arv_dtm tie en_i to 1'b1, so the hold path never occurs"}
]
```

### UART baud counters: bits above the reachable autobaud ceiling

```text

ab_div_ok (arv_dtm_uart.v:128-129) admits a measured bit period only if
AB_DIV_FLOOR (2) <= ab_tent_div <= AB_DIV_CEIL,  AB_DIV_CEIL = AB_BREAK_CLKS >> 4

AB_BREAK_CLKS is set by the INTEGRATION, and the bench sets it per build:
default build : 700    -> ceiling    43  (keeps break tests short)
+SLOW_BAUD    : 65536  -> ceiling  4096  (uart_slow_baud)
The bound that matters for coverage is the most permissive build in the merged
database, i.e. 4096. Everything below is derived from THAT:
ab_div / ab_div_nxt / baud_div               <=  4096  -> bits [31:13] dead
ab_hold_target = ab_div + (ab_div >> 1)       <=  6144  -> bits [31:13] dead
bit_half       = baud_div >> 1                <=  2048  -> bits [31:12] dead
rx_cnt / tx_cnt count to baud_div - 1         <=  4095  -> bits [31:12] dead
lowrun_cnt counts to AB_BREAK_CLKS            <= 65536  -> bits [31:17] dead

Measured with uart_slow_baud / uart_mid_baud in the suite: highest toggled bits are
ab_div 12, lowrun_cnt 16 -- consistent with the bounds above. ab_cnt is not waived:
uart_meas_wrap preloads it near 2^32, so every bit toggles.

THESE WAIVERS TRACK A BENCH PARAMETER. Raising AB_BREAK_CLKS in either build
widens the reachable range and makes them wrong (too broad). That is why the
derivation is spelled out rather than just the bit ranges.
```

```json
[
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] ab_d/", "type": "toggle", "sig": "ab_div[[]1[3-9]]", "why": "unreachable: ab_div <= 4096 (AB_DIV_CEIL at the widest bench build), so bits [31:13] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] ab_d/", "type": "toggle", "sig": "ab_div[[]2[0-9]]", "why": "unreachable: ab_div <= 4096 (AB_DIV_CEIL at the widest bench build), so bits [31:13] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/reg  [31:0] ab_d/", "type": "toggle", "sig": "ab_div_nxt[[]1[3-9]]", "why": "unreachable: ab_div <= 4096 (AB_DIV_CEIL at the widest bench build), so bits [31:13] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/reg  [31:0] ab_d/", "type": "toggle", "sig": "ab_div_nxt[[]2[0-9]]", "why": "unreachable: ab_div <= 4096 (AB_DIV_CEIL at the widest bench build), so bits [31:13] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] ba/", "type": "toggle", "sig": "baud_div[[]1[3-9]]", "why": "unreachable: ab_div <= 4096 (AB_DIV_CEIL at the widest bench build), so bits [31:13] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] ba/", "type": "toggle", "sig": "baud_div[[]2[0-9]]", "why": "unreachable: ab_div <= 4096 (AB_DIV_CEIL at the widest bench build), so bits [31:13] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] ab_h/", "type": "toggle", "sig": "ab_hold_target[[]1[3-9]]", "why": "unreachable: ab_div <= 4096 (AB_DIV_CEIL at the widest bench build), so bits [31:13] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] ab_h/", "type": "toggle", "sig": "ab_hold_target[[]2[0-9]]", "why": "unreachable: ab_div <= 4096 (AB_DIV_CEIL at the widest bench build), so bits [31:13] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] ab_h/", "type": "toggle", "sig": "ab_hold_target[[]3[01]]", "why": "unreachable: ab_div <= 4096 (AB_DIV_CEIL at the widest bench build), so bits [31:13] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] bit_h/", "type": "toggle", "sig": "bit_half[[]1[2-9]]", "why": "unreachable: derived from ab_div (<= 4096), so bits [31:12] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] bit_h/", "type": "toggle", "sig": "bit_half[[]2[0-9]]", "why": "unreachable: derived from ab_div (<= 4096), so bits [31:12] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] r/", "type": "toggle", "sig": "rx_cnt[[]1[2-9]]", "why": "unreachable: derived from ab_div (<= 4096), so bits [31:12] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] r/", "type": "toggle", "sig": "rx_cnt[[]2[0-9]]", "why": "unreachable: derived from ab_div (<= 4096), so bits [31:12] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] r/", "type": "toggle", "sig": "rx_cnt[[]3[01]]", "why": "unreachable: derived from ab_div (<= 4096), so bits [31:12] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/reg  [31:0] r/", "type": "toggle", "sig": "rx_cnt_nxt[[]1[2-9]]", "why": "unreachable: derived from ab_div (<= 4096), so bits [31:12] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/reg  [31:0] r/", "type": "toggle", "sig": "rx_cnt_nxt[[]2[0-9]]", "why": "unreachable: derived from ab_div (<= 4096), so bits [31:12] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/reg  [31:0] r/", "type": "toggle", "sig": "rx_cnt_nxt[[]3[01]]", "why": "unreachable: derived from ab_div (<= 4096), so bits [31:12] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire      [3/", "type": "toggle", "sig": "tx_cnt[[]1[2-9]]", "why": "unreachable: derived from ab_div (<= 4096), so bits [31:12] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire      [3/", "type": "toggle", "sig": "tx_cnt[[]2[0-9]]", "why": "unreachable: derived from ab_div (<= 4096), so bits [31:12] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire      [3/", "type": "toggle", "sig": "tx_cnt[[]3[01]]", "why": "unreachable: derived from ab_div (<= 4096), so bits [31:12] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/reg       [3/", "type": "toggle", "sig": "tx_cnt_nxt[[]1[2-9]]", "why": "unreachable: derived from ab_div (<= 4096), so bits [31:12] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/reg       [3/", "type": "toggle", "sig": "tx_cnt_nxt[[]2[0-9]]", "why": "unreachable: derived from ab_div (<= 4096), so bits [31:12] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/reg       [3/", "type": "toggle", "sig": "tx_cnt_nxt[[]3[01]]", "why": "unreachable: derived from ab_div (<= 4096), so bits [31:12] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] lowrun_c/", "type": "toggle", "sig": "lowrun_cnt[[]1[7-9]]", "why": "unreachable: lowrun_cnt counts to AB_BREAK_CLKS (<= 65536), so bits [31:17] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] lowrun_c/", "type": "toggle", "sig": "lowrun_cnt[[]2[0-9]]", "why": "unreachable: lowrun_cnt counts to AB_BREAK_CLKS (<= 65536), so bits [31:17] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] lowrun_c/", "type": "toggle", "sig": "lowrun_cnt[[]3[01]]", "why": "unreachable: lowrun_cnt counts to AB_BREAK_CLKS (<= 65536), so bits [31:17] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] lowrun_n/", "type": "toggle", "sig": "lowrun_nxt[[]1[7-9]]", "why": "unreachable: lowrun_cnt counts to AB_BREAK_CLKS (<= 65536), so bits [31:17] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] lowrun_n/", "type": "toggle", "sig": "lowrun_nxt[[]2[0-9]]", "why": "unreachable: lowrun_cnt counts to AB_BREAK_CLKS (<= 65536), so bits [31:17] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] lowrun_n/", "type": "toggle", "sig": "lowrun_nxt[[]3[01]]", "why": "unreachable: lowrun_cnt counts to AB_BREAK_CLKS (<= 65536), so bits [31:17] cannot be set"}
]
```

### dtmsts read-back: every field except rx_overrun is a constant

```text

dtmsts_rdata = {16'b0, RX_FIFO_DEPTH8, 7'b0, rx_overrun}   (arv_dtm_cmd.v:187)

Bits [31:16] and [7:1] are literal zeros, and RX_FIFO_DEPTH8 [15:8] is a
localparam derived from the RX_FIFO_DEPTH parameter (arv_dtm_cmd.v:101) --
constant for the life of an elaboration. Only bit 0 carries data.

A constant-1 bit still toggles as the read mux selects and deselects the
register, which is why some of the RX_FIFO_DEPTH8 bits ARE covered; the ones
that stay 0 for this depth cannot toggle by any stimulus. The whole word is
waived rather than picking bit positions out of the current depth value,
because the live set changes with RX_FIFO_DEPTH and per-bit waivers would go
stale on a re-parameterisation while still reading as deliberate.

rx_overrun (bit 0) is exercised by uart_overrun / uart_break_overrun.
```

```json
[
]
```

### dtmcs read-back: reserved and parameter-constant fields

```text

dtmcs_capture = { 11'b0,            [31:21] reserved
errinfo,          [20:18] live
2'b0,             [17:16] dmihardreset/dmireset are W1, read 0
1'b0,             [15]    reserved
IDLE_HINT,        [14:12] parameter (3 -> 011, so [14] is 0)
combined_status,  [11:10] live
DMI_ABITS[5:0],   [9:4]   parameter (7 -> 000111, so [9:7] are 0)
4'd1 }            [3:0]   version (0001, so [3:1] are 0)

11 + 2 + 1 + 1 + 3 + 3 = 21 bits are constant zero and cannot toggle by any
stimulus. A constant-ONE bit still toggles as the read mux selects the
register, which is why the IDLE_HINT/ABITS/version one-bits ARE covered.

The whole word is waived rather than naming bit positions: which bits are zero
follows from IDLE_HINT and DMI_ABITS, so per-bit waivers would silently go
stale on a re-parameterisation while still reading as deliberate.
```

```json
[
]
```

## Design review verdicts — unreachable by construction

```json
[
{"file": "arv_dtm_tap.v", "at": "/wire  [1:0] dm_cstatus/", "type": "toggle", "sig": "dm_cstatus[[]0]", "why": "unreachable: DMI completion status bit 0 is constant 0 -- its only source is arv_dtm_dmi_master rsp_stat_nxt = dmi_pslverr_i ? 2'd2 : 2'd0 (reset 0); every consumer carries that 2-bit status"},
{"file": "arv_dtm_uart.v", "at": "/wire           [1:0] dm_cstatus/", "type": "toggle", "sig": "dm_cstatus[[]0]", "why": "unreachable: DMI completion status bit 0 is constant 0 -- its only source is arv_dtm_dmi_master rsp_stat_nxt = dmi_pslverr_i ? 2'd2 : 2'd0 (reset 0); every consumer carries that 2-bit status"},
{"file": "arv_dtm_i2c.v", "at": "/wire           [1:0] dm_cstatus/", "type": "toggle", "sig": "dm_cstatus[[]0]", "why": "unreachable: DMI completion status bit 0 is constant 0 -- its only source is arv_dtm_dmi_master rsp_stat_nxt = dmi_pslverr_i ? 2'd2 : 2'd0 (reset 0); every consumer carries that 2-bit status"},
{"file": "arv_dtm_dmi_master.v", "at": "/output wire          [1:0]  cstatus_o/", "type": "toggle", "sig": "cstatus_o[[]0]", "why": "unreachable: DMI completion status bit 0 is constant 0 -- its only source is arv_dtm_dmi_master rsp_stat_nxt = dmi_pslverr_i ? 2'd2 : 2'd0 (reset 0); every consumer carries that 2-bit status"},
{"file": "arv_dtm_dmi_master.v", "at": "/wire  [1:0] rsp_stat_h/", "type": "toggle", "sig": "rsp_stat_h[[]0]", "why": "unreachable: DMI completion status bit 0 is constant 0 -- its only source is arv_dtm_dmi_master rsp_stat_nxt = dmi_pslverr_i ? 2'd2 : 2'd0 (reset 0); every consumer carries that 2-bit status"},
{"file": "arv_dtm_dmi_master.v", "at": "/reg            [1:0] rsp_stat_nxt/", "type": "toggle", "sig": "rsp_stat_nxt[[]0]", "why": "unreachable: DMI completion status bit 0 is constant 0 -- its only source is arv_dtm_dmi_master rsp_stat_nxt = dmi_pslverr_i ? 2'd2 : 2'd0 (reset 0); every consumer carries that 2-bit status"},
{"file": "arv_dtm_cmd.v", "at": "/input  wire           [1:0] cstatus_i/", "type": "toggle", "sig": "cstatus_i[[]0]", "why": "unreachable: DMI completion status bit 0 is constant 0 -- its only source is arv_dtm_dmi_master rsp_stat_nxt = dmi_pslverr_i ? 2'd2 : 2'd0 (reset 0); every consumer carries that 2-bit status"},
{"file": "arv_dtm_cmd.v", "at": "/wire           [1:0] status_r/", "type": "toggle", "sig": "status_r[[]0]", "why": "unreachable: DMI completion status bit 0 is constant 0 -- its only source is arv_dtm_dmi_master rsp_stat_nxt = dmi_pslverr_i ? 2'd2 : 2'd0 (reset 0); every consumer carries that 2-bit status"},
{"file": "arv_dtm_cmd.v", "at": "/reg            [1:0] status_nxt/", "type": "toggle", "sig": "status_nxt[[]0]", "why": "unreachable: DMI completion status bit 0 is constant 0 -- its only source is arv_dtm_dmi_master rsp_stat_nxt = dmi_pslverr_i ? 2'd2 : 2'd0 (reset 0); every consumer carries that 2-bit status"},
{"file": "arv_dtm_tap.v", "at": "/input  wire           [3:0] idcode_version_i/", "type": "toggle", "sig": "idcode_version_i[[][0-3]]", "why": "unreachable in this bench: idcode_version_i is a static ECO strap (DUT_IDVER per build, 0x0 or 0xA with IDCODE_ALT), never changing within a run; both values are read back through the IDCODE DR (idcode_bypass, idcode_alt)"},
{"file": "arv_dtm_jtag.v", "at": "/input  wire           [3:0] idcode_version_i/", "type": "toggle", "sig": "idcode_version_i[[][0-3]]", "why": "unreachable in this bench: idcode_version_i is a static ECO strap (DUT_IDVER per build, 0x0 or 0xA with IDCODE_ALT), never changing within a run; both values are read back through the IDCODE DR (idcode_bypass, idcode_alt)"},
{"file": "arv_dtm_cjtag.v", "at": "/input  wire           [3:0] idcode_version_i/", "type": "toggle", "sig": "idcode_version_i[[][0-3]]", "why": "unreachable in this bench: idcode_version_i is a static ECO strap (DUT_IDVER per build, 0x0 or 0xA with IDCODE_ALT), never changing within a run; both values are read back through the IDCODE DR (idcode_bypass, idcode_alt)"},
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] bit_full/", "type": "toggle", "sig": "bit_full[[]1[2-9]]", "why": "unreachable: bit_full = baud_div - 1 <= 4095 (AB_DIV_CEIL at the widest bench build), so bits [31:12] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] bit_full/", "type": "toggle", "sig": "bit_full[[]2[0-9]]", "why": "unreachable: bit_full = baud_div - 1 <= 4095 (AB_DIV_CEIL at the widest bench build), so bits [31:12] cannot be set"},
{"file": "arv_dtm_uart.v", "at": "/wire [31:0] bit_full/", "type": "toggle", "sig": "bit_full[[]3[01]]", "why": "unreachable: bit_full = baud_div - 1 <= 4095 (AB_DIV_CEIL at the widest bench build), so bits [31:12] cannot be set"}
]
```

<!-- BEGIN generated by cov_const.py: do not edit by hand -->

## Constant by construction (generated)

Bits tied to a constant in every coverage configuration (Yosys elaboration),
or, without Yosys, sized literals or parameters in their only continuous driver.
Regenerate with `../bin/cov_const.py cov/dats --write` after an RTL change; `--lint` flags any that went stale.

```json
[
{"file":"arv_dtm.v","at":"/output wire           [8:0] dmi_paddr_o/","type":"toggle","sig":"dmi_paddr_o[[][01]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm.v:86"},
{"file":"arv_dtm.v","at":"/output wire           [2:0] dmi_pprot_o/","type":"toggle","sig":"dmi_pprot_o[[][0-2]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm.v:89"},
{"file":"arv_dtm_cjtag.v","at":"/output wire           [8:0] dmi_paddr_o/","type":"toggle","sig":"dmi_paddr_o[[][01]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_cjtag.v:63"},
{"file":"arv_dtm_cjtag.v","at":"/output wire           [2:0] dmi_pprot_o/","type":"toggle","sig":"dmi_pprot_o[[][0-2]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_cjtag.v:66"},
{"file":"arv_dtm_cmd.v","at":"/wire          [31:0] dtmsts_rdata/","type":"toggle","sig":"dtmsts_rdata[[][1-9]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_cmd.v:189"},
{"file":"arv_dtm_cmd.v","at":"/wire          [31:0] dtmsts_rdata/","type":"toggle","sig":"dtmsts_rdata[[]1[0-9]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_cmd.v:189"},
{"file":"arv_dtm_cmd.v","at":"/wire          [31:0] dtmsts_rdata/","type":"toggle","sig":"dtmsts_rdata[[]2[0-9]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_cmd.v:189"},
{"file":"arv_dtm_cmd.v","at":"/wire          [31:0] dtmsts_rdata/","type":"toggle","sig":"dtmsts_rdata[[]3[01]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_cmd.v:189"},
{"file":"arv_dtm_dmi_master.v","at":"/output wire           [8:0] dmi_paddr_o/","type":"toggle","sig":"dmi_paddr_o[[][01]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_dmi_master.v:276"},
{"file":"arv_dtm_dmi_master.v","at":"/output wire          [2:0]  dmi_pprot_o/","type":"toggle","sig":"dmi_pprot_o[[][0-2]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_dmi_master.v:279"},
{"file":"arv_dtm_i2c.v","at":"/input  wire           [6:0] i2c_addr_i/","type":"toggle","sig":"i2c_addr_i[[][0-6]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_i2c.v:49"},
{"file":"arv_dtm_i2c.v","at":"/output wire           [8:0] dmi_paddr_o/","type":"toggle","sig":"dmi_paddr_o[[][01]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_i2c.v:54"},
{"file":"arv_dtm_i2c.v","at":"/output wire           [2:0] dmi_pprot_o/","type":"toggle","sig":"dmi_pprot_o[[][0-2]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_i2c.v:57"},
{"file":"arv_dtm_jtag.v","at":"/output wire           [8:0] dmi_paddr_o/","type":"toggle","sig":"dmi_paddr_o[[][01]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_jtag.v:62"},
{"file":"arv_dtm_jtag.v","at":"/output wire           [2:0] dmi_pprot_o/","type":"toggle","sig":"dmi_pprot_o[[][0-2]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_jtag.v:65"},
{"file":"arv_dtm_tap.v","at":"/output wire           [8:0] dmi_paddr_o/","type":"toggle","sig":"dmi_paddr_o[[][01]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_tap.v:93"},
{"file":"arv_dtm_tap.v","at":"/output wire           [2:0] dmi_pprot_o/","type":"toggle","sig":"dmi_pprot_o[[][0-2]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_tap.v:96"},
{"file":"arv_dtm_tap.v","at":"/wire   [31:0] dtmcs_capture/","type":"toggle","sig":"dtmcs_capture[[][0-9]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_tap.v:281"},
{"file":"arv_dtm_tap.v","at":"/wire   [31:0] dtmcs_capture/","type":"toggle","sig":"dtmcs_capture[[]1[2-7]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_tap.v:281"},
{"file":"arv_dtm_tap.v","at":"/wire   [31:0] dtmcs_capture/","type":"toggle","sig":"dtmcs_capture[[]2[1-9]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_tap.v:281"},
{"file":"arv_dtm_tap.v","at":"/wire   [31:0] dtmcs_capture/","type":"toggle","sig":"dtmcs_capture[[]3[01]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_tap.v:281"},
{"file":"arv_dtm_uart.v","at":"/output wire           [8:0] dmi_paddr_o/","type":"toggle","sig":"dmi_paddr_o[[][01]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_uart.v:50"},
{"file":"arv_dtm_uart.v","at":"/output wire           [2:0] dmi_pprot_o/","type":"toggle","sig":"dmi_pprot_o[[][0-2]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_uart.v:53"},
{"file":"arv_dtm_uart.v","at":"/wire [31:0] ab_div/","type":"toggle","sig":"ab_div[[]3[01]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_uart.v:127"},
{"file":"arv_dtm_uart.v","at":"/wire [31:0] ab_tent_div/","type":"toggle","sig":"ab_tent_div[[]29]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_uart.v:130"},
{"file":"arv_dtm_uart.v","at":"/wire [31:0] ab_tent_div/","type":"toggle","sig":"ab_tent_div[[]3[01]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_uart.v:130"},
{"file":"arv_dtm_uart.v","at":"/reg  [31:0] ab_div_nxt/","type":"toggle","sig":"ab_div_nxt[[]3[01]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_uart.v:163"},
{"file":"arv_dtm_uart.v","at":"/wire [31:0] baud_div/","type":"toggle","sig":"baud_div[[]3[01]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_uart.v:237"},
{"file":"arv_dtm_uart.v","at":"/wire [31:0] bit_half/","type":"toggle","sig":"bit_half[[]3[01]]","why":"constant by construction: tied to a constant in every coverage configuration (jtag, jtag_idcode_alt, uart, uart_slow_baud, i2c, cjtag), driver at arv_dtm_uart.v:240"}
]
```

<!-- END generated by cov_const.py -->
