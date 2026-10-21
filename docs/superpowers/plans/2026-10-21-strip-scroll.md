# Лента как в Photos — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** заменить ленту «вся папка с лупой» на прокручиваемую ленту в духе Photos (macOS 27): текущий снимок по
центру в своих пропорциях, жест двигает ленту и скраббит кадры, доводка на остановке.

**Architecture:** чистая модель раскладки `StripScrollLayout` и модель движения (переделанный `StripScroll`) в
LoupeCore, тестируемые без AppKit; `StripView` переписывается на один контейнерный слой с пулом ячеек и статичной
маской краёв; `StripController` держит смещение ленты и состояние «движется / стоит» и скраббит через существующий
путь `ViewerSession.scrub(to:)` / `endScrub()`. Старые `StripLayout`, `StripMagnifier`, лупа и рамка удаляются.

**Tech Stack:** Swift 6.2, AppKit, Core Animation, Swift Testing; SettingsKit (SwiftUI) для ползунка.

**Spec:** `docs/superpowers/specs/2026-10-21-strip-scroll-design.md` (читать вместе с планом).

## Global Constraints

- Ветки: фича идёт в `main` (Loupe `strip-scroll`, SettingsKit `slider-row`), в `lts/macos26` — бэкпортом
  (FrameScrub/LTS_POLICY.md). На Intel-iMac `main` не собирается: разработка и тесты — в `strip-scroll-lts`
  (от `lts/macos26` + коммиты спецификации), каждый коммит задачи переносится `git cherry-pick` в `strip-scroll`.
- Сборка и тесты Loupe только скриптами: `scripts/test.sh [--filter X]`; приложение:
  `. scripts/libjxl-env.sh && swift build --triple "$LTS_TRIPLE" --product Loupe`. Голый `swift build` не линкуется.
- Локальные пакеты: `swift package edit SettingsKit --path ../SettingsKit` (как уже сделано для HomeScreenKit);
  `Packages/` и `Package.resolved` не коммитить.
- Коммиты от `Vladimir Selin <418805+ampire5@users.noreply.github.com>`, с хвостом `Co-Authored-By: Claude Opus 5.5
  <noreply@anthropic.com>` и `Claude-Session: …`.
- Доли высоты ячейки `h` — из спецификации, именованными константами: узкая `0.5625`, зазор `0.028`, радиус
  `0.045` (по умолчанию `strip-corner-radius` = 3 pt ≈ 0.045 · 68; ключ остаётся), отступ у текущего `0.12`, маска
  краёв `0.85`; пропорция текущего до прихода своей — `1.5`.
- `strip-cell-max`: `0.5625…1.5`, по умолчанию `1.5`, в loupe.conf число или `w:h`. `strip-window` по умолчанию
  `bar`, `strip-height` по умолчанию `68`.
- Удаляемые ключи: `strip-aspect`, `strip-magnify`, `strip-magnify-reach`, `strip-magnify-limit` — в loupe.conf
  предупреждение `loupe.conf:N: 'KEY' is no longer used`, значение игнорируется.
- Производительность: событие прокрутки ≤ 1 мс главного потока на этом Intel; число слоёв не зависит от размера
  папки; ни одного синхронного декодирования при скрабе.
- Стиль кода — как в окружающем: doc-комментарии `///` на английском, плотность и именование как в `Strip*.swift`.

## Review Focus

1. Папка дописывается частями во время жеста (листинг, `FolderWatcher`): центр не прыгает, текущий файл остаётся тем
   же. → тест в Task 3 (`changedFileCountKeepsCentreFile`) и Task 4 (`fileCountChangeMidGestureKeepsFile`).
2. Пропорции приходят пачкой во время жеста или доводки: ячейки сужаются, файл в центре не меняется. → Task 3
   (`aspectsArrivingKeepCentreFile`).
3. Клик во время инерции трекпада или доводки: инерция и доводка прерываются, открывается кликнутый файл, ровно
   одно `endScrub`. → Task 4 (`pressDuringMomentumTakesOver`).
4. Ресайз окна или вход в полноэкранный режим во время движения: смещение сохраняет файл в центре. → Task 3
   (`widthChangeKeepsCentreFile`).
5. Один файл или пустая папка: жест и клик ничего не делают, ленты без ячеек не ломают вьюху. → Task 3
   (`emptyAndSingleFile`), Task 4 (`singleFileGestureDoesNothing`).

---

### Task 1: SettingsKit — строка-ползунок

Репозиторий SettingsKit: склонировать `https://github.com/ampire5/SettingsKit.git` рядом с Loupe (`../SettingsKit`),
ветка `slider-row` от `origin/main`.

**Files:**
- Modify: `Sources/SettingsKit/SettingsDescription.swift` (case в `RowKind`, построитель)
- Modify: `Sources/SettingsKit/RowViews.swift` (вид строки), `Sources/SettingsKit/SettingsModel.swift` (если число
  форматируется там, как у `.number`)
- Test: `Tests/SettingsKitTests/RowExtrasTests.swift`

**Interfaces:**
- Produces: `RowKind.slider(range: ClosedRange<Double>, marks: [(value: Double, title: String)])` и
  `SettingsRow.slider(_ key:, _ title:, range:, marks:, symbol:, description:) -> SettingsRow`. Значение пишется
  числом в кратчайшей записи (`1.5`, `0.5625`); справа подпись — `title` ближайшей метки.
- Static helper (тестируемый): `SettingsRow.nearestMark(_ value: Double, in marks: [(value: Double, title: String)]) -> String`.

- [ ] **Step 1: Тест.** `@Test func sliderRowBuildsAndNamesNearestMark()`: построитель даёт `.slider` с теми же
  `range`/`marks`; `nearestMark(0.58, marks)` == `"9:16"`, `nearestMark(1.0, marks)` == `"1:1"`,
  `nearestMark(1.4, marks)` == `"3:2"` для меток `[(0.5625,"9:16"),(0.75,"3:4"),(1,"1:1"),(4.0/3,"4:3"),(1.5,"3:2")]`.
- [ ] **Step 2:** `swift test --filter sliderRow` — FAIL (нет `.slider`).
- [ ] **Step 3:** реализовать case, построитель, `nearestMark`; вид — SwiftUI `Slider` в строке, подпись метки
  справа, запись значения через тот же путь, что `.number` (с дебаунсом). Все `switch` по `RowKind` дополнить.
- [ ] **Step 4:** `swift test` — PASS.
- [ ] **Step 5:** коммит в SettingsKit `slider-row`: «Rows: a slider with named marks».

### Task 2: Config — `strip-cell-max`, удалённые ключи, новые значения по умолчанию

**Files:**
- Modify: `Sources/LoupeCore/Config.swift`
- Modify: `Sources/LoupeSettings/Pages/PageStrip.swift`
- Test: `Tests/LoupeCoreTests/ConfigTests.swift`, `Tests/LoupeSettingsTests/PagesTests.swift`

**Interfaces:**
- Produces: `Config.stripCellMax: Double` (= 1.5), `Config.stripCellMaxRange = 0.5625...1.5`,
  `Config.retiredKeys: Set<String>`; `stripWindow` по умолчанию `.bar`, `stripHeight` по умолчанию `68`.
  `stripAspect`, `stripMagnify*` и enum `StripAspect` удаляются (их пользователей правят задачи 5–7; до тех пор
  оставить заглушки нельзя — поэтому эта задача удаляет только ключи из `keys`/`text`/`set`, а свойства удаляет
  Task 7).

- [ ] **Step 1: Тесты.**
  - `stripCellMaxParsesNumberAndRatio`: `set("strip-cell-max","3:2")` → 1.5; `"9:16"` → 0.5625; `"1"` → 1;
    `"0.5"`, `"2:1"`, `"x"` → `.badValue`; `text(forKey:)` для 1.5 → `"1.5"`; по умолчанию 1.5.
  - `retiredStripKeysWarnOnce`: `Config.parse("strip-magnify=2\nstrip-aspect=crop")` даёт ровно
    `["loupe.conf:1: 'strip-magnify' is no longer used", "loupe.conf:2: 'strip-aspect' is no longer used"]`, конфиг
    равен `Config()` по ключам ленты.
  - `stripDefaults`: `Config().stripWindow == .bar`, `Config().stripHeight == 68`, `Config().stripCornerRadius == 3`.
  - Таблица образцов ключей в `ConfigTests` (строка с `"strip-aspect": …`): убрать четыре ключа, добавить
    `"strip-cell-max": ("1", "2")`. `PagesTests`: `Config.keys.count` = 117 (120 − 4 + 1).
- [ ] **Step 2:** `scripts/test.sh --filter ConfigTests --filter PagesTests` — FAIL.
- [ ] **Step 3:** реализовать: ключ в `keys` на месте `strip-aspect`; разбор `w:h` (оба > 0) или числа, в диапазоне;
  `retiredKeys` проверяется в `Config.parse` до `set` (предупреждение, `continue`); `PageStrip`: убрать строки
  `strip-aspect` и `strip-magnify*`, добавить `.slider("strip-cell-max", "Widest thumbnail", range: 0.5625...1.5,
  marks: [9:16, 3:4, 1:1, 4:3, 3:2], symbol: "rectangle.portrait.arrowtriangle.2.outward", description: "How wide a
  thumbnail may grow when the strip has room: 9:16 keeps every one narrow, 3:2 lets a landscape show nearly
  whole. Never wider than the photo. Default 3:2.")`; описания `strip-window` (Default Bar) и `strip-height`
  (default 68) поправить. Символ проверить тестом `rowSymbolsExistAndDiffer`.
- [ ] **Step 4:** тесты — PASS.
- [ ] **Step 5:** коммит «Config: strip-cell-max; the magnifier and shape keys retire; strip under the photo by default».

### Task 3: `StripScrollLayout` — модель раскладки

**Files:**
- Create: `Sources/LoupeCore/StripScrollLayout.swift`
- Test: `Tests/LoupeCoreTests/StripScrollLayoutTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct StripScrollLayout: Equatable, Sendable {
      public static let narrowAspect = 0.5625, gapRatio = 0.028, radiusRatio = 0.045,
                        currentPaddingRatio = 0.12, fadeRatio = 0.85, unknownCurrentAspect = 1.5
      public init(fileCount: Int, width: Double, cellHeight: Double, maxAspect: Double, aspects: [Double?])
      public let cellWidth: Double                    // clamp(width / n, 0.5625 h, maxAspect h); 0 when n == 0
      public func narrowWidth(of file: Int) -> Double // min(cellWidth, aspect · h) or cellWidth if unknown
      public func centre(of file: Int) -> Double      // base x of the file's centre: all cells narrow, gaps only
      public func file(atBase x: Double) -> Int?      // nearest file, clamped to 0..<n; nil when n == 0
      public var offsetRange: ClosedRange<Double>     // centre(of: 0)...centre(of: n − 1)
      public func cells(offset: Double, current: Int, expansion: Double) -> [StripCell]
      public var fadeLength: Double { get }           // 0.85 h
  }
  ```
  `offset` — базовая координата, стоящая под центром ленты (`width / 2` во вьюхе). `cells` возвращает видимые ячейки
  плюс по одной с каждой стороны, `x` — во вьюхе. При `expansion` > 0 текущая ячейка расширяется от узкой к
  `aspects[current] ?? 1.5` · h, зазоры у неё растут от `gapRatio·h` к `currentPaddingRatio·h`, соседи
  сдвигаются симметрично от её центра; её центр остаётся в `centre(of: current)`. `StripCell` — существующий тип
  (`range` = `file..<file+1`). Радиус скругления — из `strip-corner-radius`, не из модели.
  Позиции: если все `narrowWidth` равны `cellWidth` — формула O(1); иначе массив префиксных сумм, считается в
  `init` (O(n)), поиск — двоичный.

- [ ] **Step 1: Тесты** (`h = 68`, `width = 1200`, `maxAspect = 1.5` если не сказано иное):
  - `manyFilesUseNarrowCells`: n = 1000 → `cellWidth == 0.5625 * 68`; число ячеек `cells(...)` при
    `expansion: 0` равно `ceil(1200 / (cellWidth + gap)) + 2` ± 1 и не меняется при n = 10 000.
  - `fewFilesWidenUpToMax`: n = 3 → `cellWidth == 1.5 * 68`; n = 20 → `cellWidth == 60`; при `maxAspect: 0.5625`
    и n = 3 → `0.5625 * 68`.
  - `cellNeverWiderThanPhoto`: n = 3, aspects `[1.5, 0.75, nil]` → `narrowWidth(of: 1) == 0.75 * 68`,
    `narrowWidth(of: 2) == cellWidth`.
  - `currentCentredAndExpanded`: `cells(offset: centre(of: 5), current: 5, expansion: 1)` — ячейка 5 шириной
    `aspects[5] * 68`, её центр в `600`; зазоры до соседей `0.12 * 68`, между прочими `0.028 * 68`.
  - `fewFilesClusterAroundCentre`: n = 3, `offset = centre(of: 1)` — все три ячейки внутри `0…1200`, крайние не
    касаются краёв.
  - `fileAtBaseIsNearestAndClamped`: `file(atBase: centre(of: 7) + 0.4 * cellWidth) == 7`, за пределами → 0 и n − 1.
  - `offsetRangeEnds`: `offsetRange == centre(of: 0)...centre(of: n − 1)`.
  - `emptyAndSingleFile`: n = 0 → `cells == []`, `file(atBase:) == nil`; n = 1 → одна ячейка с центром в 600.
  - `widthChangeKeepsCentreFile`, `changedFileCountKeepsCentreFile`, `aspectsArrivingKeepCentreFile`: новый layout
    с другой шириной / n + 50 / новыми пропорциями; `file(atBase: newLayout.centre(of: f)) == f` для файла f, бывшего
    в центре (контроллер пересчитывает offset через `centre(of:)`).
  - `windowIsConstantTime`: `cells(...)` на n = 1 000 000 с одинаковыми ширинами — меньше 50 µs (медиана 100
    вызовов); с префиксными суммами — меньше 200 µs.
- [ ] **Step 2:** `scripts/test.sh --filter StripScrollLayoutTests` — FAIL.
- [ ] **Step 3:** реализовать по Interfaces.
- [ ] **Step 4:** — PASS.
- [ ] **Step 5:** коммит «StripScrollLayout: the Photos-style strip as arithmetic».

### Task 4: `StripScroll` — движение ленты (жест, перетаскивание, доводка)

**Files:**
- Modify: `Sources/LoupeCore/StripScroll.swift` (переписать модель на смещение)
- Test: `Tests/LoupeCoreTests/StripScrollTests.swift` (переписать)

**Interfaces:**
- Consumes: `StripScrollLayout` (Task 3).
- Produces (сохраняя `Route`, `lockDistance`, `restDelay`, `direction`, `restDeadline`, `rested(now:)`, `end()`,
  `takeOver()`):
  ```swift
  public private(set) var offset: Double?           // nil: follows the current file (settled)
  public var isMoving: Bool { get }                 // a gesture, its momentum or a drag is on
  public mutating func event(fingerDX: Double, dy: Double, phase: ScrollPhase, momentum: ScrollPhase,
                             layout: StripScrollLayout, current: Int, now: Double) -> Outcome
  public mutating func drag(by dx: Double, layout: StripScrollLayout, current: Int) -> Outcome   // mouse
  public func settled(layout: StripScrollLayout) -> (file: Int, offset: Double)?                 // nearest centre
  public mutating func settle()                     // offset = nil (follow the current file again)
  public mutating func layoutChanged(keeping file: Int, layout: StripScrollLayout)               // re-anchor
  ```
  `Outcome.file` — новый файл в центре (скраб). Натуральное направление: пальцы влево → `offset` растёт (следующие
  файлы); мышь: лента следует за курсором (`offset -= dx`), без инерции. За пределами `offsetRange` во время жеста
  трекпада — сопротивление (смещение за край × 0.3), мышь — жёсткий упор; `settled` всегда внутри диапазона.

- [ ] **Step 1: Тесты** (layout: n = 100, h = 68, width = 1200):
  - `fingersLeftMoveToNextFiles`: от current = 10 жест с `fingerDX` −cellWidth·3 даёт `Outcome.file` 11, 12, 13 по
    порядку, `offset == centre(of: 10) + 3 * (cellWidth + gap)` ± 0.5.
  - `reversedDirection`: то же с `.reversed` идёт к 9, 8, 7.
  - `mouseDragFollowsCursor`: `drag(by: -2 * pitch)` от 10 → файл 12.
  - `trackpadRubberBandsAtEnds`, `mouseStopsAtEnds`: за `offsetRange` смещение трекпада растёт с коэффициентом 0.3,
    мыши — не растёт; `settled` → крайний файл.
  - `settlesOnNearest`: смещение `centre(of: 20) + 0.4 * pitch` → `settled.file == 20`,
    `settled.offset == centre(of: 20)`.
  - `momentumEndCommits`, `restCommitsWithoutMomentum`, `verticalIgnored`, `axisLockedOnce` — перенести из старых
    тестов с новыми ожиданиями.
  - `pressDuringMomentumTakesOver`: `takeOver()` во время momentum → следующие события momentum ничего не дают.
  - `fileCountChangeMidGestureKeepsFile`: `layoutChanged(keeping: f, layout: n + 50)` → `offset == newLayout.centre(of: f)`.
  - `singleFileGestureDoesNothing`: n = 1 — `Outcome.file == nil` для любого жеста.
- [ ] **Step 2:** `scripts/test.sh --filter StripScrollTests` — FAIL.
- [ ] **Step 3:** переписать модель; doc-комментарий типа обновить под новую механику.
- [ ] **Step 4:** — PASS.
- [ ] **Step 5:** коммит «StripScroll: the strip moves under a fixed centre; drag, rubber band, settle».

### Task 5: `StripAspects` — пропорции по файлам без режимов

**Files:**
- Modify: `Sources/LoupeCore/StripAspects.swift`
- Test: `Tests/LoupeCoreTests/StripAspectsTests.swift`

**Interfaces:**
- Produces: `public private(set) var aspects: [Double?]` (по индексу плейлиста; `nil` — неизвестна). Удаляются
  `mode`, `setMode(_:)`, `layoutAspects`, зависимость от `StripLayout.Aspects`/`filledAspects` (медиана-догадка
  больше не нужна: узким ячейкам пропорция не нужна, текущему — `unknownCurrentAspect`). Остальное (выборки,
  интервал, `paused`, `onChange`, `appliesOrientation`) без изменений.

- [ ] **Step 1:** в тестах заменить проверки `layoutAspects` на `aspects` (известные — значения, остальные `nil`),
  удалить тесты режима `crop`.
- [ ] **Step 2:** `scripts/test.sh --filter StripAspectsTests` — FAIL.
- [ ] **Step 3:** реализовать.
- [ ] **Step 4:** — PASS (сборка приложения на этом шаге может падать в `StripController` — его чинит Task 7; тесты
  LoupeCore должны проходить).
- [ ] **Step 5:** коммит «StripAspects: one aspect per file, no shapes».

### Task 6: `StripView` — новая отрисовка

**Files:**
- Modify (переписать): `Sources/Loupe/StripView.swift`
- Modify: `Sources/LoupeCore/StripHitZone.swift` (убрать увеличенные кадры: зона наведения — полоса минус полоса
  захвата края), `Sources/LoupeCore/StripResizeDrag.swift` (убрать ограничение лупы), их тесты.

**Interfaces:**
- Consumes: `StripScrollLayout`, `StripCell`.
- Produces (для Task 7):
  ```swift
  var layout: StripScrollLayout
  func show(offset: Double, current: Int, expansion: Double, animated: Bool)  // places cells; animated: 0.2 s ease-out
  func setImage(_ image: CGImage?, forFile file: Int)    // fades in 0.15 s over the placeholder frame
  func setUnavailable(forFile file: Int)
  var visibleFiles: [Int] { get }                        // ordered from the centre outwards
  func showLabel(file: Int, name: String); func endHover()
  var onHover: ((Int?) -> Void)?
  var onPress: ((Int) -> Void)?                          // a click (press+release, < 3 pt of travel) on a file
  var onDrag: ((CGFloat) -> Void)?; var onDragEnd: (() -> Void)?
  var onTrackpadScroll: ((NSEvent) -> Void)?; var onScroll: ((NSEvent) -> Void)?   // wheel → viewer, as now
  // kept as they are: onResizeDrag, onResizeEnd, onResize, onBackingChange, isScrollSpent, isOverlay, acceptsMouse,
  // trackOutside, cancelResize, refreshHover, isPressed
  ```
  Слои: один `contentLayer` (сдвиг — `position.x`, `CATransaction.setDisableActions(true)` вне анимаций),
  слой на файл из пула по `file`, заглушка — `borderWidth = 1`, `borderColor` белый 0.38, без заливки, радиус
  `strip-corner-radius`; эскиз — `contents` с `contentsGravity = .resizeAspectFill`, `masksToBounds`; маска краёв —
  `CAGradientLayer` (прозрачный → непрозрачный на `fadeLength`) как `mask` всей вьюхи; без подложки и рамки; подпись — маленькая вьюха `StripLabelView`
  (`NSGlassEffectView`, капсула, текст 12 pt, цифры моноширинные) вместо `CATextLayer`.

- [ ] **Step 1:** тесты `StripHitZone`/`StripResizeDrag` поправить под удаление лупы (убрать кейсы увеличенных
  кадров и предела лупы; оставить полосу захвата и зону наведения).
- [ ] **Step 2:** `scripts/test.sh --filter StripHitZoneTests --filter StripResizeDragTests` — FAIL → реализовать
  правки в LoupeCore → PASS.
- [ ] **Step 3:** переписать `StripView` по Interfaces (вью-тестов в проекте нет; проверка — Task 7 и ручная).
- [ ] **Step 4:** коммит вместе с Task 7 (вьюха без контроллера не собирается).

### Task 7: `StripController` — состояние ленты и скраб; удаление старого

**Files:**
- Modify (переписать большую часть): `Sources/Loupe/StripController.swift`
- Modify: `Sources/Loupe/StripHover.swift` (оставить только «файл под курсором» и задержку подписи; всё про
  увеличение удалить), `Sources/Loupe/ViewerWindowController.swift` (подписки на новые колбэки вьюхи; шеврон),
  `Sources/Loupe/ViewerSession.swift:170` (комментарий `stripVisibleFiles`)
- Delete: `Sources/LoupeCore/StripLayout.swift`, `Sources/LoupeCore/StripMagnifier.swift`,
  `Tests/LoupeCoreTests/StripLayoutTests.swift`, `Tests/LoupeCoreTests/StripMagnifierTests.swift`;
  в `Config.swift` — свойства `stripAspect`, `stripMagnify*`, `stripMagnifyLimitRange`, enum `StripAspect`.
- Test: `Tests/LoupeCoreTests/StripScrollTests.swift` (последовательности контроллера, вынесенные в модель — см. ниже)

**Interfaces:**
- Consumes: всё из Tasks 2–6.
- Поведение (спецификация, раздел «Поведение»):
  - `sessionDidChange` при `!scroll.isMoving`: шаг на ±1 → `view.show(offset: centre(of: new), …, animated: true)`;
    дальше → `animated: false`; раскрытие `expansion: 1`.
  - Жест/перетаскивание: `view.show(offset: scroll.offset, current: centreFile, expansion: 0, animated: false)`;
    `Outcome.file` → `session.scrub(to:)` (как сейчас). Конец (commit, отпускание мыши) → `scroll.settled` →
    анимация к `offset` с `expansion: 1` → `session.endScrub()` ровно один раз → `scroll.settle()`.
  - `onPress(file)` → `session.scrub(to: file)`, `session.endScrub()`, анимация к `centre(of: file)`.
  - Видимые файлы для эскизов: `session.stripVisibleFiles = view.visibleFiles`; запрос эскизов — только для ячеек,
    задержавшихся в окне ≥ `ViewerSession.dwellDelay` во время движения, сразу — в покое. Размер эскиза — по ширине
    ячейки (раскрытая текущая — по `aspect · h`).
  - Шеврон: `NSButton` без рамки с `chevron.down` / `chevron.up` (18 × 9 pt, белый 0.75), по центру над лентой
    (6 pt над фото) или у нижнего края, когда лента спрятана; видим, пока мышь над нижней третью фото или над
    лентой; действие — `togglePin()`.
- Тест последовательности (в модели, чтобы без AppKit): `@Test func gestureScrubsEachFileOnceAndCommitsOnce` —
  жест через 5 файлов, затем momentum end: `Outcome.file` ровно 5 раз, `commit` ровно один раз.

- [ ] **Step 1:** тест последовательности — FAIL, затем проходит после Task 4 (если уже проходит — оставить как
  регрессию).
- [ ] **Step 2:** переписать контроллер, удалить старые типы и свойства, поправить вызывающих (компилятор укажет).
- [ ] **Step 3:** `scripts/test.sh` — весь набор PASS; сборка приложения — OK.
- [ ] **Step 4:** ручная проверка на этой машине (приложение собрать и запустить, папка ≥ 1000 фото и папка из
  3 фото): трекпад, мышь, клик, края, ресайз окна и края ленты, полноэкранный режим, шеврон, `T`, заглушки на
  холодном кэше эскизов (`thumb-cache-size=0` на время проверки).
- [ ] **Step 5:** коммит (Task 6 + 7): «Strip: Photos' filmstrip — scrolls under a fixed centre, current photo
  in its shape; the magnifier and whole-folder layout go».

### Task 8: замер в LoupeBench и документация

**Files:**
- Create: `Sources/LoupeBench/StripBench.swift`; Modify: `Sources/LoupeBench/main.swift` (команда `strip`)
- Modify: `README.md` (раздел про ленту и таблица клавиш, если затронута), `docs/testing.md` (как запустить замер)

**Interfaces:**
- `LoupeBench strip [--files N]` (по умолчанию 10 000): 2 000 событий жеста через `StripScroll.event` +
  `StripScrollLayout.cells` — печать медианы и p99 µs на событие и максимум ячеек за событие.

- [ ] **Step 1:** реализовать команду; запустить `swift run -c release --triple "$LTS_TRIPLE" LoupeBench strip`
  (после `. scripts/libjxl-env.sh`). Ожидаемо: p99 < 1000 µs, ячеек ≤ 40 при h = 68 и ширине 1800.
- [ ] **Step 2:** README: описание ленты (поведение Photos, `strip-cell-max`), убрать упоминания лупы.
- [ ] **Step 3:** коммит «LoupeBench strip; README: the new strip».

### Task 9: перенос в `main` и проверка на M4

- [ ] **Step 1:** SettingsKit: запушить `slider-row`, PR в `main` с меткой `backport:lts-feature` (с подтверждения
  пользователя).
- [ ] **Step 2:** Loupe: `git switch strip-scroll && git cherry-pick <коммиты задач 2–8 из strip-scroll-lts>`;
  конфликты — разрешить, сохранив поведение `main`.
- [ ] **Step 3:** на M4: `scripts/test.sh` — PASS; ручная проверка из Task 7 Step 4; вид на macOS 27 сверить со
  скриншотами Photos.
- [ ] **Step 4:** PR Loupe `strip-scroll` → `main` с меткой `backport:lts-feature` (с подтверждения пользователя).
