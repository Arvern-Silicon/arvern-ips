# VC Static Lint — apb_usb_host

Signoff-grade structural lint for apb_usb_host. Separate from and additional to the
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
| 1 | `default` | `apb_usb_host` | (defaults) |
| 2 | `sync_rst` | `apb_usb_host` | ASYNC_RST_EN=0 |
| 3 | `ctrl` | `apb_usb_host` | CTRL_EN=1 |
| 4 | `diag` | `apb_usb_host` | DIAG_EN=1 |
| 5 | `full` | `apb_usb_host` | CTRL_EN=1 DIAG_EN=1 |
| 6 | `clk12` | `apb_usb_host` | CLK_HZ=12000000 |
| 7 | `clk13m5` | `apb_usb_host` | CLK_HZ=13500000 |
| 8 | `clk25` | `apb_usb_host` | CLK_HZ=25000000 |
| 9 | `clk33` | `apb_usb_host` | CLK_HZ=33333333 |
| 10 | `clk36` | `apb_usb_host` | CLK_HZ=36000000 |
| 11 | `clk100` | `apb_usb_host` | CLK_HZ=100000000 |
| 12 | `clk200` | `apb_usb_host` | CLK_HZ=200000000 |
| 13 | `open` | `apb_usb_host` | MDELEG_RST=9'h000 |
| 14 | `smode_sync_rst` | `apb_usb_host` | ASYNC_RST_EN=0 MDELEG_RST=9'h105 |
| 15 | `addrw16` | `apb_usb_host` | ADDRW=16 |
| 16 | `tang` | `apb_usb_host` | ASYNC_RST_EN=0 CLK_HZ=33333333 |
| 17 | `full_corner` | `apb_usb_host` | ADDRW=12 ASYNC_RST_EN=0 CLK_HZ=25000000 CTRL_EN=1 DIAG_EN=1 MDELEG_RST=9'h000 |

## Status

All 17 configs: 0 errors, 0 warnings, `stale=0`. Deliberately unconsumed inputs
(`paddr_i[1:0]`, `pprot_i[2:1]`, the unused write-data bits, the accumulator carry of
the bit clock, the software-transfer decode, commands and events with `CTRL_EN = 0`, and
the counter events with `DIAG_EN = 0`) are sunk into `*_unused` wires. Design waivers in `waivers.tcl`: the unreset second stage of `arv_synchronizer`
in the synchronous-reset builds, the documented mixed set/reset reset value of `CTRL`
(`0x6`), and an `MDELEG` field reset to Supervisor.

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
