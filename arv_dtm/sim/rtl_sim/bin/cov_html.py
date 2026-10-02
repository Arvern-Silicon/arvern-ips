#!/usr/bin/env python3
"""Render Verilator coverage databases as a self-contained HTML report.

Reads the same *.dat files as cov_report.py and writes one HTML file with the
RTL sources annotated. Line, branch and toggle are kept separate -- a point is
covered if any test hit it.

Toggle points carry the signal name, so an uncovered toggle names the signal
that never changed rather than just the line.

  cov_html.py <dats-dir> [-o coverage.html]
"""
import sys
import os
import glob
import json
import shutil
import subprocess
import tempfile
import collections
import cov_waive

PAGES = ('v_line', 'v_branch', 'v_toggle')


def parse(datdir, rtl_pats=('/rtl/verilog/',)):
    """{(file, line, page, signal, hier, num): max_count} merged across every database.

    Keyed per instance, the same identity cov_report.py uses, so both tools report
    the same totals. A line's badge is therefore hit/total across all instances.
    """
    pts = {}
    for fn in glob.glob(os.path.join(datdir, '*.dat')):
        test = os.path.basename(fn)[4:-4] if os.path.basename(fn).startswith('cov_') \
               else os.path.basename(fn)[:-4]
        with open(fn, encoding='utf-8', errors='replace') as fh:
            for ln in fh:
                if not ln.startswith("C '"):
                    continue
                key, _, cnt = ln[3:].rpartition("' ")
                try:
                    c = int(cnt.strip())
                except ValueError:
                    continue
                d = {}
                for fld in key.split('\x01'):
                    if '\x02' in fld:
                        k, v = fld.split('\x02', 1)
                        d[k] = v
                path = d.get('f', '')
                if not any(pat in path for pat in rtl_pats):
                    continue
                # The page suffix names the parameterised module variant
                # (arv_ipdff__W7_Az2 vs __W20_Az2) and `h` is truncated in the
                # database, so the suffix is what separates instances.
                page_full = d.get('page', '')
                page = page_full.split('/')[0]
                if page not in PAGES:
                    continue
                k = (path, int(d.get('l', 0)), page, d.get('o', ''),
                     d.get('h', ''), d.get('n', ''), page_full)
                e = pts.get(k)
                if e is None:
                    e = pts[k] = [0, set()]
                e[0] = max(e[0], c)
                if c > 0:
                    e[1].add(test)
    return pts


def build(pts, reasons=None):
    """-> (files_payload, totals) with two views per file.

    'acc'  accumulated: one point per SOURCE location, covered if any instance or
           configuration hit it. This is the "did the regression reach this code"
           question and is the default.
    'inst' per-instance: every elaborated copy counted separately, so a line hit in
           the UART build but not the I2C one shows as partial. Finds config gaps,
           but on a design with many instances of a primitive it is mostly noise.
    """
    reasons = reasons or {}
    views = {'acc': {}, 'inst': {}}
    for key, (cnt, tests) in pts.items():
        path, line, page, sig, hier, num, variant = key
        r = reasons.get(key)
        views['inst'][key] = (cnt, tests, r)
        k = (path, line, page, sig, num)
        prev = views['acc'].get(k)
        # Collapsed point is waived only if every instance behind it was.
        views['acc'][k] = (max(prev[0], cnt), prev[1] | tests, prev[2] and r) if prev \
                          else (cnt, set(tests), r)

    src_cache, files, totals = {}, {}, {}
    for view, vpts in views.items():
        per_file = collections.defaultdict(
            lambda: {p: collections.defaultdict(list) for p in PAGES})
        for k, (cnt, tests, r) in vpts.items():
            path, line, page, sig = k[0], k[1], k[2], k[3]
            per_file[path][page][line].append((sig, cnt, tests, r))

        totals[view] = {p: [0, 0] for p in PAGES}
        for path, pages in sorted(per_file.items()):
            name = os.path.basename(path)
            if name not in src_cache:
                try:
                    with open(path, encoding='utf-8', errors='replace') as fh:
                        src_cache[name] = fh.read().split('\n')
                except OSError:
                    src_cache[name] = ['(source not readable: %s)' % path]
            entry = files.setdefault(name, {'path': path, 'src': src_cache[name], 'v': {}})
            pv = entry['v'].setdefault(view, {})
            for page in PAGES:
                lines, hit, found, nwaived = {}, 0, 0, 0
                for line, items in pages[page].items():
                    live = [it for it in items if not it[3]]
                    wvd  = [it for it in items if it[3]]
                    h = sum(1 for _, c, _t, _r in live if c > 0)
                    detail = []
                    for sg, c, ts, _r in sorted(live, key=lambda x: (x[0], -x[1]))[:40]:
                        e = {'k': sg, 'c': c, 'n': len(ts)}
                        # Name the tests only when few hit it -- that is the thin-margin
                        # case worth knowing; for widely-hit points the count is enough.
                        if 0 < len(ts) <= 6:
                            e['t'] = sorted(ts)
                        detail.append(e)
                    lines[str(line)] = {
                        'hit': h, 'tot': len(live),
                        'miss': sorted({sg for sg, c, _t, _r in live if c == 0 and sg})[:24],
                        'd': detail,
                        'w': [{'k': sg, 'c': c, 'r': r}
                              for sg, c, _t, r in sorted(wvd, key=lambda x: x[0])[:12]],
                    }
                    hit += h
                    found += len(live)
                    nwaived += len(wvd)
                pv[page] = {'lines': lines, 'hit': hit, 'found': found, 'wv': nwaived}
                totals[view][page][0] += hit
                totals[view][page][1] += found
    return files, totals


# Raw string: every backslash here belongs to the JavaScript, not to Python.
# Without the r-prefix "\n" becomes a real newline, which is legal inside a JS
# template literal but a syntax error inside a normal "..." string.
TEMPLATE = r"""<!DOCTYPE html>
<meta charset="utf-8">
<title>arv_dtm coverage</title>
<style>
 :root { --hit:#1f6f3f; --miss:#8c1c1c; --part:#8a6d1f; --bg:#ffffff; --fg:#1b1b1b; --dim:#7a7a7a;
         --bgmiss:#ffd4d4; --bgpart:#ffeec2; --sig:#7a1010;
         --bgwaive:#e6e6e6; --waive:#5c5c5c; }
 @media (prefers-color-scheme: dark) {
   :root { --hit:#7fd6a0; --miss:#ff8b8b; --part:#e8c56a; --bg:#161616; --fg:#e6e6e6; --dim:#9a9a9a;
           --bgmiss:#4d1c1c; --bgpart:#463714; --sig:#ffb3b3;
           --bgwaive:#2b2b2b; --waive:#9d9d9d; }
 }
 * { box-sizing:border-box; }
 body { margin:0; font:13px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
        background:var(--bg); color:var(--fg); display:flex; height:100vh; }
 #side { width:340px; flex:none; overflow:auto; border-right:1px solid #8883; padding:10px; }
 #main { flex:1; overflow:auto; padding:10px 14px; }
 h1 { font-size:14px; margin:0 0 8px; }
 .metrics { display:flex; gap:4px; margin-bottom:10px; flex-wrap:wrap; }
 .metrics button { font:inherit; padding:4px 9px; cursor:pointer; border:1px solid #8886;
                   background:transparent; color:inherit; border-radius:4px; }
 .metrics button.on { background:#8883; font-weight:700; }
 .f { padding:3px 5px; cursor:pointer; border-radius:3px; display:flex;
      justify-content:space-between; gap:8px; white-space:nowrap; }
 .f:hover { background:#8882; }
 .f.on { background:#8884; font-weight:700; }
 .pct { color:var(--dim); flex:none; }
 .cnt { opacity:.7; margin-right:6px; font-variant-numeric:tabular-nums; }
 .wvn { color:var(--waive); margin-right:6px; font-variant-numeric:tabular-nums; }
 .fname { overflow:hidden; text-overflow:ellipsis; }
 .bad .pct { color:var(--miss); }
 table { border-collapse:collapse; width:100%; }
 td { vertical-align:top; padding:0 6px; white-space:pre-wrap; word-break:break-word; }
 td.n { text-align:right; color:var(--dim); user-select:none; width:1%; white-space:nowrap; }
 td.c { text-align:right; width:1%; white-space:nowrap; font-size:11px; }
 tr.hit  td.c { color:var(--hit); }
 tr.part td.c { color:var(--part); font-weight:700; }
 tr.miss td.c { color:var(--miss); font-weight:700; }
 /* Band the whole row -- applied to td, which is reliable under border-collapse. */
 tr.miss td { background:var(--bgmiss); }
 tr.waived td { background:var(--bgwaive); }
 /* Line has live points AND waived ones: keep its coverage colour but mark it. */
 tr.haswv td.n { border-left:3px solid var(--waive); padding-left:3px; }
 .wmark { color:var(--waive); margin-left:4px; }
 tr.waived td.c, tr.waived td.n { color:var(--waive); }
 tr.part td { background:var(--bgpart); }
 tr.miss td.n, tr.part td.n { color:var(--fg); opacity:.75; }
 .sig { color:var(--sig); font-size:11px; font-weight:700; }
 #sum { color:var(--dim); margin-bottom:4px; overflow:hidden; text-overflow:ellipsis;
        white-space:nowrap; }
 #hdr { position:sticky; top:0; z-index:5; background:var(--bg);
        margin:-10px -14px 0; padding:10px 14px 6px; border-bottom:1px solid #8883; }
 #nav { display:flex; align-items:center; gap:6px; font-size:12px; }
 #nav button { font:inherit; padding:2px 9px; cursor:pointer; border:1px solid #8886;
               background:transparent; color:inherit; border-radius:4px; line-height:1.3; }
 #nav button:disabled { opacity:.35; cursor:default; }
 #nav .cnt2 { color:var(--dim); font-variant-numeric:tabular-nums; }
 tr.flash td { animation: fl 1.1s ease-out; }
 @keyframes fl { from { box-shadow: inset 0 0 0 2px var(--fg); } to { box-shadow: none; } }
 #tip { position:fixed; z-index:9; max-width:520px; padding:7px 10px; border-radius:5px;
        background:var(--bg); color:var(--fg); border:1px solid #8887;
        box-shadow:0 4px 14px #0006; font-size:12px; display:none;
        white-space:pre-wrap; overflow-wrap:anywhere; }
 #tip b { color:var(--miss); }
 #sug { display:none; position:fixed; right:14px; bottom:14px; z-index:11; max-width:min(46rem,92vw);
        background:var(--bg); color:var(--fg); border:1px solid #8886; border-radius:6px;
        box-shadow:0 6px 20px #0007; font-size:12px; }
 #sughdr { display:flex; align-items:center; gap:8px; padding:6px 9px; border-bottom:1px solid #8884; }
 #sughdr b { flex:0 0 auto; }
 #sugnote { flex:1 1 auto; color:var(--dim); }
 #sug pre { margin:0; padding:9px; overflow-x:auto; white-space:pre; font-size:11px; }
 #sugwarn { padding:0 9px 8px; color:var(--part); }
 #sug button { font:inherit; padding:1px 8px; cursor:pointer; border:1px solid #8886;
               border-radius:4px; background:transparent; color:inherit; }
 #tip u { color:var(--waive); text-decoration:none; }
 #tip i { color:var(--hit); font-style:normal; }
 tr.miss, tr.part, tr.hit { cursor:default; }
 #viewsel { display:block; margin:-4px 0 10px; color:var(--dim); cursor:pointer; font-size:12px; }
</style>
<div id="side">
  <h1>Coverage</h1>
  <div class="metrics" id="metrics"></div>
  <label id="viewsel"><input type="checkbox" id="perinst"> per-instance</label>
  <div id="files"></div>
</div>
<div id="main"><div id="hdr"><div id="sum"></div>
  <div id="nav"><button id="prevh" title="previous hole (p)">▲</button><button id="nexth" title="next hole (n)">▼</button><span class="cnt2" id="holecnt"></span><label class="cnt2" id="wvlab" title="also step through waived points"><input type="checkbox" id="wvnav"> waived</label><button id="wvsug" title="just the waiver entries" disabled>waiver</button><button id="wvsec" title="a whole Markdown section: heading, rationale scaffold and the fenced entries" disabled>+ section</button></div></div>
<div id="sug"><div id="sughdr"><b>Suggested waiver</b> <span id="sugnote"></span><button id="sugcopy">copy</button><button id="sugclose">close</button></div><pre id="sugtext"></pre><div id="sugwarn"></div></div>
<div id="src"></div></div>
<div id="tip"></div>
<script>
const DATA = __DATA__, TOTALS = __TOTALS__, SUGGEST = __SUGGEST__;
const PAGES = ["v_line","v_branch","v_toggle"], LABEL = {v_line:"Line",v_branch:"Branch",v_toggle:"Toggle"};
let page = "v_line", file = null, view = "acc";

const pct = (h,t) => t ? (100*h/t) : null;

function drawMetrics() {
  document.getElementById("metrics").innerHTML = PAGES.map(p => {
    const [h,t] = TOTALS[view][p], v = pct(h,t);
    return `<button data-p="${p}" class="${p===page?'on':''}">${LABEL[p]} ${v===null?'-':v.toFixed(1)+'%'}</button>`;
  }).join("");
  document.querySelectorAll("#metrics button").forEach(b =>
    b.onclick = () => { page = b.dataset.p; drawMetrics(); drawFiles(); drawSrc(); });
}

function drawFiles() {
  const rows = Object.keys(DATA).map(n => {
    const g = DATA[n].v[view][page];
    return {n, v: pct(g.hit, g.found), hit:g.hit, found:g.found, wv:g.wv||0};
  });
  // worst first: that is where the holes are
  rows.sort((a,b) => (a.v===null)-(b.v===null) || a.v-b.v || a.n.localeCompare(b.n));
  if (!file || !DATA[file]) file = rows.length ? rows[0].n : null;
  document.getElementById("files").innerHTML = rows.map(r =>
    `<div class="f ${r.n===file?'on':''} ${r.v!==null&&r.v<100?'bad':''}" data-f="${r.n}">
       <span class="fname">${r.n}</span><span class="pct">` +
       `<span class="cnt">${r.found?r.hit+'/'+r.found:'-'}</span>` +
       `<span class="wvn">${r.wv?'⊘'+r.wv:''}</span>` +
       `${r.v===null?'-':r.v.toFixed(0)+'%'}</span></div>`).join("");
  document.querySelectorAll(".f").forEach(d =>
    d.onclick = () => { file = d.dataset.f; drawFiles(); drawSrc(); });
}

function drawSrc() {
  if (!file) return;
  const f = DATA[file], g = f.v[view][page];
  document.getElementById("sum").textContent =
    `${f.path}  —  ${LABEL[page]} ${g.hit}/${g.found}` +
    (g.found ? ` (${pct(g.hit,g.found).toFixed(1)}%)` : " (no points)") +
    (g.wv ? `   ⊘ ${g.wv} waived, excluded from the total` : "");
  const out = [];
  f.src.forEach((text, i) => {
    const d = g.lines[String(i+1)];
    let cls = "", note = "", sigs = "";
    if (d) {
      const nw = (d.w || []).length;
      if (d.tot === 0) {                      // every point on this line is waived
        cls = "waived"; note = "waived";
      } else {
        cls = d.hit === 0 ? "miss" : (d.hit < d.tot ? "part" : "hit");
        // Mixed line: without this it renders as plain covered and the waiver is
        // invisible in the source pane even though the header counts it.
        if (nw) cls += " haswv";
        note = `${d.hit}/${d.tot}` + (nw ? `<span class="wmark">⊘${nw}</span>` : "");
      }
      if (d.miss.length) sigs = `\n      <span class="sig">✗ ${d.miss.map(esc).join(", ")}</span>`;
    }
    const tip = d ? esc(tipText(i+1, d)) : "";
    out.push(`<tr class="${cls}" data-tip="${tip}"><td class="n">${i+1}</td><td class="c">${note}</td>` +
             `<td class="s">${esc(text)}${sigs}</td></tr>`);
  });
  document.getElementById("src").innerHTML = "<table>" + out.join("") + "</table>";
  document.getElementById("main").scrollTop = 0;
  collectHoles();
}
// A "hole" is an actionable row: fully uncovered or partially covered. Waived rows are
// deliberate and are skipped by default -- the "waived" box adds them back, so a reviewer
// can walk the waivers and check each justification against the code it sits on.
let holes = [], holeIdx = -1;

function withWaived() { return document.getElementById("wvnav").checked; }

function collectHoles() {
  holes = Array.from(document.querySelectorAll(
    withWaived() ? "#src tr.miss, #src tr.part, #src tr.waived, #src tr.haswv"
                 : "#src tr.miss, #src tr.part"));
  holeIdx = -1;
  updateHoleUI();
}

function updateHoleUI() {
  const n = holes.length;
  const w = withWaived() ? "point" : "hole";
  document.getElementById("holecnt").textContent =
    n ? (holeIdx >= 0 ? `${w} ${holeIdx + 1} / ${n}` : `${n} ${w}${n === 1 ? "" : "s"}`)
      : `no ${w}s`;
  document.getElementById("prevh").disabled = !n;
  document.getElementById("nexth").disabled = !n;
}

function gotoHole(delta) {
  if (!holes.length) return;
  holeIdx = (holeIdx + delta + holes.length) % holes.length;   // wraps both ways
  const row = holes[holeIdx];
  row.scrollIntoView({ block: "center", behavior: "smooth" });
  document.querySelectorAll("#src tr.flash").forEach(r => r.classList.remove("flash"));
  void row.offsetWidth;                       // restart the animation
  row.classList.add("flash");
  updateHoleUI();
  const noHole = !curHoleKey();
  document.getElementById("wvsug").disabled = noHole;
  document.getElementById("wvsec").disabled = noHole;
  if (document.getElementById("sug").style.display === "block") showSuggestion(sugMode);
}

// ---- suggested waiver for the current hole ---------------------------------
// SUGGEST was computed in Python by the same suggest_entries() the CLI uses, so
// what is shown here is exactly what `--suggest` would print. Nothing is matched
// or folded in the browser: a second implementation could disagree, and a
// suggestion that does not match is precisely the failure being designed out.
function curHoleKey() {
  if (holeIdx < 0 || !holes.length) return null;
  const row = holes[holeIdx];
  const ln  = row.querySelector("td.n");
  if (!ln || !file) return null;
  return file + ":" + parseInt(ln.textContent, 10);
}

// Build the fenced JSON block: a real JSON array, so it parses as-is. The bare
// objects the CLI prints do not -- they lack the brackets and commas.
function fenceFor(s) {
  return "```json\n[\n" +
         s.entries.map(e => JSON.stringify(e)).join(",\n") +
         "\n]\n```";
}

// A whole Markdown section, ready to paste: heading, a prompt for the argument,
// the caveats as HTML comments (visible while editing, invisible when rendered),
// then the entries. The prose is the part no tool can check, so the scaffold asks
// for the one thing that makes a waiver reviewable -- the mechanism.
function sectionFor(key, s) {
  const notes = [];
  if (s.skipped)
    notes.push(s.skipped + " point(s) at this location are already COVERED and were left out.\n     Do NOT widen the glob to include them -- --lint would call that BROAD.");
  if (!s.literal)
    notes.push("No unique text on this line, so the anchor is a LINE NUMBER.\n     It will drift if the file is edited above this point.");
  return "## <SHORT TITLE: what makes this unreachable>\n\n" +
         "<!-- " + key + " -->\n\n" +
         "<Explain the MECHANISM. Name the signal, line or parameter that makes this\n" +
         "impossible, so a reviewer can re-check the argument without re-deriving it.\n" +
         "\"no test covers it\" is a GAP, not a waiver.>\n\n" +
         (notes.length ? "<!-- " + notes.join("\n\n     ") + " -->\n\n" : "") +
         fenceFor(s) + "\n";
}

function showSuggestion(asSection) {
  const key = curHoleKey();
  const s = key && SUGGEST[key];
  const box = document.getElementById("sug");
  if (!s) {
    document.getElementById("sugtext").textContent =
      "No suggestion for this line.\n\nEither every point here is already covered or waived,\nor the hole is a partial line whose uncovered points sit elsewhere.";
    document.getElementById("sugnote").textContent = key || "";
    document.getElementById("sugwarn").textContent = "";
  } else {
    document.getElementById("sugtext").textContent =
      asSection ? sectionFor(key, s) : fenceFor(s);
    document.getElementById("sugnote").textContent =
      key + (asSection ? "  \u2014 full Markdown section" : "  \u2014 fenced entries");
    let w = [];
    if (s.skipped) w.push(s.skipped + " point(s) here are already COVERED and were left out \u2014 do not widen the glob to include them.");
    if (!s.literal) w.push("No unique text on this line, so the anchor is a LINE NUMBER and will drift if the file is edited above it.");
    w.push("Replace <MECHANISM> with the reason this is unreachable \u2014 the loader rejects the placeholder.");
    document.getElementById("sugwarn").textContent = w.join("  ");
  }
  box.style.display = "block";
}

let sugMode = false;
document.getElementById("wvsug").onclick = () => { sugMode = false; showSuggestion(false); };
document.getElementById("wvsec").onclick = () => { sugMode = true;  showSuggestion(true);  };
document.getElementById("sugclose").onclick = () => document.getElementById("sug").style.display = "none";
document.getElementById("sugcopy").onclick  = () => {
  const t = document.getElementById("sugtext").textContent;
  navigator.clipboard.writeText(t).then(
    () => { const b = document.getElementById("sugcopy"); b.textContent = "copied"; setTimeout(() => b.textContent = "copy", 1200); },
    () => { const b = document.getElementById("sugcopy"); b.textContent = "select+copy"; }
  );
};

document.getElementById("wvnav").onchange = () => collectHoles();
document.getElementById("nexth").onclick = () => gotoHole(1);
document.getElementById("prevh").onclick = () => gotoHole(-1);
document.addEventListener("keydown", ev => {
  if (ev.target.tagName === "INPUT" || ev.metaKey || ev.ctrlKey || ev.altKey) return;
  if (ev.key === "n" || ev.key === "N") { gotoHole(1);  ev.preventDefault(); }
  if (ev.key === "p" || ev.key === "P") { gotoHole(-1); ev.preventDefault(); }
});

function esc(s){ return s.replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])); }

// Branch points come in true/false pairs. Verilator records the false direction even
// when no `else` is written -- there it is the implicit fall-through -- so "else never
// taken" really means "the condition never evaluated false". Say that outright.
const BR = {"if": "true path", "else": "false path"};

function tipText(lineNo, d) {
  const L = [`line ${lineNo} — ${LABEL[page]} ` +
             (d.tot === 0 ? "waived" : `${d.hit}/${d.tot}`) +
             (view === "inst" ? "  (per-instance)" : "")];

  if (page === "v_branch") {
    const sum = {};
    (d.d || []).forEach(e => { sum[e.k] = (sum[e.k] || 0) + e.c; });
    if ("if" in sum && "else" in sum) {
      if (sum["else"] === 0 && sum["if"] > 0)
        L.push("  → condition was ALWAYS TRUE (never once false)");
      else if (sum["if"] === 0 && sum["else"] > 0)
        L.push("  → condition was ALWAYS FALSE (never once true)");
    }
  }

  (d.d || []).forEach(e => {
    const name = (page === "v_branch" && BR[e.k]) ? BR[e.k] : (e.k || "(point)");
    if (e.c > 0) {
      L.push(`  ✓ ${name}  ${e.n} test${e.n===1?"":"s"}, up to ${e.c} exec in one` +
             (e.t ? `\n       ${e.t.join("\n       ")}` : ""));
    } else {
      L.push(`  ✗ ${name}  never taken`);
    }
  });
  (d.w || []).forEach(e => {
    L.push(`  ⊘ ${e.k || "(point)"}  WAIVED${e.c ? "" : " (was never reached)"}`);
    L.push(`       ${e.r}`);
  });
  if ((d.d||[]).length === 40) L.push("  … (truncated)");
  return L.join("\n");
}

const tipEl = document.getElementById("tip");
document.getElementById("src").addEventListener("mousemove", ev => {
  const tr = ev.target.closest("tr[data-tip]");
  if (!tr || !tr.dataset.tip) { tipEl.style.display = "none"; return; }
  tipEl.textContent = tr.dataset.tip;
  tipEl.style.display = "block";
  const w = tipEl.offsetWidth, h = tipEl.offsetHeight;
  let x = ev.clientX + 16, y = ev.clientY + 14;
  if (x + w > innerWidth  - 8) x = ev.clientX - w - 16;
  if (y + h > innerHeight - 8) y = Math.max(8, ev.clientY - h - 14);
  tipEl.style.left = x + "px"; tipEl.style.top = y + "px";
});
document.getElementById("src").addEventListener("mouseleave", () => tipEl.style.display = "none");
document.getElementById("perinst").onchange = e => {
  view = e.target.checked ? "inst" : "acc";
  drawMetrics(); drawFiles(); drawSrc();
};
drawMetrics(); drawFiles(); drawSrc();
</script>
"""


def main(argv, rtl_pats=('/rtl/verilog/',)):
    datdir = argv[1] if len(argv) > 1 else 'dats'
    out = 'coverage.html'
    if '-o' in argv:
        out = argv[argv.index('-o') + 1]

    wv = cov_waive.Waivers(cov_waive.default_path(__file__))
    for e in wv.errors:
        print("  WAIVER ERROR: %s" % e)
    if wv.errors:
        return 1

    pts = parse(datdir, rtl_pats)
    if not pts:
        print("ERROR: no rtl/verilog coverage points found in %s" % datdir)
        return 1
    # Waived points stay in the payload so they can be shown greyed with their reason;
    # build() keeps them out of hit/found so waiving cannot improve the score.
    nw = 0
    nw_src = set()
    reasons = {}
    for k in pts:
        path, line, page, sig = k[0], k[1], k[2], k[3]
        w = wv.match(path, line, page, sig)
        if w:
            nw += 1
            nw_src.add((path, line, page, sig))
            reasons[k] = w.reason

    warn = cov_waive.check_fresh(datdir, {k[0] for k in pts})
    if warn:
        print("  WARNING: %s" % warn)

    files, totals = build(pts, reasons)

    # Pre-compute a ready-to-paste waiver for every hole, using the SAME
    # suggest_entries() the CLI uses. Doing it here rather than in JavaScript is
    # deliberate: a second implementation of the fnmatch fold in the browser could
    # disagree with Python, and a suggestion that does not actually match is the
    # exact failure this tooling exists to prevent.
    # cov_html's parse() keys points as (path, line, page, sig, ...) -> (cnt, tests),
    # so adapt to the normalised record shape suggest_entries() takes.
    recs, holes = [], set()
    for k, v in pts.items():
        path, line, page, sig = k[0], k[1], k[2], k[3]
        cnt = v[0]
        recs.append((page, path, line, sig, cnt))
        if cnt or not line or wv.match(path, line, page, sig):
            continue
        holes.add((os.path.basename(path), line))
    suggest = {}
    for fname, line in sorted(holes):
        try:
            entries, skipped, literal = cov_waive.suggest_entries(recs, fname, line)
        except Exception:
            continue
        if not entries:
            continue
        for e in entries:
            e.pop('_folded', None)
        suggest['%s:%d' % (fname, line)] = {
            'entries': entries, 'skipped': skipped, 'literal': literal}

    doc = TEMPLATE.replace('__DATA__', json.dumps(files)) \
                  .replace('__TOTALS__', json.dumps(totals)) \
                  .replace('__SUGGEST__', json.dumps(suggest))
    with open(out, 'w', encoding='utf-8') as fh:
        fh.write(doc)

    # The page is inert if its script fails to parse, and that failure is silent in a
    # browser -- validate here when a JS engine is available.
    if shutil.which('node'):
        js = doc[doc.index('<script>') + 8: doc.rindex('</script>')]
        with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False) as fh:
            fh.write(js)
            tmp = fh.name
        r = subprocess.run(['node', '--check', tmp], capture_output=True, text=True)
        os.unlink(tmp)
        if r.returncode != 0:
            print("  ERROR: generated JavaScript does not parse:")
            print("    " + r.stderr.strip().splitlines()[0] if r.stderr.strip() else "")
            return 1

    print("  wrote %s  (%d files, %.1f KB)" % (out, len(files), os.path.getsize(out) / 1024.0))
    if nw:
        print("    %-13s %d points excluded (%d source locations)" % ('waived', nw, len(nw_src)))
    for w in wv.stale():
        print("    STALE WAIVER: %s matched nothing (%s)" % (w, w.src))
    for view, label in (('acc', 'accumulated'), ('inst', 'per-instance')):
        parts = []
        for p in PAGES:
            h, t = totals[view][p]
            parts.append("%s %d/%d %.1f%%" % (p.replace('v_', ''), h, t, 100.0 * h / t if t else 0))
        print("    %-13s %s" % (label, "   ".join(parts)))
    return 0


if __name__ == '__main__':
    # --rtl PAT restricts the report to source paths containing PAT (repeatable),
    # e.g. the DUT's own tree so separately-verified IPs stay out of the file list.
    pats = [sys.argv[i + 1] for i, a in enumerate(sys.argv) if a == '--rtl']
    argv = [a for a in sys.argv if a != '--rtl' and a not in pats]
    sys.exit(main(argv, tuple(pats) if pats else ('/rtl/verilog/',)))
