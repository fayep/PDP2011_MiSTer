#!/usr/bin/env python3
# Part of the PDP2011 MiSTer regression checks (orig-plus-fixes). Needs the
# MiSTer at MISTER_HOST (default 192.168.51.209) with pdp_harness, the serial
# console enabled (CFG bit 2), UART mode None, and the named .mgl in /media/fat/_Debug.
"""Load an .mgl N times and count how often the core starts the boot ROM.
usage: boot_repeat.py <mgl-basename> <logfile> [loads] [wait_s]
Each load goes through the menu core first (a full reconfiguration of the
FPGA), then the .mgl, and passes when the boot ROM banner "Hello, world"
appears on the console within wait_s (default 20). A core that does not start
at the boot ROM prints nothing. Everything the console prints is kept in the
log; the harness is stopped afterwards so ttyS1 is free again.
Exit 0 = every load booted, 1 = at least one did not.
"""
import os
import subprocess
import sys
import time
import os as _os, subprocess as _sp, sys as _sys
if _sp.run(["sh", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "mister_guard.sh")]).returncode:
    _sys.exit("not taking the MiSTer: it may be in use (regress/mister_guard.sh). Ask first.")

MGL, LOG = sys.argv[1], sys.argv[2]
LOADS = int(sys.argv[3]) if len(sys.argv) > 3 else 10
WAIT = int(sys.argv[4]) if len(sys.argv) > 4 else 20
HOST = os.environ.get("MISTER_HOST", "192.168.51.209")
SSH = ["sshpass", "-p", "1", "ssh", "-o", "StrictHostKeyChecking=no", "-o", "LogLevel=ERROR",
       "-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=keyboard-interactive", "root@" + HOST]
SERIAL = "/tmp/pdp_harness/serial.log"


def ssh(cmd, timeout=60):
    return subprocess.run(SSH + [cmd], capture_output=True, timeout=timeout).stdout.decode("latin-1")


def since_start():
    """Console text since the harness last started."""
    return ssh("awk '/pdp_harness started/{n=NR} {l[NR]=$0} END{for(i=n+1;i<=NR;i++) print l[i]}' "
               + SERIAL + " | tr -d '\\r'")


booted = 0
with open(LOG, "w") as log:
    for i in range(1, LOADS + 1):
        ssh("ps w | grep -q '[M]iSTer_pdp2011' && echo 'load_core /media/fat/menu.rbf' | timeout 15 tee /dev/MiSTer_cmd > /dev/null; sleep 4; "
            "for p in $(pidof pdp_harness); do kill $p; done; "
            "setsid nohup /media/fat/Scripts/pdp_harness -tcp :7788 > /tmp/pdp_harness_stdout.log 2>&1 < /dev/null & "
            "sleep 2; cp /media/fat/_Debug/%s.mgl /tmp/claude_loaded.mgl; echo 'load_core /media/fat/_Debug/%s.mgl' > /dev/MiSTer_cmd" % (MGL, MGL))
        t0 = time.time()
        text = ""
        while time.time() - t0 < WAIT:
            time.sleep(2)
            text = since_start()
            if "Hello, world" in text:
                break
        ok = "Hello, world" in text
        booted += ok
        line = "load %2d: %s (%.0f s)" % (i, "BOOT" if ok else "NO OUTPUT", time.time() - t0)
        print(line, flush=True)
        log.write("##### " + line + "\n" + text + "\n")
    ssh("for p in $(pidof pdp_harness); do kill $p; done")
    summary = "RESULT %d/%d loads booted" % (booted, LOADS)
    print(summary)
    log.write(summary + "\n")
sys.exit(0 if booted == LOADS else 1)
