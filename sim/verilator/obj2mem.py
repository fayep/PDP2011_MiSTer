#!/usr/bin/env python3
"""obj2mem.py <prog.obj> <prog.mem> -- a MACRO-11 absolute .obj (formatted binary, TXT records)
as the harness's .mem image: one "word-index value" pair per word, in decimal."""
import sys
d = open(sys.argv[1], 'rb').read()
mem = {}
i = 0
while i < len(d):
    if d[i] == 0:
        i += 1; continue
    assert d[i] == 1 and d[i+1] == 0, 'bad block at %d' % i
    n = d[i+2] | d[i+3] << 8
    rec = d[i+4:i+n]
    if rec[0] == 3:                         # TXT: load address, then bytes
        addr = rec[2] | rec[3] << 8
        for k, b in enumerate(rec[4:]):
            a = addr + k
            w = mem.get(a >> 1, 0)
            mem[a >> 1] = (w & 0xff00) | b if a % 2 == 0 else (w & 0x00ff) | (b << 8)
    i += n + 1
with open(sys.argv[2], 'w') as f:
    for w in sorted(mem):
        f.write('%d %d\n' % (w, mem[w]))
print('%s: %d words' % (sys.argv[2], len(mem)))
