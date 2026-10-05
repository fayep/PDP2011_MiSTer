#!/bin/sh
# Build and run tb_xu_deuna (DEUNA + firmware on the frame port). Run from the repo root.
set -e
F="--std=08 -fsynopsys -frelaxed --workdir=sim/build_xu"
mkdir -p sim/build_xu
for f in cpuregs fpuregs cpu mmu cr kw11l xubm xubl xufp xu_ddr_bridge; do
   ghdl -a $F rtl/$f.vhd
done
# kl11: the bit counters run one past 7 (harmless in hardware, a bound failure in GHDL)
sed -e "s/^signal recv_bit : integer range 0 to 7/signal recv_bit : integer range 0 to 8/" -e "s/^signal xmit_bit : integer range 0 to 7/signal xmit_bit : integer range 0 to 8/" rtl/kl11.vhd > sim/build_xu/kl11_sim.vhd
ghdl -a $F sim/build_xu/kl11_sim.vhd roms/xubrt45.vhd rtl/xu.vhd sim/tb_xu_deuna.vhd
ghdl -e $F -o sim/build_xu/tb_xu_deuna tb_xu_deuna
sim/build_xu/tb_xu_deuna --stop-time=${STOP:-3000ms} --ieee-asserts=disable 2>&1 | grep -v "^$"
