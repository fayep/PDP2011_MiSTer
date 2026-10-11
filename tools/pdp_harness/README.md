# pdp_harness

A small daemon for the MiSTer's ARM side that owns `/dev/ttyS1` (the
PDP2011 core's serial console) exclusively, so a human (`tail -f` on
the log) and a scripted debug session (via the control socket) can
both observe/drive the console without fighting over the port.

Built because holding the port open with `picocom` or `screen` and
scripting keystrokes into the same session at the same time doesn't
work — and because picocom's software flow control (`-fx`) actively
corrupts the console when talking to the KL11 emulation, which has no
flow-control awareness at all (see `notes/` for that investigation).

## Build (cross-compile for the MiSTer's ARM Cortex-A9)

```sh
cd tools/pdp_harness
GOOS=linux GOARCH=arm GOARM=7 go build -ldflags="-s -w" -o pdp_harness .
```

Confirm the target's arch first with `uname -m` (expect `armv7l`).

## Deploy

Copy the resulting `pdp_harness` binary to `/media/fat/Scripts/` on the
MiSTer and run it detached:

```sh
mkdir -p /tmp/pdp_harness
nohup /media/fat/Scripts/pdp_harness > /tmp/pdp_harness/daemon.log 2>&1 &
disown
```

Requires exclusive access to the serial device — detach any other
process (picocom, screen, `MiSTer_pdp2011`'s own console handling
appears to coexist fine, since ttyS1 is a plain UART any process can
open) holding `/dev/ttyS1` first.

## Usage

- `-log /tmp/pdp_harness/serial.log` (default) — raw serial RX, `tail -f` it.
- `-sock /tmp/pdp_harness.sock` (default) — control socket, one
  request per line, plain text:
  - `ping` -> `pong`
  - `send <text>` — writes `<text>` + CR to the serial TX
  - `sendraw <hex>` — writes raw hex-encoded bytes (e.g. control chars)

  Every request gets exactly one reply line: `OK` or `ERR <message>`.
- `-tcp <addr>` (empty by default, opt in explicitly, e.g. `-tcp :7788`)
  — additionally listens on TCP, same protocol as `-sock`, so a
  session on a DIFFERENT machine can drive the console directly
  (`echo 'send START' | nc <mister-ip> 7788`) instead of going through
  SSH + socat for every single command. **No auth at all** — only for
  a trusted local lab network, never expose this to the internet.

Busybox's `nc` on the MiSTer lacks `-U` (Unix socket) support; use
`socat - UNIX-CONNECT:/tmp/pdp_harness.sock` instead for LOCAL
(on-MiSTer) use of the unix socket:

```sh
echo 'send START' | socat - UNIX-CONNECT:/tmp/pdp_harness.sock
```
