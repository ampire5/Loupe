#!/usr/bin/env python3
"""Window-switch bench for Loupe: two full-screen windows (a viewer on big JPEGs, a Home grid on a slow NAS folder),
Spaces switched with ⌃← / ⌃→ while both load. Records the main-thread responsiveness probe (an Apple Event round trip
every 100 ms), the app's CPU, and the Loupe debug log; prints per-switch latency (keystroke → `activate` line) and
probe stalls. Needs: build/Loupe.app, no other Loupe running, Accessibility for the terminal (System Events keystrokes).

usage: switch-bench.py --app PATH --viewer FILE --home FOLDER --out DIR [--switches N] [--period S] [--settle S]
                       [--restore]   (quit after setup, relaunch with session-restore=last and switch during restore)
"""
import argparse, os, re, subprocess, threading, time

from window_bench import bench_environment, ensure_full_screen, report_ownership

def monotonic(): return time.monotonic()

def osa(script):
    t = monotonic()
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return monotonic() - t, r.stdout.strip(), r.stderr.strip()

class Probe(threading.Thread):
    """Apple Event round trips; a stalled main thread shows as a long reply."""
    def __init__(self, period):
        super().__init__(daemon=True); self.period = period; self.samples = []; self.stop = False
    def run(self):
        while not self.stop:
            t0 = monotonic()
            dt, out, err = osa('tell application "Loupe" to name')
            self.samples.append((t0, dt, out == "Loupe"))
            rest = self.period - (monotonic() - t0)
            if rest > 0: time.sleep(rest)

class CPU(threading.Thread):
    def __init__(self, pid):
        super().__init__(daemon=True); self.pid = pid; self.samples = []; self.stop = False
    def run(self):
        last = None
        while not self.stop:
            r = subprocess.run(["ps", "-o", "cputime=,rss=", "-p", str(self.pid)], capture_output=True, text=True).stdout.split()
            if len(r) == 2:
                m = re.match(r"(\d+):(\d+)\.(\d+)", r[0])
                cpu = int(m.group(1)) * 60 + int(m.group(2)) + int(m.group(3)) / 100 if m else 0
                self.samples.append((monotonic(), cpu, int(r[1]) * 1024))
            time.sleep(0.5)

def launch(app, env, args, log):
    return subprocess.Popen([f"{app}/Contents/MacOS/Loupe", *args], env=env, stdout=log, stderr=subprocess.STDOUT)

def wait_log(path, pattern, timeout):
    t0 = monotonic()
    while monotonic() - t0 < timeout:
        with open(path, errors="replace") as f:
            if re.search(pattern, f.read()): return True
        time.sleep(0.2)
    return False

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True); ap.add_argument("--viewer", required=True); ap.add_argument("--home", required=True)
    ap.add_argument("--out", required=True); ap.add_argument("--switches", type=int, default=15)
    ap.add_argument("--period", type=float, default=2.0); ap.add_argument("--settle", type=float, default=20)
    ap.add_argument("--restore", action="store_true"); ap.add_argument("--no-switch", action="store_true")
    ap.add_argument("--label", default="run")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    conf = os.path.join(a.out, "conf"); os.makedirs(conf, exist_ok=True)
    with open(os.path.join(conf, "loupe.conf"), "w") as f:
        f.write("open-in=window\nsession-restore=none\n")
    env = bench_environment(a.out, conf)
    logpath = os.path.join(a.out, f"{a.label}.log")
    log = open(logpath, "w")
    marks = []   # (t, what)

    proc = launch(a.app, env, [a.viewer], log)
    marks.append((monotonic(), "launch viewer"))
    wait_log(logpath, r"activate 1 ", 20)
    time.sleep(1.5)
    ensure_full_screen(proc)
    subprocess.run(["open", "-a", a.app, a.home])
    marks.append((monotonic(), "open home folder"))

    if a.restore:
        # Let both windows exist, then quit (Last Session saved) and relaunch with restore; switch during the restore.
        time.sleep(25)
        osa('tell application "Loupe" to quit'); proc.wait(timeout=30)
        with open(os.path.join(conf, "loupe.conf"), "w") as f:
            f.write("open-in=window\nsession-restore=last\n")
        log.write("\n=== relaunch with session-restore=last ===\n"); log.flush()
        marks.append((monotonic(), "relaunch (restore)"))
        proc = launch(a.app, env, [], log)
        time.sleep(1.5)

    probe = Probe(0.1); probe.start()
    cpu = CPU(proc.pid); cpu.start()
    osa('tell application "Loupe" to activate')
    keys = []
    direction = 123  # ⌃← first (the viewer's Space is to the left of the Home one when opened later)
    for i in range(0 if a.no_switch else a.switches):
        time.sleep(a.period)
        t = monotonic()
        osa(f'tell application "System Events" to key code {direction} using control down')
        keys.append(t)
        direction = 124 if direction == 123 else 123
    time.sleep(a.settle)
    probe.stop = True; cpu.stop = True
    marks.append((monotonic(), "end"))
    osa('tell application "Loupe" to quit')
    try: proc.wait(timeout=20)
    except subprocess.TimeoutExpired: proc.kill()
    log.close()

    # Analysis
    text = open(logpath, errors="replace").read()
    acts = [(float(m.group(1)), m.group(2)) for m in re.finditer(r"\[loupe (\d+\.\d+)\] activate (\d+) ", text)]
    print(f"== {a.label}")
    print("keystroke → first `activate <other>` line (ms):")
    lat = []
    for k in keys:
        nxt = [t for t, w in acts if t > k and t - k < 5]
        lat.append((nxt[0] - k) * 1000 if nxt else None)
    print("  " + ", ".join("—" if l is None else f"{l:.0f}" for l in lat))
    good = [l for l in lat if l is not None]
    if good: print(f"  n={len(good)} p50={sorted(good)[len(good)//2]:.0f} max={max(good):.0f}")
    base = sorted(d for _, d, ok in probe.samples if ok)
    if not base: raise SystemExit("no successful Apple Event probe")
    print(f"probe: n={len(base)} p50={base[len(base)//2]*1000:.0f} ms p95={base[int(len(base)*0.95)]*1000:.0f} ms max={base[-1]*1000:.0f} ms")
    stalls = [(t, d) for t, d, ok in probe.samples if d > 0.25]
    t0 = marks[0][0]
    print("probe stalls > 250 ms (s since launch, ms):", ", ".join(f"{t-t0:.1f}s {d*1000:.0f}" for t, d in stalls) or "none")
    if cpu.samples:
        c0, c1 = cpu.samples[0], cpu.samples[-1]
        print(f"cpu: {(c1[1]-c0[1]):.1f} s over {(c1[0]-c0[0]):.1f} s = {100*(c1[1]-c0[1])/(c1[0]-c0[0]):.0f} % of one core; rss max {max(s[2] for s in cpu.samples)/1e9:.2f} GB")
    for pat, name in [(r"folder names (.+?): (\d+) files in (\d+) ms", "folder names"), (r"home shown", "home shown"),
                      (r"session opened", "session opened")]:
        for m in re.finditer(r"\[loupe (\d+\.\d+)\] " + pat, text):
            print(f"  {name}: +{float(m.group(1))-t0:.1f}s {m.group(0)[20:][:90]}")
    thumbs = re.findall(r"\[loupe (\d+\.\d+)\] thumb ", text)
    if thumbs: print(f"  thumbs logged: {len(thumbs)}, first +{float(thumbs[0])-t0:.1f}s last +{float(thumbs[-1])-t0:.1f}s")
    restore_start = next((t for t, name in marks if name == "relaunch (restore)"), None)
    report_ownership(text, restore_start)
    with open(os.path.join(a.out, f"{a.label}-probe.tsv"), "w") as f:
        for t, d, ok in probe.samples: f.write(f"{t-t0:.3f}\t{d*1000:.0f}\t{int(ok)}\n")
    with open(os.path.join(a.out, f"{a.label}-keys.tsv"), "w") as f:
        for k, l in zip(keys, lat): f.write(f"{k-t0:.3f}\t{'' if l is None else f'{l:.0f}'}\n")

if __name__ == "__main__":
    main()
