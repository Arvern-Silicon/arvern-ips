# VC Static Lint — arv_custom_csr

Signoff-grade structural lint for arv_custom_csr. Separate from and additional to the
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
| 1 | `default` | `arv_custom_csr` | (defaults) |
| 2 | `min_banks` | `arv_custom_csr` | NR_MAC_RO=1 NR_MAC_RW=1 NR_SUP_RO=1 NR_SUP_RW=1 NR_USR_RO=1 NR_USR_RW=1 |
| 3 | `wide_banks` | `arv_custom_csr` | NR_MAC_RO=8 NR_MAC_RW=8 NR_SUP_RO=8 NR_SUP_RW=8 NR_USR_RO=8 NR_USR_RW=8 |
| 4 | `sync_rst` | `arv_custom_csr` | ASYNC_RST_EN=0 |
| 5 | `ro_only` | `arv_custom_csr` | NR_MAC_RW=0 NR_SUP_RW=0 NR_USR_RW=0 |
| 6 | `rw_only` | `arv_custom_csr` | NR_MAC_RO=0 NR_SUP_RO=0 NR_USR_RO=0 |
| 7 | `no_sup` | `arv_custom_csr` | NR_SUP_RO=0 NR_SUP_RW=0 |
| 8 | `two_banks` | `arv_custom_csr` | NR_MAC_RW=65 NR_SUP_RW=65 NR_USR_RW=65 |
| 9 | `max_banks` | `arv_custom_csr` | NR_MAC_RO=60 NR_MAC_RW=128 NR_SUP_RO=64 NR_SUP_RW=128 NR_USR_RO=64 NR_USR_RW=256 |

## Status

Clean on every config, no design-specific waivers.

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
