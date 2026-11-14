# VC Static Lint — apb_gpio

Signoff-grade structural lint for apb_gpio. Separate from and additional to the
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
| 1 | `default` | `apb_gpio` | (defaults) |
| 2 | `sync_rst` | `apb_gpio` | ASYNC_RST_EN=0 |
| 3 | `no_sync` | `apb_gpio` | SYNC_EN=0 |
| 4 | `no_cgate` | `apb_gpio` | INP_CGATE_EN=0 |
| 5 | `open` | `apb_gpio` | MDELEG_RST=9'h000 |
| 6 | `smode_sync_rst` | `apb_gpio` | ASYNC_RST_EN=0 MDELEG_RST=9'h105 |
| 7 | `gpio31` | `apb_gpio` | GPIO_NR=31 |
| 8 | `gpio8` | `apb_gpio` | GPIO_NR=8 |
| 9 | `gpio1` | `apb_gpio` | GPIO_NR=1 |
| 10 | `gpio1_corner` | `apb_gpio` | ASYNC_RST_EN=0 GPIO_NR=1 INP_CGATE_EN=0 MDELEG_RST=9'h000 SYNC_EN=0 |
| 11 | `addrw8` | `apb_gpio` | ADDRW=8 |
| 12 | `alt1` | `apb_gpio` | ALT_NR=1 |
| 13 | `alt2` | `apb_gpio` | ALT_NR=2 |
| 14 | `alt3` | `apb_gpio` | ALT_NR=3 |
| 15 | `alt4` | `apb_gpio` | ALT_NR=4 |
| 16 | `alt4_gpio1` | `apb_gpio` | ALT_NR=4 ASYNC_RST_EN=0 GPIO_NR=1 |

## Status

All 16 configs: 0 errors, 0 warnings, `stale=0`. Deliberately unconsumed inputs
(`paddr_i[1:0]`, `pprot_i[2:1]`, the write-data and strobe bits above `GPIO_NR-1`,
the alternate-function inputs of absent functions, and `scan_mode_i` with
`INP_CGATE_EN=0`) are sunk into `*_unused` wires. Design waivers in `waivers.tcl`:
the unreset second stage of `arv_synchronizer` in the synchronous-reset builds with
`SYNC_EN=1`, the enable latch of the input-path `arv_cgate`, and the mixed set/reset
reset value of an `MDELEG` field reset to Supervisor (`MDELEG_RST` with a `2'b01`
field, the `smode_sync_rst` config).

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
