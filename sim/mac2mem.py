#!/usr/bin/env python3
"""Convert a macro11 .obj (DEC formatted-binary object) to a flat .mem file.

Emits one "<word-index> <value>\n" line per 16-bit word, both DECIMAL (VHDL
std.textio integer reads are base-10).  word-index = byte-address / 2.
Only handles absolute (.ASECT) objects - TXT blocks are taken
verbatim and any RLD relocation directives are ignored (an absolute program
has none that matter).  A GHDL testbench reads the .mem with std.textio.

Usage:  mac2mem.py <in.obj> <out.mem>
"""
import sys, struct


def records(blob):
    i = 0
    n = len(blob)
    while i < n:
        # skip null padding between records
        while i < n and blob[i] == 0:
            i += 1
        if i >= n:
            break
        if blob[i] != 1:
            raise ValueError("expected 0x01 record start at %d, got %02x" % (i, blob[i]))
        if blob[i + 1] != 0:
            raise ValueError("bad record header at %d" % i)
        length = struct.unpack_from("<H", blob, i + 2)[0]   # header(4) + data, excl checksum
        data = blob[i + 4 : i + length]
        i += length + 1                                     # + checksum byte
        yield data


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    blob = open(sys.argv[1], "rb").read()
    words = {}
    for data in records(blob):
        if not data:
            continue
        btype = data[0]
        if btype != 3:            # only TXT
            continue
        addr = struct.unpack_from("<H", data, 2)[0]
        payload = data[4:]
        for k in range(0, len(payload) - 1, 2):
            w = payload[k] | (payload[k + 1] << 8)
            words[addr + k] = w
        if len(payload) % 2:
            words[addr + len(payload) - 1] = payload[-1]
    with open(sys.argv[2], "w") as f:
        for a in sorted(words):
            f.write("%d %d\n" % (a // 2, words[a]))
    sys.stderr.write("%s: %d words\n" % (sys.argv[2], len(words)))


if __name__ == "__main__":
    main()
