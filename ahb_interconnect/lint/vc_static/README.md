# VC Static Lint — ahb_interconnect

Signoff-grade structural lint for ahb_interconnect. Separate from and additional to the
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
| 1 | `generic_default` | `ahb_interconnect_generic` | (defaults) |
| 2 | `generic_syncrst` | `ahb_interconnect_generic` | ASYNC_RST_EN=0 |
| 3 | `hiperf_default` | `ahb_interconnect_hiperf` | (defaults) |
| 4 | `hiperf_syncrst` | `ahb_interconnect_hiperf` | ASYNC_RST_EN=0 |
| 5 | `fused_default` | `ahb_interconnect_fused` | (defaults) |
| 6 | `fused_norom` | `ahb_interconnect_fused` | NR_S_X_ROM=0 |
| 7 | `fused_syncrst` | `ahb_interconnect_fused` | ASYNC_RST_EN=0 |

## Status

Clean on all 7 configs. Waivers: registered feedback through `arv_ipdff`
port maps (the default subordinate's data-phase shift, the AHB hready loop),
and the fused ROM controller's arbitration flop with a non-zero reset value.

Note that unused nets must be sunk with `|{1'b0, ...}`, not `&{1'b0, ...}`:
the latter is a constant 0 that a structural linter folds away, and the
"unused" warnings come back.

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
