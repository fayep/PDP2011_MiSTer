#!/usr/bin/env python3
# Part of the PDP2011 MiSTer regression checks (orig-plus-fixes). Needs the
# MiSTer at MISTER_HOST (default 192.168.51.209) with pdp_harness, the serial
# console enabled (CFG bit 2), UART mode None, and the named .mgl in /media/fat/_Debug.
"""Boot XXDP+, run one diagnostic for a fixed time, count passes and errors.

usage: diag_run.py <mgl-basename> <logfile> <DIAG> [run_seconds]

The .mgl must boot an XXDP+ disk that holds DIAG (e.g. XXDP_RL.dsk with
EKBAD0). After the date, "R <DIAG>" is typed at the "." prompt and the
console is collected for run_seconds (default 240), or until DIAG_PASSES (default 3)
clean END PASS lines have come in. The diagnostic runs
with its default switches (report errors, keep going). Counts "END PASS"
lines and error reports (report column headers, error words), operator prompts and a
console gone quiet. Everything the console prints is kept in the log.
Exit 0 = at least one pass, no reports, no operator prompt, not quiet; 1 otherwise.
  diag_run.py --score <logfile> <DIAG>   re-scores a saved log (no MiSTer)
"""
import re, subprocess, sys, time
import os as _os, subprocess as _sp, sys as _sys

# --- scoring ----------------------------------------------------------------------------------
# XXDP diagnostics word their failures freely ("MMR0 LOCKED UP THE WRONG PAGE NUMBER", "INCORRECT
# STORE BY MTP INSTRUCTION", "TMCE KT BEND DOESN'T GO LOW ..."), so a vocabulary match ("error",
# "fail", "bad") misses most of them. Every report does print a column header, though: count
# those. Operator prompts and a console gone quiet are failures too -- a looping diagnostic keeps
# printing END PASS, a wedged one goes silent.
REPORT_HDR = re.compile(r"ERRORPC|ERROR PC|TESTNO|TEST NUMBER|TST NUM|PC AT ABORT|CALL AT PC|TEST NO\b", re.I)
VOCAB = re.compile(r"\berror\b|\?err|\bfail|\bbad\b", re.I)
OPERATOR = re.compile(r"CHANGE SWITCH|LOOK AT THE CONSOLE|SET SWITCH|TYPE \S+ TO CONTINUE", re.I)

def score(run_part, quiet_s=None, quiet_limit=60):
    """-> (result, passes, reports, notes) for the console text after 'R <DIAG>'."""
    t = run_part.replace("\0", "")
    lines = [l.strip() for l in re.split(r"[\r\n]+", t)]
    passes = sum(1 for l in lines if re.search(r"END PASS", l, re.I))
    hdr = sum(1 for l in lines if REPORT_HDR.search(l))
    vocab = sum(1 for l in lines if VOCAB.search(l) and not REPORT_HDR.search(l))
    reports = max(hdr, vocab)
    notes = []
    if hdr or vocab: notes.append(f"{hdr} report headers, {vocab} error-word lines")
    if OPERATOR.search(t): notes.append("waiting for the operator: " + OPERATOR.search(t).group(0))
    if quiet_s is not None and quiet_s >= quiet_limit:
        notes.append(f"console quiet for the last {quiet_s:.0f}s (hang?)")
    ok = passes > 0 and reports == 0 and not OPERATOR.search(t) and not (quiet_s is not None and quiet_s >= quiet_limit)
    return ("PASS" if ok else "FAIL"), passes, reports, notes

if len(sys.argv) > 1 and sys.argv[1] == "--score":          # diag_run.py --score <logfile> <DIAG>
    txt = open(sys.argv[2], errors="replace").read()
    d = sys.argv[3].upper(); i = txt.lower().rfind(f"r {d.lower()}")
    r, p_, e_, n_ = score(txt[i:] if i >= 0 else "")
    print(f"{r} passes={p_} reports={e_}" + ("".join(f"\n  {n}" for n in n_)))
    sys.exit(0 if r == "PASS" else 1)
if _sp.run(["sh", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "mister_guard.sh")]).returncode:
    _sys.exit("not taking the MiSTer: it may be in use (regress/mister_guard.sh). Ask first.")

MGL, LOG, DIAG = sys.argv[1], sys.argv[2], sys.argv[3].upper()
RUN = int(sys.argv[4]) if len(sys.argv) > 4 else 240
PASSES = int(_os.environ.get("DIAG_PASSES", "3"))   # stop after this many clean END PASS lines (0: always run RUN)
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
ssh(f"""ps w | grep -q '[M]iSTer_pdp2011' && echo 'load_core /media/fat/menu.rbf' | timeout 15 tee /dev/MiSTer_cmd > /dev/null; sleep 4
for p in $(pidof pdp_harness); do kill $p; done; sleep 1
stty -F /dev/ttyS1 19200 cs8 -parenb -cstopb -crtscts clocal -icanon -echo -ixon min 1 time 0
setsid nohup /media/fat/Scripts/pdp_harness -tcp :7788 > /tmp/pdp_harness_stdout.log 2>&1 < /dev/null &
sleep 2; cp /media/fat/_Debug/{MGL}.mgl /tmp/claude_loaded.mgl; echo 'load_core /media/fat/_Debug/{MGL}.mgl' | timeout 15 tee /dev/MiSTer_cmd > /dev/null""", timeout=60)
note(f"loaded {MGL}")

stage = 0; t_start = None; seen_len = 0; t_last = time.time()
while time.time() - t0 < RUN + 180:
    time.sleep(3)
    low = console().lower()
    if len(low) != seen_len: seen_len, t_last = len(low), time.time()
    if stage == 0 and re.search(r"enter date.*:\s*$", low.rstrip(" ")):
        send("01-OCT-99"); note("answered date"); stage = 1
    elif stage == 1 and re.search(r"\n\.\s*$", low):
        send(f"R {DIAG}"); note(f"started R {DIAG}"); stage = 2; t_start = time.time()
    elif stage == 2 and time.time() - t_start > RUN:
        break
    elif stage == 2 and PASSES and score(console()[console().lower().find(f"r {DIAG.lower()}"):])[1] >= PASSES \
            and score(console()[console().lower().find(f"r {DIAG.lower()}"):])[2] == 0:
        break                                        # enough clean passes: no need to sit out RUN
txt = console()
run_part = txt[txt.lower().find(f"r {DIAG.lower()}"):] if stage == 2 else ""
result, passes, errors, notes = score(run_part, quiet_s=time.time() - t_last)
note(f"{DIAG}: {passes} END PASS lines, {errors} error reports in {RUN}s: {result}")
for n in notes: note(f"  {n}")
log.write("=== console ===\n" + txt + "\n"); log.close()
ssh("for p in $(pidof pdp_harness); do kill $p; done")   # free ttyS1 for a terminal
print(f"{result} passes={passes} errors={errors}")
sys.exit(0 if result == "PASS" else 1)
