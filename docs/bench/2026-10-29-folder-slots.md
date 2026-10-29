# Shared slots and folder filmstrip — verification

Date: 2026-10-29. Branch: `codex/folder-slots` in Loupe, HomeScreenKit and FrameScrub.

## Machine and method

Apple M4 Max, 14 physical cores, 36 GiB RAM, macOS 27.0.1, Swift 6.4; debug build. The required Intel measurement is **not performed**.

`CFFIXED_USER_HOME=<scratch-home> Loupe --folder-slots-bench` runs the actual `SlotsController` and `FolderStripController` in a real 1200×800 AppKit window. It uses 1000 fixture gallery rows, five fresh windows, ten tab round trips per window, a resize to 1000×700 and hide. Every action includes layout and Core Animation flush. `CLOCK_THREAD_CPUTIME_ID` measures main-thread CPU, not wall-clock network time. `populate-1000-rows` includes the run-loop interval in which async rows arrive.

## Main-thread results

| Action | Samples | Median ms | Maximum ms |
|---|---:|---:|---:|
| first-show | 5 | 7.837 | 9.855 |
| populate-1000-rows | 5 | 5.398 | 9.308 |
| tab-return | 50 | 0.704 | 1.579 |
| resize | 5 | 2.334 | 3.125 |
| hide | 5 | 0.624 | 0.700 |

The measurements are comfortably below the 100 ms navigation / 50 ms control budgets on this ARM machine. These are maximum observed values, not an Intel guarantee. No round-by-round accumulation is apparent in the raw five-round results.

## Behavioral checks

- `bottom-fit: PASS`: moving the filmstrip to a 1100×240 bottom slot keeps the current picture, caption and card within its height. The original width-only sizing failed at 860 pt; sizing from both available dimensions fixes it.
- `stale-reply: PASS`: actual controller receives A then B; delayed/cancelled A cannot emit an open after B.
- `file-view-suspends: PASS`: hiding the folder page invalidates a pending selection; returning does not commit it. Loupe calls the same hide/suspend boundary when entering File View (Home → Folders), Recent or Stash browsing.
- `branch-order: PASS`: the current branch has no own photos, a nested child opens its deeper descendant; the next steps remain the following child and then the next outer sibling. A title-length-based ancestor choice failed this check (`E,E,D`); selecting by tree depth passes (`E,D,B`).
- Screenshot of the actual slot over a white backing inspected: dark veil, readable light text, current-row outline, capsule. Fixture gallery rows intentionally have no photos. The zero-size hidden panel constraint warnings seen in the first bench were eliminated by a valid initial hidden frame.
- Source tests cover sorting, unknown counts, archives, cancellation, empty trees, cycles and a real symbolic directory link. Shared host tests cover lazy reuse, focus return, live view transfer, and explicit hidden preparation for FrameScrub bridge actions.

## Resource policy

Disk selection admits one demand listing process-wide; a timed-out syscall retains admission until it actually exits. This prevents cancelled choices accumulating worker threads, but an indefinitely stuck listing temporarily blocks further filmstrip disk listings; ordinary Home/viewer navigation remains separate. This is an intentional conservative limitation.

Covers use the existing ThumbnailStore/CoverQueue, including its foreground pause and measured network listing limit of one. Classification happens after admission; until then local rows conservatively share that same lane. This can fill local covers more slowly than Home’s measured two local lanes, while adding no new parallelism. Visible metadata/pictures are trimmed on scrolling; sends coalesce to the latest desired rows, and hiding sends an empty want.

## Verification history

- HomeScreenKit: 659 tests passed; FrameScrub: 1753 tests passed (1719 core + 34 settings).
- An initial FrameScrub crash was missing video fixtures in the isolated clone; read-only fixtures were then attached. File/GUI tests need normal filesystem/AppKit access rather than this harness sandbox.
- Full Loupe runs caught missing key samples/settings rows and hard-coded existing group order. Those were fixed without weakening the assertions. One run while other work was active also failed the existing `cubeBuildTime` timing threshold; a later run transiently failed `ImageCacheSessionsTests.evictsOldestInactiveFirst` (coarse versus bytes). Neither subsystem was changed. Final clean standard run: **2209 tests passed** (2146 LoupeCore + 63 LoupeSettings), 0 failures; Metal render matrices are outside this UI change’s standard pass.
- Whole-branch review was performed by the author, per the user's request to avoid agent costs.

`scripts/kits-check.py --no-fetch` correctly blocks a release while HomeScreenKit is in edit mode (missing release pin); no edit-mode lockfile is committed.

## Scope and remaining acceptance

No live Stash server or large slow SMB corpus was available in this run. The Stash adapter compiles and generic gallery order/ID behavior is tested; real mount/auth/server integration remains a smoke-test requirement. Synthetic UI measurements do not establish end-to-end network throughput or total resident-memory behavior on a real collection. Intel timing, native fullscreen interaction and a manual VoiceOver pass remain required before a release build is handed over. Reduce Motion follows the shared SlotMotion path; visual confirmation on an Intel machine remains open.

This work does not release a kit or publish app binaries. Before merging: kit main + new minor tag, app manifests/pins updated to that tag outside edit mode, kits-check and CI. Current local verification uses HomeScreenKit edit mode, with no edit-mode lockfile committed.

## Raw UI results

```text
round	action	main-thread-ms
1	first-show	9.855
1	populate-1000-rows	9.308
1	tab-return	1.579
1	tab-return	0.636
1	tab-return	0.597
1	tab-return	0.589
1	tab-return	0.592
1	tab-return	0.581
1	tab-return	0.580
1	tab-return	0.627
1	tab-return	0.666
1	tab-return	0.854
1	resize	3.125
1	hide	0.700
2	first-show	7.273
2	populate-1000-rows	5.296
2	tab-return	1.327
2	tab-return	0.853
2	tab-return	0.735
2	tab-return	0.709
2	tab-return	0.800
2	tab-return	0.639
2	tab-return	0.819
2	tab-return	0.771
2	tab-return	0.684
2	tab-return	0.655
2	resize	2.217
2	hide	0.624
3	first-show	7.950
3	populate-1000-rows	5.651
3	tab-return	1.086
3	tab-return	1.026
3	tab-return	0.890
3	tab-return	0.876
3	tab-return	0.888
3	tab-return	0.822
3	tab-return	0.744
3	tab-return	0.667
3	tab-return	0.658
3	tab-return	0.739
3	resize	2.154
3	hide	0.608
4	first-show	7.837
4	populate-1000-rows	5.398
4	tab-return	1.181
4	tab-return	0.720
4	tab-return	0.804
4	tab-return	0.700
4	tab-return	0.662
4	tab-return	0.651
4	tab-return	0.668
4	tab-return	0.671
4	tab-return	0.804
4	tab-return	0.803
4	resize	2.691
4	hide	0.678
5	first-show	7.638
5	populate-1000-rows	5.162
5	tab-return	1.197
5	tab-return	0.726
5	tab-return	0.687
5	tab-return	0.673
5	tab-return	0.666
5	tab-return	0.673
5	tab-return	0.677
5	tab-return	0.806
5	tab-return	0.700
5	tab-return	0.658
5	resize	2.334
5	hide	0.601
bottom-fit: PASS
stale-reply: PASS
file-view-suspends: PASS
branch-order: PASS
folder-slots: finished; Intel timing requires a separate Intel run
```
