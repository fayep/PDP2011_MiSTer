#!/bin/bash
# sim/verilator/build_rh.sh -- as build.sh, for unibus_vl_rh (the RH70 and its disk slot) and the
# rhbench.cpp harness: sim/verilator/build_rh/vsim_rh.
set -e
cd "$(dirname "$0")"; V=$PWD; R=${RTL_ROOT:-$(cd ../.. && pwd)}; B=${B:-$V/build_rh}
GHDL=${GHDL:-$HOME/Source/ghdl-6.0.0/bin/ghdl}
mkdir -p $B/work
D=$(sed -n '1s/^-- deps: //p' $R/sim/tb_xxdp.vhd)          # same file list as tb_xxdp
F=""; for f in $D; do for p in rtl roms sim .; do [ -f $R/$p/$f ] && { F="$F $R/$p/$f"; break; }; done; done
$GHDL -a --std=08 -fsynopsys -frelaxed --workdir=$B/work $F $V/unibus_vl_rh.vhd
$GHDL --synth --std=08 -fsynopsys -frelaxed --workdir=$B/work --out=verilog unibus_vl_rh > $B/unibus_vl_rh.v
sed -E -i.bak 's/([ .(])event([ ,)(])/\1event_o\2/g' $B/unibus_vl_rh.v
verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial fast \
   -Wno-fatal -Wno-lint -Wno-style --top-module unibus_vl_rh --Mdir $B/obj \
   -CFLAGS "-O2 -std=c++17" -o vsim_rh $B/unibus_vl_rh.v $V/rhbench.cpp > $B/verilator.log 2>&1 \
   || { tail -30 $B/verilator.log; exit 1; }
cp $B/obj/vsim_rh $B/vsim_rh
echo "built $B/vsim_rh"
