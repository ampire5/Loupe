#!/usr/bin/env bash
# Runs the input→present latency matrix (spec §6.1, Task 13): LOUPE_FRAME_LATENCY 1|2 × LOUPE_DRAWABLES 2|3,
# 3 runs each, LOUPE_AUTOPAN=10, full screen, one summary line per run from scripts/latency-report.sh.
# The screen must be unlocked and awake; each run takes up to 60 s (the app is killed by an alarm).
# Usage: scripts/latency-matrix.sh <photo> [log-dir]
#   photo    a large image, e.g. a 147 MP JPEG from the AI folder
#   log-dir  where the per-run logs go (default: build/latency)
# Needs build/Loupe.app (scripts/make-app.sh) and no Loupe running (it refuses otherwise). The runs pass -fullScreen YES, which the app saves as its remembered
# full-screen preference (local.loupe fullScreen); the script puts that preference back exactly as it was (present with
# its value, or absent) when it ends, including on Ctrl-C or an error.
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 <photo> [log-dir]" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
photo=$1
logs=${2:-$root/build/latency}
app=$root/build/Loupe.app/Contents/MacOS/Loupe
[[ -f "$photo" ]] || { echo "no such photo: $photo" >&2; exit 2; }
[[ -x "$app" ]] || { echo "no build/Loupe.app; run scripts/make-app.sh first" >&2; exit 2; }
# Loupe is single-instance by bundle id: with one already running, each run would hand its file over and quit.
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$root/build/Loupe.app/Contents/Info.plist")
# NSRunningApplication by bundle id; if that cannot be asked, any process named Loupe counts.
if ! running=$(osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationsWithBundleIdentifier('$bundle_id').count" 2>/dev/null); then
    running=$(pgrep -x Loupe | wc -l | tr -d ' ')
fi
if [[ $running != 0 ]]; then
    echo "Loupe ($bundle_id) is running; quit it first (the runs would hand over to it and quit)" >&2
    exit 2
fi
mkdir -p "$logs"

# Remember the user's saved full-screen preference and restore it on any exit.
dom=local.loupe key=fullScreen
if saved=$(defaults read "$dom" "$key" 2>/dev/null); then
    saved_type=$(defaults read-type "$dom" "$key" | sed 's/^Type is //')
else
    saved_type=
fi
restore() {
    if [[ -z $saved_type ]]; then
        defaults delete "$dom" "$key" 2>/dev/null || true
    else
        case $saved_type in
            boolean) defaults write "$dom" "$key" -bool "$([[ $saved == 1 ]] && echo YES || echo NO)" ;;
            integer) defaults write "$dom" "$key" -int "$saved" ;;
            float) defaults write "$dom" "$key" -float "$saved" ;;
            *) defaults write "$dom" "$key" -string "$saved" ;;
        esac
    fi
}
trap restore EXIT

for run in 1 2 3; do for fl in 1 2; do for d in 2 3; do
    log=$logs/fl$fl-d$d-run$run.log
    LOUPE_DEBUG=1 LOUPE_AUTOPAN=10 LOUPE_FRAME_LATENCY=$fl LOUPE_DRAWABLES=$d \
        perl -e 'alarm shift; exec @ARGV' 60 "$app" -fullScreen YES "$photo" 2> "$log" || true
    echo -n "latency=$fl drawables=$d run=$run: "
    "$root/scripts/latency-report.sh" "$log" || true
done; done; done
