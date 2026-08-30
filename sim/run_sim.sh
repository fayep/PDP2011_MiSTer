#!/bin/sh
# Local GHDL simulation runner. All dependency files (rtl/, roms/) are
# tracked in this repo -- this script just needs to find them relative
# to its own location, one level up from sim/.
#
# Usage: sim/run_sim.sh <top-entity> [ghdl -r extra args...]
# Example: sim/run_sim.sh tb_shim_stream --stop-time=2ms
#          sim/run_sim.sh tb_xu_pcsr0_start --stop-time=10ms

set -e
TOP="$1"; shift || true
GHDL_FLAGS="--std=08 -fexplicit -fsynopsys"

DEPS="cpuregs.vhd fpuregs.vhd cpu.vhd mmu.vhd cr.vhd xubm.vhd xubl.vhd \
xu_ddr_mailbox.vhd xu_enc424j600_shim.vhd xubrt45.vhd m9312h47.vhd \
m9312l47.vhd vgafont.vhd vtbrt42.vhd vga.vhd vgacr.vhd vt.vhd kl11.vhd \
kw11l.vhd rh11.vhd rk11.vhd rl11.vhd sdspi.vhd dr11c.vhd ps2.vhd mnckw.vhd \
mncaa.vhd mncad.vhd mncdi.vhd mncdo.vhd paneldb.vhd paneldriver.vhd \
panelos.vhd csdr.vhd xu.vhd unibus.vhd mister_top.vhd"

cd "$(dirname "$0")"

# All compiled artifacts (GHDL work library + object files + the
# executable) live in build/, entirely gitignored -- keeps them out of
# both git and any rsync of the source tree into the Quartus container
# (which would otherwise pick up arm64-compiled .o/.cf junk into an x86
# build, harmless to Quartus itself but real clutter worth not creating).
mkdir -p build
GHDL_FLAGS="$GHDL_FLAGS --workdir=build -Pbuild"

for f in $DEPS; do
	found=""
	for d in ../rtl ../roms . ..; do
		if [ -f "$d/$f" ]; then found="$d/$f"; break; fi
	done
	[ -n "$found" ] || { echo "MISSING: $f (not in rtl/, roms/, ./, or ../ -- see comment at top of this script)"; exit 1; }
	ghdl -a $GHDL_FLAGS "$found"
done

ghdl -a $GHDL_FLAGS "$TOP.vhd"
ghdl -e $GHDL_FLAGS -o "build/$TOP" "$TOP"
exec "build/$TOP" "--vcdgz=build/$TOP.vcd.gz" "$@"
