#!/usr/bin/env python3
"""Coverage job list for runcov: every simulation run_all performs, as
   tag|top|submit_file|stimulus(or -)|+define+... list
Parsed from run/run_all itself so the two cannot drift apart."""
import os, re, sys

RUN = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'run')
jobs, sync, seen = [], False, set()
for line in open(os.path.join(RUN, 'run_all')):
    s = line.strip()
    if s.startswith('#'):
        continue
    if 'export SIM_EXTRA_DEFINES="-D ASYNC_RST_EN=0"' in s:
        sync = True
    elif s.startswith('unset SIM_EXTRA_DEFINES'):
        sync = False
    m = re.match(r'\.\./bin/runsim\s+(\w+)((?:\s+-\w+)*)', s)
    if m:
        test, opts = m.group(1), m.group(2).split()
        design = 'HIPERF' if '-hiperf' in opts else 'FUSED' if '-fused' in opts else 'GENERIC'
        d = [design, 'RANDOM_WS' if '-random_ws' in opts else 'ZERO_WS']
        if '-fixed_b_prio' in opts: d.append('FUSED_FIXED_B_PRIO')
        if '-arb_parked' in opts:   d.append('ARB_PARKED_GRANT')
        if sync:                    d.append('ASYNC_RST_EN=0')
        tag = '__'.join([test] + [x.split('=')[0].lower() for x in d])
        jobs.append((tag, 'tb_ahb_interconnect', 'submit.f', test, d))
        continue
    m = re.match(r'\./run_(default_subordinate|fused_rom|fused_sram)\s*(\w*)', s)
    if m:
        unit, sel = m.group(1), m.group(2) or 'rr'
        top = {'default_subordinate': 'tb_ahb_default_subordinate', 'fused_rom': 'tb_ahb_fused_rom_ctrl',
               'fused_sram': 'tb_ahb_fused_sram_ctrl'}[unit]
        d = ['FUSED_FIXED_B_PRIO'] if sel == 'fixb' else []
        jobs.append(('unit_%s_%s' % (unit, sel), top, 'submit_%s.f' % unit, '-', d))
for tag, top, sub, stim, d in jobs:
    if tag in seen:
        continue
    seen.add(tag)
    print('%s|%s|%s|%s|%s' % (tag, top, sub, stim, ' '.join('+define+' + x for x in d)))
