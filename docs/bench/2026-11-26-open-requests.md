# External open path checks

Measured November 26, 2026 on a Mac16,6 with an M4 Max, 14 physical cores and macOS 27.2.1. The native AppKit
test window had one button. The harness queued its action for 20 ms after the start of each open event and measured
when AppKit delivered the action. The synchronous run used the `AppDelegate.targets` loop from `d3a464e` and
`OpenRouter.firstPerFolder`. The asynchronous run used `OpenRequests.submit` from the patch. The harness was
compiled with Swift 6 and `-O`. It used temporary files and the AppKit window without loading the Loupe state database.

The local and SMB batches each contained the same two stock JPEGs in one folder. The SMB volume was already mounted.
The held-path case inserted a 180 ms wait immediately before the filesystem call for a single local path. Each row
records the first, median and maximum of five consecutive rounds. Open wall time ends when the ordered targets
are available for routing. Input lateness is the elapsed time after the button action was due.

| Batch and measurement | Synchronous (ms) | Asynchronous (ms) |
|---|---:|---:|
| Local open wall time | 0.139 / 0.092 / 0.139 | 0.252 / 0.145 / 0.252 |
| Mounted SMB open wall time | 2.628 / 0.145 / 2.628 | 0.199 / 0.163 / 0.199 |
| Held-path open wall time | 182.990 / 182.990 / 190.249 | 182.306 / 183.018 / 183.269 |
| Held-path input lateness | 163.054 / 163.054 / 170.324 | 8.316 / 3.558 / 9.235 |
| Time to return from held-path open submission | 182.990 / 182.990 / 190.249 | 0.012 / 0.018 / 0.058 |

The mounted SMB run reflects a warm share. Viewer window construction, image decoding and first paint are outside
the measured interval. The sandbox denied `sample` access to the isolated benchmark process. This run used Apple
silicon. The Intel window budget remains unmeasured.

The worker limit is half the physical cores, with a minimum of one and a ceiling of two. Two slots let the later
request in the controlled reversal test finish while the first is held. Delivery keeps the accepted events in order.
Each slot runs at most one path check at a time. The external queue retains up to 64 batches. New arrivals are
rejected at the limit so a stalled mount cannot grow the FIFO indefinitely. `OpenRequestsTests` controls the probe
to cover arrival order, overflow, shutdown cancellation and a drop whose original viewer closes.
