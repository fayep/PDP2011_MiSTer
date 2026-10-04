#!/usr/bin/env python3
"""mkrhex.py [outdir] -- build the rhex exerciser tape and pattern disk.

  rhex.tap, rhextm.tap  SIMH tapes (rhextm: BGTM, background TM11 load): record 0 a dummy label (the boot ROM skips it),
             record 1 the program image from address 0, two tape marks.
  rhpat.dsk  RP06 image (174419968 bytes, sparse) with the pattern in
             blocks 0..NPAT-1: word 0 = LBN, word 1 = ~LBN,
             word w (2..255) = ((LBN & 0o377) << 8 | w) ^ 0o125252.
Needs tools/macro11 from the main checkout (see the boot ROM notes)."""
import os, subprocess, sys
NPAT = 19000
RP06 = 174419968
here = os.path.dirname(os.path.abspath(__file__))
out = sys.argv[1] if len(sys.argv) > 1 else here
M11 = os.path.expanduser('~/Source/PDP2011_MiSTer/tools/macro11')
def build(name, defs):
  src = os.path.join(out, name + '.mac')
  open(src, 'w').write(defs + open(os.path.join(here, 'rhex.mac')).read())
  obj = os.path.join(out, name + '.obj'); lst = os.path.join(out, name + '.lst')
  subprocess.run([M11, src, '-o', obj, '-l', lst], check=True)
  d = open(obj, 'rb').read()
  img = bytearray(65536); top = 0; i = 0
  while i < len(d):
      if d[i] == 0: i += 1; continue
      assert d[i] == 1 and d[i + 1] == 0, 'bad block at %d' % i
      n = d[i + 2] | d[i + 3] << 8
      rec = d[i + 4:i + n]
      if rec[0] == 3:                                   # TXT: load address, bytes
          a = rec[2] | rec[3] << 8
          img[a:a + len(rec) - 4] = rec[4:]
          top = max(top, a + len(rec) - 4)
      i += n + 1
  prog = bytes(img[:(top + 1) & ~1])
  def rec(b):
      L = len(b).to_bytes(4, 'little')
      return L + b + (b'\0' if len(b) & 1 else b'') + L
  tap = rec(b'RHEX'.ljust(80, b' ')) + rec(prog) + b'\0' * 8 + b'\xff\xff\xff\xff'
  open(os.path.join(out, name + '.tap'), 'wb').write(tap)
  print('%s: program %d bytes (0-%o), tape %d bytes' % (name, len(prog), len(prog) - 1, len(tap)))
build('rhex', '')
build('rhextm', 'BGTM = 1\n')
blk = bytearray(512)
with open(os.path.join(out, 'rhpat.dsk'), 'wb') as f:
    for l in range(NPAT):
        w = [l & 0xffff, ~l & 0xffff] + [(((l & 0o377) << 8) | k) ^ 0o125252 for k in range(2, 256)]
        f.write(b''.join(x.to_bytes(2, 'little') for x in w))
    f.truncate(RP06)
print('pattern disk %d blocks' % NPAT)
