#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    flatten_filelist.py
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Recursively flatten a Verilog `-f` filelist into a single absolute-path
# file list.  Paths inside each filelist (regular file entries, +incdir+
# directives, and nested -f includes) are resolved relative to THAT
# filelist's own directory -- the iverilog / verilator standard
# convention.  The output is a flat list of absolute paths plus
# unchanged simulator directives, safe to pass to any tool regardless of
# the simulator's cwd.
#
# DUPLICATES: a source file (or +incdir+) reachable through more than one
# route -- e.g. listed directly AND pulled in again via a nested -f that
# references a shared library filelist (arv_common) -- is emitted only ONCE
# (first occurrence wins, preserving compile order).  This prevents
# duplicate-module elaboration errors when several IPs each pull the same
# shared primitives.  Passthrough directives (+define+, -D, ...) are never
# deduplicated.
#
# Usage:
#   flatten_filelist.py [--format {raw,tcl,qsf}] [--relative-to DIR]
#                       <input_filelist> <output_file>
#
#   --relative-to DIR  emit file/incdir paths relative to DIR instead of
#                      absolute. Use for relocatable tool flows where the
#                      generated list is consumed from a different filesystem
#                      location than where it was generated.
#
#   --format raw   (default) emit a simulator-style flat filelist
#                  (file paths + +incdir+ + passthroughs).
#   --format tcl   emit a Design-Compiler-friendly TCL fragment that
#                  defines two list variables:
#                      RTL_SOURCE_FILES   - absolute paths of .v sources
#                      RTL_INCDIRS        - absolute include directories
#                  Simulator-only directives (-D, +define+, ...) are
#                  dropped because dc_shell sets defines its own way.
#   --format qsf   emit an Intel/Altera Quartus assignment fragment (source
#                  the result from a project .qsf with `source <file>`):
#                      set_global_assignment -name VERILOG_FILE       <path>
#                      set_global_assignment -name SYSTEMVERILOG_FILE <path>  (.sv)
#                      set_global_assignment -name VHDL_FILE          <path>  (.vhd)
#                      set_global_assignment -name SEARCH_PATH        <dir>   (+incdir+)
#                      set_global_assignment -name VERILOG_MACRO      "X=Y"   (+define+/-D)
#                  Run-dir-local (`./`) sim artifacts are dropped (synthesis
#                  uses real RTL only).
#
# Recognised line forms:
#   //, blank             - dropped
#   -f <path>             - recurse into <path> (relative to current
#                           filelist's dir)
#   +incdir+<path>        - resolved to absolute path; emitted
#   +define+...           - passed through unchanged (raw); VERILOG_MACRO (qsf); dropped (tcl)
#   -D<...>, +<directive> - passed through unchanged (raw); -D -> VERILOG_MACRO (qsf); dropped (tcl)
#   `./<path>` or just `.`- passed through UNCHANGED (= simulator-cwd
#                           relative, for run-dir-local generated files).
#                           In tcl/qsf mode these are dropped (run-dir-local
#                           files are sim-only).
#   anything else         - treated as a file path; resolved to absolute
#                           (relative to current filelist's dir) and emitted
#----------------------------------------------------------------------------

import argparse
import os
import sys
from pathlib import Path


def process_filelist(filepath, processed=None):
    """Return a list of lines (strings, no trailing newline) for the
    flattened filelist."""
    if processed is None:
        processed = set()

    filepath = Path(filepath).resolve()
    if filepath in processed:
        return []  # circular include guard
    processed.add(filepath)
    base = filepath.parent

    out = []
    try:
        with open(filepath, 'r') as fh:
            for line in fh:
                stripped = line.strip()
                # Skip blanks and pure-comment lines
                if not stripped or stripped.startswith('//') or stripped.startswith('#'):
                    continue
                # Strip inline `//` comments
                if '//' in stripped:
                    stripped = stripped[:stripped.index('//')].strip()
                if not stripped:
                    continue

                # -f recursion (nested filelist)
                if stripped.startswith('-f '):
                    inc_path = stripped[3:].strip()
                    inc_full = (base / inc_path).resolve()
                    if inc_full.exists():
                        out.extend(process_filelist(inc_full, processed))
                    else:
                        print(f"WARNING: nested filelist not found: {inc_full} "
                              f"(referenced from {filepath})", file=sys.stderr)
                    continue

                # +incdir+<path>
                if stripped.startswith('+incdir+'):
                    inc = stripped[len('+incdir+'):]
                    # `./` or `./<something>` = cwd-relative (preserve).
                    # `.` alone or any other form = filelist-relative.
                    if inc.startswith('./'):
                        out.append(f"+incdir+{inc}")
                    else:
                        inc_abs = (base / inc).resolve()
                        out.append(f"+incdir+{inc_abs}")
                    continue

                # Other +directive+ or -D defines: pass through unchanged
                if stripped.startswith('+') or stripped.startswith('-'):
                    out.append(stripped)
                    continue

                # `./` or `./<file>` = simulator-cwd-relative; preserve verbatim
                if stripped.startswith('./'):
                    out.append(stripped)
                    continue

                # Bare file path (or `.`): resolve to absolute
                file_abs = (base / stripped).resolve()
                if not file_abs.exists():
                    print(f"WARNING: file not found: {file_abs} "
                          f"(referenced from {filepath})", file=sys.stderr)
                out.append(str(file_abs))
    except FileNotFoundError:
        print(f"Error: could not open filelist: {filepath}", file=sys.stderr)
    return out


def dedup_lines(lines):
    """Drop duplicate source-file and +incdir+ entries, keeping the FIRST
    occurrence so compile order is preserved.  Passthrough directives
    (+define+, -D, other +.../-...) are never deduplicated."""
    seen = set()
    out = []
    dropped = 0
    for ln in lines:
        if ln.startswith('+incdir+'):
            key = ln
        elif ln.startswith('+') or ln.startswith('-'):
            out.append(ln)          # passthrough directive: keep every one
            continue
        else:
            key = ln                # file path (absolute or ./-relative)
        if key in seen:
            dropped += 1
            continue
        seen.add(key)
        out.append(ln)
    if dropped:
        print(f"INFO: flatten_filelist: removed {dropped} duplicate file/incdir "
              f"entr{'y' if dropped == 1 else 'ies'}.", file=sys.stderr)
    return out


def relativize_lines(lines, base):
    """Rewrite absolute file paths and +incdir+ paths to be relative to `base`.
    Used for tool flows that need relocatable, location-independent paths (the
    generated list is consumed from a different filesystem location than where
    it was generated). `./`-prefixed run-dir-local entries and passthrough
    directives are left untouched."""
    base = Path(base).resolve()

    def _rel(p):
        return os.path.relpath(Path(p).resolve(), base)

    out = []
    for ln in lines:
        if ln.startswith('+incdir+'):
            inc = ln[len('+incdir+'):]
            out.append('+incdir+' + (inc if inc.startswith('./') else _rel(inc)))
        elif ln.startswith('+') or ln.startswith('-'):
            out.append(ln)
        elif ln.startswith('./'):
            out.append(ln)
        else:
            out.append(_rel(ln))
    return out


def emit_raw(src, lines, dst):
    with open(dst, 'w') as fh:
        fh.write("//=========================================================\n")
        fh.write("// AUTO-GENERATED FLATTENED FILELIST  (do not edit)\n")
        fh.write(f"// Source: {Path(src).resolve()}\n")
        fh.write(f"// Entries: {len(lines)}\n")
        fh.write("//=========================================================\n\n")
        for ln in lines:
            fh.write(ln + '\n')


def emit_tcl(src, lines, dst):
    files = []
    incdirs = []
    for ln in lines:
        if ln.startswith('+incdir+'):
            incdirs.append(ln[len('+incdir+'):])
        elif ln.startswith('+') or ln.startswith('-'):
            # simulator-only directive: drop
            continue
        elif ln.startswith('./'):
            # run-dir-local sim artifact: drop
            continue
        else:
            files.append(ln)

    def _emit_list(fh, name, items):
        if not items:
            fh.write(f"set {name} [list]\n")
            return
        fh.write(f"set {name} [list \\\n")
        for it in items:
            fh.write(f"    {it} \\\n")
        fh.write("]\n")

    with open(dst, 'w') as fh:
        fh.write("#=========================================================\n")
        fh.write("# AUTO-GENERATED RTL FILELIST  (do not edit)\n")
        fh.write(f"# Source : {Path(src).resolve()}\n")
        fh.write(f"# Files  : {len(files)}\n")
        fh.write(f"# Incdirs: {len(incdirs)}\n")
        fh.write("#=========================================================\n\n")
        _emit_list(fh, "RTL_SOURCE_FILES", files)
        fh.write("\n")
        _emit_list(fh, "RTL_INCDIRS", incdirs)


def emit_qsf(src, lines, dst):
    """Emit Intel/Altera Quartus `set_global_assignment` lines, to be sourced
    from a project .qsf."""
    rows = []   # (assignment-name, value) in original order

    def _macro(text):
        text = text.strip()
        if text:
            rows.append(("VERILOG_MACRO", f'"{text}"'))

    for ln in lines:
        if ln.startswith('+incdir+'):
            rows.append(("SEARCH_PATH", ln[len('+incdir+'):]))
        elif ln.startswith('+define+'):
            _macro(ln[len('+define+'):])
        elif ln.startswith('-D'):
            _macro(ln[2:])
        elif ln.startswith('+') or ln.startswith('-'):
            continue          # other simulator-only directive: drop
        elif ln.startswith('./'):
            continue          # run-dir-local sim artifact: drop (synthesis = real RTL)
        else:
            ext = Path(ln).suffix.lower()
            if ext == '.sv':
                name = "SYSTEMVERILOG_FILE"
            elif ext in ('.vhd', '.vhdl'):
                name = "VHDL_FILE"
            else:
                name = "VERILOG_FILE"
            rows.append((name, ln))

    n_files = sum(1 for n, _ in rows if n.endswith("_FILE"))
    with open(dst, 'w') as fh:
        fh.write("#=========================================================\n")
        fh.write("# AUTO-GENERATED QUARTUS SOURCE ASSIGNMENTS  (do not edit)\n")
        fh.write("# Source this file from your project .qsf:  source <this_file>\n")
        fh.write(f"# Source : {Path(src).resolve()}\n")
        fh.write(f"# Files  : {n_files}\n")
        fh.write("#=========================================================\n\n")
        for name, val in rows:
            fh.write(f"set_global_assignment -name {name:<18} {val}\n")


def main():
    ap = argparse.ArgumentParser(
        description="Flatten a Verilog -f filelist (recursive) to absolute paths.")
    ap.add_argument("--format", choices=["raw", "tcl", "qsf"], default="raw",
                    help="Output format: 'raw' (simulator filelist, default), "
                         "'tcl' (Design Compiler TCL fragment), or "
                         "'qsf' (Quartus set_global_assignment fragment).")
    ap.add_argument("--relative-to", metavar="DIR", default=None,
                    help="Emit file/incdir paths relative to DIR instead of "
                         "absolute (relocatable; the list is consumed from a "
                         "different filesystem location than it was generated).")
    ap.add_argument("input", help="Input root filelist (.f)")
    ap.add_argument("output", help="Output flattened file")
    args = ap.parse_args()

    lines = dedup_lines(process_filelist(args.input))
    if args.relative_to:
        lines = relativize_lines(lines, args.relative_to)

    try:
        if args.format == "raw":
            emit_raw(args.input, lines, args.output)
        elif args.format == "tcl":
            emit_tcl(args.input, lines, args.output)
        else:
            emit_qsf(args.input, lines, args.output)
    except Exception as e:
        print(f"Error writing {args.output}: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
