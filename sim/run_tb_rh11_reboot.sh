#!/bin/sh
# Build and run tb_rh11_reboot for RH70 and RH11. Run from the repo root.
# SEEDS="1 2 3" NITER=200 sim/run_tb_rh11_reboot.sh
set -e
F="--std=08 -fsynopsys -frelaxed --workdir=sim/build_reboot"
mkdir -p sim/build_reboot
ghdl -a $F rtl/mister_blkdev.vhd rtl/rh11.vhd sim/tb_rh11_reboot.vhd
ghdl -e $F -o sim/build_reboot/tb_rh11_reboot tb_rh11_reboot
for s in ${SEEDS:-1}; do
   for m in 1 0; do
      sim/build_reboot/tb_rh11_reboot -gRH70=$m -gSEED=$s -gNITER=${NITER:-200} --stop-time=60000ms --ieee-asserts=disable 2>&1 | grep -v "^$"
   done
done
