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

Payload bytes are stored at the load address **byte-wise**.  Odd load
addresses stitch a leftover byte from the previous DOS-11 record (EKBAD0
block 2 ends at 002066, block 3 starts at 002067).  Pairing payload
words from k=0 at (load//2) misplaces every later odd-origin block.

Emits one "<word-index> <value>\\n" line per 16-bit word, both DECIMAL
(word-index = byte-address / 2), matching sim/mac2mem.py.

Usage:
  abs2mem.py <in.bin> <out.mem>
  abs2mem.py -o <out.mem> <in.bin> [<in.bin> ...]
Later files overlay earlier ones (same 64K byte image).
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


def parse_abs(blob, mem=None, hit=None):
    """Load one abs file into a 64K byte image.  Returns
    (words_dict, transfer, nblocks, nterm, nbadcs, consumed, modes).
    words_dict maps word-index -> value for any word with a written byte.
    mem/hit if passed are reused so a later file can overlay.
    """
    if mem is None:
        mem = bytearray(65536)
    if hit is None:
        hit = bytearray(65536)
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
            load = rec["load"]
            for k, b in enumerate(payload):
                a = load + k
                if 0 <= a < 65536:
                    mem[a] = b
                    hit[a] = 1
        off += rec["size"]
    words = {}
    for a in range(0, 65536, 2):
        if hit[a] or hit[a + 1]:
            words[a // 2] = mem[a] | (mem[a + 1] << 8)
    return words, transfer, nblocks, nterm, nbadcs, off, modes, mem, hit


def _emit(path, words, xfer, nblocks, nterm, nbadcs, consumed, modes, nbytes):
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    with open(path, "w") as f:
        for a in sorted(words):
            f.write("%d %d\n" % (a, words[a]))
    lo = min(words) * 2
    hi = max(words) * 2 + 1
    mc = "".join(modes)
    sys.stderr.write(
        "%s: %d words  bytes %06o-%06o  blocks=%d term=%d badcs=%d "
        "modes=%s xfer=%s consumed=%d/%d\n"
        % (path, len(words), lo, hi, nblocks, nterm, nbadcs, mc,
           ("%06o" % xfer) if xfer is not None else "none",
           consumed, nbytes)
    )
    sys.stderr.write("  @0=%06o  @200=%06o\n" % (
        words.get(0, 0), words.get(0o200 // 2, 0)))


def main():
    args = sys.argv[1:]
    if len(args) >= 3 and args[0] == "-o":
        dst, srcs = args[1], args[2:]
    elif len(args) == 2:
        srcs, dst = [args[0]], args[1]
    else:
        sys.exit(__doc__)
    mem = bytearray(65536)
    hit = bytearray(65536)
    tot_blocks = tot_term = tot_bad = 0
    all_modes = []
    last_xfer = None
    last_cons = last_n = 0
    words = {}
    for src in srcs:
        blob = open(src, "rb").read()
        words, xfer, nblocks, nterm, nbadcs, consumed, modes, mem, hit = \
            parse_abs(blob, mem, hit)
        tot_blocks += nblocks
        tot_term += nterm
        tot_bad += nbadcs
        all_modes.extend(modes)
        last_xfer = xfer
        last_cons, last_n = consumed, len(blob)
        if len(srcs) > 1:
            sys.stderr.write("  loaded %s blocks=%d xfer=%s\n" % (
                os.path.basename(src), nblocks,
                ("%06o" % xfer) if xfer is not None else "none"))
    if not words:
        sys.exit("%s: no absolute-loader blocks" % srcs[0])
    _emit(dst, words, last_xfer, tot_blocks, tot_term, tot_bad,
          last_cons, all_modes, last_n)


if __name__ == "__main__":
    main()
