#!/bin/sh
# Build and run tb_rh11_bracket for RH70 and RH11. Run from the repo root.
# Extra args go to the simulator, e.g. -gSEED=3 -gNXFER=200.
set -e
F="--std=08 -fsynopsys -frelaxed --workdir=sim/build_bracket"
mkdir -p sim/build_bracket
ghdl -a $F rtl/mister_blkdev.vhd rtl/rh11.vhd sim/tb_rh11_bracket.vhd
ghdl -e $F -o sim/build_bracket/tb_rh11_bracket tb_rh11_bracket
for m in 1 0; do
   sim/build_bracket/tb_rh11_bracket -gRH70=$m "$@" --stop-time=60000ms --ieee-asserts=disable 2>&1 | grep -v "^$"
done
