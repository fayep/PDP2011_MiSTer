# RSTS V9.6 boot block + INIT.SYS: annotated disassembly

Reverse-engineered from a real RSTS V9.6 RL02 pack (`rsts_v9.6_rl.dsk`,
via SIMH), cross-checked against live single-stepping in SIMH (V4.0-0,
built locally at `~/Source/simh` specifically because the stock V3.12-3
build has no write-type breakpoints) and a purpose-built recursive-
descent disassembler (`~/Source/11orcam`, package `pdp11dis`). Produced
while chasing the "N devices disabled" boot-time message as a possible
lead on the RH70/RSTS hang documented in `rsts-v10-rh70-hang.md` — that
specific message's construction was **not** located this session (see
Open Questions), but the boot block and a meaningful slice of
`INIT.SYS`'s resident code were fully traced and are documented here as
a reusable reference.

Address notation is octal throughout, matching MACRO-11/DEC convention.
`L######:`/`D######:` labels mark, respectively, a branch/call target
and a plain data reference — exactly as the disassembler renders them.
Comments after `;` are this session's own annotations, not anything
recovered from symbol tables (RSTS ships no debug symbols for this
code).

## The big picture: two bootstrap stages solving the same problem at
different levels of indirection

Both major pieces of code this session fully traced turn out to be
doing the same conceptual job -- "make room for what comes next" --
just with different tools available:

  - **Stage 1, the boot block** (no MMU active yet): "make room" means
    literally copying its own 512 bytes to a new address with a CPU
    `MOV` loop (`000420-000442`), then jumping into the relocated
    copy, so it can safely load the real resident image starting at
    address 0 -- the space it just vacated. Confirmed directly: right
    after the self-relocation, its own table-driven loader reads real
    `INIT.SYS` content straight into address 0 (see the reconstructed
    log's very first two transfers).
  - **Stage 2, `MAPCOPY_PARAM`-family calls** (MMU live): "make room"
    usually doesn't require moving any bytes at all -- swap which
    physical bank a virtual window shows, done. A physical copy only
    becomes necessary at the one point where content has to stop being
    a temporary view and become genuinely, permanently resident: the
    RL controller's DMA address register (`RLBA`) is only 16 bits, so
    a disk read can only ever land in a bank within the low 64K
    directly. Getting content into any of the high physical banks
    found this session (`0o400000` and friends) therefore requires an
    actual copy, not just a remap -- confirmed directly in the
    reconstructed log: 20 of the 22 real `MAPCOPY_PARAM` calls pair ONE
    window at its own page's plain identity value (PAR5 `0o1200`, PAR6
    `0o1400` -- i.e. "this page's own permanent home") against some
    OTHER, non-identity bank on the other side, and copies between
    them. The remaining 2 calls (the last pair, see "Physical memory
    layout" below) break this pattern -- PAR5 is `0o510` instead of
    the usual `0o1200` -- so "always identity on one side" is a strong
    tendency in the early phase, not an absolute rule for every call.
    Same underlying problem as
    stage 1's relocation ("the next thing needs a permanent home, and
    it isn't there yet"), solved with a fundamentally cheaper
    mechanism once paging exists -- swap a window instead of moving
    bytes, and only actually copy when something must leave the
    RLBA-reachable staging area for good.

## Methodology notes (read this before the listing)

- **File-offset = address calibration**: `INIT.SYS`'s first 64KB is
  loaded byte-for-byte at its own low addresses with zero relocation
  offset — confirmed by live single-stepping SIMH against the
  disassembly of the extracted file. This holds only under 64KB; the
  file is 318,464 bytes total (622 blocks), and the remainder is
  reached only through the MMU-based overlay mechanism described
  below, which does NOT preserve a fixed file-offset/address
  relationship.
- **Self-relocation**: the boot block copies itself from address 0 to
  157000 before running, and the copy is complete and byte-identical —
  so every address below is shown once; the 157000-relocated mirror is
  the literal same bytes at address+157000 and isn't repeated.
- **MMU overlay banks are NOT loaded via simple file-offset math.** A
  live disk-read sweep (every real `RD` command's `RLDA`, decoded to
  LBN, across the full ~1760-write boot sequence up to the "devices
  disabled" prompt) never once touched `INIT.SYS`'s own LBN range
  (2-623) except a repeated read of LBN 4 — meaning the overlay content
  loaded into KIPAR5/KIPAR6 windows during INIT's execution is NOT a
  simple "read block N of INIT.SYS" operation. How it's actually
  populated remains unresolved (see Open Questions).
- **Live-vs-static divergence**: several addresses in the 100000-127777
  range (`110434`, `110126`, `120562` seen live) contain **different,
  non-zero, coherently-executing code** at runtime than what's stored
  in the extracted file at the same offset (which is all-zero, or a
  different valid instruction). This region is genuinely patched or
  generated at runtime — static disassembly of it from the on-disk
  file is unreliable, and anything from that range below is explicitly
  flagged.
- **RL11 register physical addresses** (22-bit/4MB addressing, `set cpu
  11/70,4M`): the UNIBUS I/O page relocates to the top of the full 4MB
  physical space, NOT `17xxxx`. `RLCS`=`17774400`, `RLDA`=`17774404`,
  `RLMP`=`17774406`; `KIPAR5`=`17772352`, `KIPAR6`=`17772354`. Formula:
  `physical = 17760000 + (unibus_addr & 017777)`.
- **RL11 function codes** (`RLCS` bits 1-3, with GO bit 0 set as for any
  real command write): `01`=NOP, `03`=WCK, `05`=GSTA, `07`=SEEK,
  `11`=RHDR, `13`=WT, `15`=RD, `17`=RNOHDR. Only `RD`/`WT`/`WCK` treat
  `RLDA` as a cylinder/head/sector address; `SEEK`/`GSTA` use it for
  something else entirely (confirmed the hard way: `RLDA=173200`
  decoded as LBN 39440, impossible on a ~20K-block pack, because it was
  actually a `SEEK` command).
- **LBN <-> RLDA** (RL02, 40 sectors/track, 2 heads): `RLDA = (cyl<<7)
  | (head<<6) | sector`; `LBN = (cyl*2 + head)*40 + sector`.

---

## Boot block (LBN 0, loaded to address 0 by SIMH's synthetic ROM /
real hardware's own bootstrap ROM, then self-relocates to 157000)

```
000000:  000240               nop
000002:  000573               br     000372
D000004:
000004:  000006               rtt                  ; unused here as an instruction --
                                                     ; this word is really part of the
                                                     ; boot block's own small data area
D000016:
000016:  174400               .word  174400         ; RLCS UNIBUS address, used below via
                                                     ; deferred addressing to read the
                                                     ; CURRENT RLCS status (drive-type bits)
D000026:
000026:  000000               .word  000000         ; drive-type byte, filled in below
D000030:
000030:  000000               .word  000000         ; drive-type word, filled in below

L000372:
000372:  000400               br     000374
L000374:
; --- drive-type autodetect: read RLCS, extract type bits, stash them ---
000374:  017700 177416        mov    @000016,r0     ; r0 = *RLCS (deferred through the
                                                     ; pointer at 000016) -- CURRENT status,
                                                     ; not the address itself
000400:  042700 176377        bic    #176377,r0     ; isolate the drive-type field
000404:  010067 177420        mov    r0,000030       ; stash word form
000410:  000300               swab   r0
000412:  110067 177410        movb   r0,000026       ; stash byte form
000416:  005000               clr    r0

; --- self-relocation: copy this whole 512-byte block to 157000-157777 ---
000420:  012701 157000        mov    #157000,r1
000424:  012705 000400        mov    #000400,r5      ; loop count = 256 (0400 octal) words
                                                     ; = exactly one block/512 bytes
L000430:
000430:  012021               mov    (r0)+,(r1)+
000432:  077502               sob    r5,000430
; three more words copied (predecrement -- into the TOP of the relocated
; copy, i.e. the first few bytes of the NEXT block, LBN 1, which SIMH's
; own boot ROM also loaded to address 1000-1777 as part of its initial
; 2-block load):
000434:  012041               mov    (r0)+,-(r1)
000436:  012041               mov    (r0)+,-(r1)
000440:  012041               mov    (r0)+,-(r1)
000442:  062707 157000        add    #157000,pc      ; self-relocating jump: PC becomes
                                                     ; fallthrough(000446) + 157000 = 157446.
                                                     ; NOTE: ADD/SUB/BIC/BIS on PC COMBINE
                                                     ; with PC's post-instruction value, they
                                                     ; do not replace it like MOV would --
                                                     ; this is the exact bug this session's
                                                     ; own disassembler caught and fixed.

; ---- from here on, execution is at address+157000; only shown once ----

L157050:
157050:  000533               br     157340

; --- RLDA/RLCS-relative disk-address-computation helper (157052) ---
; converts a linear LBN (held across several fixed cells) into a real
; RLDA cyl/head/sector value using DIV against #24 (20 octal = the
; per-half-cylinder sector count in this encoding) and ASH shifts,
; then dispatches through the shared completion-poll at 157322.
L157052:
157052:  016700 177740        mov    157016,r0       ; r0 = &RLCS  (direct load this time,
                                                     ; not deferred -- literal 174400)
L157056:
157056:  016703 177754        mov    157036,r3
157062:  005002               clr    r2
157064:  012704 000024        mov    #000024,r4
157070:  071204               div    r4,r2
157072:  160304               sub    r3,r4
157074:  000304               swab   r4
157076:  020467 177744        cmp    r4,157046
157102:  101402               blos   157110
157104:  016704 177736        mov    157046,r4
L157110:
157110:  160467 177732        sub    r4,157046
157114:  072227 000006        ash    #000006,r2
157120:  006303               asl    r3
157122:  050203               bis    r2,r3
157124:  016700 177666        mov    157016,r0
157130:  016705 177710        mov    157044,r5
157134:  072527 000004        ash    #000004,r5
157140:  056705 177664        bis    157030,r5       ; OR in the drive-type bits detected
                                                     ; way back at boot -- so the disk
                                                     ; command's drive-select field really
                                                     ; does depend on autodetected hardware
157144:  052705 000010        bis    #000010,r5       ; GO bit
; --- wait for controller ready, then issue command ---
157150:  005720               tst    (r0)+
L157152:
157152:  010540               mov    r5,-(r0)
L157154:
157154:  105710               tstb   (r0)
157156:  100376               bpl    157154           ; poll RLCS bit 7 (DONE) until set
157160:  005720               tst    (r0)+
157162:  100773               bmi    157152
157164:  016720 177652        mov    157042,(r0)+     ; write RLDA
157170:  005720               tst    (r0)+
157172:  011040               mov    (r0),-(r0)
157174:  042710 000177        bic    #000177,(r0)
157200:  042702 000100        bic    #000100,r2
157204:  160210               sub    r2,(r0)
157206:  103003               bcc    157216
157210:  005410               neg    (r0)
157212:  052710 000004        bis    #000004,(r0)
L157216:
157216:  032703 000100        bit    #000100,r3
157222:  001402               beq    157230
157224:  052710 000020        bis    #000020,(r0)
L157230:
157230:  005210               inc    (r0)
157232:  005745               tst    -(r5)
157234:  004767 000060        jsr    pc,157320        ; -> shared completion poll
157240:  103436               bcs    157336           ; error -> bail
157242:  022020               cmp    (r0)+,(r0)+
157244:  005404               neg    r4
157246:  010410               mov    r4,(r0)
157250:  005404               neg    r4
157252:  010340               mov    r3,-(r0)
157254:  066705 177554        add    157034,r5
157260:  004767 000034        jsr    pc,157320        ; -> shared completion poll (again)
157264:  103424               bcs    157336
157266:  006304               asl    r4
157270:  060467 177546        add    r4,157042
157274:  005567 177544        adc    157044
157300:  005767 177542        tst    157046
157304:  001414               beq    157336
157306:  072427 177767        ash    #177767,r4
157312:  060467 177520        add    r4,157036
157316:  000657               br     157056           ; loop: more of the transfer remains

; --- shared "issue command, poll for completion" primitive ---
L157320:
157320:  024040               cmp    -(r0),-(r0)      ; (odd no-op-ish pair; harmless --
                                                     ; likely an assembler artifact of
                                                     ; whatever macro generated this)
L157322:
157322:  010510               mov    r5,(r0)          ; write the command word to RLCS
L157324:
157324:  105710               tstb   (r0)
157326:  100376               bpl    157324           ; poll DONE bit
157330:  005720               tst    (r0)+
157332:  100001               bpl    157336
157334:  000261               sec                      ; error -> set carry for caller
L157336:
157336:  000207               rts    pc

; --- the ORIGINAL boot-time single-block read: LBN 11, direct RLDA
; write of the literal value 000013 octal, no drive-select/geometry
; math at all (this is the very first disk access after relocation) ---
L157340:
157340:  016700 177452        mov    157016,r0
L157344:
157344:  105710               tstb   (r0)
157346:  100376               bpl    157344
157350:  012760 000013 000004 mov    #000013,000004(r0)  ; RLDA = 13(8) = LBN 11
                                                          ; (live-confirmed: this exact
                                                          ; write is the very first RLDA
                                                          ; write of the whole boot)
157356:  016705 177446        mov    157030,r5            ; the drive-type word from way
                                                          ; back -- reused as the command
157362:  022525               cmp    (r5)+,(r5)+          ; (again, likely macro artifact)
157364:  000756               br     157322                ; -> shared poll, does NOT return
                                                          ; here (see below)

; NOTE: LBN 11 reads back as all-zero on the actual pack -- confirmed
; directly via `files11 -b 11 <disk> 1`. The exact purpose of this
; read (if it's even checked/used) is unresolved; it may be a
; drive-presence probe rather than a real data load.

; --- the master entry point (157446), reached via the self-relocating
; ADD #157000,PC above ---
L157446:
157446:  010706               mov    pc,sp             ; SP = 157450 (right after this insn)
157450:  004737 157050        jsr    pc,@#157050       ; -> 157050's stub -> 157340 (LBN 11
                                                     ; probe read above)
L157454:
; --- table-driven bulk loader: walks BACKWARD through a table of
; 3-word entries via predecrement (Faye's own "push state at branch"
; framing applies structurally here too -- SP/R1 IS the table cursor),
; calling the disk-address-compute-and-read routine (157052) once per
; entry until a zero count is popped. The table itself is NOT inside
; this 512-byte boot block -- it must be delivered by whatever the
; LBN-11 read above actually loads (unresolved, see above), or is
; already resident from SIMH's own initial 2-block load. ---
157454:  014137 157046        mov    -(r1),@#157046   ; pop count
157460:  001417               beq    157520            ; count==0 -> done, jump to 157022
157462:  014137 157040        mov    -(r1),@#157040   ; pop word 2 of this entry
157466:  014137 157036        mov    -(r1),@#157036   ; pop word 3 (starting LBN, low)
157472:  004737 157052        jsr    pc,@#157052       ; -> compute RLDA + issue read
157476:  103412               bcs    157524            ; error -> halt
157500:  006337 157046        asl    @#157046
157504:  063737 157046 157042 add    @#157046,@#157042
157512:  005537 157044        adc    @#157044
157516:  000756               br     157454             ; next table entry

L157520:
157520:  000137 157022        jmp    @#157022           ; -> boot handoff (see below)
L157524:
157524:  000000               halt                       ; hard failure path -- this is the
                                                         ; SAME halt this session originally
                                                         ; mis-hit via a debugging artifact
                                                         ; (continuous breakpoint interrupt
                                                         ; distorting RL controller timing);
                                                         ; on real/undisturbed execution this
                                                         ; is the genuine "Booted device hung/
                                                         ; unknown device/data error" dead end.

; --- boot handoff: jumps to a fixed address (052416) that is NOT part
; of this 512-byte block at all -- it's wherever the table-driven
; loader above actually deposited INIT's real entry point. Outside the
; scope of a single-block trace; this is exactly the address the
; disassembler itself flags as "point the next -x call here". ---
D157016:
157016:  174400               .word  174400
L157022:
157022:  012707 052416        mov    #052416,pc
```

---

## INIT.SYS resident portion (file offset = address, valid under 64KB
only)

A recursive-descent trace seeded from every entry point found this
session (live single-stepping) PLUS an automated scan for candidate
entries (`disasm.py -scan`: JSR/JMP absolute targets, the instruction
right after an RTS/HALT, and register-push prologue runs) reaches
~26,000 real instruction words across this 64KB. Only the specific
routines this session actually understood the PURPOSE of are
transcribed below; the full raw trace is much larger and mostly
mechanical (the resident image is dense with real code, not mostly
padding).

### Shared error/dispatch handler (021042)

Referenced twice, 4 bytes apart, from a device-table entry found at
live physical address `041212` during a traced block-copy
(`004114-004120: MOV (R5)+,(R4)+`, destination resolved via the
disassembler's own forward register-value model to `041212`) --
consistent with being a common "default handler" pointer shared by
adjacent device-table slots.

```
021042:  103430               bcs    021124
021044:  010167 021014        mov    r1,042064
021050:  004767 001434        jsr    pc,022510
021054:  000137 001720        jmp    @#001720          ; jumps through a fixed low-memory
                                                     ; CELL, not a fixed CODE address --
                                                     ; its current content (004537, both
                                                     ; live and in the static file) doesn't
                                                     ; disassemble as anything coherent, so
                                                     ; this looks like a patchable vector
                                                     ; whose real target is set by whoever
                                                     ; is ABOUT to dispatch a specific
                                                     ; error, not exercised on every boot
021060:  105067 021004        clrb   042070
021064:  004767 001246        jsr    pc,022336
021070:  016767 016210 020764 mov    037304,042062
021076:  012702 000040        mov    #000040,r2
021102:  004737 001740        jsr    pc,@#001740
021106:  016701 016174        mov    037306,r1
021112:  004767 000474        jsr    pc,021612
021116:  103352               bcc    021044
021120:  004737 001720        jsr    pc,@#001720
021124:  012700 035377        mov    #035377,r0
021130:  012702 000016        mov    #000016,r2
021134:  112762 000176 035376 movb   #000176,035376(r2)
021142:  077204               sob    r2,021134         ; fills 16 table entries with a
                                                     ; fixed byte -- looks like resetting
                                                     ; a 16-entry status/flags table
021144:  105767 020721        tstb   042071
021150:  100421               bmi    021214
```

### Device-table iteration loop (121600 / 123226 / 123240)

Real, meaningful table-walking code: indexes a table via a computed
byte offset (`R3` masked/shifted from `R0`/a device number), looks up
a pointer via `045762(R2)`, and dispatches through it (`JSR PC,123764`)
-- consistent with iterating every configured device slot and invoking
a per-device handler. `020103` = an ASH-based division/shift routine
referenced from here that computes a ratio (candidate for a
capacity/size calculation, given the later `MUL #1000` / `CMP #020000`
pattern seen at 120700-120716 in the same neighborhood).

```
L121600:
121600:  010246               mov    r2,-(sp)
121602:  010346               mov    r3,-(sp)
121604:  042703 000017        bic    #000017,r3
121610:  010305               mov    r3,r5
121612:  042705 177000        bic    #177000,r5
121616:  040503               bic    r5,r3
121620:  062705 045000        add    #045000,r5
121624:  000303               swab   r3
121626:  010302               mov    r3,r2
121630:  042702 177761        bic    #177761,r2
121634:  016202 045762        mov    045762(r2),r2      ; table lookup -- per-device
                                                       ; handler pointer
121640:  001005               bne    121654
L121642:
121642:  105767 116160        tstb   040026
121646:  001021               bne    121712
L121650:
121650:  104400               trap   0o000
121652:  125050               cmpb   @-(r0),@-(r0)
L121654:
121654:  072327 177774        ash    #177774,r3
121660:  120367 124074        cmpb   r3,045760
121664:  103366               bcc    121642
121666:  010346               mov    r3,-(sp)
121670:  004767 002070        jsr    pc,123764           ; dispatch through the looked-up
                                                       ; handler
121674:  062602               add    (sp)+,r2
121676:  005503               adc    r3
121700:  004767 001514        jsr    pc,123420
121704:  012603               mov    (sp)+,r3
121706:  012602               mov    (sp)+,r2
121710:  000207               rts    pc
L121712:
121712:  022626               cmp    (sp)+,(sp)+
121714:  000261               sec
121716:  000207               rts    pc

L123226:
123226:  010003               mov    r0,r3
123230:  042703 000017        bic    #000017,r3
123234:  001423               beq    123304
123236:  004767 176336        jsr    pc,121600            ; -> the iteration loop above
```

### Size/ratio computation (120576-120776 area)

Real arithmetic, not boilerplate: shift-based division loop
(`ASR`/`ROR` pair, the classic software-divide idiom on a CPU that may
lack integer DIV for this operand shape) followed by a `MUL #1000` and
a `CMP #020000` clamp. Reached repeatedly during live single-stepping
of the device-table walk, consistent with computing a per-device
capacity or size figure for display, though the exact quantity was not
identified this session.

```
120576:  006305               asl    r5
120600:  016301 030532        mov    030532(r3),r1
120604:  060501               add    r5,r1
120606:  011101               mov    (r1),r1
120610:  016300 030564        mov    030564(r3),r0
120614:  060500               add    r5,r0
120616:  011000               mov    (r0),r0
120620:  016705 117144        mov    037770,r5
120624:  166701 117136        sub    037766,r1
120630:  005600               sbc    r0
L120632:
120632:  006205               asr    r5
120634:  103403               bcs    120644
120636:  006000               ror    r0
120640:  006001               ror    r1
120642:  000773               br     120632
L120644:
120644:  010167 117106        mov    r1,037756
120650:  005000               clr    r0
120652:  062701 007777        add    #007777,r1
120656:  005500               adc    r0
120660:  073027 177764        ashc   #177764,r0
120664:  010167 117070        mov    r1,037760
120670:  004767 003526        jsr    pc,124422
120674:  010167 117052        mov    r1,037752
120700:  070127 001000        mul    #001000,r1
120704:  020127 020000        cmp    r1,#020000
120710:  101402               blos   120716
120712:  012701 020000        mov    #020000,r1
L120716:
120716:  010167 117032        mov    r1,037754
```

### MMU PAR/PDR save + hardware-probe routine (154266-154550)

The most significant find this session: a full save of every MMU
register set (Supervisor I-space PDR0-7, Kernel I-space PAR0-7, User
I-space PAR0-7, Kernel D-space PAR0-7) into a fixed buffer at
143602-143676, bracketed by installing a **temporary bus-error trap
vector** (address `4`, PC=own minimal cleanup stub, PSW=saved) --
the classic "probe risky memory/hardware, catch the fault harmlessly,
restore real state after" technique, almost certainly RSTS's
memory-size or device-presence detection run once during INIT startup.
Also resets Supervisor I-space's 8 PDRs to a default full-access value
(`077406`) as it saves them, and temporarily clears bit 2 of `SR3`
around the Kernel D-space portion.

This is very plausibly upstream of (or directly feeding) whatever
ultimately produces the "N devices disabled" count, though the exact
connection was not traced this session.

```
154266:  012767 000012 170432 mov    #000012,144726     ; status/counter = 12
154274:  012703 154574        mov    #154574,r3
154300:  012704 000004        mov    #000004,r4          ; r4 = &(bus error vector)
154304:  011446               mov    (r4),-(sp)           ; save old vector PC word
154306:  012724 154550        mov    #154550,(r4)+        ; install: PC = 154550 (a minimal
                                                          ; "cmp (sp)+,(sp)+" stub)
154312:  011446               mov    (r4),-(sp)           ; save old vector PSW word
154314:  013724 177776        mov    @#177776,(r4)+       ; install: PSW = current PSW
154320:  032737 000001 177572 bit    #000001,@#177572     ; SR0 bit 0 -- is the MMU even on?
154326:  001511               beq    154552               ; no -> skip all of this
154330:  012767 000010 170370 mov    #000010,144726       ; counter = 8

; --- save + reset Supervisor I-space PDR0-7 ---
154336:  012703 172300        mov    #172300,r3           ; r3 = &SIPDR0
154342:  012705 143622        mov    #143622,r5           ; r5 = save buffer
L154346:
154346:  011325               mov    (r3),(r5)+           ; save current PDR value
154350:  012723 077406        mov    #077406,(r3)+        ; then RESET it to a fixed
                                                          ; full-access default
154354:  020327 172320        cmp    r3,#172320            ; 8 registers done?
154360:  103772               bcs    154346

; --- save Kernel I-space PAR0-7 (read-only save, no reset) ---
154362:  012703 172340        mov    #172340,r3           ; r3 = &KIPAR0
154366:  012705 143602        mov    #143602,r5
L154372:
154372:  012325               mov    (r3)+,(r5)+
154374:  020327 172360        cmp    r3,#172360
154400:  103774               bcs    154372
154402:  016737 167140 143616 mov    143546,@#143616

; --- save User I-space PAR0-7 ---
154410:  012703 177640        mov    #177640,r3           ; r3 = &UIPAR0
154414:  012705 143662        mov    #143662,r5
L154420:
154420:  012325               mov    (r3)+,(r5)+
154422:  020327 177660        cmp    r3,#177660
154426:  103774               bcs    154420

154430:  013767 172354 167114 mov    @#172354,143552      ; save current KIPAR6 (single word --
                                                          ; this is the live overlay-bank
                                                          ; register this whole session's
                                                          ; overlay-tracing work centered on)
154436:  012737 154534 000004 mov    #154534,@#000004     ; install a SECOND bus-error vector
                                                          ; (PC=154534, a second minimal
                                                          ; cleanup stub) for the riskier
                                                          ; D-space portion below
154444:  032737 000004 172516 bit    #000004,@#172516     ; SR3 bit 2 -- some enable flag
154452:  001431               beq    154536
154454:  013767 172516 167076 mov    @#172516,143560      ; save SR3
154462:  042737 000004 172516 bic    #000004,@#172516     ; temporarily CLEAR SR3 bit 2
154470:  012767 177777 170226 mov    #177777,144724
154476:  012767 000000 170222 mov    #000000,144726

; --- save Kernel D-space PAR0-7 ---
154504:  012703 172360        mov    #172360,r3           ; r3 = &KDPAR0
154510:  012705 143642        mov    #143642,r5
L154514:
154514:  012325               mov    (r3)+,(r5)+
154516:  020327 172400        cmp    r3,#172400
154522:  103774               bcs    154514

154524:  016737 167020 143656 mov    143550,@#143656
154532:  000403               br     154542
154534:  022626               cmp    (sp)+,(sp)+           ; second trap-vector stub body
L154536:
154536:  005067 170162        clr    144724               ; probe complete -- clear status
154542:  012703 154604        mov    #154604,r3           ; r3 -> a small table whose first
                                                          ; word is literally 172354
                                                          ; (KIPAR6) -- continues into
                                                          ; whatever actually restores/uses
                                                          ; the saved state (not traced
                                                          ; further this session)
154550:  022626               cmp    (sp)+,(sp)+           ; first trap-vector stub body
```

### The page-5/6 map+copy primitive cluster (023256, 025006, 025120,
025204) -- the best lead so far toward a real "load overlay N" routine

Prompted by the reasoning that a centralized loader, if one exists,
must live in the always-resident first-loaded part (you can't page in
the code that implements paging). `023256` is called as the first step
of three sibling routines at `025006`/`025120`/`025204`; it is **not**
a caller-argument fetcher (an earlier working theory this session,
corrected here) -- it's a defensive utility that saves `r0`/`r1`/SR0,
resets ALL of Kernel I-space PAR0-7 to a clean identity map, and
restores `r0`/`r1`/SR0 unchanged before returning. So `r0`/`r1` in the
sibling routines are genuinely whatever THEIR OWN caller set up before
calling in -- `023256`'s job is just to guarantee a known-good state
everywhere outside pages 5/6 before they get manipulated.

```
; --- KIRESET: reset Kernel I-space PAR0-7 to identity, preserving r0/r1 ---
L023256:
023256:  010046               mov    r0,-(sp)
023260:  010146               mov    r1,-(sp)
023262:  016746 154304        mov    177572,-(sp)  ; 177572=SR0
023266:  005067 154300        clr    177572  ; 177572=SR0 (MMU off during reset)
023272:  012700 172340        mov    #172340,r0     ; r0 = &KIPAR0
023276:  005001               clr    r1              ; r1 = 0 (identity base)
L023300:
023300:  012760 077406 177740 mov    #077406,177740(r0)  ; PDR = full-access default
023306:  010120               mov    r1,(r0)+             ; PAR = r1, advance
023310:  062701 000200        add    #000200,r1            ; r1 += one page's worth
023314:  020027 172360        cmp    r0,#172360             ; done all 8?
023320:  103767               bcs    023300
023322:  012740 177600        mov    #177600,-(r0)          ; last slot (KIPAR7) =
                                                            ; standard I/O-page passthrough
023326:  012667 154240        mov    (sp)+,177572  ; 177572=SR0 (restore, re-enables MMU
                                                    ; if it was on)
023332:  012601               mov    (sp)+,r1
023334:  012600               mov    (sp)+,r0
023336:  000207               rts    pc

; --- the PARAMETERIZED sibling: both banks caller-supplied ---
L025006:
025006:  004767 176244        jsr    pc,023256        ; -> KIRESET (r0/r1 untouched)
025012:  010037 172352        mov    r0,@#172352  ; KIPAR5 = r0 -- COMPUTED, not a constant
025016:  010137 172354        mov    r1,@#172354  ; KIPAR6 = r1 -- COMPUTED, not a constant
025022:  012737 000001 177572 mov    #000001,@#177572  ; enable MMU
025030:  160100               sub    r1,r0
025032:  100003               bpl    025042
025034:  020027 177600        cmp    r0,#177600
025040:  101011               bhi    025064
L025042:
025042:  012700 120000        mov    #120000,r0
025046:  012701 140000        mov    #140000,r1
025052:  004767 177710        jsr    pc,024766        ; -> block-copy, one direction
L025056:
025056:  005037 177572        clr    @#177572  ; disable MMU
025062:  000207               rts    pc
L025064:
025064:  012700 140000        mov    #140000,r0
025070:  012701 120000        mov    #120000,r1
025074:  012702 004000        mov    #004000,r2
L025100:
025100:  014041               mov    -(r0),-(r1)          ; -> block-copy, OTHER direction
025102:  014041               mov    -(r0),-(r1)
025104:  077203               sob    r2,025100
025106:  000763               br     025056

; --- sibling: KIPAR6 fixed, only page 5 (if any) caller-supplied ---
L025120:
025120:  004767 176132        jsr    pc,023256
025124:  012737 002200 172354 mov    #002200,@#172354  ; KIPAR6 = FIXED 002200
025132:  012737 000001 177572 mov    #000001,@#177572
025140:  000207               rts    pc

; --- sibling: KIPAR6 picked between two fixed values by a size threshold ---
L025204:
025204:  004767 176046        jsr    pc,023256
025210:  026627 000002 020000 cmp    000002(sp),#020000
025216:  103407               bcs    025236
025220:  062766 160000 000002 add    #160000,000002(sp)
025226:  012737 002600 172354 mov    #002600,@#172354  ; KIPAR6 = 002600
025234:  000403               br     025244
L025236:
025236:  012737 002400 172354 mov    #002400,@#172354  ; KIPAR6 = 002400
L025244:
025244:  062766 140000 000002 add    #140000,000002(sp)
025252:  012737 000001 177572 mov    #000001,@#177572
025260:  000207               rts    pc
```

`025006` is the strongest remaining lead toward a real generalized
overlay-loading mechanism found this session: it maps BOTH pages from
caller-supplied register values and then moves data between them. The
open thread is finding `025006`'s own callers, to see what they
compute `r0`/`r1` from (a segment/overlay number, a table lookup, or
something else) -- that's very plausibly the actual "page in segment
N" entry point sitting behind everything else this session found.

### Reconstructing the real load sequence: reads + MAPCOPY_PARAM calls,
in true chronological order

Confirming Faye's own hypothesis ("maybe it just snagged all of it and
swapped it out somewhere else") required combining two passive,
non-disruptive SIMH instrumentation channels into ONE file so they'd
interleave in real chronological order:

  - `SET RL DEBUG=OPS;RWR` -- logs every real RL11 register write and
    disk transfer (`sim_disk_rdsect lbn:... len:...`) with **zero**
    effect on CPU timing (confirmed the hard way: even an
    instantaneous, auto-continuing BREAKPOINT-based approach corrupted
    the RL controller's internal timing and produced a false "device
    hung" HALT that never occurs on an undisturbed boot -- passive
    debug logging has no such effect since nothing ever actually stops).
  - `SET DEBUG <file>` and `SET CONSOLE LOG=<same file>` pointed at the
    SAME filename, so RL debug output and the console output of an
    execute breakpoint's own auto-continuing action (`ex r0; ex r1;
    cont`, fired once per real `MAPCOPY_PARAM` entry at `025006`)
    land in one file in true time order.
  - One real complication: the SAME breakpoint address (`025006`) later
    coincidentally decodes as a completely different instruction
    (`SUB 20(R1),R4`) once some OTHER overlay content gets mapped over
    that virtual window later in execution -- entirely expected paged-
    memory behavior, not a bug. Filtered by keeping only hits whose
    decoded instruction was genuinely `JSR PC,23256` (`025006`'s real,
    unique first instruction).

Result: 22 genuine `MAPCOPY_PARAM` calls, interleaved with the real
reads, revealing a clear repeating cycle:

```
Phase 1 (before ANY disk activity): 10 MAPCOPY_PARAM calls sweep
through 5 bank pairs -- (4000,4200), (1600,2000), (3000,3200),
(3400,3600), (2400,2600) -- almost certainly zeroing/initializing
these banks to a known state, since nothing has been loaded yet.

Phase 2: real chunk reads begin, landing at LOW resident/staging
addresses (022000, 046000, 072000, 116000, 142000, ... -- all within
the 16-bit RLBA-addressable 64K, as expected).

Phase 3 (repeats once per bank pair, 5 times total):
  1. re-read LBN 2 (init.sys's own first block -- almost certainly
     checking a header/version field before processing the next
     segment)
  2. read one real content chunk into a low staging address (110000,
     117000, 143000, 120000, ...)
  3. MAPCOPY_PARAM call for the SAME bank pair seen in phase 1 --
     e.g. (4000,4200) again, then (1600,2000), then (3000,3200), then
     (3400,3600), then (2400,2600)
```

This is a real, repeatable "check header -> load a chunk -> redistribute
a bank pair" cycle, run once per bank pair.

### Physical memory layout: where each loaded piece landed

A second, clean full-boot capture (fresh `combined.log`, no leftover
data from earlier runs) resolved the staging-chunk-to-bank-pair
correlation left open above, by tracking every `RL0 sim_disk_rdsect`
line seen since the previous genuine `MAPCOPY_PARAM` hit. Five bank
pairs, each fed by one shared staging-read burst immediately before the
pair's two copy-out calls:

| bank pair (phys)  | staging LBNs read just before | bytes  |
|--------------------|-------------------------------|--------|
| `0o400000`/`0o420000` | 0, 4, 40, 80, 120, 160, 200 | 57,856 |
| `0o160000`/`0o200000` | 2, 20452, 20518, 20514, 20546, 20562, 20570, 20576, 2, 226, 240, 280, 2 | 25,088 |
| `0o300000`/`0o320000` | 2, 304, 320, 2 | 11,520 |
| `0o340000`/`0o360000` | 2, 346, 360, 2 | 12,544 |
| `0o240000`/`0o260000` | 2, 392, 400, 2 | 7,680 |

The repeated `LBN 2` is `init.sys`'s own first block, re-read as a
header/version check before each new segment, exactly as phase 3
above describes.

**Correction (sector size)**: an earlier version of this section
claimed the `0o160000`/`0o200000` pair's staging LBNs (20452-20576)
were disk-exerciser filler and out-of-container zero-fill, based on a
pack-size mismatch. That was wrong -- it used 512 bytes/sector for the
LBN-to-file-offset math, but RL01/RL02 sectors are 256 bytes (128
words: `RL_NUMWD=128` at `pdp11_rl.c:104`, and `rl_attach` calls
`sim_disk_attach_ex` with sector size `RL_NUMWD*sizeof(uint16)` =
256 -- confirmed directly in source, Faye caught the error: "RL has
256B (128 word) sectors"). At the CORRECT offset (`lbn*256`), this
pack is a full, correctly-sized RL02 (512 cyl x 2 x 40 sectors x 256B
= 10,485,760 bytes, plus a 512-byte SIMH container footer =
10,486,272 bytes total, matching the file exactly), and every one of
those LBNs holds real, structured binary data -- not filler, not
zero-fill. **`pdp11dis/rldma.py`'s `RL_BLOCK_BYTES` had the same bug
(512 instead of 256) and has been fixed.**

**A genuine 11th target, breaking the "always identity on one side"
pattern**: two final `MAPCOPY_PARAM` calls target physical `0o460000`,
but with `PAR5 = 0o510` (phys `0o51000`) instead of the usual `0o1200`
-- i.e. by this point BOTH sides of the copy are non-identity banks,
not "this page's home vs. some staging bank". These two calls are also
preceded by a much larger, messier read burst (315 and 37 reads,
~213KB and ~20KB) dominated by repeated small reads to LBN 2 and to
the same LBN-20000s cluster from the pair above (real content, per the
correction just above) interspersed with reads around LBN 1516-1660,
2488-2492, and 3394-3424 -- the shape of real directory-driven file
lookups (many short reads to a few recurring locations) rather than
one clean sequential chunk. This looks like the point where the
mechanism transitions from "load fixed, known overlay
segments" to "load whatever `INIT.SYS`'s own file-system code decides
it needs next" -- consistent with this being the LAST of the 22 calls
before the
mechanism goes quiet for the rest of the boot (see "Full-boot capture"
below).

Reproducing this capture: `notes/rsts-init-symbols.txt`'s addresses
plus
```
set debug combined.log
set console log=combined.log
set rl debug=OPS;RWR
break -e 25006;ex r0;ex r1;cont
break -e 25120;ex r0;ex r1;cont
break -e 25204;ex r0;ex r1;cont
boot rl
```
against a disposable copy of the disk image (never the working one --
this technique is safe for CPU timing but a breakpoint typo/mistake is
not a reason to risk the real working disk).

**Full-boot capture** (not just up to "devices disabled"): extending
the same idle/prompt-driven wait loop to auto-answer "Proceed with
system startup?" (instead of stopping there) and keep going until 60s
of real quiet, the SAME technique ran the ENTIRE boot to completion --
`*** From [1,2] on KB0...` / `** RSTS/E is on the air...` (genuine
timesharing start) -- with zero false halts across the whole run,
confirming this instrumentation is safe for a complete boot, not just
the early phase. Two findings from the complete capture:

  - **1,061 real disk transfers, 3,451 KB total moved** across the
    whole boot (vs. 703 transfers / 1,762 KB up to just the
    devices-disabled prompt -- so roughly half of all boot-time disk
    activity happens strictly AFTER that prompt).
  - **Still exactly the same 22 `MAPCOPY_PARAM` hits** as the partial
    capture -- meaning ALL of this specific map+copy activity is
    concentrated in the early SYSGEN/INIT phase, and NONE of it recurs
    through these same three entry points for the rest of the boot,
    all the way to real timesharing start. Either the unstaging work
    this mechanism does is fully complete by that point, or later
    phases use a different, not-yet-identified sibling routine this
    session never set a breakpoint on.

### Reusable symbol corpus

Everything named above (plus the boot-block addresses) is now also
captured machine-readably in `notes/rsts-init-symbols.txt`
(`<addr-octal> <name> [; description]` lines), loadable via
`disasm.py -x ... -symfile notes/rsts-init-symbols.txt` to auto-
annotate any future trace with these names instead of bare addresses.
Keep adding to that file as this investigation continues, rather than
re-deriving these names from scratch each session.

---

## Open questions / next steps

1. **"N devices disabled" -- REOPENED.** An earlier pass in this same
   investigation declared this falsified ("LBN 479 is never read"), but
   that check used the wrong RL sector size (512 bytes instead of the
   real 256 -- see the sector-size correction above) for BOTH sides of
   the comparison: the string's LBN was computed wrong (should be
   `958`, not `479` -- byte offset 245420, and `479*512` happens to
   equal `958*256`, which is exactly why the coincidence went
   unnoticed), and the disk-read log's own "never reads it" claim was
   drawn from the same miscalibrated mental model, even though the
   log's own `lbn:` values were always correct (they come straight from
   SIMH's native, correct 256-byte sector numbers -- only my by-hand
   cross-checking used the wrong unit).

   Redone with the corrected LBN: the real transfer covering LBN 958
   (`RLDA=0o2710`, cyl 11 sect 8/head 1, 32 sectors / 8192 bytes
   starting at LBN 928, landing at staging address `0o110000`) DOES
   happen during boot -- and it happens as part of the huge, messy
   final read burst that feeds the LAST (21st/22nd, anomalous
   `PAR5=0o51000`) `MAPCOPY_PARAM` call into physical `0o460000` (see
   "Physical memory layout" above; LBN 928 appears explicitly in that
   burst's read list). The target string sits at byte 7852 within that
   8192-byte transfer (sector 30 of 32).

   NOT yet confirmed: whether this specific content actually survives
   into `0o460000` (vs. being an intermediate scratch read that gets
   overwritten before the copy) or whether the message is assembled
   from this exact byte range at all rather than a nearby one -- the
   next concrete step is a live dump of `0o460000` right after this
   pair's calls, compared byte-for-byte against this transfer's
   content at the corresponding offset.

   **UPDATE (this session, `11orcam` disassembler tooling used to drive
   a live catch): the `0o460000` overlay-bank theory above is now
   believed WRONG for the live print itself.** Caught live with a
   Ctrl-E break the instant the console showed "disabled" (disposable
   copy `/tmp/tsclean7.dsk`, same one used throughout this
   investigation): at that moment SR0 (`177572`) reads `000044` --
   bit 0 (MMU enable) is CLEAR, i.e. the MMU is OFF when this text
   actually appears, which makes a >64K physical bank like `0o460000`
   unreachable at the moment of the print (real/flat 16-bit addressing
   only). The exact three string fragments (`" device"`, `"s"`,
   `" disabled"`, confirmed at file offset `0o735242` in `init.sys`
   directly, matching disk LBN 958 exactly in `/tmp/tsclean7.dsk`) do
   NOT have a duplicate resident copy anywhere under 64K in the file,
   so the live text is most likely assembled character-by-character
   through a print primitive fed some other way (possibly still via a
   brief MMU-on/off bracket around the actual character-emit call, the
   same pattern `MAPCALL_1600_2000`/`MAPCALL_4000_4200` already use
   elsewhere) rather than referenced as a static string constant at
   the moment we sampled state -- a plain PC/SR0 snapshot after the
   fact can't distinguish these, since by the time an external Ctrl-E
   lands, the relevant call has already returned.

   A second, full-boot capture (breakpoints on `025006`/`025120`/
   `025204`/`025262`, auto `ex r0; ex r1; cont`, console log
   interleaved with the breakpoint transcript so order is exact)
   confirms `025262` (`MAPCALL_1600_2000`) is NOT overlay-loading-
   specific at all -- it's hit thousands of times throughout the WHOLE
   boot, well past "Adjusting memory table", with wildly different
   `r0`/`r1` pairs -- it's a generic call-through-a-mapped-page
   primitive used pervasively, not something reserved for the 22
   SYSGEN-phase overlay loads. Immediately before "13 devices
   disabled" prints, `025262` is hit in a tight repeating loop with
   **r1 constant at `041020`** (the same value across ~30 consecutive
   hits) while **r0 cycles through a small set of values**
   (`000110`, `000075`, `000100`, `000103`, `000104`, alternating and
   repeating, not monotonic) -- consistent with once-per-device-slot
   dispatch through a small per-device driver bank, matching
   `notes/rsts-init-symbols.txt`'s `DEVWALK`/`DEVCHK` device-table-
   iteration description. `041020` itself is confirmed, directly from
   the on-disk file, to be all-zero at rest -- i.e. a RUNTIME-BUILT
   scratch table (very plausibly the device-status/disabled-flags
   table itself), not a static string or code address; the small `r0`
   values are NOT ASCII text when decoded (tried; no readable string
   falls out) and don't fit a bank-physical-address pattern either
   (too small/inconsistent for a `PAR*0o100` staging address) --
   most likely per-device small integer codes.

   NOT yet confirmed: the exact meaning of the small r0 codes, what
   `025262`'s own r0 parameter is really used for structurally (its
   own disassembly was never pulled the way `025006`/`025120`/`025204`
   were above), or the actual counting/print call itself (still not
   caught mid-execution -- only ever sampled just after it returns).
   The natural next step, now that `025262` is confirmed as the real
   proximate caller for this specific message, is disassembling
   `025262` itself in full (parallel to the `023256`/`025006` listing
   above) and setting the live breakpoint AT `025262` with a filter on
   `r1==041020` (SIMH breakpoint action can conditionally re-`cont`
   only when NOT matching, stepping into the routine on the real hits)
   rather than intercepting after the fact via Ctrl-E.
2. **How overlay banks actually get their content**: RESOLVED for 4 of
   the 6 known bank pairs with genuine file content -- see "Physical
   memory layout" above for the exact staging LBNs behind
   `0o400000`/`0o420000`, `0o300000`/`0o320000`, `0o340000`/`0o360000`,
   and `0o240000`/`0o260000`. The `0o160000`/`0o200000` pair turned out
   NOT to be file content at all -- its "staging reads" are `INIT.SYS`
   probing past the RL01/RL02 cylinder boundary (255->256->257), most
   of which lands on disk-exerciser filler bytes or, past cyl 255,
   entirely outside this container's real 20,480-block extent (SIMH
   synthesizes zero for those rather than erroring) -- almost certainly
   pack-size auto-detection, not a load. Ruled out for the 4 genuine
   pairs: simple file-offset-relative-to-
   INIT.SYS's-own-LBN-range reads (the real LBNs are scattered, not a
   contiguous run), and a single large multi-block DMA burst covering
   the whole file -- provably impossible, in fact: `init.sys` is
   318,464 bytes, LARGER than the entire 256KB (18-bit) unmapped-DMA
   window, so it cannot fit as one contiguous blob regardless of
   placement. The RL11's DMA address is confirmed 18-bit at the shared
   UNIBUS busmaster interface (`rtl/unibus.vhd:409`), so reaching
   physical addresses beyond 256KB requires the UNIBUS map (`mmu.vhd`'s
   `ubmmaddr` path, real registers at physical `17770200-17770374`,
   matching the actual 11/70's documented `770200-770376` range) to be
   both enabled (`SR3` bit 5) and actually programmed -- checked live
   once: bit 5 WAS set but every map register read zero, and all known
   overlay banks (up to `0o460000`) sit comfortably under 256KB anyway,
   so nothing observed this session has actually required the map.
   Still open: the final, non-identity-paired call into `0o460000` (see
   above) is fed by a much messier, directory-lookup-shaped read
   pattern that hasn't been correlated to a specific file the way the
   other 5 pairs were -- finding `025006`'s callers remains the natural
   next step to understand what actually selects each pair's content
   rather than continuing to chase disk reads directly.
3. **RSTS genuinely uses ED=1 (downward-expanding) MMU pages** during
   normal execution -- confirmed live (`KIPAR1`, `KIPAR4` both ED=1 at
   a point during ordinary boot). This remains the strongest surviving
   hang hypothesis from this whole line of investigation: 2.11BSD (this
   project's own gold-standard gate) may never exercise that path,
   hiding a latent bug. `mmu.vhd`'s `abort_pagelength` logic was checked
   against the Processor Handbook's own worked example and found
   correct on this specific comparison, but that doesn't rule out a
   subtler issue elsewhere in the downward-page path.
4. **Tooling**: `~/Source/11orcam`'s `pdp11dis` package now supports
   multi-file/MMU-aware address mapping, whole-file string scanning,
   automated entry-point discovery (`-scan`), block-copy-loop detection,
   and bounded branch-refined register-value tracking (push/pop state at
   conditional branches, refined by a preceding `CMP reg,#imm`) -- see
   its own module docstrings for details. Reusable for continuing this
   investigation or any similar RSTS/RT-11 reverse-engineering task.
