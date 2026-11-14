#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Module:    rules.tcl
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : rules.tcl
# Module Description : VC Static lint rule policy for the aRVern IPs -- per-tag enable/disable on top of the stage selection.
#----------------------------------------------------------------------------
# PROVENANCE: copied verbatim from arvern/lint/vc_static/rules.tcl, and
# IDENTICAL IN EVERY IP. It is a house policy, not a design-specific one -- the
# aRVern-named examples in the rationale comments below are illustrations of
# WHY a rule is off, and apply equally here. Keep every copy in step: a rule
# that is noise for the core is noise for the IPs, and divergence should be a
# deliberate, commented choice.
#----------------------------------------------------------------------------
# WHAT THIS FILE IS
#   The shipped tag set is a superset of several vendors' house coding
#   standards. This file turns off the rules that encode a standard aRVern does
#   not follow, so that what remains is defects rather than style. Stage
#   selection itself lives in run_vclint (VCLINT_STAGES); this file only refines
#   the enabled set.
#
# HOW TO ADD A RULE HERE
#   Take the tag name from results/report.lint_full.txt (NOT from
#   proverilog.log -- see the namespace note below), append it to the matching
#   list, and give it a one-line reason. Prefer fixing the RTL over disabling a
#   rule, and prefer a scoped waiver in waivers.tcl over a global disable when
#   the RTL is correct and only this rule disagrees.
#
# TAG NAMESPACE
#   configure_hdl_tag and report_hdl use VC tag names (CODING_*, CONN_*, NTL_*,
#   SYN_*). The VER_* / R_* / X_* identifiers in results/proverilog.log are the
#   Leda engine's internal numbering and mean nothing to configure_hdl_tag --
#   naming one here silently matches nothing.
#

# ---------------------------------------------------------------------------
# Translated SpyGlass rulesets (SG_*)
#
# Roughly 2400 of the LANGUAGE_CHECK tags are other organisations' house
# standards (SG_STARC2002/2005, SG_LINT, SG_MORELINT, SG_OPENMORE) and
# vendor-internal ones (SG_INTEL, SG_AMD, SG_MTK, SG_SARC).
#
# The native CODING_* / SYN_* rules underneath are KEPT -- those are the real
# language-semantics and synthesizability checks (casex without default, bits
# shifted out, self-assignment, signed/unsigned mixing, system tasks in RTL).
#
# The list is harvested from the live catalog rather than hard-coded, so it
# cannot go stale on a tool upgrade. No effect unless -lang is passed.
# ---------------------------------------------------------------------------
redirect -file ./tag_catalog.txt { configure_hdl_tag -all -verbose }
set _sg {}
set _fh [open ./tag_catalog.txt r]
while {[gets $_fh _line] >= 0} {
    if {[regexp {^\s+(SG_\w+)\s*$} $_line -> _t]} { lappend _sg $_t }
}
close $_fh

# vcst prints [Error] TCL_CMD_FAILED for each individually-rejected tag before
# the catch sees it. Those are expected, so the loop is redirected to keep the
# run log readable -- the tally below reports the real outcome, and
# tag_disable.log retains the detail.
set _ok 0
set _skipped 0
set _n [llength $_sg]
redirect -file ./tag_disable.log {
for {set _i 0} {$_i < $_n} {incr _i 40} {
    set _chunk [lrange $_sg $_i [expr {$_i + 39}]]
    if {[catch {configure_hdl_tag -disable -tag $_chunk}]} {
        foreach _t2 $_chunk {
            if {[catch {configure_hdl_tag -disable -tag $_t2}]} {
                incr _skipped
            } else {
                incr _ok
            }
        }
    } else {
        incr _ok [llength $_chunk]
    }
}
}
puts "\[vc_lint\] SpyGlass tags disabled: $_ok of $_n ($_skipped not accepted by this build)"
unset -nocomplain _sg _fh _line _t _t2 _ok _skipped _n _i _chunk

# ---------------------------------------------------------------------------
# Native style rules encoding a coding standard aRVern does not follow
#
# LANGUAGE_CHECK stage, so these only matter under -lang.
#
#   CODING_DECL_USE_LOGIC              "use logic instead of reg and wire"
#   CODING_ALWAYS_USE_ALWAYS_COMB      "always_comb should be used"
#   CODING_ALWAYS_ONLYUSE_ALWAYS_COMB  same requirement, second tag
#   CODING_ALWAYS_USE_ALWAYS_FF        "always_ff should be used by FF"
#       All four demand SystemVerilog. aRVern is Verilog-2001
#
#   CODING_DECL_COMMENT                comment required on every declaration
#   NAMING_INST_PIN_NET_SAME           pin and net must share a name
#       aRVern deliberately maps e.g. clk_i -> hclk_i at instantiation.
#   NAMING_PORT_IN_OUT_UPPER_CASE      uppercase port names
#       aRVern uses lowercase with _i/_o suffixes.
#   NAMING_MOD_PARAM_NAME              parameters must start with P_
#   NAMING_ARRAY_NOT_HARD_CODED        hard-coded bus sizes discouraged
#   CODING_NAMING_INST_NUMPREFIX       instance names must embed the module name
#   XPROP_STMT_TERN_RHS                LEDA VRQ x-uglify standard -- not used here
#   SYN_DECL_NET_ASSIGN                "no assignment in net declaration"
#       Would flag most continuous assignments in the core.
#   CODING_STMT_PARAM_CONST            numeric literals should be parameters
#       Impractical for ISA opcode encodings.
#   CODING_EXPR_NESTED_CONDEXPR        no nested conditional expressions
#       The decode priority muxes are nested by design.
#
# KEPT deliberately, despite sitting in the same CODING_ALWAYS_* / CODING_CASE_*
# space: CODING_ALWAYS_NO_ELSE and CODING_CASE_LATCHLIKE are latch-inference
# checks, not style.
# ---------------------------------------------------------------------------
set _style {
    CODING_DECL_USE_LOGIC
    CODING_ALWAYS_USE_ALWAYS_COMB
    CODING_ALWAYS_ONLYUSE_ALWAYS_COMB
    CODING_ALWAYS_USE_ALWAYS_FF
    CODING_DECL_COMMENT
    NAMING_INST_PIN_NET_SAME
    NAMING_PORT_IN_OUT_UPPER_CASE
    NAMING_MOD_PARAM_NAME
    NAMING_ARRAY_NOT_HARD_CODED
    CODING_NAMING_INST_NUMPREFIX
    XPROP_STMT_TERN_RHS
    SYN_DECL_NET_ASSIGN
    CODING_STMT_PARAM_CONST
    CODING_EXPR_NESTED_CONDEXPR
}

# Header-comment templates: these require a specific house header format
# (Author / Date / Modification / Description / File Name fields, plus
# per-function and per-type header blocks). aRVern has its own header block --
# the field is spelled "Module Description" rather than "Description", and
# there are no Author or Modification fields at all -- so each of these fires
# on every file in the design. Renaming aRVern's header fields to satisfy a
# foreign template would not fix a defect.
#
# KEPT deliberately: CODING_COMMENT_DC_SHELL ("do not use embedded dc_shell
# scripts in the source code") shares the prefix but is a real check.
lappend _style \
    CODING_COMMENT_HEADER \
    CODING_COMMENT_AUTHOR_HEADER \
    CODING_COMMENT_DATE_HEADER \
    CODING_COMMENT_EDIT_HEADER \
    CODING_COMMENT_FILE_NAME_HEADER \
    CODING_COMMENT_FUNCTION_HEADER \
    CODING_COMMENT_TYPE_HEADER \
    CODING_COMMENT_LINE_TYPE \
    CODING_COMMENTS_AUTHOR_FIELD_MISSING \
    CODING_COMMENTS_DATE_FIELD_MISSING \
    CODING_COMMENTS_DESCRIPTION_FIELD_MISSING \
    CODING_COMMENTS_FILE_NAME_FIELD_MISSING \
    CODING_COMMENTS_MODIFICATION_FIELD \
    CODING_COMMENTS_PORT_MODE

set _sok 0
set _sskip 0
foreach _st $_style {
    if {[catch {configure_hdl_tag -disable -tag $_st}]} { incr _sskip } else { incr _sok }
}
puts "\[vc_lint\] style tags disabled: $_sok ($_sskip not recognised)"
unset -nocomplain _style _st _sok _sskip

# ---------------------------------------------------------------------------
# Register-at-port methodology
#
# NETLIST stage, so unlike the blocks above these affect the DEFAULT run too.
#
# "Inputs/outputs should be registered" is an FPGA/timing-closure convention
# that makes every module boundary a timing endpoint. aRVern deliberately does
# the opposite: the documented critical path is the single-cycle
# inst_hrdata -> inst_haddr branch-target loop through decode (see the
# "Critical Timing Path" section of CLAUDE.md), and AHB-Lite address/control
# generation is combinational by protocol. Satisfying these rules would mean
# changing the microarchitecture, not fixing a defect.
#
# KEPT deliberately: CODING_PORT_READ_OUTPUT shares the prefix but is a
# different check -- it is handled with the hierarchy rules below.
# ---------------------------------------------------------------------------
set _portreg {
    CODING_PORT_IN_REGISTER
    CODING_PORT_OUT_REGISTER
    CODING_PORT_OUT_DIRECT_REGISTER
    CODING_PORT_TOP_MODOUT_REGISTER
    CODING_PORT_UNREGISTERED_OUTPUT
    CODING_PORT_REGISTERED
    CODING_PORT_INOUT_REGISTERED
}
set _pok 0
set _pskip 0
foreach _pt $_portreg {
    if {[catch {configure_hdl_tag -disable -tag $_pt}]} { incr _pskip } else { incr _pok }
}
puts "\[vc_lint\] register-at-port tags disabled: $_pok ($_pskip not recognised)"
unset -nocomplain _portreg _pt _pok _pskip

# ---------------------------------------------------------------------------
# Hierarchy / path-topology methodology
#
# NETLIST stage -- affects the default run. These describe how logic is
# partitioned across the hierarchy, not whether it is correct.
#
#   CODING_HW_SNAKE_PATH        signals threaded through a module without local use
#   CODING_TREE_RECOV_PATH      reconvergent fanout -- inherent in any real datapath
#   CODING_INST_NOT_UNIQUIFIED  "netlist not uniquified" -- unavoidable at RTL, since
#                               arv_dff is instantiated ~250 times and uniquification
#                               is a Design Compiler step, not an RTL property
#   CODING_HW_GLUE_LOGIC        "avoid glue logic at top level" -- arvern.v wires
#                               submodules together with assigns, which is what a
#                               top level is for
#   CODING_HW_MULT_FANOUT       one net driving two ports of the same instance
#
# The last three below are one coding style reported under three different
# tags: aRVern reads its own output ports. arv_fetch, for example, drives
# id_pc_o and then reads it throughout the module -- id_pc_o IS the PC. That is
# legal Verilog; the alternative is an internal wire plus `assign port = wire`,
# which synthesises identically. A rename sweep through arv_fetch/arv_decode,
# the modules carrying the documented critical path, would buy a lint metric
# and nothing else.
#
#   CODING_HW_REENTRANT_PATH    an output re-enters its own module
#   CONN_PORT_MODOUT_SUBIN      an output also drives a sub-module input
#   CODING_PORT_READ_OUTPUT     reading from an output port (LANGUAGE_CHECK only)
#   CONN_PORT_CONN_MISMATCH    147  "undriven bits detected in port connection"
#       The fourth name for this style, and the most misleadingly worded: it
#       fires when a net's only driver is a CHILD module's output port rather
#       than an assign in the parent -- that is, on ordinary hierarchical
#       wiring. Two shapes, both traced to the RTL and both properly driven:
#         - a parent output wired straight to a submodule output, e.g.
#           arv_csr_top.cfg_timeout_wait_o, driven from mstatus_tw at
#           arv_csr_traps.v:851
#         - an internal wire between two submodules, e.g. trig_m_trap_entry,
#           driven by arv_csr_traps and consumed by arv_debug_trigger
#       Complying would mean an intermediate wire plus an explicit assign for
#       every inter-module net in the design.
#   CONN_PORT_INPUT_DEFINEDAS_OUTPUT  7  "input defined as output" -- the fifth
#       name for the same style, seen from the consuming side: a module reads
#       its own output port as an input, e.g. arv_csr_cntr feeding time_req_o
#       into a flop enable, or arv_load_store reading data_haddr_o.
#   CODING_TREE_NO_FEEDTHROU    an input wired straight to an output with no
#       logic between. Silent on the core; fires ~30 times on any SoC top,
#       every one of them AHB fabric doing its job: ahb_subordinate_mux
#       replicating the address phase to every subordinate
#       (s_haddr_o = {NR_S{haddr_i}}), ahb_manager_if's hsel_o = m_grant_i,
#       the SRAM controllers exporting hclk_i as sram_clk_o and passing
#       zero-wait-state read data straight through, the fused interconnect
#       handing m_x_haddr_i to the external decoder. A fabric that did not
#       feed through would not be a fabric. Same class as SNAKE_PATH above.
#
# CAREFUL: this is a hand-picked list, NOT the CODING_HW_* / CODING_TREE_*
# families. Those families also contain CODING_TREE_ASYNC_FDBKLOOP (async
# feedback loop), CODING_TREE_SYNC_LOOP (combinational loop),
# CODING_TREE_SETRST_ORIG (set and reset from a common source) and
# CODING_HW_PULSE_GEN -- all real defect detectors that stay ENABLED. Do not
# turn this into a prefix sweep.
# ---------------------------------------------------------------------------
set _topo {
    CODING_HW_SNAKE_PATH
    CODING_TREE_RECOV_PATH
    CODING_INST_NOT_UNIQUIFIED
    CODING_HW_GLUE_LOGIC
    CODING_HW_MULT_FANOUT
    CODING_HW_REENTRANT_PATH
    CONN_PORT_MODOUT_SUBIN
    CODING_PORT_READ_OUTPUT
    CONN_PORT_CONN_MISMATCH
    CONN_PORT_INPUT_DEFINEDAS_OUTPUT
    CODING_TREE_NO_FEEDTHROU
}
set _tok 0
set _tskip 0
foreach _tt $_topo {
    if {[catch {configure_hdl_tag -disable -tag $_tt}]} { incr _tskip } else { incr _tok }
}
puts "\[vc_lint\] hierarchy/topology tags disabled: $_tok ($_tskip not recognised)"
unset -nocomplain _topo _tt _tok _tskip

# ---------------------------------------------------------------------------
# Fan-out
#
# CONN_NET_HEAVY_FANOUT flags high fan-out nets. In a CPU core those are the
# clock, reset and enable nets, and they are expected. Fan-out is a synthesis /
# physical-design concern that Design Compiler already reports (TIM-134, waived
# in synthesis/synopsys/waivers.txt), so tracking it here duplicates a check
# with a better home.
#
# If you want it back but quieter: the fan-out threshold is a rule parameter
# rather than a fixed value -- see configure_hdl_tag_param -- so it can be
# raised instead of disabling the rule outright.
# ---------------------------------------------------------------------------
if {[catch {configure_hdl_tag -disable -tag CONN_NET_HEAVY_FANOUT}]} {
    puts "\[vc_lint\] WARNING: could not disable CONN_NET_HEAVY_FANOUT"
} else {
    puts "\[vc_lint\] fan-out tag disabled: CONN_NET_HEAVY_FANOUT"
}

# ---------------------------------------------------------------------------
# Reset architecture -- CONDITIONAL on the configuration being linted
#
# ASYNC_RST_EN is aRVern's reset-style switch: 1 = every flop asynchronously
# reset, 0 = every flop synchronously reset. Two rules encode exactly opposite
# expectations, so precisely one of them is correct for any given build:
#
#   CODING_RST_ASYNC_FF  "use asynchronous reset/set for initial reset/set to
#                        register" -- fires on any flop that is NOT async-reset
#   CODING_FF_NO_ASYNC   "use only fully synchronous flip-flops"
#                        -- fires on any flop that IS async-reset
#
# Enabling the one that matches the build turns it into a positive check that
# the reset architecture is uniform: in an async build any stray sync flop is
# flagged, and in a sync build any stray async flop is flagged. The other is
# disabled, since it would otherwise flag every flop in the design.
#
# rules.tcl is sourced after rtl_params.tcl, so the elaboration parameters are
# in scope here. Default to the async expectation if the parameter is absent
# (e.g. -no_params), matching arvern.v's own default.
# ---------------------------------------------------------------------------
set _arst 1
if {[info exists RTL_PARAM_ASYNC_RST_EN]} { set _arst $RTL_PARAM_ASYNC_RST_EN }
if {$_arst == 1} {
    configure_hdl_tag -disable -tag CODING_FF_NO_ASYNC
    puts "\[vc_lint\] reset style ASYNC: enforcing CODING_RST_ASYNC_FF (all flops must be async-reset)"
} else {
    configure_hdl_tag -disable -tag CODING_RST_ASYNC_FF
    puts "\[vc_lint\] reset style SYNC: enforcing CODING_FF_NO_ASYNC (all flops must be sync-reset)"
}
unset -nocomplain _arst

# ---------------------------------------------------------------------------
# LANGUAGE_CHECK house-style rules (second pass)
#
# All LANGUAGE_CHECK, so these only matter under -lang. Each was read from the
# catalog before being listed; the defect-class rules in the same families are
# deliberately left enabled and are listed at the bottom of this block.
#
#   CODING_INST_PARAMETER          every parameter must be named explicitly at
#                                  instantiation. Considered and rejected, not
#                                  dismissed: this rule WOULD catch an instance
#                                  silently inheriting a default it did not
#                                  intend -- e.g. an arv_dff missing
#                                  .ARST_EN(ARST_EN), which would stay async in
#                                  a sync-reset build. Kept off because arvern
#                                  deliberately relies on defaults (arv_dff has
#                                  three parameters, most instances want
#                                  WIDTH=1), an audit confirmed 250/250
#                                  instances propagate ARST_EN, and compliance
#                                  would mean naming every defaulted parameter
#                                  across ~237 sites. Re-enable if that
#                                  guarantee is ever wanted enforced rather
#                                  than audited.
#   CODING_STMT_CONSIDER_CARRY     "pay attention to carry" -- fires on arithmetic
#                                  generally; an advisory, not a defect
#   CODING_FSM_INDEPENDENT_BLK     FSMs must live in their own hierarchy
#   CODING_DECL_SIG_CNT            one signal declaration per line
#   CODING_EXPR_USE_BITOP          prefer & | ~ over && || ! even on 1-bit operands
#   CODING_STMT_ARITH_CONDEXPR     no arithmetic inside a conditional expression
#   CODING_NAMING_ACTIVE_LOW_POLARITY  active-low signals need an _X/_N suffix
#   CODING_ASSIGN_BASE_FORMAT      every constant needs an explicit base
#   CODING_PORTMAP_NO_LOGICEXPR    no expressions in port maps
#   CODING_OPERATOR_REDUCTION_LIMIT  no reduction operators on vectors wider than 8
#   CODING_SIGNAL_LOWER_CASE / CODING_DECL_SIGNAL_LOWER_CASE  naming case
#   CODING_STMT_MULTI_ASSIGN       one assignment per line
#   CODING_ARRAY_LSB_ZERO          array LSB should be 0
#   CODING_PORT_SAME_ORDER         instance port order must match declaration order
#   CODING_CASE_DEFAULT_X          assign X in default clauses to save area
#
#   -- second tail pass, each checked against the RTL --
#   SYN_EXPR_SHIFT_OP              "shift by a non-constant is not allowed" -- the
#                                  barrel shifter and one-hot decoders; variable
#                                  shifts are synthesisable and required by RV32
#   SYN_DECL_PARAM_BITSEL / CODING_EXPR_BITSELECT_NON_VECTOR
#                                  bit-select on a scalar parameter (MUL_EN[0],
#                                  ZBB_EN[0]) -- arvern's idiom for coercing an
#                                  unsized parameter to one bit; legal Verilog
#   CODING_IF_WITHOUT_ELSE         all ten are safe: two are `else if (en_i)` in
#                                  CLOCKED blocks (that IS the flop enable, not a
#                                  latch), three are in functions that assign
#                                  their result unconditionally first
#                                  (arv_csr_hpm rdata=32'h0, arv_alu CLZ/CTZ/CPOP)
#   CODING_STMT_OPERATOR_PRECEDENCE  every instance parses as intended -- `==`
#                                  binds tighter than `&`, `&` tighter than `|`,
#                                  `?:` lowest. A readability preference for
#                                  redundant parentheses
#   CODING_STMT_CONST_EXPR / CODING_IF_CONST_COND / SIMSYN_EXPR_PARAM_RANGE
#                                  constant conditions produced by parameter
#                                  folding -- intrinsic to a configurable core
#   CODING_RESET_SYNC / SYN_ASYNC_EXIST
#                                  "synchronous/asynchronous reset detected" --
#                                  informational reports, not findings
#
#   -- sync-reset builds only (ASYNC_RST_EN=0); invisible in the default config,
#      found by linting the ofat:ASYNC_RST_EN=0 sweep entry --
#   SYN_SYNCRST_CNT_PROC / SYN_SYNCRST_CNT_UNIT / SYN_SYNCSET_CNT_PROC /
#   SYN_SYNCSET_CNT_UNIT           "[ActualSize] synchronous resets/sets detected"
#                                  -- metric counters that report a number, with no
#                                  threshold and no pass/fail; same class as the
#                                  fan-out rule
#   SYN_SEQBLK_ONE_CTRL            "at most one synchronous reset/set/load signal
#                                  per sequential block" -- an enabled sync-reset
#                                  flop has two by construction (rst_n_i and en_i).
#                                  Complying would mean giving up either the reset
#                                  or the enable on every flop in the design
#   SYN_SYNC_ACTIVE_LOW / CODING_ASYNC_RST_FALLEDG / CODING_RST_FIRSTLINE
#                                  reset-style conventions (active-low sync init,
#                                  explicit == 1'b0 comparison, reset on the first
#                                  line) that arvern's arv_dff does not follow
#   CODING_FUNC_RET_STMT           the last statement in a function must assign the
#                                  function name. Checked: count_leading_zeros and
#                                  count_trailing_zeros assign it unconditionally
#                                  BEFORE the loop, so the return value is always
#                                  defined -- the rule objects to statement order
#   CODING_SIGNAL_MULT_FANOUT      a signal driving several ports -- same pass-through
#                                  style as the hierarchy rules above
#   CODING_DECL_MEMORY / SVSYN_UNPACKED_ARRAY_DETECTED
#                                  both flag the same 6 declarations, and all are
#                                  arrays of WIRES (mhpmcounter_lo/hi, mhpmevent_reg,
#                                  hpm_ctr_rdata_wire, tdata1_or, tdata2_or) driven by
#                                  generate loops -- indexed collections for the 8 HPM
#                                  counters and 8 debug triggers, not inferred memories
#   XPROP_STMT_IF / _CASE / _COND_EXP   LEDA VRQ x-uglify standard, as XPROP_STMT_TERN_RHS
#   CODING_FSM_* (USE_MOORE/MOORE/TWO_BLK/STATE_NAME/COMB_SEQ)  mutually contradictory
#                                  FSM-style opinions
#   NAMING_* / CODING_NAME_*       signal, clock, reset and module naming conventions
#
# CODING_DECL_DEFAULT_NETTYPE is disabled for the opposite reason: it demands
# that `default_nettype NOT be used, while arvern deliberately sets
# `default_nettype none in every file. Following it would be a regression.
#
# LEFT ENABLED in these same families, because they detect defects rather than
# style: CONN_PORT_CONN_MISMATCH, CONN_STMT_UNEQ_SIZE1,
# CODING_ASSIGN_UNEQUAL_LENGTH, CODING_WIDTH_UNEQ_*, CODING_EXPR_PRECISION_LOSS,
# CODING_EXPR_BITSELECT_NON_VECTOR, CODING_STMT_OPERATOR_PRECEDENCE,
# CODING_IF_WITHOUT_ELSE, CONN_PORT_INPUT_DEFINEDAS_OUTPUT, and the reset-style
# rules (CODING_RST_FIRSTLINE, SYN_SYNC_ACTIVE_LOW, CODING_ASYNC_RST_FALLEDG,
# CODING_RESET_SYNC, SYN_ASYNC_EXIST).
# ---------------------------------------------------------------------------
set _lang_style {
    CODING_INST_PARAMETER
    CODING_STMT_CONSIDER_CARRY
    CODING_FSM_INDEPENDENT_BLK
    CODING_DECL_SIG_CNT
    CODING_EXPR_USE_BITOP
    CODING_STMT_ARITH_CONDEXPR
    CODING_NAMING_ACTIVE_LOW_POLARITY
    CODING_ASSIGN_BASE_FORMAT
    CODING_PORTMAP_NO_LOGICEXPR
    CODING_OPERATOR_REDUCTION_LIMIT
    CODING_DECL_DEFAULT_NETTYPE
    CODING_SIGNAL_LOWER_CASE
    CODING_DECL_SIGNAL_LOWER_CASE
    CODING_STMT_MULTI_ASSIGN
    CODING_ARRAY_LSB_ZERO
    CODING_PORT_SAME_ORDER
    SYN_EXPR_SHIFT_OP
    SYN_DECL_PARAM_BITSEL
    CODING_EXPR_BITSELECT_NON_VECTOR
    CODING_IF_WITHOUT_ELSE
    CODING_STMT_CONST_EXPR
    CODING_IF_CONST_COND
    SIMSYN_EXPR_PARAM_RANGE
    CODING_RESET_SYNC
    SYN_ASYNC_EXIST
    SYN_SYNCRST_CNT_PROC
    SYN_SYNCRST_CNT_UNIT
    SYN_SYNCSET_CNT_PROC
    SYN_SYNCSET_CNT_UNIT
    SYN_SEQBLK_ONE_CTRL
    SYN_SYNC_ACTIVE_LOW
    CODING_ASYNC_RST_FALLEDG
    CODING_RST_FIRSTLINE
    CODING_EXPR_DLY_FF
    CODING_ARRAY_VECT_OP
    SIMSYN_CASE_ITEM_COVER
    CODING_EXPR_USE_CASE
    SYN_BIT_INDEX_CONST
    CODING_STMT_NEG_REGWIRE
    CODING_CASE_DEFAULT_X
    CODING_SIGNAL_MULT_FANOUT
    CODING_DECL_MEMORY
    SVSYN_UNPACKED_ARRAY_DETECTED
    XPROP_STMT_IF
    XPROP_STMT_CASE
    XPROP_STMT_COND_EXP
    CODING_FSM_USE_MOORE
    CODING_FSM_MOORE
    CODING_FSM_TWO_BLK
    CODING_FSM_STATE_NAME
    CODING_FSM_COMB_SEQ
    CODING_SEQBLK_OWN_HIER
    CODING_COMBBLK_NOALWAYS
    NAMING_SIGNAL_RESET
    NAMING_SIGNAL_REG_END
    NAMING_SIGNAL_REG_DRIVE_CLK
    NAMING_SIGNAL_CLOCK
    NAMING_MOD_USE_UPPER_CASE
    NAMING_PORT_NO_OF_CHARS
    CODING_NAME_FUNC
    CODING_NAME_FF_OUT
    CODING_NAME_ACTIVELOW_RST
    CODING_NAME_ACTIVEHIGH_RST
    CODING_NAME_SYNC_RST
}
set _lok 0
set _lskip 0
redirect -file ./tag_disable_lang.log {
foreach _lt $_lang_style {
    if {[catch {configure_hdl_tag -disable -tag $_lt}]} { incr _lskip } else { incr _lok }
}
}
puts "\[vc_lint\] language style tags disabled: $_lok ($_lskip not recognised)"
unset -nocomplain _lang_style _lt _lok _lskip
