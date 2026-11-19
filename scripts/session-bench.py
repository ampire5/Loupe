#!/usr/bin/env python3
"""The owner's scenario: a session of N full-screen viewer windows on folders of big JXL files is restored; during
the restore the front window is flipped fast (ahead of the cache) and jumped to the end/start; then each window in
turn gets a Space switch, a few flips, Enter (folder browser) and Enter (back to the photo). Measures the
main-thread probe, switch latency, flip → sharp, viewer ↔ browser latency, CPU, and counts log events.

usage: session-bench.py --app PATH --out DIR --label L --file F ... [--conf k=v ...] [--fast N] [--fast-period S]
"""
import argparse, os, re, subprocess, threading, time

from window_bench import bench_environment, ensure_full_screen, report_ownership

def monotonic(): return time.monotonic()
def osa(script):
    t = monotonic(); r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return monotonic() - t, r.stdout.strip(), r.stderr.strip()
def key(code, mods=""):
    t = monotonic(); osa(f'tell application "System Events" to key code {code}{mods}'); return t

class Probe(threading.Thread):
    def __init__(self, period):
        super().__init__(daemon=True); self.period = period; self.samples = []; self.stop = False
    def run(self):
        while not self.stop:
            t0 = monotonic(); dt, out, _ = osa('tell application "Loupe" to name')
            self.samples.append((t0, dt, out == "Loupe"))
            rest = self.period - (monotonic() - t0)
            if rest > 0: time.sleep(rest)

class CPU(threading.Thread):
    def __init__(self, pid):
        super().__init__(daemon=True); self.pid = pid; self.samples = []; self.stop = False
    def run(self):
        while not self.stop:
            r = subprocess.run(["ps", "-o", "cputime=,rss=", "-p", str(self.pid)], capture_output=True, text=True).stdout.split()
            if len(r) == 2:
                m = re.match(r"(\d+):(\d+)\.(\d+)", r[0])
                cpu = int(m.group(1)) * 60 + int(m.group(2)) + int(m.group(3)) / 100 if m else 0
                self.samples.append((monotonic(), cpu, int(r[1]) * 1024))
            time.sleep(0.5)

def wait_log(path, pattern, timeout):
    t0 = monotonic()
    while monotonic() - t0 < timeout:
        with open(path, errors="replace") as f:
            if re.search(pattern, f.read()): return True
        time.sleep(0.2)
    return False

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True); ap.add_argument("--out", required=True); ap.add_argument("--label", required=True)
    ap.add_argument("--file", action="append", required=True); ap.add_argument("--conf", action="append", default=[])
    ap.add_argument("--fast", type=int, default=20); ap.add_argument("--fast-period", type=float, default=0.15)
    ap.add_argument("--no-restore", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    conf = os.path.join(a.out, f"conf-{a.label}"); os.makedirs(conf, exist_ok=True)
    def write_conf(restore):
        with open(os.path.join(conf, "loupe.conf"), "w") as f:
            f.write(f"open-in=window\nsession-restore={'last' if restore else 'none'}\n" + "".join(c + "\n" for c in a.conf))
    write_conf(False)
    env = bench_environment(a.out, conf)
    logpath = os.path.join(a.out, f"{a.label}.log"); log = open(logpath, "w")
    def launch(args): return subprocess.Popen([f"{a.app}/Contents/MacOS/Loupe", *args], env=env, stdout=log, stderr=subprocess.STDOUT)

    proc = launch([a.file[0]]); wait_log(logpath, r"activate 1 ", 20)
    time.sleep(1.5); ensure_full_screen(proc)
    for f in a.file[1:]:
        time.sleep(2.5); subprocess.run(["open", "-a", a.app, f])
    time.sleep(6)
    n = len(a.file)
    marks = {}
    if not a.no_restore:
        osa('tell application "Loupe" to quit'); proc.wait(timeout=30)
        write_conf(True)
        log.write("\n=== relaunch with session-restore=last ===\n"); log.flush()
        marks["relaunch"] = monotonic(); proc = launch([])
        time.sleep(2.0)
    t0 = marks.get("relaunch", monotonic())
    probe = Probe(0.1); probe.start(); cpu = CPU(proc.pid); cpu.start()
    osa('tell application "Loupe" to activate')

    fast = []
    for _ in range(a.fast):
        time.sleep(a.fast_period)
        fast.append(key(124))
    jumps = [key(119)]; time.sleep(1.0)          # END: last photo
    jumps.append(key(115)); time.sleep(1.0)      # HOME: first photo
    switches, flips, browse, back = [], [], [], []
    direction = 123
    for w in range(n):
        if n > 1:
            switches.append(key(direction, " using control down")); time.sleep(1.0)
        for _ in range(4):
            flips.append(key(124)); time.sleep(0.3)
        browse.append(key(36)); time.sleep(2.0)   # ENTER: folder browser
        back.append(key(36)); time.sleep(1.5)     # ENTER: open the selected photo
    time.sleep(8)
    probe.stop = True; cpu.stop = True
    osa('tell application "Loupe" to quit')
    try: proc.wait(timeout=20)
    except subprocess.TimeoutExpired: proc.kill()
    log.close()

    text = open(logpath, errors="replace").read()
    if "=== relaunch" in text: text = text.split("=== relaunch", 1)[1]
    lines = [(float(m.group(1)), m.group(2)) for m in re.finditer(r"\[loupe (\d+\.\d+)\] (.*)", text)]
    def after(ts, pred, within):
        out = []
        for k in ts:
            c = [t for t, l in lines if t > k and t - k < within and pred(l)]
            out.append((c[0] - k) * 1000 if c else None)
        return out
    def pct(v, q): v = sorted(v); return v[min(len(v) - 1, int(len(v) * q))]
    def report(name, vals):
        ok = [v for v in vals if v is not None]
        if ok: print(f"{name}: n={len(ok)}/{len(vals)} p50={pct(ok,0.5):.0f} p90={pct(ok,0.9):.0f} max={max(ok):.0f} ms" + (f"; missed {vals.count(None)}" if None in vals else ""))
        else: print(f"{name}: none of {len(vals)} matched")
    print(f"== {a.label}  ({n} windows{', restored' if not a.no_restore else ''}; conf: {' '.join(a.conf) or 'defaults'})")
    so = [t for t, l in lines if l.startswith("session opened")]
    if so: print(f"session opened: +{so[0]-t0:.1f}s after relaunch")
    navs = [(t, re.sub(r"^navigate -> ", "", l)) for t, l in lines if l.startswith("navigate -> ")]
    def sharp_after(ts):
        out = []
        for k in ts:
            nv = [(t, f) for t, f in navs if t > k and t - k < 3]
            if not nv: out.append(None); continue
            nt, fname = nv[0]
            sh = [t for t, l in lines if t >= nt and l.startswith("entry " + fname) and "full on screen" in l and t - nt < 30]
            out.append((sh[0] - k) * 1000 if sh else None)
        return out
    report("fast flip → navigate", after(fast, lambda l: l.startswith("navigate -> "), 3))
    report("fast flip → sharp (full on screen)", sharp_after(fast))
    report("jump (END/HOME) → sharp", sharp_after(jumps))
    report("switch ⌃← → activate", after(switches, lambda l: l.startswith("activate "), 5))
    report("flip → navigate", after(flips, lambda l: l.startswith("navigate -> "), 3))
    report("flip → sharp", sharp_after(flips))
    report("Enter → home shown", after(browse, lambda l: l.startswith("home shown"), 10))
    report("Enter (browser) → navigate (photo again)", after(back, lambda l: l.startswith("navigate -> ") or l.startswith("focus "), 10))
    base = sorted(d for _, d, ok in probe.samples if ok)
    if not base: raise SystemExit("no successful Apple Event probe")
    print(f"probe: n={len(base)} p50={base[len(base)//2]*1000:.0f} p95={base[int(len(base)*0.95)]*1000:.0f} max={base[-1]*1000:.0f} ms")
    stalls = [(t, d) for t, d, ok in probe.samples if d > 0.25]
    print("probe stalls > 250 ms (s after relaunch, ms):", ", ".join(f"{t-t0:.1f}s {d*1000:.0f}" for t, d in stalls) or "none")
    if cpu.samples:
        c0, c1 = cpu.samples[0], cpu.samples[-1]
        print(f"cpu: {(c1[1]-c0[1]):.1f} s over {(c1[0]-c0[0]):.1f} s = {100*(c1[1]-c0[1])/(c1[0]-c0[0]):.0f} % of one core; rss max {max(s[2] for s in cpu.samples)/1e9:.2f} GB")
    for k in ["activate ", "thumb ", "folder names", "folder re-read", "cancel", "stand-in", "home shown", "strip show"]:
        c = sum(1 for _, l in lines if k in l)
        print(f"  log lines with '{k.strip()}': {c}")
    report_ownership(text, marks.get("relaunch"))
    with open(os.path.join(a.out, f"{a.label}-probe.tsv"), "w") as f:
        for t, d, ok in probe.samples: f.write(f"{t-t0:.3f}\t{d*1000:.0f}\t{int(ok)}\n")

if __name__ == "__main__":
    main()
