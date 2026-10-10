#!/bin/sh
# Build and run tb_xufp_bridge (xu frame port + DDR3 bridge). Run from the repo root.
set -e
F="--std=08 -fsynopsys -frelaxed --workdir=sim/build_xufp"
mkdir -p sim/build_xufp
ghdl -a $F rtl/xufp.vhd rtl/xu_ddr_bridge.vhd sim/tb_xufp_bridge.vhd
ghdl -e $F -o sim/build_xufp/tb_xufp_bridge tb_xufp_bridge
sim/build_xufp/tb_xufp_bridge --stop-time=200ms --ieee-asserts=disable 2>&1 | grep -v "^$"
