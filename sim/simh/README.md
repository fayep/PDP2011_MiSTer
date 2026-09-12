# SIMH reference notes

Curated from a prior debugging session's `/tmp` scratch files (the
RSTS/E FPA/boot-hang investigation, Aug 2026) -- extracted here because
that investigation's actual scripts and ~2.4GB of intermediate disk
images were disposable scratch (regenerable, or one-off states of a
patched disk), but the real, working *knowledge* of how to drive SIMH
for this project is worth keeping.

`open-simh` is installed via Homebrew (`brew list open-simh`); the
`pdp11` binary is at `/opt/homebrew/bin/pdp11`.

## Real, proven config for this project's environment

```
set cpu 11/70
set cpu 2m
set rq disable
set dz disable
set tm disable
set rp enable
set rp0 rp06
attach rp0 <disk.dsk>
boot rp0
```

This boots a real 2.11BSD/RSTS-style RP06 disk image under SIMH,
matching real hardware's own CPU model closely enough for comparison
work. `break <addr>` (octal) sets a breakpoint before `boot`; once
stopped, `examine <addr>:<addr>` dumps a memory range.

## Hand-assembling and single-stepping a small program

Real, working pattern (Faye's own, done interactively, not scripted):
`deposit -m <addr> <mnemonic>` deposits one assembled instruction at a
time (SIMH assembles the mnemonic itself); `examine -m <addr>` reads
it back to verify. **Always initialize SP first** -- an uninitialized
SP means any `JSR`/`RTS` corrupts memory immediately.

This is the right approach for testing a *specific subroutine* in
isolation (e.g. verifying xubrt45's own byte-order/arithmetic logic for
a given piece of `pktin`) without needing to boot a full OS or model
XU's actual SPI/DDR3 hardware at all -- pre-deposit the *expected
response bytes* directly into the memory locations firmware would have
DMA'd them into (e.g. `dnpp`/`dpkth`), then single-step through just the
parsing/arithmetic code and examine the result registers/memory
afterward. This isolates firmware's own logic from the shim/RTL
entirely.

## Real, hard-won caveat

**Don't trust automated `expect`-driven SIMH timing for diagnosis.**
Scripted `expect` sessions in the prior investigation showed a real,
unexplained flaw -- multi-minute "hangs" at essentially random PCs that
did *not* occur when driven by hand, running the identical command
sequence. This was specifically observed *booting a full OS* (a long,
timing-sensitive sequence); a short, deterministic single-subroutine
test (deposit a few instructions, single-step, examine) has no real
timing dependency and should not be affected the same way, but treat
any `expect`-scripted *boot* sequence's timing as unreliable evidence.

See the `pdp2011-fpa-boot-hang` memory for the full original
investigation this was extracted from (a different bug, RSTS/E boot
hang, not XU-related) if more historical context is ever needed.

