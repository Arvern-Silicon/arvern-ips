#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Module:    check_core_manifest
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : check_core_manifest.py
# Module Description : Check that an IP's FuseSoC manifest (<ip>.core) lists
#                      exactly the RTL files of rtl/verilog/filelist.f, so the
#                      two cannot drift apart. The native flows consume the
#                      filelist and never notice a stale manifest; an external
#                      integration through fusesoc fails at file collection.
#
# Usage: check_core_manifest.py [<ip directory>]   (default: the IP this
#        script lives in). Exit status 1 on any mismatch.
#----------------------------------------------------------------------------

import os
import re
import sys


def filelist_rtl(path):
    """Local .v entries of a filelist (the -f includes are dependencies)."""
    files = []
    for line in open(path):
        line = line.split('//')[0].strip()
        if not line or line.startswith('-f') or line.startswith('+'):
            continue
        files.append(os.path.basename(line))
    return files


def core_rtl(path):
    """Files of the 'rtl' fileset of a CAPI2 core file (no YAML dependency)."""
    files, in_rtl, in_files = [], False, False
    for raw in open(path):
        line = raw.split('#')[0].rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        s = line.strip()
        if s == 'rtl:' and indent == 2:
            in_rtl, in_files = True, False
            continue
        if in_rtl and indent <= 2:
            in_rtl = False
        if in_rtl and s == 'files:':
            in_files = True
            continue
        if in_rtl and in_files:
            m = re.match(r'-\s+(\S+)', s)
            if m:
                files.append(os.path.basename(m.group(1)))
            else:
                in_files = False
    return files


def main():
    ip_dir = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else \
        os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
    ip = os.path.basename(ip_dir)
    core = os.path.join(ip_dir, ip + '.core')
    flist = os.path.join(ip_dir, 'rtl', 'verilog', 'filelist.f')
    for p in (core, flist):
        if not os.path.isfile(p):
            print(f'check_core_manifest: {p} not found')
            return 1
    want, have = filelist_rtl(flist), core_rtl(core)
    missing = [f for f in want if f not in have]
    extra   = [f for f in have if f not in want]
    if not missing and not extra:
        print(f'check_core_manifest: {ip}.core matches rtl/verilog/filelist.f ({len(want)} files)')
        return 0
    for f in extra:
        print(f'check_core_manifest: {ip}.core lists {f}, which is not in filelist.f')
    for f in missing:
        print(f'check_core_manifest: {ip}.core is missing {f}')
    return 1


if __name__ == '__main__':
    sys.exit(main())
