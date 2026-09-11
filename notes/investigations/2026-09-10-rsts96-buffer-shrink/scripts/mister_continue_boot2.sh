#!/bin/sh
DEV=/dev/ttyS1
LOG=/tmp/mister_continue_boot2.log
rm -f "$LOG"
stty -F $DEV 19200 cs8 -parenb -cstopb -crtscts clocal -icanon -echo -ixon min 1 time 0
exec 3<>$DEV
cat <&3 > "$LOG" &
CATPID=$!
sleep 1
printf '6-SEP-95\r' >&3

sent_time=0
sent_ts=0
i=0
while [ $i -lt 60 ]; do
  sleep 1
  i=$((i+1))
  if [ $sent_time -eq 0 ] && grep -qi "current time" "$LOG" 2>/dev/null; then
    sleep 1
    printf '12:00 AM\r' >&3
    sent_time=1
  fi
  if [ $sent_ts -eq 0 ] && grep -qi "timesharing?" "$LOG" 2>/dev/null; then
    sleep 1
    printf '\r' >&3
    sent_ts=1
  fi
  if grep -q "devices disabled" "$LOG" 2>/dev/null; then
    sleep 2
    break
  fi
done

kill $CATPID 2>/dev/null
exec 3<&-
sleep 1
echo "=== CAPTURE START ==="
cat "$LOG"
echo "=== CAPTURE END ==="
