#!/usr/bin/env python3
"""mkvtcheck2.py [outdir] -- EDT-style screen test for the built-in VT100.

Builds vtcheck2.tap (same boot layout as vtcheck.tap: the program writes the
byte sequence below to KL11 line 1, then 'vtcheck2 done' on the console) and,
if pyte is importable, prints the screen a VT100/VT102 shows for it -- to
compare with a screenshot of the on-screen terminal.

Exercises: scroll region (DECSTBM), writing outside it, IL and DL inside it,
LF at the bottom margin, RI at the top margin, origin mode (DECOM)."""
import os, subprocess, sys
here = os.path.dirname(os.path.abspath(__file__))
out = sys.argv[1] if len(sys.argv) > 1 else here
E = '\x1b'
seq = E + '[2J' + E + '[H'
for r in range(1, 25):
    seq += E + '[%d;1H' % r + 'line %02d' % r
seq += E + '[1;22r'                                   # scroll region 1-22 (cursor homes)
seq += E + '[23;1H' + 'STATUS-23 (outside region)'
seq += E + '[24;1H' + 'PROMPT-24'
seq += E + '[10;20H' + E + '[L' + 'IL@10'            # insert line at 10: 10..21 -> 11..22
seq += E + '[5;20H' + E + '[M' + 'DL@5'               # delete line 5: 6..22 -> 5..21, 22 blank
seq += E + '[22;30H' + '\n' + 'LF@22'                 # LF at bottom margin: region scrolls up
seq += E + '[1;30H' + E + 'M' + 'RI@1'                # RI at top margin: region scrolls down
seq += E + '[?6h' + E + '[5;20r' + E + '[1;40H' + 'ORG(5,40)'   # origin mode: row 1 = region top (5)
seq += E + '[?6l' + E + '[r' + E + '[24;60H' + 'end'
data = seq.encode('ascii')

lines = []
for i in range(0, len(data), 16):
    lines.append('\t.byte\t' + ','.join('%o' % b for b in data[i:i+16]))
prog = open(os.path.join(here, 'vtcheck.mac')).read()
a = prog.index('vtseq:'); b = prog.index('done:')
prog = prog[:a] + 'vtseq:\n' + '\n'.join(lines) + '\n\t.byte\t0\n' + \
       "done:\t.byte\tCR,LF\n\t.ascii\t/vtcheck2 done/\n\t.byte\tCR,LF,0\n\t.even\n\t.end\n"
prog = prog.replace('vtcheck - VT100 character set handling', 'vtcheck2 - VT100 scroll region, IL/DL, IND/RI, DECOM')
src = os.path.join(out, 'vtcheck2.mac'); open(src, 'w').write(prog)
M11 = os.path.expanduser('~/Source/PDP2011_MiSTer/tools/macro11')
obj = os.path.join(out, 'vtcheck2.obj'); lst = os.path.join(out, 'vtcheck2.lst')
subprocess.run([M11, src, '-o', obj, '-l', lst], check=True)
d = open(obj, 'rb').read(); img = bytearray(65536); top = 0; i = 0
while i < len(d):
    if d[i] == 0: i += 1; continue
    n = d[i + 2] | d[i + 3] << 8; rec = d[i + 4:i + n]
    if rec[0] == 3:
        ad = rec[2] | rec[3] << 8; img[ad:ad + len(rec) - 4] = rec[4:]; top = max(top, ad + len(rec) - 4)
    i += n + 1
p = bytes(img[:(top + 1) & ~1])
def rec(b):
    L = len(b).to_bytes(4, 'little'); return L + b + (b'\0' if len(b) & 1 else b'') + L
open(os.path.join(out, 'vtcheck2.tap'), 'wb').write(rec(b'VTCHECK2'.ljust(80, b' ')) + rec(p) + b'\0' * 8 + b'\xff\xff\xff\xff')
print('vtcheck2: sequence %d bytes, program %d bytes' % (len(data), len(p)))
try:
    import pyte
    s = pyte.Screen(80, 24); pyte.Stream(s).feed(seq)
    print('expected (pyte VT102):')
    for r, l in enumerate(s.display, 1): print('%2d|%s' % (r, l.rstrip()))
except ImportError:
    print('(pyte not available: no expected screen)')
