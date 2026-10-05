#!/bin/sh
# Part of the PDP2011 MiSTer regression checks: refuse to take the MiSTer
# while someone else is using it. Every script that loads a core runs this
# first and stops if it fails.
#
# Safe when the menu core is loaded (nobody can have a system running; Main
# may still hold leaked image descriptors from an earlier core), or when the
# core came from a _Debug/claude_*.mgl and Main has no image open except
# claude_* scratch images.
# Anything else (a user's own MGL, or a user's disk mounted through the OSD)
# means a person may have a system running: exit 1 and say what is there.
# There is deliberately no override; ask the user, and let them shut down.
H=${MISTER_HOST:-192.168.51.209}
# MISTER_GUARD_TEST replaces the ssh query (for testing this script only)
if [ -n "$MISTER_GUARD_TEST" ]; then out=$MISTER_GUARD_TEST; else
out=$(sshpass -p 1 ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o PubkeyAuthentication=no \
      -o PreferredAuthentications=password root@$H '
p=$(pidof MiSTer_pdp2011 MiSTer | tr " " "\n" | head -1)
echo "core: $(tr "\0" " " < /proc/$p/cmdline)"
for f in /proc/$p/fd/*; do readlink "$f"; done 2>/dev/null | grep -E "\.(dsk|DSK|tap|TAP|img|vhd)$" | sed "s/^/open: /"
' 2>&1) || { echo "mister_guard: cannot reach the MiSTer: $out"; exit 1; }
fi
core=$(echo "$out" | sed -n 's/^core: //p')
bad=$(echo "$out" | sed -n 's/^open: //p' | grep -v '/claude_[^/]*$')
case "$core" in
   *menu.rbf*) exit 0 ;;
   */_Debug/claude_*.mgl*) ;;
   *) echo "mister_guard: NOT SAFE - core loaded by the user: $core"; exit 1 ;;
esac
if [ -n "$bad" ]; then
   echo "mister_guard: NOT SAFE - user images open:"; echo "$bad" | sed 's/^/   /'; exit 1
fi
exit 0
