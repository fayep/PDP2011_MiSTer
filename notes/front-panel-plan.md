# On-screen 11/70 front panel: design note

Status: plan only, nothing implemented. Written 2026-10-02 against
`orig-plus-fixes` at eca62bd (release-20261002).

## Goal

An alternate video view showing a PDP-11/70 front panel, like the console
view in the PDP-1 core. Requirements:

- **Real lamps:** driven by the CPU's existing console "loom" (the `cons_*`
  ports), not by a model of the panel.
- **Working switches:** the switch register, LOAD ADRS, EXAM, DEP, CONT,
  ENABLE/HALT, S INST, START and both rotary knobs, all fed back through the
  same loom.
- **No new clock-domain crossings:** everything is clocked from `clk_100`, or
  from cpuclk, which `clk_100` generates at fixed phases. STA must check every
  path, and nothing may rely on luck.
- **No debug machinery:** nothing from the mainline debug work (tracecap, PC
  breakpoints, `pdp-odt` panel hooks). Inspiration only, as with the RL fixes.

## How the PDP-1 core does it

Reference: <https://github.com/MiSTer-devel/PDP1_MiSTer>, `src/pdp1_vga_console.v` and `src/pdp1.sv`.

- **Clocks:** the CPU runs on `CLK_50M`. All video (Type 30 CRT, console
  view, teletype) runs on one 108 MHz PLL clock at 1280x1024@60, with
  `VGA_CE = 1`.
- **Background:** `console_bg.mif` holds the panel drawn in Inkscape as a
  1-bit image. It's read 32 pixels per ROM word, and a set bit is white,
  otherwise the panel blue.
- **Lamps and switches:** drawn on top procedurally on a 32-pixel grid.
  `is_circle_12` (bulbs) and `is_circle_8` (switch knobs) are quarter-circle
  lookup tables mirrored into four quadrants. A bulb's color is just its
  register bit.
- **Lamp data:** the CPU registers are copied into the 108 MHz domain once
  per frame, at `vertical_counter == v_line_timing`. That's a multi-bit
  crossing **without synchronization**. It works by luck and statistics,
  which is what we want to avoid.
- **Switches:** the keyboard (on 50 MHz) moves a cursor (`selected_ptr_x/y`)
  and Enter strobes a toggle. The strobe is edge-detected through two
  registers in the 108 MHz domain. The switch registers live in the video
  module and feed the CPU, another crossing.
- **Views:** F4 cycles a final RGB mux between CRT, console and teletype.
  That's trivial because all three views share one clock and one timing
  generator.

Keep from it: the background ROM plus procedural lamps and switches, the
grid layout, the cursor UI and the single-timing-generator mux. Don't keep:
the 50/108 MHz split and the unsynchronized register copies.

## What this core already has

### The loom, and a panel driver on it

`unibus` exports the full 11/70 console interface, and `mister_top`
already wires all of it to Sytse's PiDP-11 driver `rtl/paneldriver.vhd`
(instance `panel`, around `mister_top.vhd:692`). Its matrix pins are `open`
and it has `paneltype => 0`, which means "no console".

| Signals | Panel function |
|---|---|
| `cons_consphy`, `cons_progphy` (22 bits) | ADDRESS lamps (console physical, program physical) |
| `cons_shfr`, `cons_br`, `cons_dr`, `cons_maddr` (16 bits) | DATA lamps (data paths, bus register, display register, micro address) |
| `cons_run`, `pause`, `master`, `kernel`, `super`, `user`, `id`, `map16/18/22`, `parh`, `parl`, `adrserr` | status lamps |
| `cons_sw` (22 bits) | switch register |
| `cons_load`, `exa`, `dep`, `cont`, `start` | momentary switches, one cpuclk pulse each |
| `cons_ena`, `cons_inst` | ENABLE/HALT, S INST / S BUS CYCLE |
| `cons_adss_mode`, `cons_adss_id`, `cons_adss_cons` | ADDRESS knob selection, into the CPU |

`paneldriver` already does everything a real panel needs, all on cpuclk:

- **Lamp integration:** for each lamp it counts how many cycles out of
  `sample_cycles` (x"0400", 1024 cpuclk, about 143 us) the signal was on, and
  lights it if the count exceeds `minon_cycles`. The results are the
  `temp_addr`, `temp_data` and `temp_*` registers.
- **ADDRESS knob:** `rotary1_bin` (0..7) maps to `adss` (the lamp source) and
  to `cons_adss_*` (into the CPU). The positions are PROG PHY, CONS PHY,
  KERNEL D, SUPER D, USER D, USER I, SUPER I and KERNEL I.
- **DATA knob:** `rotary2_bin` (0..3) maps to `ddss`, selecting data paths,
  micro address, display register or bus register.
- **Knob lamps:** the lamps showing each knob's position.
- **Momentary switches:** `panelos` edge-detects to one cpuclk pulse.
- **Defaults:** with `paneltype = 0`, `cons_ena` = '1' (ENABLE) and every
  momentary is '0'.

### The clocks are already where we want them

- **`clk_100` already runs everything we need:** `CLK_VIDEO`, `hps_io`
  (`clk_sys`, so `ps2_key`, `status[]` and the OSD), `sd_card` and the DRAM
  state machine that generates cpuclk.
- **cpuclk:** a 140 ns generated clock (`pdp2011.sdc`, edges {1 15 29}).
  Its rise ends `dram_c1` and its fall ends `dram_c8`.
- **SDC multicycles in place** (honest constraints since release-20261003,
  every exception says `-start`/`-end`): `cpuclk -> divclk`
  `-setup -end 5 / -hold -end 4` for all paths, and `divclk -> cpuclk`
  `-setup -start 3 / -hold -start 2` for the `dati[*]` registers **only**.
  Everything else `divclk -> cpuclk` must meet a single period or be a
  false-pathed synchroniser.
- **Caution, falling edge:** `cpuclk -> divclk -setup -end 5` is right for
  registers launched on the cpuclk rise. The NPR arbiter and the RH70 run on
  `nclk` (the fall, the edge ending `dram_c8`), and for those the `dram_c12`
  sample is only 40 ns away, not 50. It had 11.8 ns to spare on
  2026-10-03 builds, but the exception over-allows it. Anything new launched
  on `nclk` needs its own exception.
- **The only foreign domain is the VT's pixel clock.** `vga.vhd` toggles
  `vgaclk` on `clk_50` (25 MHz). It uses that both as a clock and as
  `ce_pix`, which `CE_PIXEL` then samples in the `clk_100` video path. STA
  reports it as an unconstrained clock. VT timing is 640x480@60 (800x524
  total).

### Room

The release build uses 100 of 553 block RAMs (11% of the bits), 45% of the
ALMs and 32 of 112 DSPs, so there's plenty for a background ROM and a
renderer.

## Design

```
                 cpuclk domain                       clk_100 domain
   unibus ── cons_* ──> paneldriver ── lamps ─[A]─> panel_view (renderer) ──┐
          <─ cons_* ──  (paneltype 4)  <─ sw ──[B]── panel_input <─ ps2_key │
                                                         ^    status[] (OSD) │
                                                   vt ───────────────────── mux ─> VGA/HDMI
```

### 1. `paneldriver` gets a virtual panel type

Add `paneltype = 4` ("MiSTer virtual panel"). Keep the lamp integration,
knob decoding, `panelos` one-shots and defaults unchanged. Change only the
two ends.

- **Inputs:** a new port `vpanel_sw` replaces `panel_sw_raw1..3`:
  - 22 switch-register bits;
  - LOAD, EXAM, DEP, CONT, ENA, INST, START;
  - ADDRESS knob position 0..7 and DATA knob position 0..3.
  
  For type 4 these go straight to `rotary1_bin`/`rotary2_bin` instead of the
  quadrature state machines, and skip `paneldb`, since a virtual switch
  doesn't bounce.
- **Outputs:** a new port `vpanel_lamps` exports what would otherwise drive
  `panel_col`:
  - `temp_addr` (22) and `temp_data` (16);
  - the status lamps;
  - one-hot `adss` (8) and `ddss` (4) for the knob lamps.
  
  All are registers updated on cpuclk.

That keeps exactly the behavior a PiDP-11 owner sees. The paneldriver
signals are already in `mister_top`'s `dont_retime` list (`sample_cycles`,
`minon_cycles`), and the qsf turns retiming off for all of `emu`.

**Optional, graded brightness:** export the high bits of each lamp's
on-count instead of the thresholded bit, so the renderer can draw an
incandescent 0..7 brightness. That gives the real 11/70 shimmer, such as the
DATA lamps glowing half-lit while running. It costs about 50 lamps x 3 bits
of extra latches.

### 2. Crossing [A], lamps from cpuclk to clk_100

`vpanel_lamps` is launched on the cpuclk rise (the edge ending `dram_c1`).
`panel_view` registers it in `clk_100` with an enable in one fixed DRAM
state, `dram_c8`, 7 divclk periods after the launch.

- **Already covered by the SDC:** this is exactly the relationship the
  existing `cpuclk -> divclk -setup -end 5 / -hold -end 4` covers (for rise-launched
  registers: keep `vpanel_lamps` off `nclk`). The row-address
  capture at `dram_c6` is the tighter case, so STA checks it with margin and
  no new constraint is needed.
- **Implementation:** `mister_top` can export a one-cycle `dram_c8` strobe
  to the renderer, or the renderer can sit inside `mister_top` next to the
  state machine.
- **Tear-free:** after this capture, a second copy is taken during vertical
  blanking, so a frame never shows half-updated lamps.

That's the PDP-1 core's per-frame copy, but from a source that's constrained
and stable at the sampling edge.

### 3. Crossing [B], switches from clk_100 to cpuclk

`panel_input` keeps the switch state in `clk_100`. It drives `vpanel_sw`
from a register that updates only with an enable at the edge ending
`dram_c12`, the same edge `dati` uses.

- **Constraint:** this is exactly the existing
  `dati` relationship, but the SDC's `-setup -start 3 / -hold -start 2` names
  `dati[*]` only, so `vpanel_sw` needs the same pair of exceptions added for
  its own registers. It's 3 periods to the
  next cpuclk rise, and the hold relaxation is valid because the register
  changes at most once per cpuclk period.
- **Momentaries:** a key press holds the level for about 100 ms, which also
  reads as a visible press on screen. `panelos` turns that into a single
  cpuclk pulse.
- **Power-up and reset state:** ENABLE, S INST off, SR = 0, ADDRESS knob on
  PROG PHY (the real 11/70's usual position), DATA knob on DATA PATHS. With
  these, a core that has never shown the panel behaves exactly as today, so
  the boot/regress cycles are unaffected.
- **OSD-sourced bits:** where an OSD item drives a panel bit (for example
  "Halt switch"), it goes through this same register. `status[]` is
  false-pathed on the assumption "changes only before a reset", which isn't
  true for a live switch. Re-registering it in `clk_100` (the same domain,
  just quasi-static) and then crossing at `dram_c12` keeps the cpuclk-side
  path constrained.

### 4. Input UI

`ps2_key` from `hps_io` is already on `clk_100`. Proposed layout,
PDP-1-style, with every key active only while the panel view is shown:

- **cursor keys:** move along the switch register (bits 21..0, with octal
  grouping on screen);
- **Space or Enter:** toggle the selected switch;
- **0..7:** shift an octal digit into the switch register (quick entry);
- **F-keys:** LOAD ADRS, EXAM, DEP, CONT, ENABLE/HALT toggle, S INST toggle
  and START;
- **PgUp / PgDn and Home / End:** turn the ADDRESS and DATA knobs;
- **one hotkey:** toggle Terminal / Panel view, also available as an OSD
  item.

The VT receives the keyboard as emulated PS/2 serial (`ps2k_c`/`ps2k_d`,
from `hps_io` `ps2_kbd_*_out`). While the panel is shown, those keys must
not reach the VT. Gate the PS/2 clock only at frame boundaries (when the
line is idle), so the VT's decoder never sees half a byte. Pick the hotkey
from keys the VT keymap doesn't use; check `rtl/vt.vhd` and `rtl/ps2.vhd`
before choosing.

Later, a gamepad could map to the momentaries, and `cons_reset` (the PiDP-11
two-switch reset combo) could become an OSD item.

### 5. Renderer, `panel_view` on clk_100

- **Timing:** 640x480@60 with `CE_PIXEL` every 4 `clk_100` cycles (25 MHz).
  That's the same mode as the VT, so switching views doesn't make the MiSTer
  scaler relock. If the panel needs more pixels, 800x600@72 (CE every 2,
  50 MHz) is the fallback, at the cost of a relock on each switch.
- **Layout:** fit the real 11/70 panel into 640 pixels with 28 px per
  switch/lamp column (22 columns plus margins). Keep the 11/70 color bands
  (alternating purple/magenta groups of three) and the lamp rows ADDRESS,
  DATA and status, with the knobs on the right.
- **Background:**
  - Preferred: a 1-bit legend/line mask (640x480 = 300 kbit, about 30 M10K),
    with the color bands generated from the column number. It's crisp and
    cheap.
  - Alternative: a 4-bit palette image (1.2 Mbit, about 150 M10K) if we have
    licensed artwork to convert.
- **Lamps:** circle lookup tables as in the PDP-1 core. Color is a warm
  incandescent palette, indexed by the graded brightness if we build that.
- **Switches:** two sprites (up/down), plus a cursor highlight.
- **Knobs:** a pointer drawn from the position (8 or 4 angles), plus the
  knob-position lamps, which come from `adss`/`ddss`.

### 6. View switching

- **Phase A, view mux:** mux `{R,G,B,HS,VS,DE,CE}` between the VT and the
  panel at the end of `pdp2011.sv`. Since the panel copies the VT's mode,
  the switch is close to seamless, but the two timing generators aren't
  phase-locked, so a frame may glitch on the switch.
- **Phase B, VT onto `clk_100`:** clean up the VT clocking. Replace the
  `clk_50` toggle `vgaclk` with a `clk_100` CE every 4 cycles, and have the
  VT and the panel share one timing generator. Then the switch is a pure RGB
  mux like the PDP-1, and the VT's unconstrained `vgaclk` warning disappears.
  
  This touches `vga.vhd` (one VT feature at a time), so it must pass the VT
  visual check and the full boot cycles on its own.

### 7. Drive panel (added 2026-10-03)

A row of drive operator panels under the CPU panel, so disk and tape
activity is visible as it happens. Motivation: chasing the RSTS/E 10.1
INIT trap, the question "did the RP go not-ready during that overlay load?"
would have been answered at a glance.

**Lamps come from controller state that already exists** (the always-present
controllers added per-controller `*_img_mounted` online flags; the RH work
added GO/RDY/DRY and the block-device handshake). Each controller exports a
small lamp vector on cpuclk, launched on the **rising** edge (re-register the
RH's `nclk` signals once on `clk` first), crossing to `clk_100` exactly like
[A]. Access lamps (READ, WRITE, SEEK) are pulse-stretched in the controller
to about 50 ms so a single 512-byte block still shows; status lamps (READY,
ONLINE, PROTECT) are levels.

| Drive | Lamps | Switches (OSD or panel keys, via [B]) |
|---|---|---|
| RP06 (RH70) | READY (DRY and MOL), FAULT (DS.ERR / ATA with error), ATTN (ATA), WRITE PROTECT (WRL), READ, WRITE | START/STOP (spin up/down = online), WRITE PROTECT |
| RK05 (RK11) | PWR, RDY, ON CYL, FAULT, WT PROT, LOAD, WT, RD | RUN/LOAD, WT PROT |
| RL02 (RL11) | LOAD, READY, FAULT, WRITE PROT | LOAD, WRITE PROT |
| TU10 (TM11) | SELECT, ON-LINE, LOAD POINT (BOT), END POINT (EOT), WRITE ENABLE, FWD/REV | ON-LINE/OFF-LINE, REWIND |

Unit lamps only for units that exist (one RP, one RK, one RL, one TU today);
the layout should leave room for more units per controller.

**Switch semantics must match the drives**, not just toggle a bit:

- **RP START/STOP:** going offline = what an unmounted image does today
  (MOL=0, VV cleared, UNS on commands). Coming back up must behave like a
  real RP04/06 cycle-up (RJP04 maintenance manual 3.6.8): **set ATA and reset
  VV**, so the OS sees attention and must pack-acknowledge. Note the current
  RH sets VV by itself when an image is mounted ("no OS needs a pack
  acknowledge for a mounted image"); a panel cycle-up should follow the
  manual instead. Never take a drive offline under a transfer: offline
  waits for GO to clear (the same bracketing rule as RDY/DRY).
- **WRITE PROTECT:** RH `rmds_wrl` (DS.WRL; writes fail with WLE), RK and RL
  equivalents. A level, applied between commands.
- **TM REWIND / ON-LINE:** only when the drive is not busy.
- All switch levels cross through [B] and are sampled by the controller only
  when it is idle (GO clear), so a panel action can never land in the
  middle of a transaction.

**Reference:** RP05/RP06 DCL maintenance manual EK-RP056-MM-01 (DS bits,
DRY table 2-1) and RJP04 subsystem maintenance manual DEC11-HRJPA-B-D
(operator switches 3.6.8, RDY/DRY 4.x), on bitsavers under
`pdf/dec/disc/rp04_rp05_rp06/` and `pdf/dec/disc/rp04/`. Verify the RK05,
RL02 and TU10 lamp sets against their own manuals before drawing them.

### 8. Phase C: dashboard view (added 2026-10-04)

Inspiration from the user: one screen with the terminal, the CPU panel,
the drive buttons and a tape deck together, instead of switching views.

- **Mode (user, 2026-10-04): 1920x1080 if doable, else 1280x720.**
  Preferred route: the **MiSTer framebuffer** (`MISTER_FB`, `FB_EN/FB_BASE/
  FB_WIDTH/...` in pdp2011.sv; DDRAM_* is unused in this core today). The
  core renders into DDR3 only when something changes (a lamp, a character,
  a reel frame) and the scaler shows it at full HDMI resolution: no
  148.5 MHz pixel pipeline to close timing on. Fallback: native 1280x720@60
  (74.25 MHz pixel clock from a video PLL output).
- **Layout (user): picture-in-picture.** One view full screen (terminal by
  default, at a crisp native size), the others as windows; a hotkey cycles
  which is large. Simpler than a fixed dashboard grid.
- **Terminal pane:** the renderer reads the VT's character and attribute
  buffers through a second read port and draws 80x24 with the existing
  font ROM (`vgafont`), same colours as the VT's OSD setting.
- **CPU panel pane:** as steps 1-4, plus styling: cream bezel, `digital`
  logo, labelled lamp groups, the two rotary knobs drawn. **Palette option:**
  11/70 (purple / magenta, authentic) or "classic" (red / white / orange,
  as in the inspiration image and the 11/40-era panels).
- **Drive buttons:** section 7's drive panel as illuminated push-buttons
  (RK0, RL0, RH0, MT0 ...), colour = state: green ready, amber busy
  (transfer in progress, pulse-stretched), red fault / offline, dark = no
  image. The button doubles as the drive's START/STOP or LOAD switch.
- **Tape deck:** TM11 reels animated from the TM's motion state (forward,
  reverse, rewind = fast, stopped), a handful of sprite frames per reel;
  BOT / EOT / ON-LINE lamps underneath.
- **Activity graphs:** counted in the FPGA, so no Linux help: blocks/s per
  controller and hps latency (sd_rd -> sd_ack time, max and average per
  second), as scrolling bar graphs. These are diagnostics too: they would
  have shown the install-time hps stalls directly. FPGA temperature would
  need MiSTer_pdp2011 (Main) to pass it down; later, optional.

## Timing and fit

- **No new clocks.** All new registers are on `clk_100` or cpuclk, so no SDC
  changes are expected beyond what [A] and [B] already reuse.
- **Must stay at zero:** `check-fit.sh` (retimed registers) and negative
  slack, just as for release-20261002.
- **Placement:** the renderer is pure `clk_100` logic with a lot of slack
  (25 MHz pixels), so register its outputs before the mux so it doesn't
  compete with the DRAM state machine.

## Steps

Each step is a separate commit and build. Each must close timing (no
negative slack), pass `check-fit.sh`, and pass `regress/rsts_cycle.py`
(RSTS 9.6, RP and RL) and `regress/bsd_cycle.py` (2.11BSD).

1. **Renderer, static.** `panel_view` with a test pattern and the
   background, behind an OSD "Video: Terminal / Front panel" (Phase A mux).
   *Check:* both views look right, and the OS cycles are unaffected.
2. **Live lamps.** `paneltype 4` outputs plus crossing [A]. The switch input
   is tied to the defaults.
   *Check:* RUN / ADDRESS / DATA lamps move while RSTS runs, the knob lamps
   show the default positions, and the cycles pass.
3. **Switches and knobs.** `panel_input` plus crossing [B] and the keyboard.
   *Check:*
   - HALT stops the CPU and CONT resumes it;
   - LOAD ADRS / EXAM / DEP read and write memory;
   - the knobs change the ADDRESS and DATA lamps;
   - toggling in and starting a tiny program from the switches works (the
     classic test);
   - the cycles pass with the panel never touched.
4. **Graded brightness** (optional).
5. **Phase B**, moving the VT onto `clk_100` (optional, separate).
6. **Drive panel lamps** (section 7): per-controller lamp vectors, pulse
   stretch, crossing [A], drawn under the CPU panel.
   *Check:* lamps follow a boot (RP READY drops during transfers, READ
   flickers), and the cycles pass.
7. **Drive panel switches:** START/STOP and WRITE PROTECT per drive, via [B],
   applied only when the controller is idle.
   *Check:* a stop/start cycle under RSTS gives ATA and needs a pack
   acknowledge; write protect gives WLE; no transfer is ever cut short.

## Open questions

- **Drive panel placement:** under the CPU panel in the same view, or a
  third view (Terminal / CPU panel / Drives)?
- **Cycle-up VV:** should mounting an image from the OSD also follow the
  manual (ATA set, VV reset), or keep today's convenience (VV set on mount),
  with only the panel START switch behaving like the hardware?

- **Artwork:** procedural (mask plus generated bands), or a converted image?
  Is there 11/70 or PiDP-11 panel artwork we're licensed to use?
- **Resolution:** 640x480 to match the VT (recommended), or 800x600 for a
  sharper panel?
- **Hotkey and key layout:** confirm against the VT keymap and the user's
  habits.
- **Shared panel state:** should the panel's switch state survive a core
  reset (like a real panel) or reset to the defaults? Recommended: survive,
  except at power-up.
