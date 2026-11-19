# File View scrolling with a large sidebar

Apple M4 Max, macOS 27.2.1, debug build. An AppKit probe opened a 1400 × 900 Loupe window and moved
each scroll view by 28 points for 240 steps, three times. Each step measured main-thread CPU with
`CLOCK_THREAD_CPUTIME_ID`, including layout and the Core Animation commit. The probe also measured
wall time between steps, with an 8.33 ms requested interval, and profiled the process with `sample`
at a 1 ms interval. These are scroll and main-loop timings. Display presentation and physical input
latency require separate measurements.

The SMB sidebar had about 2,310 logical rows. The SMB grid was measured in another folder with a
few hundred images. Both shares were read-only for the probe. The local fixture had 1,600 directories
and 3,500 images. During scrolling it added one directory and one image every 650 ms, through the
normal folder watcher and listing refresh.

| Scenario | Before, CPU p95 | Reused sidebar rows | Added off-main marking index | Added fast URL lookups |
|---|---:|---:|---:|---:|
| SMB sidebar | 20.4–32.0 ms | — | 2.3–4.1 ms | 2.1–4.4 ms |
| SMB grid | 1.7–1.9 ms | — | — | 1.3–1.4 ms |
| Local sidebar with arrivals | 30.3–39.1 ms | 3.3–3.4 ms | 2.8–4.4 ms | 2.6–3.8 ms |
| Local grid with arrivals | 12.6–13.2 ms | 2.2–2.5 ms | 1.7–2.0 ms | 1.5–1.7 ms |

The SMB sidebar's AppKit document went from 2,310 subviews to 32, including the drop indicator.
The baseline profile showed AppKit recomputing visible rectangles and traversing the sidebar's
views when scrolling. The process-wide self sample counts included 37 in
`NSViewGetTransformToAncestor`, 26 in `NSViewHierarchyInvalidateVisibleRect`, and 69 in
`CA::Layer::get_frame_transform`. On the local fixture, the sidebar change also reduced grid cost
because the grid and sidebar share the window's layout and display cycle.

During relists, `FolderBrowserSource.remember` built a URL index on the main thread. The profile
showed Foundation calling `faccessat` from `standardizedFileURL`. After moving the index into
photo-mark preparation and reusing the existing fast URL standardization, the two warm local grid
rounds had maximum wall intervals of 32 and 33 ms, down from 68 and 63 ms. The first local grid
round still had a 490 ms wall interval while the scroll step itself took at most 4 ms of CPU.

HomeScreenKit's regression test
`swift test --jobs 4 --filter scrollingALargeSidebarKeepsOnlyViewportRowsAttached` exercises a
2,500-row sidebar and checks that only the viewport's rows are attached after a large scroll.
An Intel Mac and viewer presentation were outside this measurement.
