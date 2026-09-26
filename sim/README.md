# sim/ — GHDL testbench harness

Small, self-contained VHDL testbenches for individual RTL blocks, run
under [GHDL](https://github.com/ghdl/ghdl).  This is dry-run verification
of a single module's logic -- it does not model the DE10-Nano, the HPS,
or SDRAM.

## Running

```
sim/run_sim.sh <tb-entity> [--stop-time=4ms ...]
```

By default `run_sim.sh` imports every `rtl/` and `roms/` `.vhd` plus the
testbench and lets `ghdl -m` work out the analysis order -- a new
testbench just drops in, nothing to maintain.

## Mocks

A testbench that defines a behavioural stand-in for a real entity (e.g.
a mock `sdspi` that serves blocks from an in-memory array) can't use
auto mode -- `ghdl -m` would re-analyse the real file over the mock.
Such a testbench declares an explicit ordered list, real file before
the mock:

```vhdl
-- deps: sdspi.vhd tm11.vhd
```

`run_sim.sh` then analyses exactly that list, then the testbench file
last, so the mock architecture wins.  GHDL prints a "was also defined"
warning for this; it is expected.

## XXDP / MAINDEC

`sim/run_xxdp.sh EKBAD0` (or `ZMMCA0`) converts one or more abs-loader
`.BIC`/`.BIN` files from `XXDP_ROOT` through `abs2mem.py` (byte-wise
load, optional comma-separated overlay list in `sim/xxdp.tab`) and runs
the shared `tb_xxdp` harness.  Add another test with one line in
`sim/xxdp.tab` — see that file and `docs/xxdp-cpu-mem-tb.md`.

`sim/*.mem` is gitignored; `run_xxdp.sh` writes `sim/build/xxdp_<name>.mem`.

`sim/simh/` has notes on driving Open SIMH's `pdp11` as a reference
model for comparison work.
