# Before touching real MiSTer hardware or starting a "known" investigation

These are hard gates, not suggestions. They exist because both were
skipped in a real session (2026-09-10) and cost hours: a full
MMU/timing investigation was run against boot captures where the disk
was never actually mounted, and a boot-procedure note that already
existed in `memory/` was ignored anyway.

1. **Never `load_core` a bare `.rbf` on the MiSTer.** It only reloads
   the FPGA bitstream (`fpga_load_rbf()` in Main_MiSTer_pdp2011) and
   does NOT mount any disk. Always load an `.mgl` (which triggers
   `xml_load()`, the real mount handshake). If no `.mgl` exists for
   the rbf under test, write one first — see
   `memory/feedback_mister_boot_procedure.md` for the exact recipe
   (resilver -> bounce menu.rbf -> load the `.mgl` -> stty
   `min 1 time 0` -> real date/time strings, not bare CR).

2. **Before starting work on a recurring/named bug** (grep for its
   name — e.g. "RSTS V9.6 hang", "RH70", "XBUF") **run
   `grep -rln <keyword> memory/*.md notes/*.md`** and actually read
   what comes back before forming a new theory or re-tracing from
   scratch. Don't rely on having read a file once earlier in the
   conversation — re-grep, every time, even mid-session.

3. **Tools that already exist for this repo's RSTS/INIT work** — check
   these before building a new one:
   - `~/Source/files11` (Go): read/extract files directly from a
     `.dsk` image without booting anything (`files11 <image>` lists,
     `-c "[g,u]FILE" <image> <dest>` extracts).
   - `~/Source/11orcam` (`disasm.py`): PDP-11 disassembler, including
     recursive-descent mode (`-x`) that follows real control flow.
   - `notes/rsts-init-disasm.md`, `notes/rsts-init-symbols.txt`,
     `notes/rsts-init-macros.mlib`: prior INIT.SYS reverse-engineering.
   - `pdp-odt` (SSH front panel, `/media/fat/Scripts/pdp-odt`, talks to
     `/tmp/pdp2011.odt`): `halt`, `run`/`cont`, `step`, `peek`, `poke`,
     `r7 <oct>` on the live real-hardware CPU.
