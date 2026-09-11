# RSTS V9.6 "13 devices disabled" hang: the buffer-shrink thread (2026-09-10)

This is the log of one investigation session, written up honestly --
including the mistakes and dead ends, not just the conclusion -- so a
future session (or a future me) doesn't have to re-walk it. Faye's
explicit instruction: "the journey is the deliverable, not something
to keep in /tmp or some junkdir."

## Starting point

Prior sessions had concluded MiSTer "never even reaches the Adjusting
memory table branch" that SIMH takes, and spent real effort (an RTL
NXM fix, a cpuclk timing stretch) chasing a 2044-vs-1920 memory-size
theory built on that premise. See
`../../memory-snapshot-rsts-v96-hang-kipar5-nonidentity.md` (this
session's copy of the Claude memory file) for that full prior trail.

## Mistake #1: disk-copy direction, and a scare over it

Early this session, a routine "reset to pristine" cp accidentally
targeted the user's own working disk (not the GA master) -- see
`../../feedback_disk_copy_direction_safety.md`.  Resolved by (a)
reading the raw session transcript to confirm the GA master itself was
never touched, (b) the simple, decisive test: copy GA fresh and
actually boot it.  Rule going forward: GA files are always the `cp`
*source*, never the destination.

## Mistake #2: driving MiSTer with a bare .rbf (no disk mounted)

The bigger mistake. `load_core /media/fat/_Computer/PDP2011_events.rbf`
only reloads the FPGA bitstream (`fpga_load_rbf()` in
`Main_MiSTer_pdp2011/input.cpp`) -- it does NOT mount any disk. Only
loading an `.mgl` (which triggers `xml_load()`) does the real mount
handshake. With no disk mounted, the M9312 hi-ROM boot probe
(`roms/m9312h47.mac`, the `boot:`/`nomt`/`nork`/`norl`/`norp` chain)
finds no ready device, hits `nodev: .asciz "?"`, and halts -- a boot-ROM
failure banner that looks exactly like "the machine hung" if you don't
know to check.

This bug wasn't new information -- `notes/rsts-init-disasm.md`'s own
"Cleanup state" section already said "Bounce menu.rbf to reload the
core," and this session had already read that file. The mistake was
not re-checking it before acting, not a missing note. See
`../../feedback_mister_boot_procedure.md` for the durable writeup and
the full boot recipe (resilver -> bounce menu.rbf -> load a `.mgl`
naming the real target rbf -> `stty ... min 1 time 0` -> real date/time
strings, not bare CR).

Working `.mgl` for this investigation's build, left in place on the
MiSTer SD card at `/media/fat/_Debug/pdp2011_events_rsts96.mgl`:
```xml
<mistergamedescription>
    <rbf>_Computer/PDP2011_events</rbf>
    <file delay="0" type="s" index="1" path="rsts_v9.6_rl.dsk"/>
</mistergamedescription>
```

## The actual finding: MiSTer DOES take the adjust path

Once booted properly (clean, freshly-resilvered disk, real date/time
input), MiSTer's console output is (full capture:
`mister_clean_boot_trace_capture.txt`):

```
Start timesharing? <Yes>

Cannot use extra 12K of buffers.  Reduced to 11K.

Size of monitor has changed from 76K to 75K.

Default memory allocation table shows MORE
memory than INIT detects on this machine.

Adjusting memory table.

  Memory allocation table:

     0K: 00000000 - 00453777 (  75K) : EXEC
    75K: 00460000 - 14547777 (1551K) : USER
  1626K: 14550000 - 16777777 ( 294K) : XBUF

Memory available to RSTS/E is 1920K words.
```

MiSTer DOES print "Adjusting memory table." and DOES land on XBUF=1626K,
identical to SIMH. The prior sessions' premise ("MiSTer skips this
branch entirely") was false -- an artifact of the unmounted-disk bug
above. The ENTIRE and ONLY divergence from SIMH's clean-adjust boot is
the two MiSTer-only lines:
```
Cannot use extra 12K of buffers.  Reduced to 11K.
Size of monitor has changed from 76K to 75K.
```
That 1K buffer-count shrink is the whole EXEC 76K->75K story. It is
NOT an MMU/NXM/timing bug -- both prior RTL fixes tried this session
(NXM commit `b406979`, cpuclk-150 commit `46b5772`) were validated
against the bad (unmounted-disk) data and have not been re-tested
against this corrected understanding.

## Chasing the buffer-count decision: what didn't work

Goal: find the code that computes "12" -> "11" (K of buffers) and
"76" -> "75" (monitor size), and why it resolves differently on MiSTer
vs SIMH given byte-identical GA disks (md5 `7452bb2411ba9251f5d5f9a285a74b1f`
confirmed identical on both).

1. **Extracted INIT.SYS via `~/Source/files11`**
   (`files11 -c "[0,1]INIT.SYS" <disk> <dest>`, 318,464 bytes, matches
   `notes/rsts-init-disasm.md`'s known size) and grepped for the
   message strings. Found `Cannot use extra`, `Size of monitor`,
   `Adjusting memory table` all in the same 512-byte file block (505),
   confirming they're one packed message table, not separate.

2. **SIMH live-memory ASCII search** (`examine -c <range>`, remembering
   that plain `examine` without `-v` is PHYSICAL addressing on this
   simulator) across every physical bank documented in
   `notes/rsts-init-disasm.md`'s MAPCOPY_PARAM table, plus the low
   identity-mapped region: the message text is resident NOWHERE at any
   point checked. Likely explanation: the table is fetched into a small
   transient scratch buffer only at print time, then that physical page
   gets reused immediately after -- a static-in-time search will never
   catch it. **Dead end for this specific approach**, not proof the
   mechanism doesn't exist.

3. **`trace_full_build7.txt`** (a real-hardware MMU+disk trace from
   2026-09-09, format decoded via `Main_MiSTer_pdp2011/support/pdp2011/
   panel.cpp`'s `trace_dump()` comment: `TRACE_KIND_DISK`: `a=LBN,
   b=dest phys addr, c=word count`). Used this to compute a candidate
   physical destination (LBN 1014 -> phys `126000`, right next to the
   `126144-166` resident table this whole investigation has focused on)
   -- but a fresh capture on a boot THAT ACTUALLY HIT the buffer-shrink
   message produced a **byte-identical** trace, stopping at the exact
   same 1856th event every time. Faye's pushback was correct to
   question this: TRACE_DEPTH is 16384, nowhere near full, so "the ring
   filled up" is not the explanation. The right read (also Faye's,
   "the likelihood is you DID hit Cannot use extra last time") is that
   the *early*, fully-deterministic M9312-ROM-driven bulk load is
   genuinely reproducible byte-for-byte across boots -- that's not a
   captured-recording bug, it's physics -- but this specific trace
   window may not extend far enough into INIT's own later on-demand
   reads to prove either way. Left unresolved at end of session.

4. **`pdp-odt peek`/`poke` extended addressing**: discovered
   `panel.cpp`'s `set_sr()` only transmits the low 16 bits of an
   address plus a single boolean "is-extended" flag (`sr22`) -- the
   real upper 6 address bits (16-21) are silently discarded:
   ```c
   int sr22 = (v & 017600000) ? 1 : 0;   // just a flag, not a value!
   uint16_t lo = (uint16_t)(v & 0177777);
   ```
   So `peek <phys-addr-above-0177777>` cannot work today -- confirmed
   empirically (`peek 0350000` echoed back `MA 150000`, its low-16-bit
   truncation). This is a **real, previously-undocumented gap** in the
   SSH ODT interface, independent of anything else in this
   investigation -- worth fixing (properly encode bits 16-21, e.g. as
   their own multi-bit user_io field) since it currently makes it
   impossible to directly inspect any extended-memory physical bank
   from the SSH front panel. Workaround used instead: poke KIPAR5
   (`172352`, ordinary 16-bit I/O address) to map the target bank into
   virtual page 5, then peek through virtual `120000-137777` -- this is
   the exact technique RSTS's own MAPCOPY_PARAM uses. (First attempt at
   this had its own bug -- a shell string-concatenation mistake
   produced garbage addresses 0,2,4... instead of 120000,120002,...;
   not yet redone correctly as of this write-up.)

## Real progress: the `020102` dispatch table, and a genuine 11orcam fix

Found by disassembling `INIT.SYS`'s first ~6200 octal bytes directly
(reliable fixed file-offset=address region, `~/Source/files11`'s
extracted `init.sys`) rather than more live tracing, per Faye's steer.
This region is INIT.SYS's own overlay/message dispatch table (matching
`notes/rsts-init-disasm.md`'s previously-unmapped `file[0] = 000001
035171 076400 140664 162720 ...` header).

Structure decoded: repeated 8-byte entries `[jsr r5,@#020102] [param]
[ptr]` starting at `003000`. `020102` itself
(`020102-020446`, MAPCALL_4000_4200's real body): checks `(r5)==6`
(a fixed literal case, maps physical `0400000`/`0420000`); otherwise
falls to `020210`, which checks the SAME param against `020364`
(=`110000`, a shared type tag) and then indexes a SEPARATE table at
`param + 001020` for a 3-word descriptor `{tag=110000, running-offset,
w3}`. Extracted all 20 real param groups (`003000-003546`) and their
descriptors -- see raw work in this session's shell history (not yet
saved as a standalone data file; redo via the python snippet in the
session transcript if needed). `param=030` (our target "memory
adjustment" category, 6 pointers landing in virtual page 5) has
`w3=013056`, which is a bare `halt` statically -- not yet resolved to
real code (either not a direct address, or only meaningful under a
KIPAR5 mapping not yet identified). **Not fully solved** -- this is
real structure, not yet the final answer for where "Cannot use extra"
lives.

**Real, durable fix made to `~/Source/11orcam` (`pdp11dis/flow.py`)**:
the recursive-descent tracer assumed every `jsr` falls through to the
next word after returning. Wrong for `JSR R5,dst` specifically -- the
classic DEC/RSX/RSTS "inline parameter" calling idiom (callee reads
data placed right after the call through R5, itself adjusts the
return address past it before `RTS R5`) -- which is exactly what was
turning `003004`/`003006` (the param/ptr words after `003000`'s call)
into garbage mis-decoded instructions. Fixed: `JSR R5,` now behaves
like `JMP`/`BR` in the flow tracer (target only, no assumed
fallthrough); `JSR PC,` (a plain call/return, no such convention)
is unaffected. Verified: existing `tests/test_dump.py` (4/4) still
passes, and the README's own `xasciz` validation routine uses
`JSR PC,xasciz` (not R5), so that test's behavior is unchanged.
Confirmed fix on real data: `disasm.py -x init.sys 0 3000` no longer
produces garbage after the `003000` call.

## Open at end of session

- Whether MiSTer's tracecap genuinely doesn't record INIT's later
  on-demand reads, or whether this session just never captured the
  right window -- unresolved, Faye disputed the "doesn't record"
  conclusion and was likely right to.
- The actual code/registers behind the "12K -> 11K" decision --
  not yet found on either platform.
- The `peek`/`poke` 22-bit truncation bug in `panel.cpp`'s `set_sr()`
  -- real, found, not yet fixed.
- Redo the KIPAR5-remap peek technique with the shell bug fixed.

## Reusable scripts (in `scripts/`)

- `shclean7.ini` -- SIMH config for a clean 1920KW boot from a fresh
  GA-resilvered disk, `set cpu history=262144` armed.
- `watch5.exp` / `watch6.exp` -- expect scripts driving SIMH through a
  clean adjust-path boot with a `break -w` write-watchpoint on the
  XBUF table word (`126164`), used to trace the actual store
  instruction (`115646: MOV R0,@#126164`) back through the real
  computation loop (`125710-125732`) and the overlay-table copies
  (`110264`, `110506`). `watch6.exp` dumps the full 262144-entry
  history at that point.
- `checkpage2.exp` -- checks physical page `126000-126200` on SIMH at
  the XBUF-write breakpoint (part of the failed string-residency
  search above, kept because the negative result is itself useful
  context).
- `mister_continue_boot2.sh` / `mister_trace_boot2.sh` -- real-hardware
  boot-automation scripts: `stty -F /dev/ttyS1 19200 cs8 -parenb
  -cstopb -crtscts clocal -icanon -echo -ixon min 1 time 0` (NOT `min 0
  time N`, which makes a zero-byte read look like EOF and kills `cat`
  early), sending real date/time strings over the serial line, then
  (in the `_trace` variant) pulling `pdp-odt trace` right after boot
  reaches "13 devices disabled".

Related persistent memory files (this session's Claude memory, listed
here for cross-reference since they live outside this repo):
`feedback_disk_copy_direction_safety.md`,
`feedback_mister_boot_procedure.md`,
`rsts-v96-hang-kipar5-nonidentity.md`.
