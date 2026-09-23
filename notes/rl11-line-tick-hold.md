# RL11 line-tick hold

Commit `131f272` on `disk/native-transport-rh11`. The bitstream from that
commit is `output_files/pdp2011.rbf`, MD5 `ba1bc2f0657269f9ee3fdca3ae71326a`.
On the MiSTer it is `_Computer/PDP2011_20260922_linehold.rbf`, with
`_Debug/pdp2011_rl_linehold.mgl` pointing at `rsts_v9.6_rl.dsk`.
`_Computer/PDP2011_20260922.rbf` was left in place.

## What the hold does

`crdy_hold` in `rtl/rl11.vhd` is 255. A read, write, or write-check loads
that value into an 8-bit counter and latches the CSR, BA, DA, and MP that
software just wrote. While the counter is nonzero, reads of those four
registers return the latch, so controller ready stays clear. Each rising
edge of the KW11-L (`line_tick` from `rtl/kw11l.vhd`, the same edge that
sets the line-clock monitor bit) increments the counter. The wrap to zero
publishes the finished registers and posts the one interrupt. If the card
is still moving when the counter wraps, publication waits until the
transfer has actually set ready.

255 is one tick. This core's KW11-L is 60 Hz, so that is about 16.7 ms.
`crdy_hold = 0` is instant completion, which is what
`PDP2011_20260922.rbf` does.

Seek, get-status, and read-header still raise ready in the accepting
cycle. There is no per-unit "drive still seeking" flag. `DLSEEK` (the
overlapped driver this pack was SYSGENed with) is not what this hold
models.

## Build

`./build-fpga.sh`, log `/tmp/pdp2011-bitstream-linehold.log`. Map, fit,
and asm finished with 0 errors. TimeQuest setup slack on `cpuclk` is
−2.353. The 20260922 build was −1.467.

## What the boot did

The delay causes the boot device list not to appear. The M9312 RL path
(`roms/m9312h47.mac`, `rlgo`) issues one read of 512 words from
cylinder 0 and spins on `tstb` of RLCS until ready, then jumps to the
block it loaded. That read is a held command. Get-status, read-header,
and the seek in the same routine are not held.

A resilver from this session did not run: `resilver` was invoked from
the wrong directory and failed with `open source: open GA`. The boot
result above is from the pack as it was.
