# TM11 magtape — the SIMH device gate

Before writing any VHDL, the question was: does the tape-test guest
(RSX-11M 3.2) probe **MS:** (TS11) or **MT:** (TM11)?  That decides the
FPGA device.  Answer from SIMH: **TM11**.

## Booting RSX-11M 3.2 under SIMH (magtape device gate, Sep 2026)

`expect(1)` (event-driven, matching on prompts -- *not* `sleep`-timed
piping, which loses console chars) is the reliable way to drive an RSX
boot here. `spawn /opt/homebrew/bin/pdp11 gate.ini`, then match
`"Enter date and time"`, `"LOGGED OFF"`, `"PASSWORD:"`, `"GOOD
AFTERNOON"`, `-re "\r\n>"`.

Working image: `files11/tests/RSX11M3.2_RL02.dsk` -- despite the name
it is a 10 MB **RL01**. `set cpu 11/70` (11/45 and 11/34 crash at
`SYSTEM CRASH AT LOCATION 021776` on the date prompt). Boots to
`RSX-11M V3.2 BL26  128K  MAPPED`.

The Nankervis 20 MB `RSX11M3.2_RL.dsk` (RL02) does **not** boot under
SIMH: its VBN 0 bootstrap self-relocates, probes RL at 174400, then
runs past its own code into zero-fill and HALTs at PC 001440. Only
Nankervis's own JS emulator loader ever booted it.

Login: `HEL 1,1` / password `SYSTEM` (`[1,2]` = INVALID ACCOUNT).
`[1,2]STARTUP.CMD` ends with `BYE`, so the console is logged off by the
time you get a prompt -- log back in before `DEV`.

Magtape finding: this sysgen has **no tape device** (`DEV` shows only
DB0/DB1 RP04, DL0-3). The distribution carries `[1,54]MTDRV` (TM11,
MT:) and `[1,54]MMDRV` (TM02/03, MM:) but **no MSDRV** -- TS11/MS: is
not part of RSX-11M 3.2 BL26. The prebuilt drivers won't `LOA`
(`DRIVER BUILT WITH WRONG EXECUTIVE STB FILE`, 1979 driver vs 1981
exec) and the image has no driver `.ODL`/`.OBJ`/`.OLB` to rebuild them,
so a live CSR probe needs a full SYSGEN from the source kit. Device
identity for the FPGA is nonetheless unambiguous from the driver set:
**TM11, MT:, CSR 172520, vector 224** (or MM:/TM03 on the RH).
