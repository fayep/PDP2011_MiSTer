#!/bin/sh
DEV=/dev/ttyS1
LOG=/tmp/mister_trace_boot2.log
rm -f "$LOG"
stty -F $DEV 19200 cs8 -parenb -cstopb -crtscts clocal -icanon -echo -ixon min 1 time 0
exec 3<>$DEV
cat <&3 > "$LOG" &
CATPID=$!
sleep 1
printf '6-SEP-95\r' >&3
sleep 3
printf '12:00 AM\r' >&3
sleep 2
printf '\r' >&3

i=0
while [ $i -lt 30 ]; do
  sleep 1
  i=$((i+1))
  if grep -q "devices disabled" "$LOG" 2>/dev/null; then
    sleep 1
    break
  fi
done

kill $CATPID 2>/dev/null
exec 3<&-
sleep 1
echo "=== CAPTURE START ==="
cat "$LOG"
echo "=== CAPTURE END ==="
echo "=== TRACE START ==="
python3 /media/fat/Scripts/pdp-odt trace
echo "=== TRACE END ==="
