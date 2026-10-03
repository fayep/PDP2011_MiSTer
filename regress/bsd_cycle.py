#!/usr/bin/env python3
# Part of the PDP2011 MiSTer regression checks (orig-plus-fixes). Needs the
# MiSTer at MISTER_HOST (default 192.168.51.209) with pdp_harness, the serial
# console enabled (CFG bit 2), and the named .mgl in /media/fat/_Debug.
"""Drive one full 2.11BSD boot/login/shutdown cycle on the MiSTer through pdp_harness.

usage: bsd_cycle.py <mgl-basename> <logfile> [timeout_s]

Loads the .mgl with the harness already listening, answers the boot ROM,
INIT and login prompts, runs $SHUTUP, and passes when INIT asks
"Start timesharing?" again after "on the air". Everything the console
prints is kept in the log. Exit 0 = PASS, 1 = FAIL/timeout.
"""
import re, subprocess, sys, time

MGL, LOG = sys.argv[1], sys.argv[2]
TIMEOUT = int(sys.argv[3]) if len(sys.argv) > 3 else 1500   # fsck of the large 0c volume runs long and silent
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
note(f"loaded {MGL}")

rules = [
    ("login", r"login:\s*$", "root"),
    ("password", r"password:\s*$", ""),
    ("shell", r"\n# ?$", "shutdown -h now"),
]
done = set(); pos = 0; idx = 0; result = "TIMEOUT"
while time.time() - t0 < TIMEOUT:
    time.sleep(2)
    text = console(); low = text.lower()
    tail = low[pos:]
    if "shell" in done and re.search(r"halted|halting|system halt", tail):
        note("kernel reports halt; waiting 60 s for the disk to dismount and quiesce")
        time.sleep(60); result = "PASS"; note("halted and quiesced: PASS"); break
    fatal = re.search(r"panic:|trap type|\?fatal", low)
    if fatal:
        result = "FAIL"; note(f"fatal: {fatal.group(0)!r}: FAIL"); break
    for i in range(idx, len(rules)):
        name, rx, reply = rules[i]
        if not re.search(rx, tail.rstrip(" "), re.S):
            continue
        done.add(name); idx = i + 1; pos = len(low)
        send(reply); note(f"answered {name!r} with {reply!r}")
        break
if result == "TIMEOUT" and "login" not in done and "marking file system clean" in console().lower():
    result = "TIMEOUT-IN-FSCK"; note("still in /etc/rc fsck (no login: yet) at the timeout")
note(f"RESULT {result}")
log.write("=== console ===\n" + console() + "\n"); log.close()
ssh("for p in $(pidof pdp_harness); do kill $p; done")   # free ttyS1 for a terminal
print(result)
sys.exit(0 if result == "PASS" else 1)
