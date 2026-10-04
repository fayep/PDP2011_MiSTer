#!/usr/bin/env python3
"""mkvtcheck.py [outdir] -- build vtcheck.tap: record 0 a label (the boot ROM
skips it), record 1 the program image from address 0, two tape marks."""
import os, subprocess, sys
here = os.path.dirname(os.path.abspath(__file__))
out = sys.argv[1] if len(sys.argv) > 1 else here
M11 = os.path.expanduser('~/Source/PDP2011_MiSTer/tools/macro11')
src = os.path.join(here, 'vtcheck.mac')
obj = os.path.join(out, 'vtcheck.obj'); lst = os.path.join(out, 'vtcheck.lst')
subprocess.run([M11, src, '-o', obj, '-l', lst], check=True)
d = open(obj, 'rb').read(); img = bytearray(65536); top = 0; i = 0
while i < len(d):
    if d[i] == 0: i += 1; continue
    assert d[i] == 1 and d[i + 1] == 0, 'bad block at %d' % i
    n = d[i + 2] | d[i + 3] << 8; rec = d[i + 4:i + n]
    if rec[0] == 3:
        a = rec[2] | rec[3] << 8; img[a:a + len(rec) - 4] = rec[4:]; top = max(top, a + len(rec) - 4)
    i += n + 1
prog = bytes(img[:(top + 1) & ~1])
def rec(b):
    L = len(b).to_bytes(4, 'little'); return L + b + (b'\0' if len(b) & 1 else b'') + L
tap = rec(b'VTCHECK'.ljust(80, b' ')) + rec(prog) + b'\0' * 8 + b'\xff\xff\xff\xff'
open(os.path.join(out, 'vtcheck.tap'), 'wb').write(tap)
print('vtcheck: program %d bytes, tape %d bytes' % (len(prog), len(tap)))
