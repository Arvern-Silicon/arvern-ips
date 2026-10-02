#!/usr/bin/env python3
"""Coverage job list for runcov: every simulation run_all performs, as
   tag|top|submit_file|stimulus|+define+... list
Parsed from run/run_all itself (its TESTS / SMALL_TESTS lists and build list) so
the two cannot drift apart."""
import os, re

RUN = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'run')
src = open(os.path.join(RUN, 'run_all')).read()
def lst(name):
    return re.search(r'\b%s="([^"]*)"' % name, src).group(1).replace('\\', ' ').split()
tests, small = lst('TESTS'), lst('SMALL_TESTS')
builds = re.search(r'for build in (.*?); do', src).group(1)
for b in re.findall(r'"([^"]*)"', builds):
    suffix, defs = b.split(':', 1)
    d = ' '.join('+define+' + x for x in re.findall(r'-D\s*(\S+)', defs))
    for t in (small if suffix == '-mem8' else tests):
        print('%s|tb_ahb_rom_controller|submit.f|%s|%s' % (t + suffix.replace('-', '__'), t, d))
