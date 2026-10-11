#!/bin/bash
# sim/verilator/run.sh <DIAG> [vsim options...] -- run an XXDP diagnostic from sim/xxdp.tab on
# the Verilator model: the same image (run_xxdp.sh's XXDP_MEM_ONLY build), start stub, switches,
# pass/fail text and cycle budget as sim/run_xxdp.sh, ~80x faster than GHDL. Builds the model
# first if rtl/ has changed. QUIET=<cycles> sets the silence limit (default 5000000, as tb_xxdp).
set -e
V=$(cd "$(dirname "$0")" && pwd); R=$(cd $V/../.. && pwd); NAME=$1; shift
[ -n "$NAME" ] || { echo "usage: sim/verilator/run.sh <DIAG> [vsim options]" >&2; exit 2; }
if [ ! -x $V/build/vsim ] || [ -n "$(find $R/rtl $R/roms $V/main.cpp $V/unibus_vl.vhd -newer $V/build/vsim 2>/dev/null | head -1)" ]; then
   bash $V/build.sh >&2
fi
LINE=$(grep -v '^#' $R/sim/xxdp.tab | awk -F'|' -v n="$NAME" '$1==n {print; exit}')
[ -n "$LINE" ] || { echo "unknown XXDP test '$NAME' (add a line to sim/xxdp.tab)" >&2; exit 1; }
f() { echo "$LINE" | awk -F'|' -v k=$1 '{print $k}'; }
MEM=$(XXDP_MEM_ONLY=1 bash $R/sim/run_xxdp.sh "$NAME" | tail -1)
set -- --mem "$R/sim/$MEM" --pc 157000 --sw "$(f 4)" --budget "$(f 9)" --quiet "${QUIET:-5000000}" "$@"
[ -n "$(f 5)" ] && set -- "$@" --pass "$(f 5)"
[ -n "$(f 6)" ] && set -- "$@" --fail "$(f 6)"
[ -n "$(f 7)" ] && set -- "$@" --fail2 "$(f 7)"
exec $V/build/vsim "$@"
