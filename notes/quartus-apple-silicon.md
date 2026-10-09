# Building with Quartus on Apple silicon

The core builds with the MiSTer toolchain, Quartus Prime 17.0.2 Lite (Build 602), from the
`raetro/quartus:mister` image. On a Mac that image is x86-64, so it runs under Rosetta, in
Apple's `container` (`container run --arch amd64 ...`) or in Docker Desktop.

## Synthesis stalls with more than one thread

Run unpinned, `quartus_map` hangs part way through synthesis: CPU drops to a few percent
of one core and stays there. It depends on how many helper processes it starts (on an
M4 Max, `--parallel` 2 and 4 usually got through, 5 and up stalled, and the default of one
per core stalled within a minute) and gets worse when something else is busy on the machine.
Fitter, assembler and TimeQuest are not affected.

The safe workaround is to pin synthesis to one thread:

    quartus_map --read_settings_files=on --write_settings_files=off pdp2011 -c pdp2011 --parallel=1

## Cause

With `--parallel`, `quartus_map` starts helper processes (`quartus_map --ipc_mode --helper=N
--helper_type=rtl|mls`) and talks to them over named pipes. It watches each helper's
output with `thr_process_peek()` in `libccl_thr.so`, a `select()` with a 5 µs timeout.
When `select()` fails, `thr_process_peek()` returns `errno`, and that includes `EINTR`,
which only means a signal arrived. Under Rosetta that happens. The helper manager
(`IPC_COMMAND::run_with_named_pipe` in `libccl_ipc.so`) treats any error as a broken
pipe: it waits 20 x 500 ms, then sends the healthy helper `SIGTERM` ("not responding").
The main process is then left blocked for ever in the kernel opening that helper's FIFO
(`wchan` `wait_for_partner`), and the remaining helpers wait for it.

## Fix

`tools/quartus/patch_libccl_thr_eintr.py` rewrites the 45-byte tail of `thr_process_peek()`
so that `EINTR` returns "no data yet" (the caller simply polls again) and every other
error is returned exactly as before. It patches only the 17.0.2 Build 602 library
(md5 `b5293fee9b3dfd0dd993e8c2e1362c60` before, `798f2d480c7ac2a781723a7630514e1b` after)
and checks the bytes it replaces. Build a patched image from the stock one, so no
Intel binaries are redistributed:

    container build --arch amd64 -t raetro/quartus:mister-eintr \
        -f tools/quartus/Containerfile tools/quartus

and use `raetro/quartus:mister-eintr` with `quartus_map` unpinned (no `--parallel`
option; the qsf's `NUM_PARALLEL_PROCESSORS ALL` applies). We also run the container with
`--init`.

Building the image takes several minutes and about 10 GB: Apple's `container` gives every
image its own ext4 snapshot, so even a one-file change re-expands the whole Quartus image
the first time it is used. Let that finish before starting anything else on the new tag.

## Results

Same commit, built on an M4 Max (Apple `container` 1.5), the same UTC date:

| `quartus_map` | Image | Synthesis | rbf |
|---|---|---|---|
| `--parallel=1` | stock | 3:54 | identical |
| `--parallel=8` | patched | 2:47 | (synthesis only) |
| unpinned (16 threads) | patched | completed* | identical |
| `--parallel=5` and up | stock | stalls | - |

\* 3:30, while another build was running.

Parallel synthesis does not change the bitstream. The gain is modest, because most of
synthesis is serial: about a minute per build.
