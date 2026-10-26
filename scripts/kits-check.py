#!/usr/bin/env python3
"""Checks Loupe's kits before a branch is merged or a build is handed over (docs/kits.md has the order of the steps).

For each package in Package.swift: Package.resolved pins it (a kit in `swift package edit` mode can drop its pin) on a
released tag; the tag is on the kit's origin/main; the kit's main is pushed; and no kit branch of the same name as
Loupe's branch is left unmerged. Code on the kit's main after the pinned tag, a kit checked out on another branch, a
dirty kit and edit mode are reported as notes. The kits' clones are looked for beside Loupe (../<Kit>); a kit without
a clone is checked against Package.resolved only.

Usage: scripts/kits-check.py [--no-fetch]   Exit status 1 when something must be fixed first.
"""
import json
import os
import re
import subprocess
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
fetch = "--no-fetch" not in sys.argv[1:]
problems, notes = [], []


def git(repo, *args):
    run = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    return run.stdout.strip() if run.returncode == 0 else None


def is_ancestor(repo, a, b):
    return subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", a, b]).returncode == 0


branch = git(root, "branch", "--show-current") or ""
manifest = open(os.path.join(root, "Package.swift")).read()
urls = re.findall(r'\.package\(\s*url:\s*"([^"]+)"', manifest)
pins = {p["identity"]: p for p in json.load(open(os.path.join(root, "Package.resolved")))["pins"]}

for url in urls:
    name = re.sub(r"\.git$", "", url.rstrip("/").split("/")[-1])
    pin = pins.get(name.lower())
    if pin is None:
        problems.append(f"{name}: no pin in Package.resolved (written while the kit was in edit mode?)")
        continue
    version, revision = pin["state"].get("version"), pin["state"].get("revision")
    if version is None:
        problems.append(f"{name}: pinned to a branch or revision ({pin['state']}), not to a released tag")
    if os.path.islink(os.path.join(root, "Packages", name)):
        notes.append(f"{name}: in edit mode (Packages/{name}): the build uses the clone, not the pin")
    repo = os.path.join(os.path.dirname(root), name)
    if not os.path.isdir(os.path.join(repo, ".git")):
        notes.append(f"{name}: no clone at ../{name}, only the pin checked")
        continue
    if fetch and git(repo, "fetch", "--quiet", "--tags", "origin") is None:
        notes.append(f"{name}: fetch failed, origin as last fetched")
    main = "origin/main"
    if version is not None:
        tagged = git(repo, "rev-parse", f"{version}^{{commit}}")
        if tagged is None:
            problems.append(f"{name}: the pinned version {version} is not a tag of the kit")
        elif tagged != revision:
            problems.append(f"{name}: tag {version} is {tagged[:7]}, Package.resolved pins {revision[:7]}")
    if revision and not is_ancestor(repo, revision, main):
        problems.append(f"{name}: the pinned {revision[:7]} is not on the kit's {main} (a branch build?)")
    elif revision:
        newest = git(repo, "describe", "--tags", "--abbrev=0", "--match", "[0-9]*", main) or version
        if newest != version:
            notes.append(f"{name}: {newest} is released, Loupe pins {version}")
        later = git(repo, "log", "--oneline", f"{newest}..{main}", "--", "Sources", "Package.swift")
        if later:
            notes.append(f"{name}: code on {main} after {newest}, not released:\n      "
                         + later.replace("\n", "\n      "))
    ahead = git(repo, "rev-list", "--count", f"{main}..main")
    if ahead and ahead != "0":
        problems.append(f"{name}: local main has {ahead} commit(s) not pushed")
    if branch and branch != "main":
        for ref in (branch, f"origin/{branch}"):
            if git(repo, "rev-parse", "--verify", "--quiet", ref) and not is_ancestor(repo, ref, main):
                problems.append(f"{name}: branch {ref} (Loupe's branch) is not merged into the kit's {main}")
    current = git(repo, "branch", "--show-current")
    if current != "main":
        notes.append(f"{name}: the clone is on {current or 'a detached HEAD'}, not main")
    if git(repo, "status", "--porcelain"):
        notes.append(f"{name}: uncommitted changes in the clone")

for line in notes:
    print(f"note: {line}")
for line in problems:
    print(f"error: {line}")
print("kits: ok" if not problems else f"kits: {len(problems)} to fix first")
sys.exit(1 if problems else 0)
