"""Shared setup and ownership counters for the window benchmarks."""

import os
import re
import subprocess
import tempfile
import time


def bench_environment(out, conf):
    running = subprocess.run(["pgrep", "-x", "Loupe"], capture_output=True)
    if running.returncode == 0:
        raise SystemExit("a Loupe is running; quit it first")
    if running.returncode != 1:
        raise SystemExit("cannot check for a running Loupe")
    probe = subprocess.run(["osascript", "-e", 'tell application "System Events" to get UI elements enabled'],
                           capture_output=True, text=True)
    if probe.returncode != 0 or probe.stdout.strip() != "true":
        raise SystemExit(f"System Events Accessibility is required: {probe.stderr.strip()}")
    home = tempfile.mkdtemp(prefix="bench-home-", dir=os.path.abspath(out))
    return dict(os.environ, CFFIXED_USER_HOME=home, LOUPE_DEBUG="1", LOUPE_CONFIG_DIR=os.path.abspath(conf),
                LOUPE_CACHE_DIR=os.path.join(home, "cache"))


def ensure_full_screen(proc):
    script = (f'tell application "System Events" to tell (first process whose unix id is {proc.pid}) '
              'to get value of attribute "AXFullScreen" of window 1')
    window_ready = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if window_ready.stdout.strip() == "false":
        subprocess.run(["osascript", "-e", 'tell application "Loupe" to activate'], check=True)
        subprocess.run(["osascript", "-e",
                        'tell application "System Events" to key code 3 using {control down, command down}'],
                       check=True)
        for _ in range(20):
            time.sleep(0.25)
            window_ready = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
            if window_ready.stdout.strip() == "true":
                return
    if window_ready.stdout.strip() != "true":
        proc.terminate()
        proc.wait(timeout=20)
        raise SystemExit(f"benchmark window did not enter full screen: {window_ready.stderr.strip()}")


def report_ownership(text, restore_start):
    entries = [(float(stamp), message) for stamp, message in re.findall(r"\[loupe (\d+\.\d+)\] (.*)", text)]
    if restore_start is not None:
        entries = [(stamp, message) for stamp, message in entries if stamp >= restore_start]
    activations = [message for _, message in entries if message.startswith("activate ")]
    if activations:
        latest = activations[-1]
        evicted = re.search(r"other windows −(\d+) \((\d+) MB\)", latest)
        kept = re.search(r" · kept (\d+) MB", latest)
        rereads = re.search(r" · rereads (\d+)", latest)
        count, size = evicted.groups() if evicted else (0, 0)
        print(f"last activation: other windows {count} ({size} MiB), kept {kept[1] if kept else 0} MiB, "
              f"rereads {rereads[1] if rereads else 0}")
    if restore_start is not None:
        first_key = next((stamp for stamp, message in entries if message.startswith("key ")), float("inf"))
        before_key = sum(stamp < first_key and message.startswith("activate ") for stamp, message in entries)
        listings = sum(stamp - restore_start <= 3 and message.startswith("folder names ") for stamp, message in entries)
        print(f"restore: {before_key} activations before first logged key, {listings} listings in first 3 s")
        opened = next((stamp for stamp, message in entries if message.startswith("session opened:")), None)
        if opened is not None:
            full = next((stamp for stamp, message in entries
                         if stamp >= opened and "full on screen" in message), None)
            if full is not None:
                print(f"session opened → first subsequent full on screen: {(full - opened) * 1000:.0f} ms")
