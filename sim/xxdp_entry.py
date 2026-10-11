#!/usr/bin/env python3
"""XXDP+ monitor entry state for tb_xxdp, as .mem lines (mac2mem shape).

The XXDP+ DL monitor ("R NAME") loads the diagnostic and jumps to its
start address with the state below, captured from SIMH booting the real
XXDP_RL pack (break at 200 after "R EKBEE1"):

  PSW 000340, R0-R5 157366 000000 152361 154434 153352 155626,
  KSP 154314, SSP 0, USP 0, STKLIM 0, MMR0 0, MMR3 0,
  0-16: 000000 000000 000006 000000 000012 000000 000016 000000
  (vectors 4/10/14 point at a HALT in the next word).

tb_xxdp starts with every register 0. This writes the low vectors and a
stub at 157000 (inside the monitor area, which no diagnostic loads) that
sets R0-R5 and SP, then JMP @#start. PSW 340 is tb_xxdp's init_psw.
Emit these lines before the image so the diagnostic's own words win.

Usage: xxdp_entry.py <start-octal>   (the stub address is STUB below)
"""
import sys

STUB = 0o157000

LOW = [0o000000, 0o000000, 0o000006, 0o000000,
       0o000012, 0o000000, 0o000016, 0o000000]


def stub(start):
    return [
        0o012700, 0o157366,     # mov #157366,r0
        0o005001,               # clr r1
        0o012702, 0o152361,     # mov #152361,r2
        0o012703, 0o154434,     # mov #154434,r3
        0o012704, 0o153352,     # mov #153352,r4
        0o012705, 0o155626,     # mov #155626,r5
        0o012706, 0o154314,     # mov #154314,sp
        0o000137, start,        # jmp @#start
    ]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    start = int(sys.argv[1], 8)
    out = []
    for i, w in enumerate(LOW):
        out.append(f"{i} {w}")
    for i, w in enumerate(stub(start)):
        out.append(f"{STUB // 2 + i} {w}")
    print("\n".join(out))


if __name__ == "__main__":
    main()
