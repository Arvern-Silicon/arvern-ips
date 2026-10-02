# VC Static Lint — arv_dtm

Signoff-grade structural lint for arv_dtm. Separate from and additional to the
Verilator lint in `sim/rtl_sim/run/run_lint`; neither replaces the other.

## Usage

Run from this directory, with `vc_static_shell` on PATH:

```bash
./run_vclint                      # config 1 (RTL defaults): structural + netlist + quick-lint
./run_vclint -rtl_config <N|name> # lint one config from sim/rtl_sim/bin/rtl_configs.py
./run_vclint -rtl_sweep           # lint every config; summary only
./run_vclint -list_configs        # print the config table
./run_vclint -lang                # add the LANGUAGE_CHECK stage (slower, noisier)
./run_vclint -top <module>        # lint a submodule instead of the config's top
./run_vclint -raw                 # ignore rules.tcl -- report every enabled rule
./run_vclint -i                   # leave vc_static_shell open for interactive triage
./run_vclint -h                   # full option list
```

Reports land in `results/`; a `-rtl_config` run also snapshots them to
`results_sweep/<label>/`. `-rtl_sweep` writes only
`results_sweep/sweep_summary.log`, one line per config — to investigate a row,
re-run that config on its own with `-rtl_config`.

The config table is `sim/rtl_sim/bin/rtl_configs.py`, the single source of
truth shared with the Verilator lint sweep (where one exists); each entry
names the top module and the parameter overrides to elaborate. The
translation to Tcl is `sim/rtl_sim/bin/gen_rtl_params.py`, which also emits
the `RTL_PARAM_*` values that `rules.tcl` and `waivers.tcl` branch on — reset
style above all, since the two reset rules are mutually exclusive and the
`sync_rst` configs need the opposite one from the defaults.

Configs (`./run_vclint -list_configs`):

| # | label | top | overrides |
|---|-------|-----|-----------|
| 1 | `jtag_default` | `arv_dtm_jtag` | (defaults) |
| 2 | `jtag_syncrst` | `arv_dtm_jtag` | ARST_EN=0 |
| 3 | `uart_default` | `arv_dtm_uart` | (defaults) |
| 4 | `uart_syncrst` | `arv_dtm_uart` | ARST_EN=0 |
| 5 | `i2c_default` | `arv_dtm_i2c` | (defaults) |
| 6 | `i2c_syncrst` | `arv_dtm_i2c` | ARST_EN=0 |
| 7 | `cjtag_default` | `arv_dtm_cjtag` | (defaults) |
| 8 | `cjtag_syncrst` | `arv_dtm_cjtag` | ARST_EN=0 |
| 9 | `wrap_jtag` | `arv_dtm` | DTM_TYPE=0 |
| 10 | `wrap_uart` | `arv_dtm` | DTM_TYPE=1 |
| 11 | `wrap_i2c` | `arv_dtm` | DTM_TYPE=2 |
| 12 | `wrap_cjtag` | `arv_dtm` | DTM_TYPE=3 |
| 13 | `wrap_uart_fifo128` | `arv_dtm` | DTM_TYPE=1 UART_RX_FIFO_DEPTH=128 |
| 14 | `wrap_i2c_wd20` | `arv_dtm` | DTM_TYPE=2 I2C_WD_BITS=20 |

## Status

Clean on every config. Every waiver is gated on the transport
being linted (derived from the top, or from `DTM_TYPE` for the wrapper) so it
cannot read stale where its RTL is not elaborated. Two need a mention:

- **`CONN_NET_FANIN/FANOUT_DEADLOOP`** on the UART auto-baud counter and the
  cJTAG activation counter. The rule claims those counter bits are unaffected
  by any input; the RTL and the hardware say otherwise (the counters are what
  time the sync byte and the 24-bit GRL phase, and both links work on real
  boards). The population — bits `[3]` upward only, never `[2:0]`, and "dead
  loads" that are all `.en_i(1'b1)` pins — reads as a depth-limited traversal
  of the increment carry chain. Waived by tag, scoped to the two modules, with
  the reasoning in `waivers.tcl`. If a future tool version stops reporting it,
  the entry goes stale and should be removed.
- **`CODING_FF_NO_ASYNC`** in the `*_syncrst` configs: the TCK / TCKC domain is
  always async-reset (`TCK_ARST`) because the probe clock may not be running.

`stale=0` is the signal to protect: it means every waiver in `waivers.tcl`
matched something. A non-zero count means a waiver has gone stale or is scoped
to a configuration that is not being linted. It is an invariant of the
rule-policy, default-stage run of a config at its own top; it does not hold,
and is not meant to, under `-raw` or under `-top <submodule>`.

## Policy files

- `rules.tcl` — per-tag enable/disable. Copied **verbatim** from
  `arvern/lint/vc_static/rules.tcl` and identical in every IP; it is house
  policy, not design-specific. Keep the copies in step.
- `waivers.tcl` — design waivers for this IP, commented in place.
