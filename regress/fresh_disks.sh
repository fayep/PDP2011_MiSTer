#!/bin/sh
# Reset the regression test disks on the MiSTer from their golden (GA)
# images with resilver (only differing 512K blocks are written; the GAs
# are only read). Run before each regression cycle so every build starts
# from an identical, healthy disk. usage: regress/fresh_disks.sh [rl|rp|bsd|all]
H=${MISTER_HOST:-192.168.51.209}
G=/media/fat/games/PDP2011
R=/media/fat/Scripts/resilver
ssh_() { sshpass -p 1 ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o PubkeyAuthentication=no \
         -o PreferredAuthentications=keyboard-interactive root@$H "$1"; }
one() { ssh_ "cd $G && $R $1 $2 2>&1 | tail -1 && md5sum $1 $2 | awk '{print \$1}' | uniq | wc -l | sed 's/^1\$/  identical to GA/;s/^2\$/  DIFFERS from GA/'"; }
case "${1:-all}" in
  rl|all)  one rsts_v9.6_rl_GA.dsk claude_rl_test.dsk ;;
esac
case "${1:-all}" in
  rp|all)  one rsts_v9.6_rp_ga.dsk claude_rsts96_rp.dsk ;;
esac
case "${1:-all}" in
  bsd|all) one 211bsd_rp_GA.dsk claude_211bsd_rp.dsk ;;
esac
