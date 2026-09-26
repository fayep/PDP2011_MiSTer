#!/usr/bin/env python3
"""Absolute-loader (.BIN/.BIC) to GHDL .mem (same shape as mac2mem.py).

Two DEC count conventions appear on the XXDP RL extract:

  A  paper-tape / .BIN (ZMM*, ZKAAA):  size = 4+count+1,
     payload after the load-address field is count-2 bytes.
  B  some .BIC (EKBAD0, CKBAB*):       size = count+1,
     payload is count-6 bytes (count includes the 6-byte header).
     EKBAD0's first block is count=509 → 510 bytes, one DOS-11 record.

Per block, prefer the convention whose 8-bit checksum is 0.  If neither
checksums (slack), prefer A if it fits, else B.  A count==6 block with
an odd load address is the DEC terminator and is not stored.

Emits one "<word-index> <value>\\n" line per 16-bit word, both DECIMAL
(word-index = byte-address / 2), matching sim/mac2mem.py.

Usage:  abs2mem.py <in.bin> <out.mem>
"""
import os
import sys


def _candidate(blob, off, mode):
    n = len(blob)
    if off + 4 > n:
        return None
    if (blob[off] | (blob[off + 1] << 8)) != 1:
        return None
    count = blob[off + 2] | (blob[off + 3] << 8)
    if mode == "A":
        size = 4 + count + 1
        plen = count - 2
    else:
        size = count + 1
        plen = count - 6
    if size < 7 or plen < 0 or off + size > n:
        return None
    csum = sum(blob[off:off + size]) & 0xFF
    load = blob[off + 4] | (blob[off + 5] << 8)
    return {"mode": mode, "size": size, "plen": plen, "load": load,
            "count": count, "csum": csum}


def parse_abs(blob):
    words = {}
    transfer = None
    off = 0
    n = len(blob)
    nblocks = nterm = nbadcs = 0
    modes = []
    while True:
        while off < n and blob[off] == 0:
            off += 1
        if off + 4 > n:
            break
        cands = [c for m in ("A", "B") if (c := _candidate(blob, off, m))]
        if not cands:
            break
        ok = [c for c in cands if c["csum"] == 0]
        if ok:
            aok = [c for c in ok if c["mode"] == "A"]
            rec = aok[0] if aok else ok[0]
        else:
            nbadcs += 1
            rec_end = ((off // 510) + 1) * 510
            fit = [c for c in cands if off + c["size"] <= rec_end]
            rec = fit[0] if fit else cands[0]
        payload = blob[off + 6: off + 6 + rec["plen"]]
        is_term = rec["count"] == 6
        if is_term and rec["load"] % 2:
            nterm += 1
            transfer = None
        elif is_term:
            nterm += 1
            transfer = rec["load"]
        else:
            nblocks += 1
            modes.append(rec["mode"])
            for k in range(0, len(payload) - 1, 2):
                w = payload[k] | (payload[k + 1] << 8)
                words[(rec["load"] + k) // 2] = w
            if len(payload) % 2:
                a = rec["load"] + len(payload) - 1
                prev = words.get(a // 2, 0)
                if a % 2 == 0:
                    words[a // 2] = (prev & 0xFF00) | payload[-1]
                else:
                    words[a // 2] = (prev & 0x00FF) | (payload[-1] << 8)
        off += rec["size"]
    return words, transfer, nblocks, nterm, nbadcs, off, modes


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    blob = open(src, "rb").read()
    words, xfer, nblocks, nterm, nbadcs, consumed, modes = parse_abs(blob)
    if not words:
        sys.exit("%s: no absolute-loader blocks" % src)
    os.makedirs(os.path.dirname(os.path.abspath(dst)) or ".", exist_ok=True)
    with open(dst, "w") as f:
        for a in sorted(words):
            f.write("%d %d\n" % (a, words[a]))
    lo = min(words) * 2
    hi = max(words) * 2 + 1
    mc = "".join(modes)
    sys.stderr.write(
        "%s: %d words  bytes %06o-%06o  blocks=%d term=%d badcs=%d "
        "modes=%s xfer=%s consumed=%d/%d\n"
        % (dst, len(words), lo, hi, nblocks, nterm, nbadcs, mc,
           ("%06o" % xfer) if xfer is not None else "none",
           consumed, len(blob))
    )
    sys.stderr.write("  @0=%06o  @200=%06o\n" % (
        words.get(0, 0), words.get(0o200 // 2, 0)))


if __name__ == "__main__":
    main()
