#!/usr/bin/env python3
# Part of the PDP2011 MiSTer regression checks (orig-plus-fixes). Needs the
# MiSTer at MISTER_HOST (default 192.168.51.209) with pdp_harness, the serial
# console enabled (CFG bit 2), and the named .mgl in /media/fat/_Debug.
"""Drive one full RSTS/E boot/login/shutdown cycle on the MiSTer through pdp_harness.

usage: rsts_cycle.py <mgl-basename> <logfile> [timeout_s]

Loads the .mgl with the harness already listening, answers the boot ROM,
INIT and login prompts, runs $SHUTUP, and passes when INIT asks
"Start timesharing?" again after "on the air". Everything the console
prints is kept in the log. Exit 0 = PASS, 1 = FAIL/timeout.
"""
import re, subprocess, sys, time
import os as _os, subprocess as _sp, sys as _sys
if _sp.run(["sh", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "mister_guard.sh")]).returncode:
    _sys.exit("not taking the MiSTer: it may be in use (regress/mister_guard.sh). Ask first.")

MGL, LOG = sys.argv[1], sys.argv[2]
TIMEOUT = int(sys.argv[3]) if len(sys.argv) > 3 else 420
HOST = __import__("os").environ.get("MISTER_HOST", "192.168.51.209")
SSH = ["sshpass", "-p", "1", "ssh", "-o", "StrictHostKeyChecking=no", "-o", "LogLevel=ERROR",
       "-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=keyboard-interactive", "root@" + HOST]

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
ssh(f"""ps w | grep -q '[M]iSTer_pdp2011' && echo 'load_core /media/fat/menu.rbf' | timeout 15 tee /dev/MiSTer_cmd > /dev/null; sleep 4
for p in $(pidof pdp_harness); do kill $p; done; sleep 1
stty -F /dev/ttyS1 19200 cs8 -parenb -cstopb -crtscts clocal -icanon -echo -ixon min 1 time 0
setsid nohup /media/fat/Scripts/pdp_harness -tcp :7788 > /tmp/pdp_harness_stdout.log 2>&1 < /dev/null &
sleep 2; cp /media/fat/_Debug/{MGL}.mgl /tmp/claude_loaded.mgl; echo 'load_core /media/fat/_Debug/{MGL}.mgl' | timeout 15 tee /dev/MiSTer_cmd > /dev/null""", timeout=60)
note(f"loaded {MGL}")

# (name, regex on lower-cased console tail after the previous answer, reply)
rules = [
    # banner is "boot from rp:" (original ROM) or just "rp" (ROM with TM11)
    ("boot rom", r"(boot from \w+:|\n(mt|rk|rl|rp))\s*$", ""),
    ("option", r"option:.*$", ""),
    ("date", r"date\?.*$", "01-OCT-99"),
    ("time", r"time\?.*$", "12:00"),
    # really INIT's Option: prompt with START as the default -- answer the option, not "yes"
    ("start timesharing", r"start timesharing\?.*$", "START"),
    ("proceed startup", r"proceed with system startup\?.*$", "YES"),
    ("on the air", r"on the air", ""),
    ("user", r"user:\s*$", "1,2"),
    ("password", r"password:\s*$", "letmein"),
    ("attach", r"job number to attach to\?\s*$", ""),
    ("dcl prompt", r"\n\$ ?$", "run $shutup"),
    ("pbs", r"allow print/batch services jobs to complete.*\?\s*$", "yes"),
    ("minutes", r"minutes until system shutdown.*\?\s*$", "0"),
    ("restart", r"shutdown with automatic restart.*\?\s*$", ""),
]
done = set(); pos = 0; idx = 0; result = "TIMEOUT"
while time.time() - t0 < TIMEOUT:
    time.sleep(2)
    text = console(); low = text.lower()
    tail = low[pos:]
    if "on the air" in done and re.search(r"start timesharing\?", tail):
        result = "PASS"; note("INIT asked 'Start timesharing?' again after shutdown: PASS"); break
    fatal = re.search(r"\?device hung|\?fatal|\?.*crash|monitor halt|\?memory addressing|\?error", tail)
    if "start timesharing" in done and "on the air" not in done and fatal:
        result = "FAIL"; note(f"fatal message before 'on the air': {fatal.group(0)!r}: FAIL"); break
    if "start timesharing" in done and "on the air" not in done and low.count("start timesharing?") >= 2:
        result = "FAIL"; note("monitor restarted before 'on the air' (crash/restart): FAIL"); break
    for i in range(idx, len(rules)):
        name, rx, reply = rules[i]
        m = re.search(rx, tail.rstrip(" ") if name != "on the air" else tail, re.S)
        if not m:
            continue
        done.add(name); idx = i + 1; pos = len(low)
        if name == "on the air":
            note("RSTS/E is on the air"); time.sleep(3); send(""); note("sent <CR> for login")
        else:
            send(reply); note(f"answered {name!r} with {reply!r}")
        break
note(f"RESULT {result}")
log.write("=== console ===\n" + console() + "\n"); log.close()
ssh("for p in $(pidof pdp_harness); do kill $p; done")   # free ttyS1 for a terminal
print(result)
sys.exit(0 if result == "PASS" else 1)
