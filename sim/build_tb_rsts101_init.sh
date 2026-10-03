#!/bin/sh
# Build sim/build/tb_rsts101_init (GHDL). Run from sim/.
set -e
F="--std=08 -fsynopsys -frelaxed --workdir=build"
mkdir -p build
for f in cpuregs fpuregs cpu mmu cr csdr xubm xubl xu kw11l mister_blkdev rh11 rk11 rl11 tm11 dr11c mncad mnckw mncaa mncdi mncdo; do
   ghdl -a $F ../rtl/$f.vhd
done
# kl11: the bit counters run one past 7 (harmless in hardware, a bound failure in GHDL)
sed -e "s/^signal recv_bit : integer range 0 to 7/signal recv_bit : integer range 0 to 8/" -e "s/^signal xmit_bit : integer range 0 to 7/signal xmit_bit : integer range 0 to 8/" ../rtl/kl11.vhd > build/kl11_sim.vhd
ghdl -a $F build/kl11_sim.vhd
ghdl -a $F ../roms/m9312l47.vhd ../roms/m9312h47.vhd ../roms/xubrt45.vhd
# GHDL insists that a port and its actual have the same integer range
sed "s/^signal have_oddabort : integer range 0 to 1;/signal have_oddabort : integer range 0 to 255;/" ../rtl/unibus.vhd > build/unibus_sim.vhd
ghdl -a $F build/unibus_sim.vhd
ghdl -a $F tb_rsts101_init.vhd
ghdl -e $F -o build/tb_rsts101_init tb_rsts101_init
