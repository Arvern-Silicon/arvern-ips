#!/usr/bin/env python3
"""Coverage waivers: exclude known-unreachable points from the hole list.

Waivers live in `run/waivers_cov.md`: prose anywhere, entries in ```json fences.
The legacy one-line-per-waiver `.txt` format is still readable (see _load_txt) so an
unconverted tree keeps working, but new files should be Markdown.

The legacy line format was:

    <file>:<locator>   <type>[,<type>]   [sig=<glob>]   # <reason>

    file      basename of the RTL file, e.g. arv_dtm_cmd.v
    locator   a line number, /literal text/ matched as a SUBSTRING of that line, or
              re/pattern/ for an actual regex. Prefer the literal form: Verilog is
              full of ( ) [ ] which silently change meaning in a regex.
    type      line | branch | toggle | all
    sig=      optional glob narrowing what is waived. For toggle it selects signals
              -- NOTE this is an fnmatch glob, where [..] is a CHARACTER CLASS, so
              a whole bus is sig=ab_div[[]* (the [[] matches a literal '['), NOT
              sig=ab_div[*], which matches a literal asterisk and so nothing at all.
              sig=ab_div* also works but would catch ab_div_foo too.
              For branch it selects the direction (sig=if / sig=else),
              so a dead false path can be waived while its live true path keeps counting.
    reason    mandatory -- a waiver without one is rejected, not silently accepted

Two properties make this safe to rely on:

  * A waiver that matches nothing is reported as STALE. Waivers rot when the RTL moves
    underneath them, and a rotted waiver silently hides real holes.
  * Waived points are removed from the denominator and counted separately, so the
    headline number never improves just because something was waived.
"""
import os
import re
import fnmatch

# Reason placeholder emitted by suggest(). The loader REJECTS it: a waiver whose
# reason is still the generated stub reads as justified while justifying nothing,
# which is worse than no waiver at all. Filling it in is not optional.
PLACEHOLDER = '<MECHANISM>'

TYPES = {'line': 'v_line', 'branch': 'v_branch', 'toggle': 'v_toggle'}


class Waiver(object):
    __slots__ = ('file', 'line', 'rx', 'txt', 'pages', 'sig', 'reason', 'src', 'hits')

    def __init__(self, file, line, rx, txt, pages, sig, reason, src):
        self.file, self.line, self.rx, self.txt = file, line, rx, txt
        self.pages, self.sig, self.reason, self.src = pages, sig, reason, src
        self.hits = 0

    def __str__(self):
        if self.line is not None:
            loc = str(self.line)
        elif self.txt is not None:
            loc = '/%s/' % self.txt
        else:
            loc = 're/%s/' % self.rx.pattern
        return '%s:%s' % (self.file, loc)


class Waivers(object):
    def __init__(self, path=None):
        self.items = []
        self.errors = []
        self._srccache = {}
        self.path = path
        if path and os.path.exists(path):
            self._load(path)

    KEYS = {'file', 'at', 'type', 'sig', 'why'}

    def _load(self, path):
        if path.endswith('.md'):
            self._load_md(path)
        else:
            self._load_txt(path)

    def _load_md(self, path):
        """Markdown: prose anywhere, waivers in ```json fences.

        Hardened against the one SILENT failure this format has -- a fence that is
        not labelled `json` (or is never closed) would simply be skipped, and the
        waivers inside would vanish while the report just looked worse. Every fence
        is therefore inspected, and anything unexpected is an ERROR, not a skip.
        """
        import json
        with open(path, encoding='utf-8') as fh:
            lines = fh.read().split('\n')
        blocks, lang, start, buf = [], None, 0, []
        for n, ln in enumerate(lines, 1):
            if lang is None:
                m = re.match(r'\s*```(\w*)\s*$', ln)
                if m:
                    lang, start, buf = (m.group(1) or ''), n, []
            elif re.match(r'\s*```\s*$', ln):
                blocks.append((lang, start, buf))
                lang = None
            else:
                buf.append(ln)
        if lang is not None:
            self.errors.append('%s:%d: unterminated ``` fence -- every waiver below '
                               'it would be silently ignored' % (path, start))
            return
        found = 0
        for lang, start, buf in blocks:
            if lang != 'json':
                # Prose may legitimately contain sh/text/verilog blocks. Only complain
                # when a fence LOOKS like waivers in the wrong wrapper -- that is the
                # silent-loss case: the entries would simply never be read.
                head = next((l.strip() for l in buf if l.strip()), '')
                if head[:1] in ('[', '{'):
                    self.errors.append('%s:%d: this fence looks like waiver entries but is '
                                       'labelled %r, not "json" -- it would be skipped '
                                       'silently' % (path, start, lang or '(none)'))
                continue
            try:
                items = json.loads('\n'.join(buf))
            except ValueError as e:
                self.errors.append('%s:%d: fence is not valid JSON: %s' % (path, start, e))
                continue
            if not isinstance(items, list):
                self.errors.append('%s:%d: fence must hold a JSON list' % (path, start))
                continue
            for w in items:
                found += 1
                self._add_dict(w, '%s:%d' % (path, start))
        if not found and not self.errors:
            self.errors.append('%s: no waivers found. If that is intentional, delete the '
                               'file; an empty one usually means a fence broke.' % path)

    def _add_dict(self, w, where):
        """Shared by the md loader: build one Waiver from a dict, or record why not."""
        if not isinstance(w, dict):
            self.errors.append('%s: waiver must be an object' % where); return
        extra = set(w) - self.KEYS
        if extra:
            self.errors.append('%s: unknown key(s) %s -- a typo here would otherwise be '
                               'ignored silently' % (where, ', '.join(sorted(extra)))); return
        fname, at, why = w.get('file'), w.get('at'), w.get('why')
        if not fname or at is None:
            self.errors.append('%s: needs both "file" and "at"' % where); return
        if not why:
            self.errors.append('%s: waiver has no "why"' % where); return
        if PLACEHOLDER in str(why):
            self.errors.append('%s: "why" is still the generated placeholder %s -- replace '
                               'it with the mechanism' % (where, PLACEHOLDER)); return
        line = rx = txt = None
        loc = str(at)
        if loc.startswith('re/') and loc.endswith('/') and len(loc) > 4:
            try:
                rx = re.compile(loc[3:-1])
            except re.error as e:
                self.errors.append('%s: bad regex: %s' % (where, e)); return
        elif loc.startswith('/') and loc.endswith('/') and len(loc) > 2:
            txt = loc[1:-1]
        else:
            try:
                line = int(loc)
            except ValueError:
                self.errors.append('%s: "at" must be a line number, /literal/ or re/regex/'
                                   % where); return
        pages = set()
        types = w.get('type', 'all')
        for t in (types if isinstance(types, list) else str(types).split(',')):
            t = str(t).strip()
            if t == 'all':
                pages |= set(TYPES.values())
            elif t in TYPES:
                pages.add(TYPES[t])
            else:
                self.errors.append('%s: unknown type %r' % (where, t))
        if not pages:
            return
        sig = w.get('sig')
        self.items.append(Waiver(fname, line, rx, txt, pages,
                                 str(sig) if sig is not None else None, str(why), where))

    def _load_txt(self, path):
        for n, raw in enumerate(open(path, encoding='utf-8'), 1):
            body, _, reason = raw.partition('#')
            body, reason = body.strip(), reason.strip()
            if not body:
                continue
            if not reason:
                self.errors.append('%s:%d: waiver has no reason (add "# why")' % (path, n))
                continue
            if PLACEHOLDER in reason:
                self.errors.append('%s:%d: reason is still the generated placeholder %s -- '
                                   'replace it with the mechanism that makes this unreachable'
                                   % (path, n, PLACEHOLDER))
                continue
            # A /regex/ locator may contain spaces and colons, so the line cannot be
            # split on whitespace. Anchor on the delimiters instead: the type field
            # never contains '/', so a greedy /.../ lands on the last slash.
            m = re.match(r'^([^\s:]+):(\d+|re/.+/|/.+/)\s+(\S+)(?:\s+(.*))?$', body)
            if not m:
                self.errors.append('%s:%d: expected "<file>:<line|/regex/> <type> # reason"' % (path, n))
                continue
            fname, loc = m.group(1), m.group(2)
            toks = [m.group(1) + ':' + m.group(2), m.group(3)] + (m.group(4).split() if m.group(4) else [])
            line = rx = txt = None
            if loc.startswith('re/') and loc.endswith('/') and len(loc) > 4:
                try:
                    rx = re.compile(loc[3:-1])
                except re.error as e:
                    self.errors.append('%s:%d: bad regex: %s' % (path, n, e))
                    continue
            elif loc.startswith('/') and loc.endswith('/') and len(loc) > 2:
                # Literal substring, NOT a regex: Verilog source is full of ( ) [ ] * |
                # and silently-mismatching metacharacters is the classic waiver trap.
                txt = loc[1:-1]
            else:
                try:
                    line = int(loc)
                except ValueError:
                    self.errors.append('%s:%d: locator must be a line number or /regex/' % (path, n))
                    continue
            pages = set()
            for t in toks[1].split(','):
                if t == 'all':
                    pages |= set(TYPES.values())
                elif t in TYPES:
                    pages.add(TYPES[t])
                else:
                    self.errors.append('%s:%d: unknown type %r' % (path, n, t))
            if not pages:
                continue
            sig = None
            for t in toks[2:]:
                if t.startswith('sig='):
                    sig = t[4:]
                else:
                    self.errors.append('%s:%d: unknown field %r' % (path, n, t))
            self.items.append(Waiver(fname, line, rx, txt, pages, sig, reason, '%s:%d' % (path, n)))

    def _srcline(self, path, line):
        if path not in self._srccache:
            try:
                with open(path, encoding='utf-8', errors='replace') as fh:
                    self._srccache[path] = fh.read().split('\n')
            except OSError:
                self._srccache[path] = []
        src = self._srccache[path]
        return src[line - 1] if 0 < line <= len(src) else ''

    def match(self, path, line, page, sig):
        """-> the Waiver covering this point, or None."""
        if not self.items:
            return None
        base = os.path.basename(path)
        for w in self.items:
            if w.file != base or page not in w.pages:
                continue
            if w.line is not None:
                if w.line != line:
                    continue
            elif w.txt is not None:
                if w.txt not in self._srcline(path, line):
                    continue
            elif not w.rx.search(self._srcline(path, line)):
                continue
            if w.sig and not fnmatch.fnmatch(sig or '', w.sig):
                continue
            w.hits += 1
            return w
        return None

    def stale(self):
        return [w for w in self.items if w.hits == 0]


def default_path(start):
    """run/waivers_cov.md, falling back to the legacy .txt while both exist."""
    run = os.path.join(os.path.dirname(os.path.abspath(start)), '..', 'run')
    md = os.path.join(run, 'waivers_cov.md')
    return md if os.path.exists(md) else os.path.join(run, 'waivers_cov.txt')


def check_fresh(datdir, rtl_paths):
    """-> warning string if any RTL file is newer than the coverage data.

    Points are keyed by line number, so editing RTL after a run silently misaligns
    every annotation -- and makes correct waivers look stale. Cheap to detect.
    """
    import glob as _glob
    dats = _glob.glob(os.path.join(datdir, '*.dat'))
    if not dats or not rtl_paths:
        return None
    oldest = min(os.path.getmtime(d) for d in dats)
    newer = [p for p in rtl_paths
             if os.path.exists(p) and os.path.getmtime(p) > oldest]
    if not newer:
        return None
    names = ', '.join(sorted(os.path.basename(p) for p in newer)[:4])
    return ("coverage data is OLDER than the RTL (%s%s) -- line numbers no longer "
            "match the source; re-run the sweep" %
            (names, ' …' if len(newer) > 4 else ''))


#=============================================================================
# Authoring helpers -- suggest and lint
#
# These exist because the measured failure modes of hand-written waivers are NOT
# syntax errors. In practice they are:
#   * a sig glob that matches nothing, because fnmatch treats [..] as a
#     CHARACTER class -- "foo[*]" matches a literal asterisk, never a bit;
#   * a line-number anchor that silently drifts when the RTL is edited;
#   * a waiver broader than intended, which swallows COVERED points too and so
#     quietly shrinks the numerator as well as the denominator.
# suggest() removes the first two by generating the entry from the database
# instead of asking a human to type it. lint() reports the third.
#=============================================================================

def _src_anchor(path, line, want=None):
    """A distinctive literal anchor for `line`, or None if it is not unique.

    `want` (a signal name) is included when it occurs on the line, so the anchor
    reads as source rather than as a truncated fragment like 'input  wire  [3'.
    """
    try:
        with open(path, encoding='utf-8', errors='replace') as fh:
            src = fh.read().split('\n')
    except OSError:
        return None
    if not (1 <= line <= len(src)):
        return None
    txt = src[line - 1].split('//')[0].strip()
    if not txt:
        return None
    # Shrink to the shortest leading slice that still occurs exactly once: a long
    # anchor pins internal whitespace and goes stale on reformatting.
    # If the signal appears on this line, anchor through it: that is the part a
    # human recognises, and it is what makes the entry auditable.
    lo = 12
    if want and want in txt:
        lo = max(lo, txt.index(want) + len(want))
    for n in range(lo, len(txt) + 1):
        cand = txt[:n]
        if sum(1 for l in src if cand in l) == 1:
            # Do not cut mid-identifier: extend to the next word boundary so the
            # anchor reads as source rather than as a truncated fragment.
            while n < len(txt) and (txt[n].isalnum() or txt[n] == '_'):
                n += 1
                cand = txt[:n]
            return cand
    return txt if sum(1 for l in src if txt in l) == 1 else None



def _digit_class(digits):
    """['3','4','5','9'] -> '3-59'  (fnmatch character class body, ranges folded)."""
    ds = sorted(set(int(d) for d in digits))
    out, i = [], 0
    while i < len(ds):
        j = i
        while j + 1 < len(ds) and ds[j + 1] == ds[j] + 1:
            j += 1
        if j - i >= 2:
            out.append('%d-%d' % (ds[i], ds[j]))
        else:
            out.extend(str(d) for d in ds[i:j + 1])
        i = j + 1
    return ''.join(out)


def _glob_literal(text):
    """fnmatch-escape a literal name: [ opens a character class, so an array element
    such as tdata1_or[3] must be written tdata1_or[[]3]."""
    return text.replace('[', '[[]')


def _combine_bits(base, want, present):
    """Minimal fnmatch globs matching exactly `want` bit indices of `base`.

    `present` is every bit index that exists for this signal, so the result can be
    CHECKED rather than trusted: a glob that also catches a covered bit is the
    BROAD failure --lint reports, so we verify and fall back to per-bit entries.
    """
    groups = {}
    for b in want:
        t = str(b)
        groups.setdefault(t[:-1], []).append(t[-1])
    globs = []
    for prefix, lasts in sorted(groups.items()):
        lasts = sorted(set(lasts))
        cls = lasts[0] if len(lasts) == 1 else '[%s]' % _digit_class(lasts)
        globs.append('%s[[]%s%s]' % (_glob_literal(base), prefix, cls))
    # Verify: the globs must select `want` exactly, out of everything present.
    hit = set()
    for b in present:
        name = '%s[%d]' % (base, b)
        if any(fnmatch.fnmatch(name, g) for g in globs):
            hit.add(b)
    if hit != set(want):
        return None
    return globs

def records_from_report(points):
    """cov_report.parse() output -> the (page, path, line, sig, count) records
    suggest_entries() wants. cov_report and cov_html each have their own parse
    with different key shapes, so the shared code takes neither: it takes a
    normalised record and each caller adapts."""
    out = []
    for key, (page, path, cnt) in points.items():
        d = dict(f.split('\x02', 1) for f in key.split('\x01') if '\x02' in f)
        out.append((page.split('/')[0], path, int(d.get('l', 0) or 0), d.get('o', ''), cnt))
    return out


def suggest_entries(records, file_hint, line, kind=None):
    """Return (entries, skipped_covered, anchor_is_literal) for file_hint:line.

    entries is a list of dicts ready to serialise. Shared by the CLI and by
    cov_html, so the HTML can never disagree with --suggest: there is one
    implementation of the folding and its verification, and it is this one.

    `points` is {key: (page, path, count)} exactly as cov_report.parse returns.
    """
    # Collapse to the ACCUMULATED view first. parse() returns one entry per
    # elaborated instance, so without this a signal appears once per instance --
    # and with contradictory states, since one instance may cover what another
    # does not. A point is covered if ANY instance covered it.
    acc = {}
    for page, path, ln, sig, cnt in records:
        if not path.endswith('/' + file_hint) and os.path.basename(path) != file_hint:
            continue
        if ln != int(line):
            continue
        if kind and TYPES.get(kind) != page:
            continue
        acc[(page, path, sig)] = max(acc.get((page, path, sig), 0), cnt)
    hits = [(pg, pa, sg, c) for (pg, pa, sg), c in acc.items()]
    if not hits:
        return [], 0, True
    rev = {v: k for k, v in TYPES.items()}
    # A COVERED point must never be waived: it would leave the numerator as well as
    # the denominator, hiding coverage that actually exists. That is exactly what
    # --lint reports as BROAD, so proposing one here would contradict the linter.
    live = [h for h in hits if h[3] == 0]
    skipped = len(hits) - len(live)
    if not live:
        return [], len(hits), True
    anchor = _src_anchor(live[0][1], int(line), live[0][2].split('[')[0])
    at = '/%s/' % anchor if anchor else str(line)
    # Fold bit-sliced signals into as few globs as possible. Combining is only
    # emitted when _combine_bits has VERIFIED it selects the uncovered bits and
    # nothing else -- otherwise one entry per bit, which is always safe.
    # The base is everything before the LAST index, so an array element a[3][5] folds
    # over the bits of a[3], exactly like a vector.
    bybase = {}
    for page, path, sig, cnt in hits:
        m = re.match(r'^(.*)\[\d+\]$', sig)
        bybase.setdefault((page, path, m.group(1) if m else sig), []).append((sig, cnt))
    out = []
    for (page, path, base), members in sorted(bybase.items()):
        want, present, plain = [], [], []
        for sig, cnt in members:
            m = re.match(re.escape(base) + r'\[(\d+)\]$', sig)
            if m:
                present.append(int(m.group(1)))
                if cnt == 0:
                    want.append(int(m.group(1)))
            elif cnt == 0:
                plain.append(sig)
        for sig in sorted(plain):                       # if / else and friends
            out.append({'file': os.path.basename(path), 'at': at,
                        'type': rev.get(page, page), 'sig': _glob_literal(sig),
                        'why': 'unreachable: %s ' % PLACEHOLDER})
        if not want:
            continue
        globs = _combine_bits(base, sorted(want), sorted(present))
        if globs is None:                               # could not fold safely
            globs = ['%s[[]%d]' % (_glob_literal(base), b) for b in sorted(want)]
        for g in globs:
            out.append({'file': os.path.basename(path), 'at': at,
                        'type': rev.get(page, page), 'sig': g,
                        'why': 'unreachable: %s ' % PLACEHOLDER,
                        '_folded': (len(want), len(globs))})
    return out, skipped, bool(anchor)


def suggest(points, file_hint, line, kind=None):
    """CLI wrapper: print what suggest_entries() produced."""
    import json as _json
    entries, skipped, literal = suggest_entries(records_from_report(points),
                                                file_hint, line, kind)
    if entries is None:
        return 1
    if not entries:
        if skipped:
            print('# every point at %s:%s is already COVERED -- nothing to waive here.'
                  % (file_hint, line))
        else:
            print('no coverage point at %s:%s' % (file_hint, line))
        return 1
    if not literal:
        print('# NOTE: no unique text on that line -- falling back to a line number,')
        print('#       which will go stale if the file is edited above this point.')
    for e in entries:
        fold = e.pop('_folded', None)
        print(_json.dumps(e, separators=(',', ':')))
        if fold and fold[1] < fold[0]:
            print('#   ^ %d bit(s) folded into %d glob(s); verified to match those bits only'
                  % fold)
    if skipped:
        print('# %d point(s) at this location are already COVERED and were skipped.'
              % skipped)
        print('# Do NOT widen the sig glob to swallow them -- --lint would call that BROAD.')
    return 0


def lint(waivers, points):
    """Report waivers that match nothing, or that swallow covered points.

    Counts are ACCUMULATED, i.e. one per source point with the max count across
    elaborated instances -- the same view cov_report prints. Counting per instance
    instead reports a 32-bit word in a 3-instance module as 96 points, which does
    not reconcile with anything else on screen.
    """
    acc = {}
    for key, (page, path, cnt) in points.items():
        d = dict(f.split('\x02', 1) for f in key.split('\x01') if '\x02' in f)
        k = (path, int(d.get('l', 0) or 0), page, d.get('o', ''))
        acc[k] = max(acc.get(k, 0), cnt)
    bad = 0
    for w in waivers.items:
        # Match per waiver explicitly: Waivers.match() is any-of across the whole
        # set, which cannot attribute a hit to the entry that caused it.
        matched = covered = 0
        for (path, ln, page, sig), cnt in acc.items():
            d = {'l': str(ln), 'o': sig}
            if w.file != os.path.basename(path):
                continue
            if page not in w.pages:
                continue
            if w.line is not None and w.line != ln:
                continue
            if w.txt is not None and w.txt not in waivers._srcline(path, ln):
                continue
            if w.rx is not None and not w.rx.search(waivers._srcline(path, ln)):
                continue
            if w.sig and not fnmatch.fnmatch(sig, w.sig):
                continue
            matched += 1
            if cnt:
                covered += 1
        if matched == 0:
            print('STALE   %-52s matches nothing' % str(w)); bad += 1
        elif covered:
            print('BROAD   %-52s matches %d point(s), %d ALREADY COVERED'
                  % (str(w), matched, covered)); bad += 1
        else:
            print('ok      %-52s matches %d uncovered point(s)' % (str(w), matched))
    return bad
