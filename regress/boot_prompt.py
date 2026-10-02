#!/usr/bin/env python3
# Part of the PDP2011 MiSTer regression checks (orig-plus-fixes). Needs the
# MiSTer at MISTER_HOST (default 192.168.51.209) with pdp_harness, the serial
# console enabled (CFG bit 2), and the named .mgl in /media/fat/_Debug.
"""Boot an .mgl and pass when the console shows an expected prompt.

usage: boot_prompt.py <mgl-basename> <logfile> <regex> [timeout_s]

For boots with no scripted dialogue (e.g. a tape kit reaching its first
prompt). The regex is matched case-insensitively against the whole
console. Everything the console prints is kept in the log, and the
harness is stopped afterwards so ttyS1 is free again.
Exit 0 = PASS, 1 = TIMEOUT.
"""
import re, subprocess, sys, time

MGL, LOG, RX = sys.argv[1], sys.argv[2], sys.argv[3]
TIMEOUT = int(sys.argv[4]) if len(sys.argv) > 4 else 300
HOST = __import__("os").environ.get("MISTER_HOST", "192.168.51.209")
SSH = ["sshpass", "-p", "1", "ssh", "-o", "StrictHostKeyChecking=no", "-o", "LogLevel=ERROR",
       "-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password", "root@" + HOST]

def ssh(cmd, timeout=60):
    return subprocess.run(SSH + [cmd], capture_output=True, timeout=timeout).stdout

def console():
    raw = ssh("cat /tmp/pdp_harness/serial.log").decode("latin-1")
    raw = raw.replace("\r", "").replace("\0", "")
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
note(f"loaded {MGL}; waiting for /{RX}/")

result = "TIMEOUT"
while time.time() - t0 < TIMEOUT:
    time.sleep(3)
    m = re.search(RX, console(), re.I)
    if m:
        result = "PASS"; note(f"saw {m.group(0)!r}: PASS"); break
note(f"RESULT {result}")
log.write("=== console ===\n" + console() + "\n"); log.close()
ssh("for p in $(pidof pdp_harness); do kill $p; done")
print(result)
sys.exit(0 if result == "PASS" else 1)
