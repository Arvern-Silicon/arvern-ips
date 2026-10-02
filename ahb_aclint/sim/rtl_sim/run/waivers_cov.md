# Coverage waivers — ahb_aclint

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

## Before you waive

Read the three traps in `arv_dtm/sim/rtl_sim/run/waivers_cov.md` (a config tie-off, a
bench parameter capping what the DUT accepts, a default value hiding a datapath). All
three apply here: `NUM_HARTS`, `SU_MODE_EN`, `PRIV_CHECK_EN`, `LF_SYNC_EN` and
`ASYNC_RST_EN` change what is elaborated, and the clk_lf:hclk ratio is a bench
parameter.

This file covers the Verilator line/branch/toggle flow (`run_all -cov`,
`../bin/cov_report.py`). The functional cover bins (`../bin/cov_report`,
`cover_monitor.v`) are a separate, older report.

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

### AHB inputs outside a 32-bit, privilege-only slave

```json
[
{"file":"ahb_aclint.v","at":"/input  wire           [2:0] hsize_i/","type":"toggle","sig":"hsize_i[[]2]","why":"unreachable: hsize_i[2] set means a transfer of 128 bits or more, illegal on this 32-bit AHB data bus; its only reader is the lint sink hsize_unused"},
{"file":"ahb_aclint.v","at":"/wire [2:0] hsize_unused/","type":"toggle","sig":"hsize_unused[[]2]","why":"unreachable: hsize_i[2] set means a transfer of 128 bits or more, illegal on this 32-bit AHB data bus; its only reader is the lint sink hsize_unused"}
]
```

### Design review verdicts — parameter-folded ternaries, contract-tied sinks

```json
[
{"file": "ahb_aclint.v", "at": "/wire dph_priv_allowed_m_only/", "type": "branch", "sig": "cond_else", "why": "unreachable: the ternary's selector is the parameter PRIV_CHECK_EN, folded at elaboration; both arms' logic is covered through dph_mode_m (priv_check builds) and the priv_off build"},
{"file": "ahb_aclint.v", "at": "/wire dph_priv_allowed_m_only/", "type": "branch", "sig": "cond_then", "why": "unreachable: the ternary's selector is the parameter PRIV_CHECK_EN, folded at elaboration; both arms' logic is covered through dph_mode_m (priv_check builds) and the priv_off build"},
{"file": "ahb_aclint.v", "at": "/wire dph_priv_allowed_m_or_s/", "type": "branch", "sig": "cond_else", "why": "unreachable: the ternary's selector is the parameter PRIV_CHECK_EN, folded at elaboration; both arms' logic is covered through dph_mode_m/dph_mode_s (priv_check builds) and the priv_off build"},
{"file": "ahb_aclint.v", "at": "/wire dph_priv_allowed_m_or_s/", "type": "branch", "sig": "cond_then", "why": "unreachable: the ternary's selector is the parameter PRIV_CHECK_EN, folded at elaboration; both arms' logic is covered through dph_mode_m/dph_mode_s (priv_check builds) and the priv_off build"},
{"file": "aclint_mtimer.v", "at": "/wire resetn_lf_unused/", "type": "toggle", "sig": "g_lf_ports_unused.resetn_lf_unused", "why": "no functional reader: lint sink of resetn_lf_i in the LF_SYNC_EN=1 build, where the contract ties the pin high (ahb_aclint.md port table: 'Unused when LF_SYNC_EN=1 -- tie high'); driving it is outside the contract"}
]
```

<!-- BEGIN generated by cov_const.py: do not edit by hand -->

## Constant by construction (generated)

Bits tied to a constant in every coverage configuration (Yosys elaboration),
or, without Yosys, sized literals or parameters in their only continuous driver.
Regenerate with `../bin/cov_const.py cov/dats --write` after an RTL change; `--lint` flags any that went stale.

```json
[
{"file":"aclint_mswi.v","at":"/output wire            [31:0] reg_rd_data_o/","type":"toggle","sig":"reg_rd_data_o[[][1-9]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at aclint_mswi.v:107"},
{"file":"aclint_mswi.v","at":"/output wire            [31:0] reg_rd_data_o/","type":"toggle","sig":"reg_rd_data_o[[]1[0-9]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at aclint_mswi.v:107"},
{"file":"aclint_mswi.v","at":"/output wire            [31:0] reg_rd_data_o/","type":"toggle","sig":"reg_rd_data_o[[]2[0-9]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at aclint_mswi.v:107"},
{"file":"aclint_mswi.v","at":"/output wire            [31:0] reg_rd_data_o/","type":"toggle","sig":"reg_rd_data_o[[]3[01]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at aclint_mswi.v:107"},
{"file":"aclint_mswi.v","at":"/output wire                   reg_ready_o/","type":"toggle","sig":"reg_ready_o","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at aclint_mswi.v:108"},
{"file":"aclint_mswi.v","at":"/wire       [REG_AW-1:0] hart_word_index/","type":"toggle","sig":"hart_word_index[[]1[23]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at aclint_mswi.v:53"},
{"file":"aclint_mswi.v","at":"/reg  [31:0] rd_mux/","type":"toggle","sig":"rd_mux[[][1-9]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at aclint_mswi.v:98"},
{"file":"aclint_mswi.v","at":"/reg  [31:0] rd_mux/","type":"toggle","sig":"rd_mux[[]1[0-9]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at aclint_mswi.v:98"},
{"file":"aclint_mswi.v","at":"/reg  [31:0] rd_mux/","type":"toggle","sig":"rd_mux[[]2[0-9]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at aclint_mswi.v:98"},
{"file":"aclint_mswi.v","at":"/reg  [31:0] rd_mux/","type":"toggle","sig":"rd_mux[[]3[01]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at aclint_mswi.v:98"},
{"file":"aclint_mtimer.v","at":"/wire    [REG_AW-1:0] hart_byte_index/","type":"toggle","sig":"hart_byte_index[[]1[2-4]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at aclint_mtimer.v:122"},
{"file":"aclint_sswi.v","at":"/output wire             [31:0] reg_rd_data_o/","type":"toggle","sig":"reg_rd_data_o[[][0-9]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at aclint_sswi.v:104"},
{"file":"aclint_sswi.v","at":"/output wire             [31:0] reg_rd_data_o/","type":"toggle","sig":"reg_rd_data_o[[]1[0-9]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at aclint_sswi.v:104"},
{"file":"aclint_sswi.v","at":"/output wire             [31:0] reg_rd_data_o/","type":"toggle","sig":"reg_rd_data_o[[]2[0-9]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at aclint_sswi.v:104"},
{"file":"aclint_sswi.v","at":"/output wire             [31:0] reg_rd_data_o/","type":"toggle","sig":"reg_rd_data_o[[]3[01]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at aclint_sswi.v:104"},
{"file":"aclint_sswi.v","at":"/output wire                    reg_ready_o/","type":"toggle","sig":"reg_ready_o","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at aclint_sswi.v:105"},
{"file":"aclint_sswi.v","at":"/wire       [REG_AW-1:0] hart_word_index/","type":"toggle","sig":"hart_word_index[[]1[23]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at aclint_sswi.v:52"},
{"file":"ahb_aclint.v","at":"/wire         mswi_ready/","type":"toggle","sig":"mswi_ready","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at ahb_aclint.v:190"},
{"file":"ahb_aclint.v","at":"/wire [31:0]  mswi_rdata/","type":"toggle","sig":"mswi_rdata[[][1-9]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at ahb_aclint.v:191"},
{"file":"ahb_aclint.v","at":"/wire [31:0]  mswi_rdata/","type":"toggle","sig":"mswi_rdata[[]1[0-9]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at ahb_aclint.v:191"},
{"file":"ahb_aclint.v","at":"/wire [31:0]  mswi_rdata/","type":"toggle","sig":"mswi_rdata[[]2[0-9]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at ahb_aclint.v:191"},
{"file":"ahb_aclint.v","at":"/wire [31:0]  mswi_rdata/","type":"toggle","sig":"mswi_rdata[[]3[01]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at ahb_aclint.v:191"},
{"file":"ahb_aclint.v","at":"/wire                 sswi_ready/","type":"toggle","sig":"sswi_ready","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at ahb_aclint.v:280"},
{"file":"ahb_aclint.v","at":"/wire          [31:0] sswi_rdata/","type":"toggle","sig":"sswi_rdata[[][0-9]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at ahb_aclint.v:279"},
{"file":"ahb_aclint.v","at":"/wire          [31:0] sswi_rdata/","type":"toggle","sig":"sswi_rdata[[]1[0-9]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at ahb_aclint.v:279"},
{"file":"ahb_aclint.v","at":"/wire          [31:0] sswi_rdata/","type":"toggle","sig":"sswi_rdata[[]2[0-9]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at ahb_aclint.v:279"},
{"file":"ahb_aclint.v","at":"/wire          [31:0] sswi_rdata/","type":"toggle","sig":"sswi_rdata[[]3[01]]","why":"constant by construction: tied to a constant in every coverage configuration (default, nh2, nh16, su0, priv_off, sync_rst, lf_sync, lf_sync_rst), driver at ahb_aclint.v:279"}
]
```

<!-- END generated by cov_const.py -->
