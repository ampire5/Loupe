# Explicit browser selection and expanded inspector

User request: default information groups expanded; the inspector follows a deliberately selected file, not pointer hover.

The browser already owns selection and draws its ring. Preserve it and make hover-selection optional in HomeScreenKit (compatibility default on); Loupe disables it before showing any cards. Clicks, arrow/type-selection and context-menu requests explicitly change selection. Pointer hover still reveals each card's own hover UI. Keep listing/session selection restoration and lazy inspector creation unchanged.

All inspector disclosure groups default to expanded when no saved choice exists; explicit user collapse remains persisted. No unconditional reset of existing preferences.

- [x] Add native regressions for hover independence, selection ring, clicks, keys and context menus.
- [x] Add real inspector presentation tests for fresh expanded defaults and remembered collapse.
- [x] Implement the isolated changes in HomeScreenKit and Loupe on matching polish-3 branches, preserving unrelated dirty work.
- [x] Run focused/full relevant suites, benchmark the real inspector and request a scoped review.


## Execution ledger

- Root cause: card.onHover moved the browser's selected ID. Added a compatibility option in the kit and disabled it in Loupe; no second selection store was needed.
- Native selection tests RED→GREEN: pointer entry preserves the ID/ring/callback while retaining hover decorations; clicks/keys/context menus change it. Existing hover-following clients retain their default.
- Actual AppKit presentation tests RED→GREEN: all four groups and their values initially visible; a manual Generation collapse hides its value and persists across recreation.
- Additional race caught by regression: a partial listing plus a pending restored selection replaced a newer click when the old remembered file arrived. Both normal and context-click cases failed, then pass after dropping pending restoration at those explicit input boundaries.
- Independent scoped review found no important findings. The subsequent restore-race fix is covered by its own RED→GREEN regression and full kit tests.
- Native benchmark: first populated open 106.091 ms; selection medians 8.791–10.922 ms, reopen medians 19.140–20.155 ms. Captured layout inspected. No Intel claim and no render changes.
- No commit or release requested in this follow-up; preserve mixed dirty work. New defaults respect saved choices rather than rewriting personal preferences.

Final verification: all 680 kit tests, 2211 core, 63 settings, 24 native and 2 inspector presentation tests passed. Both diffs are whitespace-clean.
