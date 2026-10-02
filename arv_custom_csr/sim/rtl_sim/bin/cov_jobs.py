#!/usr/bin/env python3
"""Coverage job list for runcov: every simulation run_all performs, as
   tag|top|submit_file|stimulus|+define+... list
Parsed from run/run_all (FIXED_TESTS x its build list, SWEEP_TESTS x every line of
rtl_configs_defines.py) so the two cannot drift apart."""
import os, re, subprocess, sys

BIN = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(BIN, '..', 'run', 'run_all')).read()
def lst(name):
    return re.search(r'\b%s="([^"]*)"' % name, src).group(1).replace('\\', ' ').split()
def defs(s):
    return ' '.join('+define+' + x for x in re.findall(r'-D\s*(\S+)', s))
fixed, sweep = lst('FIXED_TESTS'), lst('SWEEP_TESTS')
builds = re.search(r'for build in (.*?); do', src).group(1)
for b in re.findall(r'"([^"]*)"', builds):
    suffix, d = b.split(':', 1)
    for t in fixed:
        print('%s|tb_arv_custom_csr|submit.f|%s|%s' % (t + suffix.replace('-', '__'), t, defs(d)))
out = subprocess.run([sys.executable, os.path.join(BIN, 'rtl_configs_defines.py')],
                     capture_output=True, text=True, check=True).stdout
for line in out.splitlines():
    label, d = line.split(':', 1)
    for t in sweep:
        print('%s__%s|tb_arv_custom_csr|submit.f|%s|%s' % (t, label, t, defs(d)))
