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
