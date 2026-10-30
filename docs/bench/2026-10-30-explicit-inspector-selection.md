# Explicit file selection and expanded information groups

## Behavior

Loupe sets `HomeBrowserView.selectsOnHover = false` before the first listing. The existing selected-entry state and its ring now stay on the chosen file while the pointer moves across other cards. The cards' hover decorations still work. Ordinary clicks, keyboard/type selection and context-menu requests change the selection and therefore the inspector. Listing/session restoration remains supported. An explicit click/context-menu request cancels pending selection restoration, so a later listing cannot replace that choice with a previously remembered file.

HomeScreenKit keeps hover-selection enabled by default for existing clients; clients can opt into persistent explicit selection without changing their card decorations. Context-menu selection has its own callback instead of depending on hover. There is no additional polling, file access, timer, or selection store.

All non-empty inspector groups default to expanded when no saved choice exists. A user's saved collapsed/expanded choice still wins. Long values retain their separate full-text action. Lazy first creation and retained reopening are unchanged.

## Verification

Native regressions exercise actual card mouse-enter, mouse-up, keyboard and context-menu routes. Hover leaves the selected ID, its ring, and the selection callback count unchanged while the hovered photo still reveals its decorations. Clicks and keys update the ID and callback. Context-menu requests select their own file. A partial-listing/session-restore regression failed with the old code: after choosing b.jpg, arrival of the previously remembered c.jpg selected c.jpg. Clearing the pending restoration on explicit selection fixes both ordinary and context clicks.

Inspector presentation tests create the real controller with synthetic capture/generation metadata. Fresh defaults show all four disclosure states expanded and their actual Camera, Generation, Path and Format values visible. Collapsing Generation hides its text and survives controller recreation while other groups stay expanded. Both tests failed before the new default, then passed. Disposable UserDefaults suites avoid modifying personal settings.

## Native window benchmark

Same M4 Max / 36 GB host as the preceding inspector benchmarks, now macOS 27.2, debug build. The existing `LoupeBench inspector` opens the real native Home window and inspector with a synthetic 1000-file listing. It now uses Loupe's explicit selection mode and starts with expanded sections. Main-thread CPU is measured with `CLOCK_THREAD_CPUTIME_ID`. This is a UI measurement, not a filesystem latency claim; it is not a controlled comparison across OS/SDK changes.

First populated open: 106.091 ms (factory registration 0.060, materialization 21.738, layout/display 36.311, later run-loop work 47.983).

| Round | Selection median ms | Selection max ms | Reopen median ms | Reopen max ms |
| --- | ---: | ---: | ---: | ---: |
| 1 | 10.922 | 16.781 | 20.155 | 21.617 |
| 2 | 9.767 | 12.617 | 19.140 | 20.681 |
| 3 | 8.791 | 10.493 | 19.571 | 21.146 |

The expanded layout was inspected from a native window capture: values wrap within the right pane, File and Location and Technical Details are open, and the selected card keeps its ring. The scroll view handles additional metadata. No steadily accumulating selection work is evident in these rounds. The first-use time remains near the approximate 100 ms screen budget on this Apple Silicon machine; Intel remains unmeasured.

## Integration

Changes stay in matching `polish-3` app/kit branches and preserve other dirty work. HomeScreenKit is still consumed in edit mode; release and pin the combined kit before distributing a tagged app. No model-specific or personal sample assets are added. No render code changed in this follow-up.

Final checks: HomeScreenKit 680 tests passed across eight products; Loupe 2211 core, 63 settings, 24 native integration and 2 inspector presentation tests passed. Scoped review found no important findings; the later restore-priority fix has a failing-before/passing-after regression. `git diff --check` is clean in both repositories.
