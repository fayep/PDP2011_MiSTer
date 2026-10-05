# XU v2: DEUNA networking through Main, frames only

Branch `feature/xu-frames` (from release-20261005, 10677d4).
Main side: `feature/xu-frames` in Main_MiSTer_pdp2011 (from feature/tape-compat).

## Why a second attempt

The parked work (`draft/xu-native-ethernet`, 2026-09-02) kept the DEUNA
firmware talking SPI to an ENC424J600 and faked the chip: a VHDL shim mirrored
the chip's 24 KB buffer and registers into DDR3, and Main's daemon played the
rest of the chip. Two sides each owned parts of one chip model, so it
collected byte-order slips, stale-cache bugs and field-packing races, and two
bugs were left red when it was parked.

The NeXT core (MiSTer-devel/NeXT_MiSTer, Main `support/next/next_enet.cpp`,
upstream since 2026-09-10) shows the simpler split: the NIC lives in the
fabric, and only whole Ethernet frames cross to Linux through small DDR3 rings.

## Why DDR3 (not SDRAM, not hps_io)

- The SDRAM is wired to the FPGA only; Linux cannot see it. It is also the
  PDP-11's main memory, and a second user would share its controller.
- hps_io (the disk/OSD channel) would work for 10 Mbit/s, but every byte costs
  Main CPU and frames would queue behind disk traffic.
- DDR3 through the FPGA-to-HPS bridge is memory Main maps with `shmem_map`.
  Nothing per byte on the ARM, and it is what NeXT, Minimig A2065 and NE2000
  already use. Inside the FPGA the frames sit in block RAM; DDR3 is only the
  mailbox between the FPGA and Linux.

## Design

```
guest memory --xubm DMA--> XU local bus --> xufp (TX/RX block RAM, regs)
                                               |  toggles + dual-clock RAM
                                               v
                                       xu_ddr_bridge (clk_sys) --DDRAM--> DDR3 rings
                                                                             |
                                                Main: support/pdp2011/xu_net.cpp
                                                  eth0 (filtered) / eth1 / macvlan / tap0
```

### 1. `rtl/xufp.vhd`: frame port on the XU CPU's local bus

The DEUNA firmware runs on its own PDP-11 inside `xu.vhd`; `xubm` already
DMAs between guest memory and any local-bus address, up to 254 bytes a command.
So the frame buffers are plain memory on the local bus and the firmware moves
whole segments with `xubm`, no 16-byte chunks and no SPI.

| Local address | Use |
|---|---|
| 020000-023777 | TX buffer, 2 KB (firmware/xubm write, bridge reads) |
| 024000-027777 | RX buffer, 2 KB (bridge writes, firmware/xubm read) |
| 777200 | CSR. Read: bit0 RXRDY, bit1 TXBUSY, bit2 HOSTUP (Main's MAC is valid), bit15 FPORT (host networking selected). Write: bit0=1 releases the RX frame |
| 777202 | RXLEN, bytes, of the frame in the RX buffer |
| 777204 | TXLEN, write = transmit that many bytes from the TX buffer |
| 777206-777212 | default (host-provided) MAC, read only, wire order, low byte first |
| 777214-777220 | guest MAC, written by the firmware |
| 777222 | MODE: bit0 promiscuous, bit1 all-multicast; writing it publishes MAC+MODE |

If Main has not published a MAC, 777206 reads the fixed fallback
08-00-2B-00-00-01, so the firmware always has a default address.

### 2. Clock crossing

`xufp` RAMs are dual-clock: port A on the XU's `nclk`, port B on the bridge
clock (`clk_sys`). Control crosses as toggles (TX request/ack, RX ready/release,
publish), each 2-FF synchronised in the receiving domain; MACs and lengths are
held stable while their toggle is outstanding. SDC false paths cover the `*_s1`
synchroniser stages. One writer per signal, per word, everywhere.

### 3. `rtl/xu_ddr_bridge.sv` and the DDR3 layout

Base ARM physical 0x1FF00000 (Avalon 64-bit word 0x03FE0000), the window every
networking core uses (one core runs at a time). Byte offsets:

| Offset | Field | Writer |
|---|---|---|
| 0x0000 | MAGIC "PDPXU001" | FPGA, at enable |
| 0x0008 | TX_WPTR, frames sent | FPGA |
| 0x0010 | TX_RPTR, frames taken | ARM |
| 0x0018 | RX_WPTR, frames delivered | ARM |
| 0x0020 | RX_RPTR, frames consumed | FPGA |
| 0x0028 | GUEST: bit63 valid, 55:48 mode, 47:0 MAC | FPGA |
| 0x0030 | HOST: bit63 valid, 47:0 default MAC | ARM |
| 0x0038 | HEARTBEAT, incremented each Main poll | ARM |
| 0x1000 | TX slots, 8 x 2048 | FPGA |
| 0x5000 | RX slots, 8 x 2048 | ARM |

Slot: u64 header, bits 10:0 = length; frame bytes from +8, byte i at byte
offset 8+i. Pointers are free-running counters; slot = ptr mod 8.

TX: the bridge copies the TX buffer to slot TX_WPTR, then bumps TX_WPTR. If the
ring is full it waits for TX_RPTR; if Main is absent (HEARTBEAT has not moved
for ~50 ms) the frame is dropped so the guest never hangs.
RX: the bridge polls RX_WPTR (~every 100 us) and, when the RX buffer is free,
copies slot RX_RPTR into it, raises RXRDY, and bumps RX_RPTR after the
firmware releases it. Main never overwrites an unconsumed slot.

### 4. Firmware (`roms/xubrt45.mac`)

At start-up, CSR bit15 selects the path: FPORT=1 uses the frame port; FPORT=0
keeps the ENC424J600 on the I/O board (PMOD) exactly as today.
Frame-port versions of: chip init and default MAC (read 777206), set
LAA/mode bits (777214/777222), transmit (`xmitst`/`xmitld`/`xmitxx` copy
segments into the TX buffer with `xubm`, then write TXLEN), receive
(`pktin`/`getfr` copy from the RX buffer to the guest ring with `xubm`, then
release), and the chip-alive check (skipped).

### 5. OSD and top level

- `O[1]` External Ethernet (I/O board ENC424J600) stays as it is.
- New `O[27:25]` Host network: Off, eth0, eth1, macvlan, tap0. Not Off selects
  the frame port (and enables the XU even when O[1] is No).
- `DDRAM_*` ports fixed to the standard 64-bit width (the template had 127).

### 6. Main (`support/pdp2011/xu_net.cpp`)

Modelled on `support/next/next_enet.cpp`, using the existing helpers in
`support/minimig/minimig_a2065_ethernet.cpp` (`ethernet_open`,
`ethernet_set_mac_filter`, `ethernet_macvlan_create`, ...).
- Maps the window, writes HOST (DEC OUI 08-00-2B + three bytes from eth0's MAC)
  and HEARTBEAT, follows the OSD mode, opens/closes the interface.
- TX: drains slots TX_RPTR..TX_WPTR to the interface.
- RX: reads frames while a slot is free; delivers unicast-to-guest,
  broadcast and multicast (everything when promiscuous). eth0 shared uses the
  BPF MAC filter like NeXT.

## Tests

1. `sim/tb_xufp_bridge`: xufp + bridge + a DDR3 model playing Main. TX frame
   lands byte-exact in a slot; injected RX frame appears in the RX buffer with
   the right length; ring full, Main absent (drop), release/refill.
2. `sim/tb_xu_deuna` (black box, the September plan): full `xu` with the real
   firmware, a Unibus memory model and the DDR3 model. GET PCBB, READ DEFAULT
   PHYSICAL ADDRESS (MAC byte order), WRITE RINGS, START; RX frame into the
   guest ring with RXI; guest TX captured byte-exact with TXI.
3. Hardware: XXDP DEUNA diagnostics, then 2.11BSD (`de0`) ping, RSTS/RSX DECnet.

## Order of work

1. xufp + bridge + tb_xufp_bridge  (this commit series starts here)
2. firmware frame-port path + tb_xu_deuna
3. plumbing, OSD, SDC, build
4. Main xu_net.cpp
5. hardware

## Open questions

- Keep the PMOD path? Kept for now (cheap: firmware branches on CSR bit15).
- Multicast filtering is done loosely in Main (all multicast passes); the
  DEUNA's multicast address table could be applied in the firmware later.
- Loadable ROMs (#19): xubrt45 could become boot2.rom for firmware fixes
  without a bitstream.
