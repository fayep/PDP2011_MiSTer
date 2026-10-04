# integ/blinkenlights: integration and soak results

Branch `integ/blinkenlights` (worktree `~/Source/PDP2011_MiSTer-integ`), build
`a81c974` (worst slack +0.068 ns, check-fit OK), tested 2026-10-04.

## What is in it

On top of the release line (`orig-plus-fixes` = release-20261003, `32fd0e7`):

- **Front panel, steps 1-2** (`feature/front-panel`):
  - `rtl/panel_view.sv`: the on-screen 11/70 panel on clk_100, in the VT's
    exact video mode;
  - live lamps from the console loom (paneldriver type 4, crossed into clk_100
    at `dram_c8`, latched per frame);
  - OSD "Video: Terminal / Front panel"; PrintScreen flips the view.
- **Reset:** `reset` registered once on clk_100 before `mister_top` (the
  por_cnt -> DRAM state machine path had only 0.47 ns in the release and
  failed once the panel shared the area); paneldriver on `cpureset_cpu`.
- **RH70 fixes** (`fix/rh-bracket`):
  - DS.DRY low while the drive is busy (RP05/06 manual table 2-1, RJP04 manual
    3.4);
  - a GO to a non-existent unit is dropped (NED);
  - a data transfer issued while the controller is busy sets CS2.PGE (SIMH
    `mba_wr`).
- **Exercisers** (`tools/rhex`):
  - `rhex`, `rhextm`, `rhexw`: RH70 with RSTS/E 10.1 INIT's command sequence,
    background TM11 load, salted writes;
  - `rhexf`: RH70 whole pack, explicit seeks, interrupts;
  - `rlex`: RL11 whole pack, seeks, interrupts, writes.
- **`regress/fresh_disks.sh`:** resets the regression disks from their GA
  images with `resilver` before a run.

## Results on a81c974

| Test | Result |
|---|---|
| tb_rh11_bracket / tb_rh11_abort / tb_rh11_blkdev (GHDL, RH70 + RH11) | 317/317, 15/15, 42/42 |
| Regression (fresh GA disks): RSTS 9.6 RP, 2.11BSD RP, RSTS 9.6 RL, tape boot, XXDP RK | 5/5 PASS |
| RSTS startup errors: RP 0; RL 5, identical to SIMH on the same GA (the RL GA is a nearly full disk) | as SIMH |
| rhexf soak (full-size RP06): format 815 cyl, then 173056 transfers incl. 43264 salted writes, seeks, interrupt rounds | 0 errors |
| rlex soak (RL02, already formatted): 228352 transfers incl. salted writes and interrupt rounds | 0 errors |
| Front panel on a81c974: ADDRESS shows 17776700 (the exerciser polling RH CS1), RUN + KERNEL + 16-bit lit, DATA changing between frames (notes/integ-blinkenlights-panel.png) | live |

## Found along the way

- **RP06 image size:** a full RP06 is 174423040 bytes. Most RSTS RP images
  here (and every scratch made with `truncate -s 174419968`) are 6 sectors
  short; MiSTer Main silently drops writes past the end of an image and reads
  zeros there. That was the exerciser's "last block" mismatch: not the RH.
- **RL regression disk:** the RSTS 9.6 RL GA starts with "No room for user on
  device" and four missing-RTS messages, in SIMH too. Judge RL runs against
  that baseline.
- **macro11:** needs `.enabl ama` for standalone programs (no linker); an
  invalid octal digit (`24680` without a dot) hangs it forever.

## Open

- **RSX-11M-PLUS on RL:** SAV rejects the booted RL ("Booted device not in
  system - DL 174400") on every build, release included; SIMH boots the same
  disk. The RL load is word-identical to SIMH; the difference is a console
  (TT) retry path that runs before SAV's check on the core. Task 14 has the
  details; next step is a whole-system GHDL run from a SIMH snapshot.
- **RSTS/E 10.1 install trap** (overlay 16 never loaded): not reproduced by
  any exerciser; still needs a trapping install with a capture build that
  does not alter the RH.
