#!/bin/sh
# Local GHDL simulation runner.
#
# By default the runner imports every rtl/ and roms/ .vhd plus the
# testbench and lets `ghdl -m` compute the analysis order -- so a new
# testbench just drops in, no dependency bookkeeping.
#
# A testbench that shadows a real entity (e.g. a behavioural mock of
# sdspi in the same file) can't use auto mode -- `ghdl -m` would
# re-analyse the real file over the mock.  Such a testbench declares an
# explicit ordered list in a header line and the runner analyses exactly
# that, then the testbench file last so the mock wins:
#
#     -- deps: sdspi.vhd tm11.vhd
#
# Files are resolved under rtl/, roms/, sim/, then the repo root.
#
# Usage:   sim/run_sim.sh <tb-entity> [extra ghdl -r args...]
# Example: sim/run_sim.sh tb_tm11 --stop-time=4ms

set -e
TOP="$1"; shift || true
GHDL_FLAGS="--std=08 -fexplicit -fsynopsys -frelaxed"

cd "$(dirname "$0")"

# Regenerate any .mem memory-image from its .mac source if missing or
# stale (macro11 -> mac2mem.py -> .mem, see e.g. tb_rsts_overlay.vhd's
# own header comment for this pipeline). .mem/.obj/.lst are build
# artifacts, not checked into git -- without this, a testbench with a
# .mac companion silently fails with "cannot open X.mem" the first time
# it's run in a fresh environment, or after the source changes, with no
# hint that a build step was needed. Cheap no-op when already current.
for mac in *.mac; do
	[ -f "$mac" ] || continue
	mem="${mac%.mac}.mem"
	if [ ! -f "$mem" ] || [ "$mac" -nt "$mem" ]; then
		obj="${mac%.mac}.obj"
		lst="${mac%.mac}.lst"
		../tools/macro11 "$mac" -o "$obj" -l "$lst"
		python3 mac2mem.py "$obj" "$mem"
	fi
done

# Compiled artifacts (work library, .o, executable) live in build/, which
# is gitignored -- keeps arm64 junk out of git and out of any rsync of
# the tree into an x86 build container.
rm -rf build
mkdir -p build
GHDL_FLAGS="$GHDL_FLAGS --workdir=build -Pbuild"

DEPS=$(sed -n 's/^--[[:space:]]*deps:[[:space:]]*//p' "$TOP.vhd" | tr '\n' ' ')

if [ -n "$DEPS" ]; then
	for f in $DEPS; do
		found=""
		for d in ../rtl ../roms . ..; do
			if [ -f "$d/$f" ]; then found="$d/$f"; break; fi
		done
		[ -n "$found" ] || { echo "MISSING dep: $f (not in rtl/, roms/, sim/, or repo root)"; exit 1; }
		ghdl -a $GHDL_FLAGS "$found"
	done
	ghdl -a $GHDL_FLAGS "$TOP.vhd"
	ghdl -e $GHDL_FLAGS -o "build/$TOP" "$TOP"
else
	ghdl -i $GHDL_FLAGS ../rtl/*.vhd ../roms/*.vhd "$TOP.vhd"
	ghdl -m $GHDL_FLAGS -o "build/$TOP" "$TOP"
fi

exec "build/$TOP" "--vcdgz=build/$TOP.vcd.gz" "$@"
