#!/usr/bin/env bash
# Summarises a LOUPE_DEBUG log of a LOUPE_AUTOPAN run (spec §6.1): input→present latency (median, p90), frame
# intervals longer than 1.5 × the display period, frames drawn and frames not presented. Only frames presented
# between "autopan start" and "autopan end" count; the period is the median of the callbacks' "period" values.
# Usage: scripts/latency-report.sh <log> [more logs…]   (one summary line per log)
set -uo pipefail   # no -e: a bad log reports its own failure line and the others still run
[[ $# -ge 1 ]] || { echo "usage: $0 <log>..." >&2; exit 2; }
status=0
for log in "$@"; do
    [[ -r "$log" ]] || { echo "$log: cannot read"; status=1; continue; }
    awk -v name="$log" '
        function stamp(line) { return substr(line, 8, index(line, "]") - 8) + 0 }
        function sorted(a, n,   i, j, t) { for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]; a[j + 1] = t } }
        function pct(a, n, p,   k) { k = int(p * (n - 1) + 0.5) + 1; return a[k] }
        /autopan start/ { start = stamp($0) }
        /autopan end/   { end = stamp($0) }
        { lines[++nl] = $0 }
        END {
            if (!start || !end) { printf "%s: no autopan start/end in log\n", name; exit 1 }
            for (i = 1; i <= nl; i++) {
                line = lines[i]
                if (line ~ /callback target/) {
                    t = stamp(line); if (t < start || t > end) continue
                    match(line, /period [0-9.]+/); per[++np] = substr(line, RSTART + 7, RLENGTH - 7) + 0
                } else if (line ~ /latency gen/) {
                    if (line ~ /not presented/) { t = stamp(line); if (t >= start && t <= end + 0.2) dropped++; continue }
                    match(line, /present [0-9.]+$/); at = substr(line, RSTART + 8) + 0
                    if (at < start || at > end) continue
                    match(line, /input→present -?[0-9.]+/); lat[++n] = substr(line, RSTART + length("input→present "), RLENGTH - length("input→present ")) + 0
                    pres[n] = at
                }
            }
            if (n < 2) { printf "%s: %d frames presented during autopan\n", name, n; exit 1 }
            if (np == 0) { printf "%s: no display-link callbacks during autopan\n", name; exit 1 }
            sorted(per, np); period = pct(per, np, 0.5)
            sorted(pres, n); long = 0
            for (i = 2; i <= n; i++) { d = (pres[i] - pres[i - 1]) * 1000; iv[i - 1] = d; if (d > 1.5 * period) long++ }
            sorted(iv, n - 1)
            sorted(lat, n)
            printf "%s: frames %d (%.1f/s), not presented %d, period %.2f ms, input→present median %.1f ms p90 %.1f ms, interval p90 %.1f ms, long intervals (>1.5×period) %d\n",
                name, n, n / (end - start), dropped + 0, period, pct(lat, n, 0.5), pct(lat, n, 0.9), pct(iv, n - 1, 0.9), long
        }' "$log" || status=1
done
exit $status
