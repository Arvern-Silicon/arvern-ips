# VC Static Lint — apb_spi

Signoff-grade structural lint for apb_spi. Separate from and additional to the
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
| 1 | `default` | `apb_spi` | (defaults) |
| 2 | `sync_rst` | `apb_spi` | ASYNC_RST_EN=0 |
| 3 | `single` | `apb_spi` | LANES_MAX=1 |
| 4 | `dual` | `apb_spi` | LANES_MAX=2 |
| 5 | `cs8` | `apb_spi` | CS_NR=8 |
| 6 | `tx_only` | `apb_spi` | POLL_EN=0 RX_EN=0 |
| 7 | `no_poll` | `apb_spi` | POLL_EN=0 |
| 8 | `fifo2` | `apb_spi` | RX_FIFO_AW=1 TX_FIFO_AW=1 |
| 9 | `fifo256` | `apb_spi` | RX_FIFO_AW=8 TX_FIFO_AW=8 |
| 10 | `open` | `apb_spi` | MDELEG_RST=9'h000 |
| 11 | `smode_sync_rst` | `apb_spi` | ASYNC_RST_EN=0 MDELEG_RST=9'h105 |
| 12 | `addrw16` | `apb_spi` | ADDRW=16 |
| 13 | `dbg_none` | `apb_spi` | DBG_PMASTER_MASK=4'b0000 |
| 14 | `sd_corner` | `apb_spi` | ASYNC_RST_EN=0 CS_NR=2 LANES_MAX=1 RX_FIFO_AW=6 TX_FIFO_AW=3 |
| 15 | `tx_only_corner` | `apb_spi` | CS_NR=3 LANES_MAX=2 MDELEG_RST=9'h000 POLL_EN=0 RX_EN=0 TX_FIFO_AW=1 |

## Status

All 15 configs: 0 errors, 0 warnings, `stale=0`. Deliberately unconsumed inputs
(`paddr_i[1:0]`, `pprot_i[2:1]`, the `pmaster_i` bits outside `DBG_PMASTER_MASK`,
`XFER[7]`, the lane-code bits a narrower build masks, and the inputs of an absent
receive or poll path) are sunk into `*_unused` wires. Design waivers in `waivers.tcl`:
the unreset second stage of `arv_synchronizer` in the synchronous-reset builds, the
documented mixed set/reset reset values of the lane outputs (`u_io`, the driven idle
bus) and of `CTRL` (`0x010`) and of an `MDELEG` field reset to Supervisor, and a
`CONN_NET_FANIN_DEADLOOP` false positive on the receive FIFO's storage counter with
`RX_FIFO_AW` >= 7 (argued in place).

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
