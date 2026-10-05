#!/usr/bin/env python3
# Part of the PDP2011 MiSTer regression checks (orig-plus-fixes). Needs the
# MiSTer at MISTER_HOST (default 192.168.51.209) with pdp_harness, the serial
# console enabled (CFG bit 2), UART mode None, and the named .mgl in /media/fat/_Debug.
"""Boot XXDP+ from a disk, answer the date, list the directory (monitor command D).

usage: xxdp_cycle.py <mgl-basename> <logfile> [timeout_s]

Passes when the D listing (ENTRY# header, entries) is followed by the "."
prompt again: the monitor booted and read the whole directory through the
disk controller. The entry count and last entry number are logged. Everything the
console prints is kept in the log; the harness is stopped afterwards.
Exit 0 = PASS, 1 = FAIL/TIMEOUT.
"""
import re, subprocess, sys, time
import os as _os, subprocess as _sp, sys as _sys
if _sp.run(["sh", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "mister_guard.sh")]).returncode:
    _sys.exit("not taking the MiSTer: it may be in use (regress/mister_guard.sh). Ask first.")

MGL, LOG = sys.argv[1], sys.argv[2]
TIMEOUT = int(sys.argv[3]) if len(sys.argv) > 3 else 300
HOST = __import__("os").environ.get("MISTER_HOST", "192.168.51.209")
SSH = ["sshpass", "-p", "1", "ssh", "-o", "StrictHostKeyChecking=no", "-o", "LogLevel=ERROR",
       "-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password", "root@" + HOST]

def ssh(cmd, timeout=60):
    """Run cmd on the MiSTer. A failed connection (refused, dropped, or a login
    rejected while the MiSTer is busy) is retried; if it never gets through the
    test stops with an error instead of carrying on as if cmd had run."""
    for attempt in range(5):
        r = subprocess.run(SSH + [cmd], capture_output=True, timeout=timeout)
        err = r.stderr.decode("latin-1")
        if r.returncode != 255 and "Permission denied" not in err and "Connection" not in err:
            return r.stdout
        time.sleep(5)
    sys.exit("ssh to %s failed 5 times: %s" % (HOST, err.strip()))

def send(text):
    subprocess.run(["nc", "-w", "2", HOST, "7788"], input=("send " + text + "\n").encode(),
                   capture_output=True, timeout=20)

def console():
    raw = ssh("cat /tmp/pdp_harness/serial.log").decode("latin-1")
    raw = raw.replace("\r", "").replace("\0", "").replace("\xff", "")
    k = raw.rfind("pdp_harness started")
    return raw[k:] if k >= 0 else raw

log = open(LOG, "w")
def note(msg):
    log.write(f"[{time.time() - t0:6.1f}s] {msg}\n"); log.flush()

t0 = time.time()
ssh(f"""echo 'load_core /media/fat/menu.rbf' > /dev/MiSTer_cmd; sleep 4
for p in $(pidof pdp_harness); do kill $p; done; sleep 1
stty -F /dev/ttyS1 19200 cs8 -parenb -cstopb -crtscts clocal -icanon -echo -ixon min 1 time 0
setsid nohup /media/fat/Scripts/pdp_harness -tcp :7788 > /tmp/pdp_harness_stdout.log 2>&1 < /dev/null &
sleep 2; echo 'load_core /media/fat/_Debug/{MGL}.mgl' > /dev/MiSTer_cmd""", timeout=60)
note(f"loaded {MGL}")

rules = [("date", r"enter date.*:\s*$", "01-OCT-99"),
         ("prompt", r"\n\.\s*$", "D")]
idx = 0; pos = 0; result = "TIMEOUT"
while time.time() - t0 < TIMEOUT:
    time.sleep(2)
    low = console().lower(); tail = low[pos:]
    if idx == len(rules) and "entry#" in tail and re.search(r"\n\.\s*$", tail):
        entries = re.findall(r"^\s*(\d+)\s+\S+\.\S+", tail, re.M)
        if entries:
            result = "PASS"; note(f"directory listed, {len(entries)} entries, last #{entries[-1]}: PASS"); break
    if re.search(r"\?\s*(error|halt)|trap to 4|halted at", tail):
        result = "FAIL"; note("error on the console: FAIL"); break
    if idx < len(rules):
        name, rx, reply = rules[idx]
        if re.search(rx, tail.rstrip(" ")):
            send(reply); note(f"answered {name!r} with {reply!r}"); idx += 1; pos = len(low)
note(f"RESULT {result}")
log.write("=== console ===\n" + console() + "\n"); log.close()
ssh("for p in $(pidof pdp_harness); do kill $p; done")   # free ttyS1 for a terminal
print(result)
sys.exit(0 if result == "PASS" else 1)
