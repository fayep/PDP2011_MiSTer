#!/bin/bash
# sim/verilator/rhaddr.sh -- RH70 block addressing for every drive type (rhaddr.mac on the rhbench
# model): 27 corner sectors per type, each block number checked against the geometry by the harness.
# nice 19, two at a time. PASS = every type END PASS with 0 wrong addresses.
set -e
V=$(cd "$(dirname "$0")" && pwd); R=$(cd $V/../.. && pwd); B=$V/build_rh
mkdir -p $B
if [ ! -x $B/vsim_rh ] || [ -n "$(find $R/rtl $R/roms $V/rhbench.cpp $V/unibus_vl_rh.vhd -newer $B/vsim_rh 2>/dev/null | head -1)" ]; then
   nice -n 19 bash $V/build_rh.sh >&2
fi
$R/tools/macro11 $V/rhaddr.mac -o $B/rhaddr.obj -l $B/rhaddr.lst >/dev/null
python3 $V/obj2mem.py $B/rhaddr.obj $B/rhaddr.mem >/dev/null
names=([3]=RM03 [4]=RP04 [5]=RM05 [6]=RP06 [7]=RP07 [8]=RM80)
for t in 3 4 5 6 7 8; do
   nice -n 19 $B/vsim_rh --mem $B/rhaddr.mem --pc 2000 --rhtype $t --pick 20:200 --serve 10:50 --quiet 0 --budget 50000000 > $B/addr_$t.log 2>&1 &
   while [ $(jobs -rp | wc -l) -ge 2 ]; do sleep 1; done
done; wait
bad=0
for t in 3 4 5 6 7 8; do
   printf "%-5s %s  %s\n" ${names[$t]} "$(grep -o 'address check: .*' $B/addr_$t.log || echo 'no writes checked')" "$(grep -ao 'END PASS\|FAIL[A-Z0-9 ]*' $B/addr_$t.log | head -1)"
   grep -q "END PASS" $B/addr_$t.log && grep -q ", 0 wrong" $B/addr_$t.log && grep -q "27 writes" $B/addr_$t.log || bad=1
   grep "^ADDR" $B/addr_$t.log | head -3
done
[ $bad = 0 ] && echo "rhaddr: PASS" || { echo "rhaddr: FAIL"; exit 1; }
