#!/usr/bin/env python3
# Part of the PDP2011 MiSTer regression checks (orig-plus-fixes). Needs the
# MiSTer at MISTER_HOST (default 192.168.51.209) with pdp_harness, the serial
# console enabled (CFG bit 2), UART mode None, and the named .mgl in /media/fat/_Debug.
"""Boot XXDP+, run one diagnostic for a fixed time, count passes and errors.

usage: diag_run.py <mgl-basename> <logfile> <DIAG> [run_seconds]

The .mgl must boot an XXDP+ disk that holds DIAG (e.g. XXDP_RL.dsk with
EKBAD0). After the date, "R <DIAG>" is typed at the "." prompt and the
console is collected for run_seconds (default 240). The diagnostic runs
with its default switches (report errors, keep going). Counts "END PASS"
lines and error reports. Everything the console prints is kept in the log.
Exit 0 = at least one pass and no errors, 1 otherwise.
"""
import re, subprocess, sys, time

MGL, LOG, DIAG = sys.argv[1], sys.argv[2], sys.argv[3].upper()
RUN = int(sys.argv[4]) if len(sys.argv) > 4 else 240
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

stage = 0; t_start = None
while time.time() - t0 < RUN + 180:
    time.sleep(3)
    low = console().lower()
    if stage == 0 and re.search(r"enter date.*:\s*$", low.rstrip(" ")):
        send("01-OCT-99"); note("answered date"); stage = 1
    elif stage == 1 and re.search(r"\n\.\s*$", low):
        send(f"R {DIAG}"); note(f"started R {DIAG}"); stage = 2; t_start = time.time()
    elif stage == 2 and time.time() - t_start > RUN:
        break
txt = console()
run_part = txt[txt.lower().find(f"r {DIAG.lower()}"):] if stage == 2 else ""
passes = len(re.findall(r"end pass", run_part, re.I))
errors = len(re.findall(r"\berror\b|\?err|\bfail|\bbad\b", run_part, re.I))   # EKBBF0 reports "CC'S BAD ..." 
result = "PASS" if passes > 0 and errors == 0 else "FAIL"
note(f"{DIAG}: {passes} END PASS lines, {errors} error reports in {RUN}s: {result}")
log.write("=== console ===\n" + txt + "\n"); log.close()
ssh("for p in $(pidof pdp_harness); do kill $p; done")   # free ttyS1 for a terminal
print(f"{result} passes={passes} errors={errors}")
sys.exit(0 if result == "PASS" else 1)
