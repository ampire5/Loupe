# Smart zoom, stage 2: finding subjects and `step-pan=subject` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the photos' subjects (faces, people, objects, saliency) are found in the background, cached in memory and in
`Loupe.db`, and `step-pan=subject` lands the view on them, gliding there when they come in just after the photo.

**Architecture:** Pure parts in LoupeCore: `SubjectBoxes` (the result), `SubjectFraming` (chain → frame → centre),
`SubjectDetector` (Vision observations → boxes, run on a `CGImage`), the catalog table. The app's `SubjectFinder`
draws a ≤ 1536 px proxy from the resident pyramid (as the subject-mask spike's `SubjectMasker` does), runs
`SubjectDetector` one photo at a time, and tells the session. The session passes the boxes into `PhotoSwitchView`,
and `ViewerView` glides when they are late.

**Tech Stack:** Swift 6, Vision, Metal (`TileRenderer` for the proxy), SQLite (`ThumbnailDatabase`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-28-smart-zoom-design.md` §4 (the centre; the scale is stage 3), §5, §6 rows
`subject-target` and `subject-analysis`, §7, §8.

## Global Constraints

- Boxes are normalised rects in the oriented photo, origin top-left, y down (as `ViewTransform.center`).
- The chain's kinds: `face`, `person`, `object` (Vision's animals and foreground instances), `saliency`. Default
  `face,person,object,saliency`.
- Faces are enlarged to the head: ×1.8 about the box's centre, then moved up by 0.15 of the box's height. The frame is
  the union of the first found kind's boxes plus 8 % of the frame's size on each side, clamped to 0…1.
- `subject-analysis`: `ahead` (default) | `on-demand` | `off`. Ahead: the photo on screen, then up to 3 ahead in the
  step direction (1 on x86_64). One analysis at a time. QoS `.utility` (stage 3 adds `.userInitiated` for the
  command). No analysis starts while the photo on screen is decoding; a step drops queued photos no longer ahead.
- The proxy's long side is at most 1536 px. The foreground-instance request runs only when the chain reaches `object`
  and the kinds before it found nothing.
- Late boxes glide the view only within 300 ms of the photo showing and only if no input touched its view since.
- Main thread: framing is arithmetic; no Vision, proxy drawing or SQLite on it.
- Real photos of people are not committed to the repository: Vision's own detection is checked in the bench on a local
  folder (`LOUPE_SUBJECT_BENCH=<dir>`), the tests cover everything around it.

## Review Focus

1. A photo with no subject at all (a white wall): `saliency` may still give a box; with `subject-target` without
   `saliency` the fallback (top / centre) must apply, never a crash or a jump to a corner.
2. Fast stepping through 200 photos: the queue never grows past the photo on screen + the ahead limit; nothing analysed
   for photos left behind; no glide on a photo the user already left.
3. A photo turned by EXIF (`exif-orientation=yes`): the boxes must be in the oriented photo's space, so the centre lands
   on the face, not on its mirror.
4. A file changed on disk: its stored boxes go with its `file_facts` (same invalidation), never served stale.
5. `subject-analysis=off`: no Vision request at all, no proxy drawn (the finder is never asked).

---

### Task 1: `SubjectBoxes` and `SubjectFraming` (LoupeCore)

**Files:**
- Create: `Sources/LoupeCore/SubjectBoxes.swift`, `Sources/LoupeCore/SubjectFraming.swift`
- Test: `Tests/LoupeCoreTests/SubjectFramingTests.swift`

**Interfaces:**
- Produces:
  - `public struct SubjectBoxes: Codable, Equatable, Sendable { public static let version = 1; public var version: Int;
    public var faces, people, objects, saliency: [CGRect] }` with `init(faces:people:objects:saliency:)` (version set),
    `public var isEmpty: Bool`.
  - `public enum SubjectKind: String, CaseIterable, Sendable { case face, person, object, saliency }`.
  - `public enum SubjectFraming { static func frame(_ boxes: SubjectBoxes, chain: [SubjectKind]) -> CGRect?;
    static func centre(_ boxes: SubjectBoxes, chain: [SubjectKind]) -> CGPoint? }` (centre of the frame, nil when no
    kind of the chain has boxes). Constants `faceGrowth = 1.8`, `faceLift = 0.15`, `margin = 0.08`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func frameTakesTheFirstKindFoundInTheChain() {
    let b = SubjectBoxes(faces: [], people: [CGRect(x: 0.2, y: 0.1, width: 0.2, height: 0.8)], objects: [],
                         saliency: [CGRect(x: 0.6, y: 0.6, width: 0.1, height: 0.1)])
    let f = SubjectFraming.frame(b, chain: [.face, .person, .object, .saliency])!
    // the person plus 8 % of its size each side: x 0.184…0.416, y 0.036…0.964
    #expect(abs(f.minX - 0.184) < 1e-9 && abs(f.maxX - 0.416) < 1e-9)
    #expect(abs(f.minY - 0.036) < 1e-9 && abs(f.maxY - 0.964) < 1e-9)
    #expect(SubjectFraming.frame(b, chain: [.saliency])!.midX > 0.6)
    #expect(SubjectFraming.frame(b, chain: [.face]) == nil)
}

@Test func facesGrowToTheHeadAndAreFramedTogether() {
    let b = SubjectBoxes(faces: [CGRect(x: 0.1, y: 0.4, width: 0.1, height: 0.1),
                                 CGRect(x: 0.7, y: 0.4, width: 0.1, height: 0.1)], people: [], objects: [], saliency: [])
    let f = SubjectFraming.frame(b, chain: [.face])!
    // each face ×1.8 about its centre (y 0.36…0.54), lifted by 0.15 × 0.1: y 0.345…0.525; the union x 0.06…0.84
    #expect(abs(f.midX - 0.45) < 1e-9)
    #expect(f.minX < 0.06 && f.maxX > 0.84)          // the margin on top of the union
    #expect(abs(SubjectFraming.centre(b, chain: [.face])!.y - 0.435) < 1e-9)
}

@Test func frameStaysInsideThePhoto() {
    let b = SubjectBoxes(faces: [CGRect(x: 0, y: 0, width: 0.2, height: 0.2)], people: [], objects: [], saliency: [])
    let f = SubjectFraming.frame(b, chain: [.face])!
    #expect(f.minX >= 0 && f.minY >= 0 && f.maxX <= 1 && f.maxY <= 1)
}

@Test func boxesRoundTripAndKnowTheirVersion() throws {
    let b = SubjectBoxes(faces: [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)], people: [], objects: [], saliency: [])
    let back = try JSONDecoder().decode(SubjectBoxes.self, from: JSONEncoder().encode(b))
    #expect(back == b && back.version == SubjectBoxes.version)
    #expect(SubjectBoxes(faces: [], people: [], objects: [], saliency: []).isEmpty)
}
```

- [ ] **Step 2: Run them to verify they fail** — `scripts/test.sh --filter SubjectFramingTests`; expected: build failure.
- [ ] **Step 3: Implement** both files. `frame`: for each kind in `chain`, take its boxes (faces grown and lifted);
  the first non-empty list's union, plus `margin × frame size` each side, intersected with the unit rect.
- [ ] **Step 4: Run them to verify they pass**, then `scripts/test.sh`.
- [ ] **Step 5: Commit** — "SubjectBoxes and SubjectFraming: the first kind of the chain found, faces grown to the
  head, framed together with a margin".

### Task 2: Settings — `subject-target`, `subject-analysis`

**Files:**
- Modify: `Sources/LoupeCore/Config.swift` (keys after `step-pan`; not folder keys), `Sources/LoupeSettings/Pages/PageZoomPan.swift`
- Test: `Tests/LoupeCoreTests/ConfigTests.swift`, `Tests/LoupeSettingsTests/PagesTests.swift` (count 145 → 147)

**Interfaces:**
- Produces: `Config.subjectTarget: [SubjectKind] = SubjectKind.allCases` (text `face,person,object,saliency`; a list
  of known kinds, comma-separated, any order, no repeats, at least one; anything else `.badValue`);
  `public enum SubjectAnalysis: String, Sendable { case ahead, onDemand = "on-demand", off }`,
  `Config.subjectAnalysis = .ahead`.

- [ ] **Step 1: Write the failing tests** — `subjectTargetParsesAListOfKinds` (`"person,face"` → `[.person, .face]`,
  text back `"person,face"`; `""`, `"face,face"`, `"face,cat"` → `.badValue`; default text
  `"face,person,object,saliency"`); `subjectAnalysisParses` (`ahead`, `on-demand`, `off` round trip; `"sometimes"` →
  `.badValue`); sample values in the every-key table (`"person"`/`"cat"`, `"off"`/`"sometimes"`), key order after
  `step-pan`.
- [ ] **Step 2: Run them to verify they fail.**
- [ ] **Step 3: Implement.** Settings rows on the zoom page after `step-pan`: `subject-target` as a text row if the
  page has one for lists (`zoom-stops` is the model), description "Where a subject is looked for, first found
  wins: face, person, object (animals and things in front), saliency (where the eye goes). Default all four in that
  order."; `subject-analysis` as a choice (Ahead / When asked / Off), description "Ahead: the photo on screen and the
  next few are looked at in the background. When asked: only the photo on screen, only while it is needed. Off: never;
  The subject falls back to the top or the middle. Default Ahead.".
- [ ] **Step 4: Run** `scripts/test.sh`; expected all pass.
- [ ] **Step 5: Commit** — "subject-target and subject-analysis in the config and the Settings window".

### Task 3: `PhotoSwitchView` takes the boxes

**Files:**
- Modify: `Sources/LoupeCore/PhotoSwitchView.swift`, `Sources/LoupeCore/ZoomRules.swift` (`chain: [SubjectKind]`)
- Modify: `Sources/Loupe/ViewerSession.swift` (`transform(showing:)` passes `subjectBoxes(url)`)
- Test: `Tests/LoupeCoreTests/PhotoSwitchViewTests.swift`

**Interfaces:**
- Consumes: Task 1, Task 2 (`ZoomRules.chain` from `config.subjectTarget`).
- Produces: `PhotoSwitchView.shown(_:current:imageSize:rules:subject:)` and `next(current:imageSize:rules:subject:)`
  with `subject: SubjectBoxes? = nil`; `public static func subjectCentre(_ boxes: SubjectBoxes?, rules: ZoomRules,
  imageSize: CGSize, viewSize: CGSize) -> CGPoint` (the framing's centre, else `fallbackCentre`), which the glide
  (Task 6) reuses. Session: `var subjectBoxes: (URL) -> SubjectBoxes? = { _ in nil }` set by the window controller.

- [ ] **Step 1: Write the failing test** — `stepPanSubjectLandsOnTheBoxes`: a tall photo, `pan: .subject`, boxes
  with one person at `(0.6, 0.5, 0.2, 0.4)` → `next(...).center` equals the framing's centre (`(0.7, 0.7)`); with
  `rules.chain == [.face]` (no faces) → `(0.5, 0)`; with boxes `nil` → `(0.5, 0)`.
- [ ] **Step 2: Run it to verify it fails.**
- [ ] **Step 3: Implement**; `ViewerSession.transform(showing:)` passes `subjectBoxes(url)` for `.switched` only.
- [ ] **Step 4: Run** `scripts/test.sh`.
- [ ] **Step 5: Commit** — "step-pan=subject lands on the photo's subject when its boxes are known".

### Task 4: The catalog keeps the boxes

**Files:**
- Modify: `Sources/LoupeCore/ThumbnailDatabase.swift` (table `file_subjects(file_id INTEGER PRIMARY KEY, boxes BLOB NOT
  NULL)` created with `factsSchema`'s `IF NOT EXISTS`; deleted wherever `file_facts` rows are deleted: lines ~121, ~125,
  ~217, ~579), `Sources/LoupeCore/ThumbnailStore.swift` (beside `facts`/`keepFacts`)
- Test: `Tests/LoupeCoreTests/ThumbnailDatabaseTests.swift`, `Tests/LoupeCoreTests/ThumbnailStoreTests.swift`

**Interfaces:**
- Produces: `ThumbnailDatabase.subjects(_ ids: [Int64]) throws -> [Int64: SubjectBoxes]` (rows of another
  `version` are skipped), `putSubjects(_ items: [(id: Int64, boxes: SubjectBoxes)]) throws`;
  `ThumbnailStore.subjects(_ urls: [URL]) -> [URL: SubjectBoxes]`, `keepSubjects(_ boxes: [URL: SubjectBoxes])`
  (only for files the catalog knows, as `keepFacts`).

- [ ] **Step 1: Write the failing tests** — `subjectsRoundTripByFile` (put, read back equal); `subjectsGoWhenTheFileChanges`
  (put, then the file row is updated with another size/mtime the way the existing facts test does it → no subjects);
  `subjectsOfAnotherVersionAreIgnored` (a row written with `version: 0` JSON → not returned).
- [ ] **Step 2–4:** fail, implement, pass; then `scripts/test.sh`.
- [ ] **Step 5: Commit** — "Loupe.db keeps the photos' subjects beside their facts, gone when the file changes".

### Task 5: `SubjectDetector` (LoupeCore) and `SubjectFinder` (app)

**Files:**
- Create: `Sources/LoupeCore/SubjectDetector.swift`, `Sources/Loupe/SubjectFinder.swift`
- Test: `Tests/LoupeCoreTests/SubjectDetectorTests.swift`

**Interfaces:**
- Consumes: Task 1, Task 2, Task 4.
- Produces:
  - `public enum SubjectDetector { static func boxes(from image: CGImage, chain: [SubjectKind]) -> SubjectBoxes;
    static func normalised(_ visionRect: CGRect) -> CGRect }` (Vision's bottom-left normalised rect → top-left;
    `normalised(CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.2)) == CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)`).
    One `VNImageRequestHandler` with `VNDetectFaceRectanglesRequest`, `VNDetectHumanRectanglesRequest`
    (`upperBodyOnly = false`), `VNRecognizeAnimalsRequest`, `VNGenerateAttentionBasedSaliencyImageRequest`; then, only
    if `chain` reaches `.object` and no earlier kind found anything, `VNGenerateForegroundInstanceMaskRequest`, whose
    instances' bounding boxes join `objects`. Requests the chain does not name are not run.
  - `final class SubjectFinder: @unchecked Sendable` (app): `static let shared`; `func boxes(for url: URL) ->
    SubjectBoxes?` (memory, any thread); `func request(_ url: URL, image: TiledImage, orientation: ImageOrientation,
    ahead: Bool, done: @escaping @MainActor (SubjectBoxes?) -> Void)`; `func keepOnly(_ urls: Set<URL>)` (drops queued
    jobs not in the set); `var isForegroundBusy: @Sendable () -> Bool`. Constants `proxySide = 1536`,
    `aheadLimit = 3` (1 on `arch(x86_64)`), `cacheLimit = 64` entries. Before analysing it asks
    `ThumbnailStore.subjects([url])`; after, `keepSubjects`.

- [ ] **Step 1: Write the failing tests** — `visionRectsTurnTopLeft` (the `normalised` example above);
  `detectorFindsNothingOnABlankImage` (a 256×256 white `CGImage`, chain `[.face, .person]` → `isEmpty`);
  `detectorFindsSaliencyOnAShape` (a 512×512 black image with a white disc at the right third, chain `[.saliency]` →
  one box whose `midX > 0.5`). If Vision's saliency gives nothing on a synthetic image, ledger it and drop that
  assertion to "does not crash".
- [ ] **Step 2–4:** fail, implement `SubjectDetector`, pass. Then write `SubjectFinder` after the spike's
  `SubjectMasker` (`git show spike/subject-mask:Sources/Loupe/SubjectMasker.swift`): its job queue, `QueueOnly`
  renderer and `drawProxy`, minus the maps; the proxy to `CGImage` via a CIContext.
- [ ] **Step 5: Commit** — "SubjectDetector (Vision → boxes) and SubjectFinder (the proxy from the resident pyramid,
  one photo at a time, cached in memory and Loupe.db)".

### Task 6: Wiring, the glide, the bench

**Files:**
- Modify: `Sources/Loupe/ViewerWindowController.swift` (sets `session.subjectBoxes = SubjectFinder.shared.boxes(for:)`,
  asks for the photo on screen and the neighbours per `subject-analysis`), `Sources/Loupe/ViewerSession.swift`
  (neighbours with their pyramids, as the spike's `subjectFocusNeighbours`), `Sources/Loupe/ViewerView.swift` (the
  glide)
- Create: `Sources/LoupeCore/SubjectGlide.swift`, `docs/bench/smart-zoom.md`
- Test: `Tests/LoupeCoreTests/SubjectGlideTests.swift`

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces: `public enum SubjectGlide { static let window: TimeInterval = 0.3; static func shouldGlide(shownAt:
  TimeInterval, now: TimeInterval, touched: Bool, samePhoto: Bool) -> Bool }`.

- [ ] **Step 1: Write the failing test** — `glideOnlySoonAndUntouched`: `(0, 0.2, false, true)` → true; `(0, 0.35,
  false, true)` → false; `(0, 0.1, true, true)` → false; `(0, 0.1, false, false)` → false.
- [ ] **Step 2–4:** fail, implement, pass.
- [ ] **Step 5: Wire.** The window controller asks the finder when the photo on screen changes (and its pyramid gets
  a resident level) if `step-pan == .subject` or later stage 3's mode; `ahead` asks the neighbours too, `on-demand`
  only the photo on screen, `off` nothing. `isForegroundBusy` is "the photo on screen has no resident level yet".
  `done` for the photo on screen: if `shouldGlide`, `ViewerView` animates (`animateZoom`) to the transform with
  `PhotoSwitchView.subjectCentre(...)`; "touched" is any pan, zoom or key handled by the view since the photo came.
- [ ] **Step 6: Bench.** `LOUPE_SUBJECT_BENCH=<dir>` (a debug hook in the finder) analyses every photo of a folder
  once at `.utility` and logs ms per photo (cheap requests, object mask separately) with `LOUPE_DEBUG`. Run it on
  "~/Pictures/benchmark/portraits" (207 portraits) on this M4 Max; write the table (median, p90, max) and the
  machine into `docs/bench/smart-zoom.md`, and the ahead limit's reason next to the constant. Intel: not measured
  here (no Intel Mac at hand), say so in the document.
- [ ] **Step 7: Verify** — `scripts/test.sh`; `scripts/make-app.sh`; in the mixed folder with `step-pan=subject`, a
  zoomed photo steps to the next and the view lands on the face (a screenshot), fast stepping leaves no glide on a
  photo already left.
- [ ] **Step 8: Commit** — "step-pan=subject in the app: subjects looked for ahead, the late ones glide the view;
  the analysis bench".
