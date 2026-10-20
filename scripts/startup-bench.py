#!/usr/bin/env python3
"""Launch-to-image timing (docs/bench/2026-10-15-startup.md): how long from exec until the window is up, the first
photo is drawn and its full resolution is on screen, per file given.

usage: scripts/startup-bench.py [--app build/Loupe.app] [--runs 3] [--seconds 4] [--conf FILE] [--keep-logs DIR] FILE...

Each FILE is opened by a fresh launch, --runs times (each launch is killed after --seconds). The app is a copy of
--app (default build/Loupe.app, from scripts/make-app.sh) with its own bundle id and executable name, so a running
Loupe is neither handed the file nor touched, and xctrace can tell them apart. The copy runs with its own home
(CFFIXED_USER_HOME, a temporary folder) holding a copy of loupe.conf (--conf, default ~/.config/loupe/loupe.conf):
the user's Loupe.db, thumbnail cache and defaults are never read or written. One launch with no file comes first and
is not counted: the first launch of a newly signed app pays the system's signature check (0.6-1.1 s).

Times are milliseconds from exec, read off the LOUPE_DEBUG log (whose clock, CACurrentMediaTime, is
CLOCK_UPTIME_RAW): `window` the render loop started, `navigate` the session opened the file, `listed` the folder
listing was applied, `image` the first frame drawn after the photo was first shown, `full` the full resolution was
on screen. "Drawn" is committed to the GPU; while the window is not visible frames are not presented, so on glass
is one or two frames later. A launch opens a window and takes focus for a moment.
"""
import argparse
import os
import plistlib
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

BUNDLE_ID = "dev.loupe.test.startup"
EXEC = "LoupeStartupBench"
LINE = re.compile(r"\[loupe ([0-9.]+)\] (.*)")


def make_app(source, workdir):
    app = os.path.join(workdir, EXEC + ".app")
    shutil.copytree(source, app, symlinks=True)
    macos = os.path.join(app, "Contents", "MacOS")
    os.rename(os.path.join(macos, "Loupe"), os.path.join(macos, EXEC))
    plist_path = os.path.join(app, "Contents", "Info.plist")
    with open(plist_path, "rb") as f:
        plist = plistlib.load(f)
    plist.update(CFBundleIdentifier=BUNDLE_ID, CFBundleExecutable=EXEC, CFBundleName=EXEC)
    with open(plist_path, "wb") as f:
        plistlib.dump(plist, f)
    subprocess.run(["codesign", "--force", "--sign", "-", app], check=True, capture_output=True)
    return os.path.join(macos, EXEC)


def launch(binary, home, args, seconds, log_path):
    env = dict(os.environ, LOUPE_DEBUG="1", CFFIXED_USER_HOME=home)
    with open(log_path, "w") as log:
        t0 = time.clock_gettime(time.CLOCK_UPTIME_RAW)
        log.write("[loupe %.4f] exec\n" % t0)
        log.flush()
        process = subprocess.Popen([binary] + args, stderr=log, stdout=subprocess.DEVNULL, env=env)
        try:
            process.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            process.send_signal(signal.SIGKILL)   # no quit handlers: nothing is written on the way out
            process.wait()


def timeline(log_path):
    events = []
    with open(log_path, errors="replace") as f:
        for line in f:
            m = LINE.match(line)
            if m:
                events.append((float(m.group(1)), m.group(2)))
    t0 = events[0][0]
    out = {}

    def mark(key, t):
        out.setdefault(key, round((t - t0) * 1000))

    shown = full_shown = False
    for t, text in events:
        if text.startswith("frame latency"):
            mark("window", t)
        elif text.startswith("navigate ->"):
            mark("navigate", t)
        elif text.startswith("folder re-read") and " files in " in text:
            mark("listed", t)
        elif text.startswith("entry ") and text.split(" [")[0].endswith("-> show"):
            shown = True
            # Full resolution: the full decode's timing is in, or the entry's state is `full` (a photo whose
            # preview is already level 0: small images, PNG, WebP, JXL).
            timings = text.rsplit("[", 1)[-1] if "[" in text else ""
            full_shown = full_shown or bool(re.search(r"\bfull \d", timings)) or ": full " in text
        elif re.match(r"frame \d+:", text):
            if shown:
                mark("image", t)
            if full_shown:
                mark("full", t)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser.add_argument("--app", default=os.path.join(root, "build", "Loupe.app"))
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--seconds", type=float, default=4)
    parser.add_argument("--conf", default=os.path.expanduser("~/.config/loupe/loupe.conf"))
    parser.add_argument("--keep-logs", metavar="DIR")
    parser.add_argument("files", nargs="+")
    opts = parser.parse_args()
    if not os.path.isdir(opts.app):
        sys.exit(f"no {opts.app}; run scripts/make-app.sh first")
    for path in opts.files:
        if not os.path.isfile(path):
            sys.exit(f"no such file: {path}")
    if subprocess.run(["pgrep", "-x", EXEC], capture_output=True).returncode == 0:
        sys.exit(f"{EXEC} is already running; quit it first")

    work = tempfile.mkdtemp(prefix="loupe-startup-")
    try:
        binary = make_app(opts.app, work)
        home = os.path.join(work, "home")
        os.makedirs(os.path.join(home, ".config", "loupe"))
        if os.path.isfile(opts.conf):
            shutil.copy(opts.conf, os.path.join(home, ".config", "loupe", "loupe.conf"))
        logs = opts.keep_logs or os.path.join(work, "logs")
        os.makedirs(logs, exist_ok=True)
        launch(binary, home, [], min(opts.seconds, 3), os.path.join(logs, "warmup.log"))

        keys = ["window", "navigate", "image", "full", "listed"]
        print("| file | run | " + " | ".join(keys) + " |")
        print("|---|---|" + "---|" * len(keys))
        summary = []
        for path in opts.files:
            rows = []
            for run in range(1, opts.runs + 1):
                log = os.path.join(logs, f"{len(summary) + 1:02d}-{os.path.basename(path)}-{run}.log")
                launch(binary, home, [os.path.abspath(path)], opts.seconds, log)
                row = timeline(log)
                rows.append(row)
                print(f"| {os.path.basename(path)} | {run} | " + " | ".join(str(row.get(k, "-")) for k in keys) + " |")
            summary.append((path, rows))
        print()
        print("Medians (ms from exec):")
        print()
        print("| file | " + " | ".join(keys) + " |")
        print("|---|" + "---|" * len(keys))
        for path, rows in summary:
            cells = []
            for k in keys:
                values = [r[k] for r in rows if k in r]
                cells.append(str(round(statistics.median(values))) if values else "-")
            print(f"| {os.path.basename(path)} | " + " | ".join(cells) + " |")
        if opts.keep_logs:
            print(f"\nlogs: {logs}")
    finally:
        if not opts.keep_logs:
            shutil.rmtree(work, ignore_errors=True)
        else:
            shutil.rmtree(os.path.join(work, EXEC + ".app"), ignore_errors=True)


if __name__ == "__main__":
    main()
