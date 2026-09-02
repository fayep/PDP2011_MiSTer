# TM11 magtape — implementation plan

Guest gate (done): RSX-11M 3.2 BL26 carries `MTDRV` (TM11, MT:) and `MMDRV`
(TM03), no `MSDRV`. Target device is **TM11**, CSR 172520, vector 224, BR5,
Unibus, read-only for v1. TS11 (`ts11.vhd`) and the shared-core refactor are
deferred to the tape-bootloader milestone.

Reference for register/bit semantics: DEC TM11 manual + SIMH `pdp11_tm.c`
(`MTC_*`, `MTS_*`, function codes). SIMH source is not in-tree (open-simh via
brew); pull `pdp11_tm.c` from the SIMH repo when wiring the bit fields.

---

## 1. Data path overview

```
OSD "S3,TAP" ─► hps_io slot 3 ─► sd_card #(WIDE) sd_card_ts (pdp2011.sv)
   ─► SPI (ts_cs/sclk/mosi/miso) ─► sdspi.vhd inside tm11.vhd
   ─► 512-byte block buffer ─► .tap byte-stream reader ─► NPR DMA ─► Unibus mem
```

`sdspi.vhd` addresses in **512-byte blocks** (SDHC, CMD17/CMD24), buffer is
256 words (`sdcard_xfer_addr` 0..255). The `.tap` container is a byte stream,
so tm11.vhd owns a byte cursor and refills the block buffer on demand.

---

## 2. New file: `rtl/tm11.vhd`

Clone the **shape** of `rtl/rl11.vhd` (closest existing model — single unit,
simple register file, one `sdspi` instance, two clocked processes):

- **Entity ports**: identical to `rl11` (base_addr, ivec, br/bg/int_vector,
  npr/npg, bus_addr_match + bus_addr/dati/dato/control_*, bus_master_*,
  sdcard_* SPI, `have_tm : in integer range 0 to 1`, reset/clk50mhz/nclk/clk).
- **`sd1 : sdspi`** instance, `enable => have_tm`, `sdcard_addr => x"0" & "0000" & tape_block(23 downto 0)` (block number).
- **Process A (`nclk`)** — register file + command decode + tape FSM.
- **Process B (`clk`)** — NPR busmaster (copy `rl11` busmaster almost verbatim;
  see §5).

### 2.1 Registers (decode `bus_addr(3 downto 1)`, match `base_addr(17 downto 4)`)

| off | name  | addr    | notes |
|-----|-------|---------|-------|
| 0   | MTS   | 172520  | status, read-only |
| 1   | MTC   | 172522  | command; R/W |
| 2   | MTBRC | 172524  | byte record counter (2's-complement) |
| 3   | MTCMA | 172526  | current memory address (low 16 of 18) |
| 4   | MTD   | 172530  | data buffer — return 0 on read, ignore write for v1 |
| 5   | MTRD  | 172532  | TU10 read lines — return 0 |

MTC fields: bit0 GO, bits1-3 function, bits4-5 = bus addr bits 17:16,
bit6 IE, bit7 CU RDY (RO), bits8-10 density/parity (ignore), bit11 power-clear,
bits12-14 unit select (only unit 0 valid), bit15 = OR of MTS error bits (RO).

MTS bits (confirm exact positions against `pdp11_tm.c`): TUR, RWS, WRL (write
lock — **always 1** for v1 read-only), BOT, 7CH(0), EOT, RLE, BTE, NXM, EOF,
ILC, PAE, ERR(15). On power-up / power-clear: TUR=1, BOT=1, WRL=1, CU RDY=1.

### 2.2 Function codes (MTC bits 3:1)

| code | fn | v1 behaviour |
|------|----|--------------|
| 000 | offline/rewind+unload | position:=0, set BOT, done |
| 001 | read | DMA one record (§4) |
| 010 | write | ILC + WRL error, no-op |
| 011 | write EOF | ILC + WRL error, no-op |
| 100 | space forward | skip `|MTBRC|` records or stop at tape mark / EOT (§4.3) |
| 101 | space reverse | skip back `|MTBRC|` records or stop at BOT / tape mark (§4.4) |
| 110 | write w/ext gap | ILC + WRL error, no-op |
| 111 | rewind | position:=0, set BOT, done |

GO with any function while CU RDY: clear CU RDY, clear MTS error bits, dispatch;
on completion set CU RDY and (if IE) raise BR5. Interrupt FSM: copy `rl11`
`interrupt_state` verbatim (trigger = CU RDY rising while IE).

---

## 3. Tape position + `.tap` block reader (the only genuinely new logic)

State:
- `tape_pos : unsigned(31 downto 0)` — byte offset into the `.tap` image.
- `blk_buf` — reuse the sdspi 256-word buffer; add `blk_valid`, `blk_lba`.
- `byte_cur : integer range 0 to 511` — cursor within the loaded block.

Primitive: **get N bytes starting at `tape_pos`** (into a small shift reg for
header parsing, or straight to the DMA word assembler):
1. `need_lba = tape_pos(31 downto 9)`. If `blk_valid=0` or `blk_lba/=need_lba`,
   kick `sdcard_read_start`, wait `sdcard_read_done`, latch buffer, `blk_lba<=need_lba`,
   `blk_valid<=1`.
2. Byte at `tape_pos` = `blk_buf(to_integer(tape_pos(8 downto 1)))`, high/low
   half by `tape_pos(0)`.
3. Increment `tape_pos`; when `tape_pos(8 downto 0)` wraps to 0, next access
   refills (step 1).

`.tap` record framing (little-endian, matches PDP-11 byte order):
- 4-byte length header `L`.
- `L == 0x00000000` → **tape mark** (EOF). Advance `tape_pos` by 4.
- `L == 0xFFFFFFFF` (or `0xFFFFFFFE`) → end of medium / erase gap → treat as EOT.
- else: `L` data bytes follow, then a 4-byte trailing length (== `L`, padded:
  payload is `(L+1) & ~1` bytes on tape when `L` is odd). Record stride =
  `4 + ((L+1)&~1) + 4`.

Note the odd-length padding: DEC `.tap` pads each record to an even byte count
but the length word is the true byte count.

---

## 4. Command execution (Process A tape FSM)

### 4.1 Read (fn 001)
1. Parse header `L` at `tape_pos`.
2. `L==0`: set EOF, CU RDY, `tape_pos += 4`, done. (MTBRC unchanged.)
3. `L==EOM`: set EOT, CU RDY, done.
4. `req = twos_complement(MTBRC)` (bytes the driver wants).
   - `xfer = min(L, req)`.
   - Hand `xfer` bytes to the DMA assembler (§5); source address =
     `tape_pos + 4`, dest = `MTC(5:4) & MTCMA`.
   - On DMA done: `MTCMA += xfer` (16-bit, carry into an internal ext-addr;
     write back MTC 5:4), `MTBRC += xfer` (counts toward 0; residual = frames
     not transferred).
   - If `L > req`: set **RLE** (record length error) — driver under-ran.
   - Always advance `tape_pos` past the **whole** record (stride from §3), so
     the next op is positioned at the following record even on RLE.
5. `bus_master_nxm` during DMA → set NXM, abort, CU RDY.
6. Set CU RDY; if IE, interrupt.

### 4.2 (write / write-EOF / write-ext) — v1: set ILC + ERR, CU RDY, no motion.

### 4.3 Space forward (fn 100)
Loop: parse `L` at `tape_pos`.
- `L==0` (tape mark): `tape_pos += 4`, set EOF, stop.
- `L==EOM`: set EOT, stop.
- else `tape_pos += stride`, `MTBRC += 1` (toward 0). Stop when `MTBRC == 0`.
No DMA. CU RDY + optional interrupt at end.

### 4.4 Space reverse (fn 101)
- If `tape_pos == 0`: set BOT, stop.
- Read the 4-byte trailing length at `tape_pos - 4` → `L`.
  - `L==0`: `tape_pos -= 4`, set EOF, stop.
  - else `tape_pos -= (4 + ((L+1)&~1) + 4)`, `MTBRC += 1`. Stop at `MTBRC==0`
    or `tape_pos==0` (BOT).

### 4.5 Rewind / offline (fn 111 / 000)
`tape_pos <= 0`, `blk_valid <= 0`, set BOT + TUR, CU RDY, interrupt.
(No separate RWS/seek modelling needed — instantaneous.)

---

## 5. NPR busmaster (Process B)

Start from `rl11.vhd` lines ~591-752. Differences:

- **Read (tape→mem)**: instead of streaming a fixed 128-word sector from the
  sdspi buffer, stream `ceil(xfer/2)` words from the **byte reader** (§3). The
  reader may cross 512-byte block boundaries mid-record — the busmaster must
  stall for a refill (`blk_valid` handshake) rather than assuming one contiguous
  buffer. Cleanest: a `tape_word_valid / tape_word_ack` micro-handshake between
  Process A (owns the byte cursor + refill) and Process B (owns NPR + bus).
- Word assembly: `word = blk_buf byte[cur+1] & blk_buf byte[cur]` (LE), i.e.
  first tape byte → bits 7:0.
- Odd `xfer`: last transfer is a single low byte (`bus_master_control_datob`),
  or just transfer the padded even count and let MTBRC residual reflect truth.
  Simpler: transfer `xfer` bytes exactly, use datob for the tail byte.
- `bus_master_addr <= ext & MTCMA_work & '0'`; increment `MTCMA_work` by 1 word.
- No write path in v1 (leave `busmaster_write*` states unreachable / deleted).

Keep the `nclk` process as the command/register owner and the `clk` process as
the pure bus mover, exactly like `rl11` — do not merge them.

---

## 6. Wiring — `rtl/unibus.vhd`

Mirror every `rl0`/`rk0` touch-point:

1. **generic** `have_tm : in integer range 0 to 1 := 0;` (entity, ~line 42).
2. **component tm11** declaration (copy the `component rl11` block, ~line 584).
3. **signals**: `ts0_addr_match, ts0_dati, ts0_npr, ts0_npg, ts0_bg, ts0_br,
   ts0_ivec, ts0_addr, ts0_dato, ts0_control_dati, ts0_control_dato`
   (naming: use `tm0_` to match the device). ~line 1140.
4. **instance** `tm0 : tm11` (copy `rl0` port map, ~line 1748):
   - `base_addr => o"772520"`, `ivec => o"224"`,
   - `sdcard_* => tm_sdcard_*`, `have_tm => have_tm`, `reset => cpu_init`.
5. **npr_states**: add `npr_tm0`; in `npr_idle` add
   `elsif tm0_npr = '1' then npr_state <= npr_tm0;` and the `npr_tm0` state
   (copy `npr_rl0`). Reset clause: `tm0_npg <= '0';` in `npr_idle`.
6. **br5_states**: add `br5_tm0`; in `br5_idle` add the `elsif tm0_br='1'`
   branch and the `br5_tm0` state (copy `br5_rk0`). Pick priority: after
   `rk0` is fine.
7. **`unibus_dati`** mux (~2473): `else tm0_dati when tm0_addr_match = '1'`.
8. **`unibus_addr_match`** (~2505): `or tm0_addr_match = '1'`.
9. **`unibus_busmaster_addr/dato/control_dati/control_dato/control_datob/npg`**
   muxes (~2553-2582): add `else … when tm0_npg = '1'` lines.
10. Pass `tm_sdcard_*` up through the entity port list (copy the `rl_sdcard_*`
    port group) and out to `mister_top`.

---

## 7. Wiring — `rtl/mister_top.vhd`

1. Generic `have_tm : in integer;` (~line 34).
2. Port group `tm_sdcard_cs/mosi/sclk/miso/debug` (~line 59, copy `rl_`).
3. In the `unibus` component decl + instance: `have_tm => have_tm`,
   `tm_sdcard_* => tm_sdcard_*` (~lines 167 / 680).

---

## 8. Wiring — `pdp2011.sv`

1. **CONF_STR** (~line 280): add after the RH line
   `"S3,TAP,Mount tape;",`
2. **hps_io**: `.VDNUM(4)` (was 3); arrays widen:
   `wire [31:0] sd_lba[4];  reg [3:0] sd_rd; reg [3:0] sd_wr; wire [3:0] sd_ack;`
   `wire [15:0] sd_buff_din[4]; wire [3:0] img_mounted; wire [3:0] img_readonly;`
3. **vsd_sel_tm**: `reg vsd_sel_tm = 0;` and in the `always @(posedge
   clk_100mhz)` block: `if(img_mounted[3]) vsd_sel_tm <= |img_size;` plus the
   RESET clear.
4. **`sd_card #(.WIDE(1)) sd_card_tm`** — copy `sd_card_rl`, use `sd_lba[3]`,
   `sd_rd[3]`, `sd_wr[3]`, `sd_ack[3]`, `sd_buff_din[3]`, `.sck(tm_sclk)`,
   `.ss(tm_cs | ~vsd_sel_tm)`, `.mosi(tm_mosi)`, `.miso(tm_miso)`.
5. `int have_tm; assign have_tm = vsd_sel_tm ? 1 : 0;` and the
   `tm_sclk/tm_cs/tm_mosi/tm_miso/tm_sddebug` wire decls.
6. `mister_top` instance: `.have_tm(have_tm)`, `.tm_sdcard_*` (~line 591).
7. Real-SD passthrough (`SD_CS/SCK/MOSI`, ~532-535): unchanged — tape is a
   virtual sd_card like RK/RL, only RH touches the physical slot.

---

## 9. Quartus project

Add `rtl/tm11.vhd` to `pdp2011.qsf` (`set_global_assignment -name VHDL_FILE
rtl/tm11.vhd`) next to the `rk11.vhd` / `rl11.vhd` lines.

---

## STATUS (2026-09-02) — working on hardware

- `rtl/tm11.vhd` + wiring (`unibus.vhd`, `mister_top.vhd`, `pdp2011.sv`,
  `files.qip`).  `sim/run_sim.sh tb_tm11` -> 27/27: power-up status,
  read (14-byte + 512-byte incl. block straddle), MTBRC/MTCMA residuals,
  tape mark -> EOF, RLE on short MTBRC, rewind -> BOT, space fwd/rev,
  media-change re-home.
- **Verified on the DE10-Nano** via ODT front-panel register pokes:
  `tu16.tap` record 1 (14 B) and record 2 (512 B, spans SD blocks 0->1)
  DMA'd byte-for-byte correct; MTS/MTC/MTBRC/MTCMA all as expected.
- Bring-up turned up an `sdspi` latent bug (`write_done` never reset) --
  split out as its own fix (`pr/sdspi-write-done-fix`), cherry-picked
  here so the tape works standalone; it drops out on rebase once that
  merges.

## Not done / deferred

- `ts11.vhd` (MS:) for the RSTS 10.1 kit, and factoring a shared
  `tape_core` -- both wait for the tape-bootloader milestone.
- Tape write / scratch-tape creation (`write` / `write-EOF` -> ILC now).
- Odd-length records DMA `ceil(L/2)` words (one pad byte); residuals
  still reflect true L.
- NXM path and interrupt delivery not yet exercised in sim.
