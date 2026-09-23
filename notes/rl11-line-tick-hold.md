# RL11 line-tick hold

`131f272` on `disk/native-transport-rh11` held both read and write.
That bitstream is `output_files/pdp2011.rbf`, MD5
`ba1bc2f0657269f9ee3fdca3ae71326a`, copied to the MiSTer as
`_Computer/PDP2011_20260922_linehold.rbf`. The `.mgl` is
`_Debug/pdp2011_rl_linehold.mgl`, disk `rsts_v9.6_rl.dsk`.
`_Computer/PDP2011_20260922.rbf` was left in place. The write-only
arm is a later change and is not in that bitstream.

## What the hold does

`crdy_hold` in `rtl/rl11.vhd` is 255. A write command loads that value
into an 8-bit counter and latches the CSR, BA, DA, and MP that software
just wrote. While the counter is nonzero, reads of those four registers
return the latch, so controller ready stays clear. Each rising edge of
the KW11-L (`line_tick` from `rtl/kw11l.vhd`, the same edge that sets
the line-clock monitor bit) increments the counter. The wrap to zero
publishes the finished registers and posts the one interrupt. If the
card is still moving when the counter wraps, publication waits until
the transfer has actually set ready. A register read does not arm or
advance the counter. If nothing ever reads the CSR, the tick still
publishes ready and posts the interrupt.

A read command does not arm the hold. The first cut armed read as well
as write. The M9312 RL boot (`roms/m9312h47.mac`, `rlgo`) loads the
boot block with one read and only then jumps to it, so that hold kept
the boot device list from appearing. With no read to finish, nothing
later in the boot ran either.

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

The first bitstream held reads. The boot device list did not appear.
Get-status, read-header, and the seek in `rlgo` were not held; the
512-word read that loads the boot block was.

A resilver from this session did not run: `resilver` was invoked from
the wrong directory and failed with `open source: open GA`. The boot
result above is from the pack as it was.
