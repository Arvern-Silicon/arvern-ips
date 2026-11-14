#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Script:    figures.py (apb_usb_host)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Generate the documentation figures as draw.io diagrams: the block diagram
# and the port state diagram. Each is exported by the draw.io desktop CLI to
# <name>.drawio.svg next to this script, with the diagram embedded (the SVG
# opens for editing in draw.io). The waveforms are WaveDrom sources,
# wave_<name>.json, rendered with wavedrom-cli:
#
#   python3 figures.py            # regenerate every <name>.drawio.svg
#   python3 figures.py --drawio   # write the <name>.drawio sources only
#   DRAWIO=/path/to/drawio        # CLI location (default: the macOS app)
#   for f in wave_*.json; do npx wavedrom-cli -i $f -s ${f%.json}.svg; done
#----------------------------------------------------------------------------
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DRAWIO = os.environ.get('DRAWIO', '/Applications/draw.io.app/Contents/MacOS/draw.io')
NO_EXPORT = '--drawio' in sys.argv

INK    = '#1f2328'
GRID   = '#8c959f'
MUTED  = '#57606a'
ACCENT = '#cf222e'
BLUE   = '#0969da'
FILL   = '#ddf4ff'
FILL2  = '#f0f9ff'
SHADE  = '#f6f8fa'
YELLOW = '#fff8c5'
ROSE   = '#ffebe9'
GREEN  = '#dafbe1'
FONT   = 'fontFamily=Helvetica;'
MONO   = 'fontFamily=Menlo;'


def esc(s):
    return (str(s).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
            .replace('"', '&quot;'))


class Drawing:
    """mxGraph cells: boxes, free text, lines, connectors between boxes."""

    def __init__(self):
        self.cells = []
        self.n = 0

    def _id(self, i=None):
        if i:
            return i
        self.n += 1
        return 'c%d' % self.n

    def box(self, x, y, w, h, label='', fill='#ffffff', stroke=INK, size=11, style='', i=None,
            parent='1', rounded=True, bold=False):
        st = ('rounded=%d;arcSize=10;whiteSpace=wrap;html=1;fillColor=%s;strokeColor=%s;fontSize=%s;'
              % (1 if rounded else 0, fill, stroke, size)) + FONT + style
        if bold:
            st += 'fontStyle=1;'
        i = self._id(i)
        self.cells.append('<mxCell id="%s" value="%s" style="%s" vertex="1" parent="%s">'
                          '<mxGeometry x="%g" y="%g" width="%g" height="%g" as="geometry"/></mxCell>'
                          % (i, esc(label), st, parent, x, y, w, h))
        return i

    def text(self, x, y, s, size=11, align='center', color=INK, bold=False, w=None, h=18, mono=False,
             parent='1'):
        w = w if w is not None else max(20, len(str(s)) * size * 0.62)
        if align == 'center':
            x0 = x - w / 2
        elif align == 'right':
            x0 = x - w
        else:
            x0 = x
        st = ('text;html=1;whiteSpace=wrap;align=%s;verticalAlign=middle;fontSize=%s;fontColor=%s;'
              % (align, size, color)) + (MONO if mono else FONT) + ('fontStyle=1;' if bold else '')
        i = self._id()
        self.cells.append('<mxCell id="%s" value="%s" style="%s" vertex="1" parent="%s">'
                          '<mxGeometry x="%g" y="%g" width="%g" height="%g" as="geometry"/></mxCell>'
                          % (i, esc(s), st, parent, x0, y - h / 2, w, h))
        return i

    def line(self, pts, color=INK, width=1.0, arrow=True, dashed=False, opacity=100, start_arrow=False):
        st = ('endArrow=%s;endFill=1;endSize=5;html=1;strokeColor=%s;strokeWidth=%s;opacity=%d;'
              % ('block' if arrow else 'none', color, width, opacity))
        if start_arrow:
            st += 'startArrow=block;startFill=1;startSize=6;'
        if dashed:
            st += 'dashed=1;'
        i = self._id()
        g = ('<mxGeometry relative="1" as="geometry"><mxPoint x="%g" y="%g" as="sourcePoint"/>'
             '<mxPoint x="%g" y="%g" as="targetPoint"/>' % (pts[0][0], pts[0][1], pts[-1][0], pts[-1][1]))
        if len(pts) > 2:
            g += '<Array as="points">' + ''.join('<mxPoint x="%g" y="%g"/>' % p for p in pts[1:-1]) + '</Array>'
        g += '</mxGeometry>'
        self.cells.append('<mxCell id="%s" style="%s" edge="1" parent="1">%s</mxCell>' % (i, st, g))

    def dot(self, x, y, r=5, color=INK):
        i = self._id()
        self.cells.append('<mxCell id="%s" value="" style="ellipse;fillColor=%s;strokeColor=none;" vertex="1" '
                          'parent="1"><mxGeometry x="%g" y="%g" width="%g" height="%g" as="geometry"/></mxCell>'
                          % (i, color, x - r, y - r, 2 * r, 2 * r))

    def link(self, s, t, label='', parent='1', both=False, dashed=False, ex=None, en=None, pts=None):
        st = ('edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;endArrow=block;endFill=1;endSize=6;'
              'strokeColor=%s;fontSize=9;labelBackgroundColor=#ffffff;' % INK) + FONT
        if both:
            st += 'startArrow=block;startFill=1;startSize=6;'
        if dashed:
            st += 'dashed=1;'
        if ex:
            st += 'exitX=%s;exitY=%s;exitDx=0;exitDy=0;' % ex
        if en:
            st += 'entryX=%s;entryY=%s;entryDx=0;entryDy=0;' % en
        g = '<mxGeometry relative="1" as="geometry">'
        if pts:
            g += '<Array as="points">' + ''.join('<mxPoint x="%g" y="%g"/>' % p for p in pts) + '</Array>'
        g += '</mxGeometry>'
        self.cells.append('<mxCell id="%s" value="%s" style="%s" edge="1" parent="%s" source="%s" target="%s">%s</mxCell>'
                          % (self._id(), esc(label), st, parent, s, t, g))

    def save(self, name):
        xml = ('<mxGraphModel grid="0" page="0" background="#ffffff"><root>'
               '<mxCell id="0"/><mxCell id="1" parent="0"/>' + ''.join(self.cells) + '</root></mxGraphModel>\n')
        if NO_EXPORT:
            out = os.path.join(HERE, name + '.drawio')
            with open(out, 'w') as f:
                f.write(xml)
        else:
            with tempfile.TemporaryDirectory() as tmp:
                src = os.path.join(tmp, name + '.drawio')
                with open(src, 'w') as f:
                    f.write(xml)
                out = os.path.join(HERE, name + '.drawio.svg')
                subprocess.run([DRAWIO, '-x', '-f', 'svg', '-e', '-b', '10', '-o', out, src],
                               check=True, capture_output=True, timeout=120)
            with open(out) as f:                     # light colours on a dark page too
                svg = f.read().replace('color-scheme: light dark;', 'color-scheme: light;', 1)
            with open(out, 'w') as f:
                f.write(svg)
        print('  wrote', os.path.basename(out))


def b(name, sub):
    return '<b>%s</b><br>%s' % (name, sub)


def small(t):
    return '<font style="font-size:9px">%s</font>' % t


PORT = ('shape=step;perimeter=stepPerimeter;fixedSize=1;size=12;')
MEM = ('shape=cylinder3;boundedLbl=1;size=8;')
CONT = ('arcSize=2;dashed=1;verticalAlign=top;align=left;spacingLeft=10;spacingTop=4;fontStyle=1;'
        'container=1;collapsible=0;')



#=============================================================================
# 1) Block diagram
#=============================================================================
def block():
    d = Drawing()
    sub = 'arcSize=4;verticalAlign=top;align=left;spacingLeft=8;spacingTop=2;fontStyle=1;container=1;collapsible=0;'
    d.box(0, 220, 120, 60, 'APB4<br>completer port<br>' + small('256 B window'), SHADE, MUTED, style=PORT, i='port', rounded=False)
    d.box(0, 60, 120, 40, 'irq_o ' + small('to the PLIC'), SHADE, MUTED, style=PORT, i='irq', rounded=False)
    d.box(0, 120, 120, 40, 'pclk_en_o ' + small('to the ICG'), SHADE, MUTED, style=PORT, i='clk', rounded=False)
    d.box(160, 20, 1010, 500, 'apb_usb_host', 'none', GRID, size=12, style=CONT, i='top')
    d.box(20, 200, 140, 60, b('APB decode', 'MDELEG privilege<br>gate'), FILL, size=10, i='dec', parent='top')
    d.box(200, 30, 200, 400, 'register file', FILL2, size=11, style=sub, i='rf', parent='top')
    d.box(15, 35, 170, 80, b('registers', 'CTRL · CMD · STATUS<br>IRQ_EN · IRQ_PEND<br>DEV_ID · DEV_IF · DEV_EP'), FILL, size=10, i='regs', parent='rf')
    d.box(15, 130, 170, 70, b('report buffers', 'receive + visible, 8 bytes each<br>copied on a report · REPORT_INFO'), YELLOW, size=10, i='rbuf', parent='rf')
    d.box(15, 215, 170, 65, b('software transfers', 'SETUP0/1 · XFER · XDATA<br>' + small('CTRL_EN = 1')), FILL, size=10, style='dashed=1;', i='xfer', parent='rf')
    d.box(15, 295, 170, 55, b('counters', 'DIAG0 · DIAG1<br>' + small('DIAG_EN = 1')), FILL, size=10, style='dashed=1;', i='diag', parent='rf')
    d.box(460, 30, 240, 420, 'apb_usb_host_seq', FILL2, size=11, style=sub, i='seq', parent='top')
    for k, (t, st) in enumerate([('port state machine', 'states, attempts, failures'),
                                 ('timer chain', '1 ms frames, keep-alive, timeouts'),
                                 ('enumeration sequencer', 'eight fixed requests'),
                                 ('descriptor parser', 'interface, endpoint, sizes'),
                                 ('transaction engine', 'SETUP · IN · OUT, toggles, retries'),
                                 ('poll scheduler', 'POLL_MS or bInterval')]):
        d.box(15, 34 + 62 * k, 210, 50, b(t, st), FILL, size=10, parent='seq')
    d.box(770, 30, 220, 420, 'apb_usb_host_sie', FILL2, size=11, style=sub, i='sie', parent='top')
    for k, (t, st) in enumerate([('bit clock', 'counter, or a phase accumulator<br>when CLK_HZ is not n × 1.5 MHz'),
                                 ('transmit', 'sync · NRZI · bit stuffing<br>CRC5 / CRC16 · EOP'),
                                 ('receive', 're-phase on edges · NRZI<br>de-stuff · PID / CRC checks'),
                                 ('line monitor', 'synchronisers · idle count<br>disconnect · bus reset')]):
        d.box(15, 34 + 94 * k, 190, 80, b(t, st), YELLOW if k in (1, 2) else FILL, size=10, parent='sie')
    d.box(1250, 210, 110, 80, 'tri-state<br>pad pair<br>' + small('15 kΩ pull-downs'), SHADE, MUTED, i='pad', rounded=False)
    d.box(1410, 210, 120, 80, 'D+ / D−<br>low-speed<br>HID device', '#ffffff', style='shape=cube;size=8;', i='dev', rounded=False)
    d.link('port', 'dec', both=True)
    d.link('dec', 'rf', both=True, en=(0, 0.53))
    d.link('rf', 'irq', ex=(0, 0.1), en=(1, 0.5), pts=[(140, 80)])
    d.link('rf', 'clk', ex=(0, 0.25), en=(1, 0.5), pts=[(140, 140)])
    d.link('rf', 'seq', 'control<br>status<br>commit', both=True, ex=(1, 0.3), en=(0, 0.28))
    d.link('seq', 'sie', 'packets<br>results', both=True, ex=(1, 0.3), en=(0, 0.3))
    d.link('sie', 'rf', 'received bytes', dashed=True, ex=(0.5, 1), en=(0.5, 1), pts=[(1095, 500), (460, 500)])
    d.link('sie', 'pad', 'usb_dp/dm/oe_o<br>usb_dp/dm_i', both=True, ex=(1, 0.52), en=(0, 0.5))
    d.link('pad', 'dev', both=True)
    d.save('usb_block')


#=============================================================================
# 2) Port state diagram
#=============================================================================
def port_states():
    d = Drawing()
    st = 'arcSize=30;'
    pos = {'OFF': (0, 160), 'DETACHED': (190, 160), 'DEBOUNCE': (380, 160), 'RESET': (570, 160),
           'RECOVERY': (760, 160), 'ENUM': (950, 160), 'RUN': (1160, 160), 'BACKOFF': (760, 20),
           'FS_DETECTED': (380, 310), 'UNSUPPORTED': (950, 310), 'FAILED': (1160, 310)}
    fill = {'RUN': GREEN, 'BACKOFF': YELLOW, 'FAILED': ROSE, 'UNSUPPORTED': ROSE, 'FS_DETECTED': ROSE,
            'OFF': SHADE}
    for n, (x, y) in pos.items():
        d.box(x, y, 130, 50, '<b>%s</b>' % n, fill.get(n, FILL), size=11, style=st, i=n)
    d.link('OFF', 'DETACHED', 'EN = 1')
    d.link('DETACHED', 'DEBOUNCE', 'any J')
    d.link('DEBOUNCE', 'DETACHED', 'line change', ex=(0.3, 1), en=(0.7, 1), pts=[(419, 250), (281, 250)])
    d.link('DEBOUNCE', 'RESET', 'low-speed J<br>100 ms')
    d.link('DEBOUNCE', 'FS_DETECTED', 'full-speed J<br>100 ms', ex=(0.7, 1), en=(0.7, 0))
    d.link('RESET', 'RECOVERY', 'SE0<br>60 ms')
    d.link('RECOVERY', 'ENUM', '10 ms')
    d.link('ENUM', 'RESET', 'after step 1', ex=(0.3, 1), en=(0.5, 1), pts=[(989, 250), (635, 250)])
    d.link('ENUM', 'RUN', 'step 8 done<br>READY')
    d.link('ENUM', 'BACKOFF', 'failure', ex=(0.5, 0), en=(1, 0.7), pts=[(1015, 55)])
    d.link('RUN', 'BACKOFF', 'failure', ex=(0.5, 0), en=(1, 0.3), pts=[(1225, 35)])
    d.link('BACKOFF', 'RESET', '100 ms', ex=(0, 0.5), en=(0.5, 0), pts=[(635, 45)])
    d.link('ENUM', 'UNSUPPORTED', 'hub, no HID,<br>sizes', ex=(0.6, 1), en=(0.6, 0))
    d.link('ENUM', 'FAILED', 'third<br>failure', ex=(1, 0.8), en=(0, 0.5), pts=[(1100, 200), (1100, 335)])
    d.link('RUN', 'FAILED', 'third failure')
    d.box(0, 400, 1290, 54, 'From every state but OFF: <b>CTRL.EN = 0</b> → OFF; a <b>disconnect</b> → DETACHED (not '
          'seen while RESET drives the bus). <b>CMD.RESTART</b> in RECOVERY, ENUM, RUN, BACKOFF, FAILED or '
          'UNSUPPORTED → RESET with ATTEMPT cleared. FAILED, UNSUPPORTED and FS_DETECTED wait for a disconnect '
          'with the lines released.', SHADE, MUTED, size=10, style='align=left;spacingLeft=8;')
    d.save('usb_port_states')


if __name__ == '__main__':
    block()
    port_states()
