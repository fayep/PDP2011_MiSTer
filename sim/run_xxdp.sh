#!/bin/sh
# Run one XXDP/MAINDEC image through tb_xxdp.
#
# Usage:
#   sim/run_xxdp.sh EKBAD0 [extra ghdl -r args...]
#   sim/run_xxdp.sh ZMMDB0   # after adding a line to sim/xxdp.tab
#
# Halt-on-error scoreboard (tb_xxdp) prints pc/ir/psw/r0 in octal.
# EKBAD0's failing test number is R0 (MAINDEC "TEST NUMBER(R0) IS").

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="$ROOT/sim"
TAB="$SIM/xxdp.tab"
XXDP_ROOT="${XXDP_ROOT:-/Users/faye/Source/files11/xxdp_rl}"

if [ -z "$1" ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
	echo "Usage: sim/run_xxdp.sh <NAME> [ghdl -r args...]" >&2
	echo "Catalog:" >&2
	grep -v '^#' "$TAB" | grep -v '^$' | cut -d'|' -f1 | sed 's/^/  /' >&2
	exit 1
fi

NAME=$1
shift
EXTRA="$*"

LINE=$(grep -v '^#' "$TAB" | grep -v '^$' | awk -F'|' -v n="$NAME" '$1==n {print; exit}')
if [ -z "$LINE" ]; then
	echo "unknown XXDP test '$NAME' (add a line to sim/xxdp.tab)" >&2
	exit 1
fi

FILE=$(echo "$LINE" | awk -F'|' '{print $2}')
PC_OCT=$(echo "$LINE" | awk -F'|' '{print $3}')
SW_OCT=$(echo "$LINE" | awk -F'|' '{print $4}')
PASS=$(echo "$LINE" | awk -F'|' '{print $5}')
FAIL=$(echo "$LINE" | awk -F'|' '{print $6}')
FAIL2=$(echo "$LINE" | awk -F'|' '{print $7}')
STOP=$(echo "$LINE" | awk -F'|' '{print $8}')
BUDGET=$(echo "$LINE" | awk -F'|' '{print $9}')

SRC="$XXDP_ROOT/$FILE"
if [ ! -f "$SRC" ]; then
	echo "missing XXDP image: $SRC (set XXDP_ROOT)" >&2
	exit 1
fi

cd "$SIM"
mkdir -p build
MEM="build/xxdp_${NAME}.mem"
python3 abs2mem.py "$SRC" "$MEM"

GHDL_FLAGS="--std=08 -fexplicit -fsynopsys -frelaxed --workdir=build -Pbuild"
TOP=tb_xxdp
DEPS=$(sed -n 's/^--[[:space:]]*deps:[[:space:]]*//p' "$TOP.vhd" | tr '\n' ' ')

need_elab=1
if [ -x "build/$TOP" ] && [ "build/$TOP" -nt "$TOP.vhd" ]; then
	need_elab=0
fi
if [ "$need_elab" -eq 1 ]; then
	rm -rf build/work-obj08.cf
	for f in $DEPS; do
		found=""
		for d in ../rtl ../roms . ..; do
			if [ -f "$d/$f" ]; then found="$d/$f"; break; fi
		done
		[ -n "$found" ] || { echo "MISSING dep: $f"; exit 1; }
		ghdl -a $GHDL_FLAGS "$found"
	done
	ghdl -a $GHDL_FLAGS "$TOP.vhd"
	ghdl -e $GHDL_FLAGS -o "build/$TOP" "$TOP"
fi

PC=$((8#$PC_OCT))
SW=$((8#$SW_OCT))

set -- --ieee-asserts=disable "--stop-time=$STOP" \
	"-gmem=$MEM" "-ginit_pc=$PC" "-gcons_sw=$SW" "-gbudget=$BUDGET"
[ -n "$PASS" ] && set -- "$@" "-gpass_match=$PASS"
[ -n "$FAIL" ] && set -- "$@" "-gfail_match=$FAIL"
[ -n "$FAIL2" ] && set -- "$@" "-gfail_match2=$FAIL2"

# shellcheck disable=SC2086
exec "build/$TOP" "$@" $EXTRA
