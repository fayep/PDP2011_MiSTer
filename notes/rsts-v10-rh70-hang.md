# RSTS/E V10.1 hang after "4 devices disabled" = RH70/RP completion signalling

## Symptom

RSTS V10.1 (rsts_v10.1_rp.dsk), serial console on ttyS1, driven through:
`Today's date? 03-Sep-98` / `Current time? 10:00 AM` /
`Start timesharing? <Yes>` -> `03-Sep-98 10:00 AM` / `4 devices disabled`
-> **stops.** Never prints `Memory available to RSTS/E is ...K words`
or anything after.  Confirmed on the STOCK build `PDP2011_20260901`
(size register 167777 / 1920KW, no "Adjusting memory table" - the table
matches).  The user confirms RSTS V10.1 boots fully on Open SIMH with
the same disk image, so this is a core bug.

## What the CPU is doing

Not wedged - the scheduler + null job run at kernel priority 1, PC
scattered across the monitor, clock interrupts fire (ISR at ~040150).
Registers at a representative halt:

    R0=176700 (RH70 CSR base)  R1=157762  R2=000400  R3=000402
    R4=160000  R5=000071  SP=002030  PC=121674

`PC 121670` = `004767` `JSR PC,+540` -> subroutine at ~122432, which is
a **disk-driver completion poll**:

    122432  BIT  #100, 30(R1)     ; done flag in the driver UCB
    122440  BNE  ...
    122442  CMP  22(R1), 24(R1)   ; transferred vs requested
    122450  BNE  ...
    122452  BIT  #10, 30(R1)      ; error flag
    122462  TST  56(R1)
    122470  BITB #1, 32(R1)

RSTS is spinning waiting for a disk I/O to be marked complete in its
driver structure, and the completion never gets recorded.

## The RH70 state says the transfer finished

    CS1 (176700) = 004670   RDY=1, GO=0, IE=0, fnc bits<5:1>=11100 (READ DATA)
    WC  (176702) = 000000   word count exhausted -> transfer complete
    ER1 (176714) = 000000   no error
    DS  (176712) = 010700   MOL, DPR, DRY, VV  -- ATA (bit15) = 0
    AS  (176716) = 000000   no attention
    DC/CC (176734/6) = 647/647   seek complete

So the RH70 did the read, hit WC=0, no error, drive ready - but nothing
tells RSTS's *polled* (IE=0) driver that it is done.

## Root cause candidates (both already FIXME'd in rtl/rh11.vhd)

1. **`rmcs1_sc` (CS1 bit 15, Special Condition) does not include ATA.**
   `rtl/rh11.vhd:382`:
   ```
   rmcs1_sc <= '1' when rmcs1_tre = '1' or rmcs1_mcpe = '1'-- FIXME, others?
   ```
   Per the RH11/RH70 spec SC = TRE | (any drive ATA).  A polled RP
   driver watches CS1 SC for command/seek completion; ours never raises
   it on attention.  Fix: `... or rmds_ata = '1'`.

2. **Writing the AS register clears ATA unconditionally.**
   `rtl/rh11.vhd:650`:
   ```
   when "00111" =>
      rmds_ata <= '0';   -- FIXME, not correct@!
   ```
   AS is write-1-to-clear per drive bit; writing a 0 must not clear.
   Also `rtl/rh11.vhd:620-624` clears ATA on *any* CS1 write with SC=0
   (not just when GO is set) - if RSTS's poll loop touches CS1 each
   pass, ATA is lost before it is seen.

## Update - all three applied (branch fix/rh70-attention, 181d741)

1. `rmcs1_sc <= ... or rmds_ata = '1'`
2. RMAS write is now write-1-to-clear (`if bus_dato(0) = '1'`)
3. CS1 write clears ATA only when GO=1 (`and bus_dato(0) = '1'`)

Building 2026-09-03 (container `rhbuild`).  Deploy the RBF, serial
console on ttyS1, drive Start timesharing, watch for the hang.

Caveat found while debugging: during the hang `DS` bit 15 (ATA) reads 0
every sample and `AS` reads 0 - so ATA was not currently set.  Either
our positioning-completion path is not raising it, or the (now removed)
premature clears were eating it.  If the build still hangs, next:
  - watch `DS`/`AS`/`CS1` continuously during Start timesharing to see
    whether ATA ever flickers on with the new clear semantics;
  - the poll UCB is at `R1=157762` with fields at `160004..160040` which
    straddles the kernel page-6/7 boundary (kernel I PDR7 = ACF 2,
    read-only) - the intermittent `MMR0 = 020003` (RO abort, kernel
    I-space) that **never traps** may be the real killer.  Check the
    `mmu.vhd` abort path: an abort sets+freezes MMR0 but if the write
    still completes / no trap is delivered, RSTS's tables corrupt.

## 2026-09-03 - CONFIRMED: lost RH70 completion interrupt

Live ODT forensics on the hung core (no rebuild - the hang was still
up).  The mainline is stuck at **PC 121344**, kernel / **register set 1**
/ **priority 5**, and *never retires a single instruction*: single-step
shows a perfectly rigid 40-instruction cycle - clock IRQ (BR6, vector
100 -> ISR at 040150) runs 40 instrs, `RTI` to 121344, and the clock is
*immediately pending again*, so the priority-5 code is 100% starved.

The instruction at 121344 is `TSTB 2(R1) / BNE`, R1 = R1' = **004514**,
an I/O request block.  The three fields it polls -
  [004516] completion byte  = 000000   (TSTB -> Z=1, never branches)
  [004556] (BIT #4000)       = 000000
  [004602] (BIT #140000)     = 000000
are all zero and never change.  This is a queued disk read waiting for
its completion to be posted by the RP interrupt service - which never
runs.

RH70 registers (frozen): `CS1=004670` (RDY=1, GO=0, **IE=0**, fnc=READ
DATA), `WC=0`, `ER1=0`, `AS=0`, `DS=010700`, `DC=CC=0647`,
`DA=006417` (trk 13, sec 15), `BA=131000`, `BAE=1`.  So: read of cyl
647(8)=423(10) / trk 13 / sec 15, DMA target phys **0o1131000** (BAE=1,
the >256KW buffer-pool region - NOT resident monitor; 18-bit 0o131000
holds intact monitor code, untouched, so nothing was over-written).
The transfer *finished* (WC=0, RDY=1, no error) but no BR5 interrupt
ever reached the CPU.

**PROOF:** `poke 17776700 04770` (set CS1 IE=1 while RDY=1) + `cont`
released the hang instantly.  The rigid 40-instr clock loop broke and
RSTS resumed broad multi-module execution (49 unique PCs / 61 samples
across the scheduler + 5 monitor modules).  It then settles into a
*second* monitor-level wait (PC ~142040, again `TST`/`TSTB` on an
R1-relative flag) with no new disk I/O - i.e. the next queued read has
also lost its interrupt.  (Console progress unconfirmed: serial console
was not enabled this run and the core's video can't be screenshotted
from the CLI.)

### Where the interrupt is lost - rtl/rh11.vhd:429-465 (interrupt FSM)

Completion raises a **1-cycle** `rmcs1_rdyset` pulse (rh11.vhd:878 etc);
line 801 consumes it the next cycle (`rmcs1_rdy<='1'; rmcs1_rdyset<='0'`).
The interrupt FSM (`i_idle`, line 435) only fires if it catches that
pulse **and** `interrupt_trigger = '0'`.  `interrupt_trigger` is set on
fire (439) and only cleared in `i_idle` when the fire condition is
*false* (442) or when IE drops mid-`i_req` (452) - never on the normal
`i_wait -> i_idle` return.  So after any interrupt the FSM sits in
`i_idle` with `interrupt_trigger` still '1'; it self-clears one cycle
later *because IE was auto-cleared at 459* - but if the driver has
already re-written CS1 with IE=1 and the next `rmcs1_rdyset` pulse lands
in that same cycle, line 435's condition is TRUE, so line 442 is skipped,
`interrupt_trigger` stays '1', and the 1-cycle pulse is gone by the next
cycle.  **Interrupt silently dropped; IE left as the driver set it.**

Fix direction: replace the "FSM must catch the 1-cycle pulse" design
with a latched pending-interrupt flip-flop - set on `rmcs1_rdyset |
rmds_ataset`, cleared only when the interrupt is actually granted
(`i_wait` exit).  Then a coincident pulse can't be missed.  Relates to
the CDC concerns in the `device-flag-cdc` / `sdspi-clocks-unconstrained`
memories.

This supersedes the SC/ATA theory above: at the hang ATA is genuinely 0
and irrelevant - the missing signal is the plain data-transfer-complete
BR5 interrupt.

### Why RL02 hangs the same way - it is the SAME idiom in rl11/rk11

`rh11.vhd`, `rl11.vhd`, `rk11.vhd` all carry the identical copy-pasted
interrupt FSM (`i_idle`/`i_req`/`i_wait`, `interrupt_trigger`).  Two
defects:

**A. `interrupt_trigger` is never cleared on interrupt delivery.**
All three: `i_wait -> i_idle` on `bg='0'` does NOT clear
`interrupt_trigger`.  It is only cleared in `i_idle` when the fire
condition is *false* (the `else`).  So after any delivered interrupt the
flag stays '1' until a cycle where IE is off or the ready/done bit is
off.  If the driver re-arms IE while the controller is still
ready/done and expects a fresh interrupt (fully legal PDP-11
semantics - "setting IE while DONE=1 interrupts"), it never comes.
  - rl11.vhd:289-312 - condition is `csr_ie='1' and csr_crdy='1'`
    (LEVEL); no auto-clear of `csr_ie`.  Stuck-trigger bites directly.
  - rk11.vhd:407-441 - condition `rkcs_ide='1' and rkcs_rdy='1'`
    (LEVEL) plus the `scpset` seek path.  Same.
  - This is exactly the pattern RSTS uses at SET/config time ("N
    devices disabled"): poke IE=1 on an already-ready controller to
    provoke an interrupt and check the vector.  If `interrupt_trigger`
    is stuck from a prior real completion, that probe interrupt is
    eaten -> hang right where we see it.

**B. RH70 only: the ready condition is an EDGE, not a level.**
rh11.vhd:435 gates on `rmcs1_rdyset` / `rmds_ataset` - 1-cycle pulses,
consumed by line 801 the next cycle.  If IE is 0 when the pulse passes
(e.g. auto-cleared at 459 by the previous interrupt, driver hasn't
re-set it yet) and the driver later sets IE=1 without re-pulsing bit 7,
`rmcs1_rdy` is still '1' but no interrupt is generated.  rl11/rk11 do
not have this half because they test the level.

The `poke 17776700 04770` proof works precisely because CS1 write bit 7
re-creates the `rmcs1_rdyset` pulse (rh11.vhd:605) alongside IE
(rh11.vhd:606) - i.e. it manufactures the edge that defect B otherwise
loses.

### Fix

1. Clear `interrupt_trigger <= '0'` on the `i_wait -> i_idle` transition
   in all three (rh11, rl11, rk11).  Minimal, fixes defect A everywhere.
2. rh11.vhd: gate the interrupt on the `rmcs1_rdy` **level** (`rmcs1_ie
   and rmcs1_rdy and not already-serviced`), or latch `rdyset|ataset`
   into a pending FF cleared on grant.  Fixes defect B.

Relates to `device-flag-cdc` / `sdspi-clocks-unconstrained` memories
(same "fragile 1-cycle handshake across the device/CPU boundary" theme).

TODO: capture the RL02 hang's CSR (`peek 17774400`) - expect
`IE=1, CRDY=1` (bits 6,7) with no interrupt in flight, which nails
defect A for RL.

## 2026-09-04 - the interrupt fix does NOT fix this hang

Built the int_owed fix (rh11/rl11/rk11, commit e5186d9) and ran it on
hardware with the RP image + serial console.  **RSTS stops at the exact
same point** ("4 devices disabled", 112 bytes on the console, no more),
with the set-0 registers **byte-identical** to the pre-fix hang:

    R0=176700  R1=157762  R2=000400  R3=000402  R4=160000  R5=000071

So the disk completion interrupt is not what's missing.  tb_rh11_dma /
tb_rh11_attn still pass; keep the commits (real bugs) but they are not
this bug.

### The single-step "clock livelock" was a measurement artefact

Earlier I read the rigid "40 instructions of clock ISR, RTI, immediately
re-interrupted, mainline never advances" as the bug.  It is not.  The
KW11-L divider (`kw11l.vhd`, second process) free-runs on `clk50mhz`
**while the CPU is halted**.  Between two SSH-paced `pdp-odt step`
calls (tens of ms) the divider overflows many times, so every single
step lands on a fresh pending tick.  At full `cont` speed the mainline
runs broadly across the scheduler + monitor - it just never makes
forward progress.  Do NOT diagnose the mainline by single-stepping here.

### What is actually latched at the hang: a read-only MMU abort

    MMR0 (777572) = 020017   bit13 = ABORT: read-only violation
                             bit0  = MMU enable, bits3:1 = page 7
                             bit4 (I/D) = 0  (but this bit is known
                             unreliable in our MMU - see the kernel-D
                             note below)
    MMR2 (777576) = 142612   VA of the aborted instruction
    MMR3 (772516) = 000065   kernel-D + user-D + UB-map + 22-bit all on

MMR0 stays frozen at 020017 - the MMU latched an abort and nothing
cleared it, which means the vector-250 abort trap was **not delivered**
(or RSTS's handler never ran).  RSTS is spinning instead of running its
memory-management trap handler.

R1 = 157762 makes the disk-completion poll (`BIT #100,30(R1)` etc, at
~122432) index into virtual 0o160000+ = MMU **page 7 = the I/O page**.
Either R1 is corrupt (register left wrong by a partially-executed
instruction - MMR1 is incompletely implemented, see
`notes/mmr1-incomplete.md`) and the poll then faults on the bad
address; or the poll address is fine and the MMU is wrongly RO-aborting
a legal kernel I/O-page access.

This RO abort is present with **stock mmu.vhd** (this build does not
carry the ACF-001 change from fix/rsts-candidate, and that change was
already tested = no change).

### How much of the disk got read (2026-09-04)

`MiSTer_pdp2011` serves the pack from a normal fd - `/proc/<pid>/fdinfo`
gives the live file offset.

 - Image `rsts_v10.1_rp.dsk` = 174,419,968 bytes = 340,664 blocks
   (a full RP06 bar 6 blocks).
 - At the hang the fd offset is frozen at **90,693,632 bytes = block
   177,136 = exactly 52.00 % of the pack** (RP06 cyl 423 / ~trk 13).
   Byte-identical across every boot / process instance.
 - It is NOT a sequential rebuild scan: within ~15 s of the disk going
   active the offset jumps straight to ~52 %, then wobbles in an
   ~3.5 MB window (blocks ~170,000-177,400) before wedging.
 - `/proc/<pid>/io`: ~10 k read syscalls, only a few MB of file data -
   so RSTS is chewing on directory / allocation structures clustered
   near pack-middle (where RSTS/E places the MFD/GFD and SATT.SYS),
   not scanning the whole disk.
 - RH70 shows that final read *complete* (cyl 423/trk 13/sec 15, WC=0,
   RDY=1, ER1=0) with nothing issued afterwards.

So the disk itself is fine and ~half the pack's addressable range has
been touched; RSTS gets one specific mid-pack block back and then never
issues another I/O.

### What that block actually is (parsed the RDS directory offline)

Copied the pack image and parsed the RSTS RDS 1.2 directory
(`scratchpad/rds*.py`).  PCS = 8.  The `[0,1]` UFD is at block 170360+.

 - Stuck read = **block 177115 = device cluster DCN 22139**.
 - DCN 22139 is retrieval entry 14/39 of **`[0,1]RSTS.SIL`** - the
   RSTS/E V10.1 **monitor Saved Image Library** (monitor code +
   overlays + tables).  RSTS.SIL = odd DCNs 22113..22189, blocks
   176904..177519, interleaved 1:1 with another file on the even
   clusters.
 - Immediately before it: **`[0,1]SWAP1.SYS`** = DCNs 21313..22112,
   blocks 170504..176903 - the big system swap file.  The ~7000-block
   "wobble window" the fd offset bounced around IS essentially all of
   SWAP1.SYS plus the start of RSTS.SIL.
 - ASCII strings recovered from blocks 176900-177400 (LOGIN messages,
   the DCL `RSTS>` prompt + "?Unable to attach to resident library",
   the RSTS privilege-name table, VT100 escape sequences,
   `@[0,1]SYSINI.COM START` / `CRASH`) are all monitor code / monitor
   tables - consistent with RSTS.SIL.

**Meaning:** at the hang ("N devices disabled", before "Proceed with
system startup?"), INIT.SYS is **reading RSTS.SIL to load the monitor
into memory and start it**.  It gets ~1/3 of the way through the
monitor image, the last read completes in the RH70 (WC=0, RDY=1), and
then nothing.  The hang is on loading the monitor itself - not a data
file, not directory structure.

### Next

1. Is the abort real or spurious?  At the hang, decode MMR2=142612 +
   the kernel PDRs for page 7 (I and D) - `peek 172356` (kI PDR7),
   `peek 172376` (kD PDR7) - and see what ACF page 7 has and whether
   the faulting access should have been allowed.
2. Trace the vector-250 path in `cpu.vhd` (`state_mmuabort`, ~2503):
   `have_mmuimmediateabort = 0` for model 70, so it waits for
   `mmuabort` to deassert before trapping - if `mmuabort` never
   deasserts (MMR0 stuck), the trap never fires.  That stuck-MMR0 ->
   no-trap loop is the likely direct cause of the spin.
3. Fix MMR1 (`cpu.vhd:937` gaps) so abort recovery restores registers,
   in case R1=157762 is the corrupt-by-partial-instruction case.

## 2026-09-04 - reproduction harness `sim/tb_rsts_overlay`

Full unibus (cpu + mmu + kw11l + rh11) + zero-wait RAM + behavioural
sdspi that serves data after an 8000-cycle delay so the ~125us line
clock ticks while the CPU spins.  Program in `tb_rsts_overlay.mac`.

 - **Phase 1** (polled read, no MMU, set 0): 4-sector polled RH70 read,
   5 clock preemptions -> **PASS**.  A bare polled-read-vs-clock race is
   not the bug.
 - **Phase 2** (polled read + MMU exactly as at the hang: MMR3=65,
   kernel-D + user-D + 22-bit + UB-map, **kI PDR7 read-only**, kD PDR7
   r/w, register **set 1**, priority 5): still **PASS**, no
   memory-management trap.  So the MMU *does* route I/O-page data
   accesses through kernel D-space correctly - the "kernel-D routed to
   the I-space RO PDR" idea is disproven in isolation, and the
   `MMR0 = 020017` seen on hardware really was the artefact of repeated
   `poke 17777572 0`.
 - **Phase 3** (interrupt-driven, wait at priority 5): HANG - but
   *expected*: priority 5 masks BR5, so the disk ISR can't be entered.
   Tells us the real hang (CPU pinned at pri 5) must be *polling*, not
   waiting on the disk interrupt.
 - **Phase 3b** (interrupt-driven, wait at priority 4 so BR5+BR6 both
   deliverable): PASS - 6 sectors, 7 interleaved clock ints.  BR5/BR6
   arbitration and RH70 completion delivery are correct.
 - **Phase 4** (APR-5 overlay window: pri-5 mainline and pri-7 clock
   ISR both doing save/remap/restore of kI+kD PAR5, JSRing into virtual
   120000): PASS - 800 rounds, every caller got the overlay it asked
   for, no stale mapping, no MM abort.

**Four mechanisms eliminated; none reproduces the wedge.**  The core's
polled read, interrupt path + arbitration, MMU D-space routing, and
PAR-5 remapping all behave correctly under a preempting clock.

Remaining unmodelled deltas from the real hang:
  - the actual RSTS.SIL monitor instruction stream (its RAM image is in
    the FPGA's separate SDRAM chip - not ARM-mappable, and ~56k
    `pdp-odt peek`s to dump is impractical)
  - BAE=1 DMA target with the UNIBUS map active (phase 5, not yet done)
  - a corrupt base pointer (R1=157762) whose *cause* is upstream and
    isn't something a repro can just inject

 - **Phase 5** (BAE=1 DMA target, matching the real hang's DMA address
   exactly, plus a data-verification check on the BAE=1 buffer): PASS -
   4 sectors, 5 interleaved clock ints, correct data, `last CS1 =
   004670` (the exact frozen value from the real hang).  First attempt
   found a *test* bug, not a core bug: every word write to RH CS1 also
   loads BAE(1:0) from CS1's own bits 9:8 (real RH70 behaviour,
   rh11.vhd ~719) - my program's separate BAE-register write was
   getting clobbered by the following GO write.

**Five mechanisms eliminated; none reproduces the wedge.**

## 2026-09-04 - RH70-idle watchdog (hardware instrumentation)

`unibus.vhd`: auto-halts the cpu (same path as the OSD Halt toggle) if
no write pokes RH CS1's GO bit for a long time, so the exact wedged
state can be read over the ODT console without guessing when to halt
by hand - the manual halting/poking this session has repeatedly
perturbed state and produced artefacts (the self-induced MMR0=020017
episode).  Threshold: originally 5s of cpuclk activity, but that's
short enough to trigger *during the interactive INIT date/time
prompts* (RSTS is legitimately disk-idle there for as long as it takes
to answer them over a scripted SSH session) - widened to ~90s (900M
cpuclk cycles @ ~10MHz).  The real hang sits disk-idle for 200s+, so
the wide margin costs nothing.  Building on branch fix/rh70-attention,
commit 64ae750.

Next once the build lands: reload, drive to the hang, let the watchdog
auto-halt, and read the *undisturbed* state - both register sets, PSW,
MMR0-3, RH70 registers - directly, instead of the noisy manually-timed
snapshots this session relied on.

## 2026-09-05 - rk11/rl11 sd-related bugs checked against rh11: clean

Two bugs found while adding rk11.vhd/rl11.vhd's packed-sector
addressing (see those commits) turned out to be pre-existing and
independent of the packing work itself:

  - sdcard_read_start/write_start were never reset in rk11.vhd/
    rl11.vhd (reads as 'U' in GHDL sim, permanently blocking the
    idle/read-start guard; real hardware apparently gets away with it
    only by luck of Cyclone V's LUT-FF power-up-to-0 convention). Fixed
    in both.
  - the busmaster_read loop's sdcard_xfer_addr increment overflows
    past the valid 0-255 range on a full-width transfer (rk11: any
    plain 256-word sector read, even before packing; rl11: an odd
    packed sector starting at address 128). Fixed in both with an
    `/= 255` guard.

Checked rh11.vhd for the same two bugs: both already correct.
sdcard_read_start/write_start are reset properly (rh11.vhd:437-438).
The xfer-address increment already uses `(sdcard_xfer_addr + 1) mod
256` (lines 1405, 1411) instead of a bare +1, avoiding the overflow
from the start - makes sense given RH70/RP06 genuinely needs
multi-block DMA spanning many sectors, so this was presumably built
correctly for that case originally. No fix needed on RH11.

## 2026-09-16 - RSTS V9.6 (not just V10.1) hits the same hang shape on RH11

Independent evidence this is a controller-level bug, not specific to
V10.1's monitor: built a fresh RSTS V9.6 install from scratch on real
MiSTer hardware this session (genuine DEC V9.6 distribution kit tape,
`rsts_v9_6_install.tap` -- had to convert from TPC to raw SimH .tap
format first, see [[reference_pdp_harness_operating]] area / this
session's own notes for that detour) onto a blank RP06 disk via TM11 +
RH11 -- i.e. a from-scratch SYSGEN done entirely on MiSTer, using
MiSTer's own real-detected memory (1920K) throughout, no GA-media
vintage-mismatch confound at all. It STILL hit the same "13 devices
disabled" hang -- PC readings (`121564`, `141552`, `115166`, `144102`,
`042014`...) matching this file's own documented "wide PC range across
multiple kernel pages, scheduler alive, mainline starved" hang
signature (see [[rsts-v96-hang-kipar5-nonidentity]] for that file's own
parallel V9.6-on-RL characterization). Disk write activity (checked via
file mtime) had genuinely stopped ~26 minutes before the check, ruling
out "it's just slow real disk I/O" as an explanation -- this really is
the hang, not patience.

This means the hang reproduces on RH11 across at least two different
RSTS monitor versions (V9.6, V10.1) with fully independent, freshly-
generated disks. Faye's correction to an over-narrow first draft of this
entry (which called it "RH11-specific"): "RH11 and RL11 and RK11 all
hang" -- all three controllers show this same-shaped symptom. This
file's own "Why RL02 hangs the same way" section above already flags a
real, concrete SHARED SUSPECT (the identical copy-pasted interrupt FSM
idiom in all three) -- but Faye's further point stands and is NOT yet
ruled out: **they could each be independently broken in their own way**,
merely producing a similar-looking "scheduler alive, mainline starved"
symptom, rather than provably sharing one root cause. The shared-idiom
fix (`e5186d9`) was tried on this exact RH70 hang and did NOT fix it
(see "2026-09-04 - the interrupt fix does NOT fix this hang" above) --
which itself is evidence AGAINST "it's simply the shared FSM bug" as a
complete explanation, at least for RH70. Do not treat "same shape across
three controllers" as proof of one shared cause; it's a real, testable
lead, not a conclusion.

This DOES still directly falsify the theory (explored earlier this same
session, before this was found) that MiSTer's hardcoded 1920K memory-
size register (`cr.vhd:365`) needed raising to fix RSTS V9.6 -- a fresh
SYSGEN with zero size-template mismatch hit the identical hang, so the
size register was never the culprit for this specific hang (it may
still be worth revisiting on its own architectural-accuracy merits
later, but not as a fix for this bug).

## 2026-09-16 - interrupt FSM defect A re-verified against CURRENT rtl/, still present as a narrow residual race; real GHDL repro + fix (defect B confirmed already fixed)

Independently re-checked the "Why RL02 hangs the same way" / "the
interrupt fix does NOT fix this hang" history above against the ACTUAL
current `rtl/rh11.vhd`, `rtl/rl11.vhd`, `rtl/rk11.vhd` on this branch
(disk/native-transport-rh11), not the old line numbers/wording. The
tree has moved on since those entries were written (this branch's own
recent commits rewrote the sd_* transport, per the log at the top of
this session) but the interrupt FSM itself is essentially what
`e5186d9` ("int_owed fix") left it as.

**Defect B (rh11-only, edge-vs-level) is genuinely fixed.** The
int_owed-latching condition in current `rh11.vhd` is:

```
if rmcs1_rdyset = '1' or rmds_ataset = '1'
   or (rmcs1_ie = '1' and rmcs1_ie_d = '0' and (rmcs1_rdy = '1' or rmds_ata = '1')) then
   int_owed <= '1';
end if;
```

The third term is a genuine level-based "IE armed while already
ready/ATA" path, independent of the 1-cycle `rdyset`/`ataset` pulses --
exactly what defect B needed. Confirmed working via Phase 1 of the new
testbench below (interrupt #2: IE cleared, then rearmed on an
already-ready controller well clear of any grant -- fires cleanly).

**Defect A (all three controllers, "interrupt_trigger never cleared on
delivery") is fixed for the WIDE case `e5186d9` targeted, but a narrow,
single-cycle race version of the exact same defect was still present
in the current tree before this session's fix below.** `int_owed` is a
level latch, cleared only in the `i_wait -> i_idle` transition
(`bg='0'`). `interrupt_trigger` -- the actual "one interrupt in flight"
guard that gates re-entry into `i_req` -- was, in the pre-fix tree,
**only ever cleared in `i_idle`'s else-branch** (taken when
`int_owed='0'`), never on the `i_wait -> i_idle` transition itself. If
a *new* completion/rearm event's `int_owed <= '1'` assignment (the
general post-case if-block, textually AFTER the interrupt_state case,
so it wins for that clock edge -- last-assignment-wins, ordinary VHDL
sequential-process semantics) lands on the EXACT SAME nclk edge as a
grant (`bg` deasserting, `i_wait -> i_idle`), then: the case's
tentative `int_owed <= '0'` gets overridden back to `'1'` by the later
assignment, while `interrupt_trigger` -- untouched by the `i_wait`
branch -- is still `'1'` from the interrupt that was just granted.
`i_idle` can then NEVER reach the `int_owed = '0'` else-branch that
would clear `interrupt_trigger` (int_owed will never be `'0'` again),
so **both signals latch permanently at `'1'` and every later
completion on that controller is silently eaten until reset** -- a
genuine, self-sustaining deadlock, not a one-off dropped interrupt.
This is a strictly narrower window than the original defect A the
notes described (needs exact single-nclk-edge coincidence between a
grant and a new completion/rearm, not merely "any rearm while ready"),
which is fully consistent with `e5186d9` having closed the wide case
but the 2026-09-04 hardware test still hanging identically -- the wide
case was never what was killing the real RH70 boot; this narrow one
might still be relevant if real bus-arbitration timing can put a
completion and a grant-ack on the same cycle, but that's unverified
(see "still unproven" below).

Same defect, same-shaped code, confirmed present in `rl11.vhd` and
`rk11.vhd` too (identical `i_wait` branch, identical general
`int_owed`-setting if-block placed after the case). rk11.vhd also has
an odd vestigial direct `interrupt_trigger <= '1'` write in its CS1
write-decode path ("setting ide, not setting go, but rdy = 1 ->
interrupt") that looks backwards at first read, but traced through
sequential/edge semantics it turns out to be harmless dead weight
(self-corrects one cycle later via the same else-branch, before
`int_owed` catches up) -- not touched, out of scope, flagged here only
so nobody rediscovers it and assumes it's live.

### Real GHDL repro: `sim/tb_rh11_int_owed_race.vhd`

Built following the same house style as `tb_rh11_attn.vhd`/
`tb_rh11_dma.vhd` (real `rh11` entity instantiation, no reimplemented
logic), but drives `bg` itself (no CPU model) so the exact grant/
deassert edge can be engineered cycle-for-cycle to coincide with a
register write. Two phases:

  - **Phase 1** (baseline, non-racing): SEEK completes with IE already
    set -> interrupt #1 delivered/granted; IE cleared then rearmed on
    the still-ready controller, well clear of any grant -> interrupt
    #2 fires cleanly. Regression-proves `e5186d9`'s fix still works.
  - **Phase 2** (the race): a third SEEK gets the FSM into `i_wait`;
    IE is cleared and then the write that rearms it is timed so its
    `int_owed`-latching edge (rmcs1_ie='1' current, rmcs1_ie_d='0'
    current -- worked out from the register-write pipeline delay, see
    the testbench's own comments for the edge-by-edge derivation) lands
    on the exact nclk edge `bg` is dropped for interrupt #3's own
    grant. Checks interrupt #4 (the rearm) is delivered, then issues a
    genuinely new, unrelated SEEK afterward and checks interrupt #5
    fires too (proving the controller isn't just "late" but actually
    unstuck).

Confirmed via temporary per-cycle `report` instrumentation added to
`rh11.vhd` (removed before commit, not part of the diff) that on the
PRE-FIX tree this exactly reproduces the predicted permanent lockup:
`int_owed='1', interrupt_trigger='1', state=i_idle` from the race edge
onward for the remainder of a 30us+ simulation window, `br` never
pulsing again. Pre-fix run: **2 of 5 checks FAIL** (interrupt #4 eaten,
and the supposedly-unrelated interrupt #5 also never fires because the
FSM is now permanently dead, not just that one interrupt).

### Fix (rh11.vhd, rl11.vhd, rk11.vhd)

Added `interrupt_trigger <= '0';` alongside the existing
`int_owed <= '0';` in the `i_wait -> i_idle` (`bg='0'`) transition, in
all three files -- clearing the in-flight guard unconditionally at the
moment the interrupt is actually granted, rather than relying on a
later `i_idle` cycle that the race could prevent from ever occurring.
Even if `int_owed` gets re-latched to `'1'` on that same edge by a
coincident event, `interrupt_trigger` is now already `'0'` the very
next edge, so `i_idle` re-enters `i_req` normally instead of
deadlocking.

Post-fix: **`tb_rh11_int_owed_race`: ALL 5 CHECKS PASS.** Full existing
regression suite re-run clean after the fix: `tb_rh11_attn`,
`tb_rh11_dma`, `tb_rh11_write`, `tb_rk11_dma`, `tb_rl11_dma`,
`tb_mmu_rl11_par_stamp` all still PASS -- no observed regression.

### What this does NOT establish

**This is a real, testbench-proven, now-fixed RTL defect -- but it is
NOT shown to be the cause of the actual RSTS hang on real hardware,**
and per this file's own 2026-09-04 entry, a structurally similar
"fix the interrupt FSM" change was already tried on real hardware and
did **not** move the RH70 hang at all (byte-identical halt state
before/after `e5186d9`). The race this session found and fixed is
strictly narrower than what `e5186d9` covered, so there is no basis yet
to expect a different real-hardware outcome:

  - Reproducing it requires an exact single-nclk-edge (100 MHz-domain)
    coincidence between a grant-ack and a fresh completion/rearm event.
    Whether real UNIBUS/interrupt-arbiter timing on this core can ever
    actually produce that coincidence during a real RSTS boot is
    UNKNOWN -- not measured, not simulated against real driver timing,
    not tested on hardware.
  - The 2026-09-04 hardware hang investigation's own later entries
    (MMR0 read-only-abort angle, `sim/tb_rsts_overlay` phases 1-5 all
    passing / eliminating polled-read, interrupt-arbitration, MMU
    D-space routing, and PAR-5 remap as mechanisms) remain the last
    live, UNRESOLVED lead for the actual RH70 hang and are untouched by
    this fix.
  - This fix has NOT been deployed to or tested on real MiSTer
    hardware, per the task boundary for this session's work (RTL +
    simulation only). Do not treat this as "found and fixed the RSTS
    hang" -- it is a real defect, real fix, real simulation proof, and
    an open question whether it's relevant to the actual boot hang at
    all.

Worth doing next, NOT done here: run this exact fix (all three
controllers) through a real hardware boot-to-hang cycle the same way
`e5186d9` was tested, using the `.mgl`-boot procedure in
`memory/feedback_mister_boot_procedure.md`, and see whether the hang
point moves even slightly -- that's the only way to learn whether this
narrow race is reachable by real RSTS driver/arbiter timing at all.
