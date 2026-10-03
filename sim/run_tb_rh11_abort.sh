#!/bin/sh
# Build and run tb_rh11_abort for RH70 and RH11. Run from the repo root.
set -e
F="--std=08 -fsynopsys -frelaxed --workdir=sim/build_abort"
mkdir -p sim/build_abort
ghdl -a $F rtl/mister_blkdev.vhd rtl/rh11.vhd sim/tb_rh11_abort.vhd
ghdl -e $F -o sim/build_abort/tb_rh11_abort tb_rh11_abort
for m in 1 0; do
   sim/build_abort/tb_rh11_abort -gRH70=$m --stop-time=2000ms --ieee-asserts=disable 2>&1 | grep -v "^$"
done
