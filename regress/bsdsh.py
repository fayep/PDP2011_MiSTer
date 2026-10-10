#!/usr/bin/env python3
# Part of the PDP2011 MiSTer regression checks: run one shell command on a
# 2.11BSD (or any) console through pdp_harness and print what it printed,
# waiting for the "# " prompt. usage: bsdsh.py "<command>" [timeout_s]
import re, subprocess, sys, time
HOST = __import__("os").environ.get("MISTER_HOST", "192.168.51.209")
SSH = ["sshpass", "-p", "1", "ssh", "-o", "StrictHostKeyChecking=no", "-o", "LogLevel=ERROR",
       "-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password", "root@" + HOST]
def log():
    r = subprocess.run(SSH + ["cat /tmp/pdp_harness/serial.log"], capture_output=True, timeout=60)
    return r.stdout.decode("latin-1").replace("\r", "").replace("\0", "")
cmd, tmo = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 60
start = len(log())
subprocess.run(["nc", "-w", "2", HOST, "7788"], input=("send " + cmd + "\n").encode(), capture_output=True, timeout=20)
t0 = time.time()
while time.time() - t0 < tmo:
    time.sleep(2)
    out = log()[start:]
    if re.search(r"\n# ?$", out.rstrip(" ")):
        break
print(out.strip())
