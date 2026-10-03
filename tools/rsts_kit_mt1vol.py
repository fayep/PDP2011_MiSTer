#!/usr/bin/env python3
"""rsts_kit_mt1vol.py <kit.tap> <out.tap>

Make a 1600 bpi RSTS/E V10.x installation kit tape install from MT (TU10/TM11)
as a single volume.

Why: the kit's installation procedure [0,1]BEGIN.COM asks the tape driver for
the drive's density. On MT (an 800 bpi TU10) it builds the volume table of
the 800 bpi two-reel kit and, after the OMS package, asks for "volume 2" --
which a 1600 bpi kit doesn't have: everything is on the one reel. On MS
(TS11) it uses the single-volume table and installs normally.

The patch replaces, in BEGIN.COM,
    $ _if temp_dev .ne. 800  then _goto TABLE_ALL
with
    $ _goto TABLE_ALL
(padded with spaces to the same length), so every kit uses the single-volume
table. BEGIN.COM is stored as plain text in a BACKUP block of SYSTEM.BCK.

Safety: the input must be a SIMH-format .tap; the line must occur exactly once
and inside one record; that record must be a RSTS BACKUP block (256-byte
header, OS id 4) written without a CRC (flag BH$NOC set, CRC field 0) --
otherwise nothing is written. The input file is never modified. An already
patched tape is reported and left alone. The output is re-read and must
differ from the input only inside that line.
"""
import re, sys

OLD = re.compile(rb"\$ _if temp_dev \.ne\. 800 +then _goto TABLE_ALL")
NEW = b"$ _goto TABLE_ALL"
PATCHED = re.compile(rb"\$CHECK_DENSITY:\r?\n\$ _goto TABLE_ALL +\r?\n")

def records(d):
    """yield (data_start, length) for each data record of a SIMH .tap"""
    i = 0
    while i + 4 <= len(d):
        n = int.from_bytes(d[i:i + 4], "little")
        if n == 0:                                  # tape mark
            i += 4; continue
        if n == 0xFFFFFFFF or n == 0x0000FFFF:      # end of medium
            return
        if n & 0x80000000:
            sys.exit("record at byte %d has its error bit set; not a clean SIMH .tap" % i)
        L = n & 0x00FFFFFF
        j = i + 4 + L + (L & 1)
        if j + 4 > len(d) or int.from_bytes(d[j:j + 4], "little") != n:
            if all(b == 0 for b in d[i:i + 16]):    # trailing padding
                return
            sys.exit("not a SIMH-format .tap (record length mismatch at byte %d)" % i)
        yield i + 4, L
        i = j + 4

def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    if src == dst:
        sys.exit("refusing to overwrite the input; give a different output name")
    d = bytearray(open(src, "rb").read())
    if PATCHED.search(d):
        sys.exit("%s is already patched (BEGIN.COM goes straight to TABLE_ALL); nothing to do" % src)
    hits = list(OLD.finditer(d))
    if len(hits) != 1:
        sys.exit("expected the density test exactly once, found %d -- not a kit this tool knows" % len(hits))
    m = hits[0]
    rec = [(s, L) for s, L in records(d) if s <= m.start() and m.end() <= s + L]
    if not rec:
        sys.exit("the line is not inside a single tape record; not patching")
    s, L = rec[0]
    h = d[s:s + 64]
    w = lambda o: int.from_bytes(h[o:o + 2], "little")
    l = lambda o: int.from_bytes(h[o:o + 4], "little")
    if w(0) != 256 or w(2) != 4:
        sys.exit("record at byte %d is not a RSTS BACKUP block (header size %d, OS id %d)" % (s, w(0), w(2)))
    crc, flags = l(36), l(44)
    if not (flags & 1) or crc != 0:
        sys.exit("BACKUP block has a CRC (flags %08x, crc %08x); patching would corrupt it" % (flags, crc))
    old = bytes(d[m.start():m.end()])
    new = NEW.ljust(len(old), b" ")
    d[m.start():m.end()] = new
    open(dst, "wb").write(d)
    # verify: same size, same record structure, differences only inside the line
    a, b = open(src, "rb").read(), open(dst, "rb").read()
    diff = [k for k in range(len(a)) if a[k] != b[k]]
    assert len(a) == len(b) and list(records(a)) == list(records(b))
    assert diff and m.start() <= diff[0] and diff[-1] < m.end()
    print("patched %s -> %s" % (src, dst))
    print("  BACKUP block: save set %r, block at byte %d, %d bytes, no CRC" % (bytes(h[48:60]).strip(b"\0\n "), s, L))
    print("  was: %s" % old.decode())
    print("  now: %s" % new.decode().rstrip())
    print("  %d bytes changed, all inside that line" % len(diff))

if __name__ == "__main__":
    main()
