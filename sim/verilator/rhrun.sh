#!/bin/bash
# sim/verilator/rhrun.sh [seeds] -- the RH70 interrupt-vs-controller-clear race bench: assemble
# rhint.mac, build the model if rtl/ changed, run the sweep with seeds 1..N (default 6), at nice 19
# and JOBS (default 2) at a time (each ~1 min, 4503 clears against a completing read, Main's latency random per seed).
# PASS = no stray interrupt (one taken after the clear had dropped IE) in any run.
set -e
V=$(cd "$(dirname "$0")" && pwd); R=$(cd $V/../.. && pwd); B=$V/build_rh; N=${1:-6}
mkdir -p $B
if [ ! -x $B/vsim_rh ] || [ -n "$(find $R/rtl $R/roms $V/rhbench.cpp $V/unibus_vl_rh.vhd -newer $B/vsim_rh 2>/dev/null | head -1)" ]; then
   nice -n 19 bash $V/build_rh.sh >&2
fi
$R/tools/macro11 $V/rhint.mac -o $B/rhint.obj -l $B/rhint.lst >/dev/null
python3 $V/obj2mem.py $B/rhint.obj $B/rhint.mem >/dev/null
J=${JOBS:-2}
for s in $(seq 1 $N); do
   nice -n 19 $B/vsim_rh --mem $B/rhint.mem --pc 2000 --seed $s --quiet 0 > $B/run_$s.log 2>&1 &
   while [ $(jobs -rp | wc -l) -ge $J ]; do sleep 1; done
done; wait
bad=0
for s in $(seq 1 $N); do
   r=$(grep -ao "STRAY [0-7]* LEGIT [0-7]*" $B/run_$s.log || echo "no result")
   echo "seed $s: $r  $(grep -o 'vsim_rh [A-Z]*' $B/run_$s.log)"
   grep -q "END PASS" $B/run_$s.log || bad=1
done
[ $bad = 0 ] && echo "rhrun: PASS" || { echo "rhrun: FAIL"; exit 1; }
