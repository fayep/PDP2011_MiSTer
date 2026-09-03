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
