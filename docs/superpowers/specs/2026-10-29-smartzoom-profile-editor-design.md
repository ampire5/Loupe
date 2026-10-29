# Remembered SmartZoom state and profile editor

User requests: remember selected profile and SmartZoom state across application restarts, make model selection clear,
and allow creating profiles with categories, priority groups and weights in the advanced panel.

- The installed application must be updated, rather than leaving an older installed copy beside a newer build.
- Remember the viewer's last mode and last enabled behavior. A new viewer restores this runtime choice above startup
  defaults; ordinary and Smart zoom parameters remain separately saved. Existing automatic profile remembering is
  verified in a second process with a real folder-settings database.
- The advanced panel puts model and composition profile at the top with clear labels and a visible Choose model button.
- New profile and Edit profile open a sheet with a name, category/weight table, and ordered rules. Selected model
  categories form a required '+' group; Vision categories are individual fallback rules, matching the existing syntax.
  Rules can be added, replaced, removed and reordered. Weighting and framing settings are editable without raw config.
- Creating clones the current effective framing options. Existing profile edits retain their names. Save validates the
  name, nonempty chain, known categories, unique canonical groups, ranges and finite weights; cancel changes nothing.
- Only the named profile is written to private detector.conf off-main, preserving other sections/comments. Creation
  rejects existing names. Successful save selects/remeasures that profile without changing Manual/Smart workflow.
- Public sources/tests/docs stay generic. No models, labels, private paths or setup instructions are added.
