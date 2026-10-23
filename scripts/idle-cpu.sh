#!/usr/bin/env bash
# How much CPU Loupe and WindowServer use while Loupe sits at rest.
# Usage: scripts/idle-cpu.sh [--app PATH] [--settle S] [--window S] FOLDER [IMAGE]
#   --app PATH    the app to run (default build/Loupe.app)
#   --settle S    seconds to wait after each launch or switch before measuring (default 60)
#   --window S    seconds each measurement lasts (default 60)
#   FOLDER        opened in Home. May be on an SMB share: only its top level is listed, never recursively.
#   IMAGE         opened in the viewer (default: the first JPEG/HEIC/PNG/JXL by name at FOLDER's top level)
# States measured, each after the settle time: (0) WindowServer alone, before Loupe launches; (1) Home on FOLDER;
# (2) the viewer on IMAGE; (3) the window hidden (NSRunningApplication.hide, no Accessibility permission needed; the
# state is skipped with a note when the app does not report itself hidden). Per state the CPU time delta of Loupe
# and of WindowServer over the window (cumulative `ps -o time=`, not instantaneous %CPU) is printed as % of one core.
# At rest Loupe should stay around 1-2 % of one core or below (docs/bench/).
# The output never contains FOLDER's path or name (it goes into public bench docs); it says only "local" or "on an
# SMB share" and the number of entries at the top level.
#
# The owner's state: Loupe has no switch for an isolated profile except LOUPE_CONFIG_DIR (loupe.conf), which this
# script uses (an empty temp dir: default settings, session-restore off). Loupe.db and the thumbnail cache sit at
# fixed places under the real home and the UserDefaults domain is the app's own, and a run writes to all of them
# (Last Session, folder positions, thumbnails, window frame). So before the run the script copies
# ~/Library/Application Support/Loupe, ~/Library/Caches/Loupe, ~/Library/Saved Application State/<bundle id>.savedState
# and exports the app's defaults domain to a temp dir, and an EXIT trap puts them back (removing what did not exist
# before) once Loupe has exited. It refuses to start when Loupe is already running.
set -euo pipefail
cd "$(dirname "$0")/.."

app=build/Loupe.app settle=60 window=60 folder="" image=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) app=${2:?--app needs a path}; shift ;;
        --settle) settle=${2:?--settle needs seconds}; shift ;;
        --window) window=${2:?--window needs seconds}; shift ;;
        -*) echo "error: unknown argument $1" >&2; exit 1 ;;
        *) if [[ -z $folder ]]; then folder=$1; elif [[ -z $image ]]; then image=$1; else echo "error: too many arguments" >&2; exit 1; fi ;;
    esac
    shift
done
[[ -n $folder ]] || { echo "usage: scripts/idle-cpu.sh [--app PATH] [--settle S] [--window S] FOLDER [IMAGE]" >&2; exit 1; }
[[ $settle =~ ^[0-9]+$ && $window =~ ^[0-9]+$ && $window -gt 0 ]] || { echo "error: --settle and --window are whole seconds" >&2; exit 1; }
[[ -d $folder ]] || { echo "error: FOLDER is not a directory" >&2; exit 1; }
[[ -x $app/Contents/MacOS/Loupe ]] || { echo "error: no Loupe app at --app" >&2; exit 1; }
app=$(cd "$app" && pwd)   # open -a needs an absolute path
if pgrep -x Loupe >/dev/null; then
    echo "error: Loupe is running; quit it first (this script does not touch a running session)" >&2; exit 1
fi

# A share this shell may not list (macOS privacy: network volumes) still works when IMAGE is given.
listed=$(ls -A1 "$folder" 2>/dev/null) || listed=""
if [[ -z $image ]]; then
    # One non-recursive listing of the top level, sorted by name.
    first=$(printf '%s\n' "$listed" | grep -iE '\.(jpe?g|heic|png|jxl)$' | head -n 1 || true)
    [[ -n $first ]] || { echo "error: no JPEG/HEIC/PNG/JXL at the top level of FOLDER (or it cannot be listed); pass IMAGE" >&2; exit 1; }
    image=${folder%/}/$first
fi
[[ -f $image ]] || { echo "error: IMAGE is not a file" >&2; exit 1; }

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
support=$HOME/Library/Application\ Support/Loupe
caches=$HOME/Library/Caches/Loupe
saved=$HOME/Library/Saved\ Application\ State/$bundle_id.savedState

work=$(mktemp -d "${TMPDIR:-/tmp}/idle-cpu.XXXXXX")
mkdir -p "$work/backup" "$work/config"
restored=0 backed_up=0
pid=""

# --- backup and restore ---------------------------------------------------------------------------------------
backup_one() { # path name
    if [[ -e $1 ]]; then cp -Rp "$1" "$work/backup/$2"; else touch "$work/backup/$2.absent"; fi
}
restore_one() { # path name
    rm -rf "$1"
    if [[ -e $work/backup/$2 ]]; then mkdir -p "$(dirname "$1")"; cp -Rp "$work/backup/$2" "$1"; fi
}
quit_loupe() {
    [[ -n $pid ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    osascript -l JavaScript -e "ObjC.import('AppKit'); var a=$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid); if (a) a.terminate();" >/dev/null 2>&1 || true
    local i=0
    while kill -0 "$pid" 2>/dev/null && [[ $i -lt 40 ]]; do sleep 0.5; i=$((i + 1)); done
    kill -0 "$pid" 2>/dev/null && kill -TERM "$pid" 2>/dev/null || true
    i=0
    while kill -0 "$pid" 2>/dev/null && [[ $i -lt 20 ]]; do sleep 0.5; i=$((i + 1)); done
    return 0
}
restore_all() {
    [[ $restored -eq 0 ]] || return 0
    restored=1
    quit_loupe
    # Only a complete backup is put back: a copy that failed half-way must not replace the real state.
    [[ $backed_up -eq 1 ]] || { echo "note: backup incomplete; nothing restored, real state untouched before launch" >&2; rm -rf "$work"; return 0; }
    pgrep -x Loupe >/dev/null && { echo "warning: Loupe still running; state NOT restored, backup kept in $work" >&2; return 0; }
    restore_one "$support" support
    restore_one "$caches" caches
    restore_one "$saved" saved
    if [[ -f $work/backup/defaults.plist ]]; then
        defaults import "$bundle_id" "$work/backup/defaults.plist"
    else
        defaults delete "$bundle_id" >/dev/null 2>&1 || true
    fi
    rm -rf "$work"
}
trap restore_all EXIT
trap 'exit 130' INT TERM

backup_one "$support" support
backup_one "$caches" caches
backup_one "$saved" saved
defaults export "$bundle_id" "$work/backup/defaults.plist" >/dev/null 2>&1 || rm -f "$work/backup/defaults.plist"
backed_up=1

# --- measuring ------------------------------------------------------------------------------------------------
cpu_seconds() { # pid -> cumulative CPU time in seconds ([dd-][hh:]mm:ss.ss)
    ps -o time= -p "$1" | awk '{ t=$1; d=0; if (index(t,"-")) { split(t,a,"-"); d=a[1]; t=a[2] }
        n=split(t,p,":"); s=0; for (i=1;i<=n;i++) s=s*60+p[i]; printf "%.2f", s+d*86400 }'
}
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
ws_pid=$(pgrep -x WindowServer | head -n 1)
[[ -n $ws_pid ]] || { echo "error: WindowServer not found" >&2; exit 1; }
loupe_pct="" ws_pct=""
measure() { # [loupe pid or empty]: sets loupe_pct, ws_pct over $window seconds
    local l0="" l1="" w0 w1 t0 t1
    [[ -z ${1:-} ]] || l0=$(cpu_seconds "$1")
    w0=$(cpu_seconds "$ws_pid"); t0=$(now)
    sleep "$window"
    [[ -z ${1:-} ]] || l1=$(cpu_seconds "$1")
    w1=$(cpu_seconds "$ws_pid"); t1=$(now)
    ws_pct=$(awk -v a="$w0" -v b="$w1" -v s="$t0" -v e="$t1" 'BEGIN { printf "%.1f", (b-a)/(e-s)*100 }')
    if [[ -n $l0 ]]; then
        loupe_pct=$(awk -v a="$l0" -v b="$l1" -v s="$t0" -v e="$t1" 'BEGIN { printf "%.1f", (b-a)/(e-s)*100 }')
    else loupe_pct="-"; fi
}

# --- the folder, described neutrally ---------------------------------------------------------------------------
mount_point=$(df -P "$folder" | awk 'NR==2 { $1=$2=$3=$4=$5=""; sub(/^ +/, ""); print }')
if mount | grep -F " on $mount_point (" | grep -qE 'smbfs|nfs|afpfs|webdav'; then where="on a network share"; else where="local"; fi
if [[ -n $listed ]]; then entries=$(printf '%s\n' "$listed" | wc -l | tr -d ' '); else entries="?"; fi
machine="$(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown CPU), $(sysctl -n hw.physicalcpu) cores ($(sysctl -n hw.logicalcpu) threads), macOS $(sw_vers -productVersion)"

# --- the run ----------------------------------------------------------------------------------------------------
echo "Baseline: WindowServer alone, settle ${settle} s, window ${window} s ..." >&2
sleep "$settle"; measure ""
base_ws=$ws_pct

echo "Launching Loupe on the folder (Home) ..." >&2
open -a "$app" --env "LOUPE_CONFIG_DIR=$work/config" "$folder"
i=0
while [[ -z $pid && $i -lt 60 ]]; do pid=$(pgrep -x Loupe | head -n 1 || true); [[ -n $pid ]] || sleep 0.5; i=$((i + 1)); done
[[ -n $pid ]] || { echo "error: Loupe did not start" >&2; exit 1; }
sleep "$settle"; measure "$pid"
home_l=$loupe_pct home_w=$ws_pct

echo "Opening the image in the viewer ..." >&2
open -a "$app" "$image"
sleep "$settle"; measure "$pid"
view_l=$loupe_pct view_w=$ws_pct

echo "Hiding the window ..." >&2
hidden=$(osascript -l JavaScript -e "ObjC.import('AppKit'); var a=$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid); a.hide(); delay(1); a.isHidden" 2>/dev/null || echo false)
if [[ $hidden == true ]]; then
    sleep "$settle"; measure "$pid"
    hid_l=$loupe_pct hid_w=$ws_pct
else
    hid_l="skipped" hid_w="skipped"
    echo "note: the app did not report itself hidden without extra permissions; hidden state skipped" >&2
fi

echo "Quitting Loupe ..." >&2
quit_loupe

echo
echo "Idle CPU, % of one core (CPU time delta over ${window} s, after ${settle} s settle)"
echo "Machine: $machine"
echo "Folder: $where, $entries entries at the top level"
echo
printf '%-34s %8s %14s\n' "State" "Loupe" "WindowServer"
printf '%-34s %8s %14s\n' "WindowServer baseline (no Loupe)" "-" "$base_ws"
printf '%-34s %8s %14s\n' "Home on the folder" "$home_l" "$home_w"
printf '%-34s %8s %14s\n' "Viewer on an image" "$view_l" "$view_w"
printf '%-34s %8s %14s\n' "Window hidden" "$hid_l" "$hid_w"
echo
echo "Threshold: Loupe at rest should stay around 1-2 % of one core or below."
