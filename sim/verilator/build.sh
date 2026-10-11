#!/bin/bash
# sim/verilator/build.sh -- GHDL-synthesise unibus_vl (rtl/ + roms/) to Verilog, then build the
# Verilator model with the C++ harness (main.cpp) into sim/verilator/build/vsim.
set -e
cd "$(dirname "$0")"; V=$PWD; R=$(cd ../.. && pwd); B=$V/build
GHDL=${GHDL:-$HOME/Source/ghdl-6.0.0/bin/ghdl}
mkdir -p $B/work
D=$(sed -n '1s/^-- deps: //p' $R/sim/tb_xxdp.vhd)          # same file list as tb_xxdp
F=""; for f in $D; do for p in rtl roms sim .; do [ -f $R/$p/$f ] && { F="$F $R/$p/$f"; break; }; done; done
$GHDL -a --std=08 -fsynopsys -frelaxed --workdir=$B/work $F $V/unibus_vl.vhd
$GHDL --synth --std=08 -fsynopsys -frelaxed --workdir=$B/work --out=verilog unibus_vl > $B/unibus_vl.v
# 'event' is a SystemVerilog keyword (mncdi has a port of that name)
sed -E -i.bak 's/([ .(])event([ ,)(])/\1event_o\2/g' $B/unibus_vl.v
verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial fast \
   -Wno-fatal -Wno-lint -Wno-style --top-module unibus_vl --Mdir $B/obj \
   -CFLAGS "-O2 -std=c++17" -o vsim $B/unibus_vl.v $V/main.cpp > $B/verilator.log 2>&1 \
   || { tail -30 $B/verilator.log; exit 1; }
cp $B/obj/vsim $B/vsim
echo "built $B/vsim"
