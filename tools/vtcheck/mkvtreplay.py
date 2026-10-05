#!/usr/bin/env python3
"""mkvtreplay.py <bytes.bin> <name> [outdir] -- replay a captured terminal stream.

Builds <name>.tap: the program (vtcheck.mac's skeleton) sends the bytes of
<bytes.bin> to KL11 line 1 (the on-screen VT when the console is on serial),
then '<name> done' on the console. If pyte is importable, prints the screen a
VT102 shows for the same bytes, to compare with a screenshot. Used for EDT
captured under SIMH (ESC [ ; 22 r scroll regions)."""
import os, subprocess, sys
here = os.path.dirname(os.path.abspath(__file__))
src_bin, name = sys.argv[1], sys.argv[2]
out = sys.argv[3] if len(sys.argv) > 3 else os.path.dirname(os.path.abspath(src_bin))
data = open(src_bin, 'rb').read().replace(b'\x00', b'')      # NUL ends the program's string
lines = ['\t.byte\t' + ','.join('%o' % b for b in data[i:i+16]) for i in range(0, len(data), 16)]
prog = open(os.path.join(here, 'vtcheck.mac')).read()
a = prog.index('vtseq:'); b = prog.index('done:')
prog = prog[:a] + 'vtseq:\n' + '\n'.join(lines) + '\n\t.byte\t0\n' + \
       'done:\t.byte\tCR,LF\n\t.ascii\t/%s done/\n\t.byte\tCR,LF,0\n\t.even\n\t.end\n' % name
prog = prog.replace('vtcheck - VT100 character set handling', name + ' - replay of a captured terminal stream')
src = os.path.join(out, name + '.mac'); open(src, 'w').write(prog)
M11 = os.path.expanduser('~/Source/PDP2011_MiSTer/tools/macro11')
obj = os.path.join(out, name + '.obj'); lst = os.path.join(out, name + '.lst')
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
open(os.path.join(out, name + '.tap'), 'wb').write(rec(name.upper().encode().ljust(80, b' ')) + rec(p) + b'\0' * 8 + b'\xff\xff\xff\xff')
print('%s: stream %d bytes, program %d bytes' % (name, len(data), len(p)))
try:
    import pyte
    s = pyte.Screen(80, 24); pyte.Stream(s).feed(data.decode('latin-1'))
    print('expected (pyte VT102):')
    for r, l in enumerate(s.display, 1): print('%2d|%s' % (r, l.rstrip()))
except ImportError:
    print('(pyte not available: no expected screen)')
