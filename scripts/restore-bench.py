#!/usr/bin/env python3
"""Restore + activation bench without keystrokes (docs/bench/2026-10-25-restore-and-rereads.md). Quit the running
Loupe first and keep a copy of ~/Library/Application Support/Loupe: Last Session there is overwritten (LOUPE_CONFIG_DIR
moves only loupe.conf). N windows opened, quit (Last Session), relaunched with
session-restore=last; then the app is sent to the back and to the front K times (osascript activate).
Counts from the LOUPE_DEBUG log: `session opened` (main CPU, longest turn), `activate` lines during the restore,
`folder re-read` / `back, no re-read` / `folder names` lines during the activation cycles.
usage: restore-bench.py --app PATH --out DIR --label L --file F ... [--cycles K]"""
import argparse, os, re, subprocess, sys, time

def osa(s): subprocess.run(["osascript", "-e", s], capture_output=True, text=True)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True); ap.add_argument("--out", required=True); ap.add_argument("--label", required=True)
    ap.add_argument("--file", action="append", required=True); ap.add_argument("--cycles", type=int, default=6)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    conf = os.path.join(a.out, f"conf-{a.label}"); os.makedirs(conf, exist_ok=True)
    def write_conf(restore):
        with open(os.path.join(conf, "loupe.conf"), "w") as f:
            f.write(f"open-in=window\nsession-restore={'last' if restore else 'none'}\n")
    if subprocess.run(["pgrep", "-x", "Loupe"], capture_output=True).returncode == 0:
        sys.exit("a Loupe is running; quit it first")
    write_conf(False)
    logpath = os.path.join(a.out, f"{a.label}.log"); log = open(logpath, "w")
    env = dict(os.environ, LOUPE_DEBUG="1", LOUPE_CONFIG_DIR=conf)
    def launch(args): return subprocess.Popen([f"{a.app}/Contents/MacOS/Loupe", *args], env=env, stdout=log, stderr=subprocess.STDOUT)
    proc = launch([a.file[0]]); time.sleep(4)
    for f in a.file[1:]:
        subprocess.run(["open", "-a", a.app, f]); time.sleep(2.5)
    time.sleep(5)
    osa('tell application "Loupe" to quit'); proc.wait(timeout=30)
    write_conf(True)
    log.write("\n=== relaunch ===\n"); log.flush()
    proc = launch([]); time.sleep(12)
    log.write("\n=== cycles ===\n"); log.flush()
    for _ in range(a.cycles):
        osa('tell application "Finder" to activate'); time.sleep(2)
        osa('tell application "Loupe" to activate'); time.sleep(4)
    osa('tell application "Loupe" to quit')
    try: proc.wait(timeout=20)
    except subprocess.TimeoutExpired: proc.kill()
    log.close()
    text = open(logpath, errors="replace").read()
    restore, cycles = text.split("=== relaunch ===", 1)[1].split("=== cycles ===", 1)
    def lines(t): return [m.group(1) for m in re.finditer(r"\[loupe [\d.]+\] (.*)", t)]
    r, c = lines(restore), lines(cycles)
    print(f"== {a.label} ({len(a.file)} windows)")
    print("  " + next((l for l in r if l.startswith("session opened")), "no session opened"))
    print(f"  restore: activate lines {sum(l.startswith('activate ') for l in r)}, "
          f"folder names {sum(l.startswith('folder names') for l in r)}, folder re-read {sum(l.startswith('folder re-read') for l in r)}")
    print(f"  {a.cycles} activations: folder re-read {sum(l.startswith('folder re-read') and ':' in l for l in c)}, "
          f"back without re-read {sum('back, no re-read' in l for l in c)}, activate lines {sum(l.startswith('activate ') for l in c)}, "
          f"paused/resumed {sum(l.endswith('paused') for l in c)}/{sum(l.endswith('resumed') for l in c)}")

main()
