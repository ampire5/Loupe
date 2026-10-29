# Владение кэшем между окнами — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Несколько окон Loupe делят один `ImageCache` без взаимного вытеснения: у каждой сессии защищённое соседство (keep set), переключение окон переводит работу предыдущего окна в фоновый класс вместо отмены, restore активирует одно окно и строит остальные по одному, закрытие окна освобождает память сразу.

**Architecture:** Чистая логика keep set'ов и порядка вытеснения — в `CacheOwners` (без I/O, тестируется таблично). `ImageCache.reconcile` планирует активную сессию в классе `.foreground` и keep set'ы остальных в классе `.keep`; классы доходят до `IOPool` через `ReadPriority.readClass`, а `FileReader` доводит чтение, прошедшее больше половины. `WindowRegistry.open(session:)` строит фронтальное окно сразу, остальные по одному за оборот без активации. `unregister` освобождает всё ничьё.

**Tech Stack:** Swift 6.2 (язык v5), AppKit macOS 26, swift-testing, SwiftPM; LoupeBench и python-скрипты бенчей.

**Spec:** `docs/superpowers/specs/2026-10-25-window-cache-ownership-design.md` — прочитать целиком; исследование и цифры «до» — `spikes/rust/REPORT.md`, `spikes/rust/reports/window-switch-map.md`, `memory-audit.md`, `bench-results.md`.

## Global Constraints

- Ветка `window-ownership` от `polish`; `Packages/` в edit-режиме выбрасывает пины из `Package.resolved` — перед каждым коммитом `git checkout -- Package.resolved` (см. память `kits-edit-mode-drops-pins`).
- Сборка только arm64 на этой машине: `. scripts/libjxl-env.sh && swift build -c release --triple "$DEPS_TRIPLE"`; тесты `scripts/test.sh` (или `swift test --triple "$DEPS_TRIPLE" --filter <Suite>`).
- CLAUDE.md: никаких новых таймеров и фоновых циклов; константы с замером рядом; main thread не блокируется; каждая из четырёх правок — отдельный коммит с замером до/после.
- Новый ключ `loupe.conf`: `keep-share` — проценты `cache-memory` под keep set'ы, по умолчанию 50, диапазон 0–80. Константа `FileReader.finishReadAbove = 0.5` (доля файла, выше которой отмена чтения доводит его до конца).
- Keep set: текущая фотография (и страница-компаньон) на нужном уровне (`.full` если `focus.needsFull`, иначе `.preview`) + сосед с каждой стороны на `.preview`. Усечение «дольше всех неактивная — первой»: сначала соседи, потом текущая до `.preview`; активная сессия усекается последней и никогда ниже своей текущей на нужном уровне.
- Классы: задания `JobClass { foreground, keep }`; чтения `ReadClass { current, foreground, keep, background }`. `yieldToCurrent` паузит только `.foreground` и `.background`.
- Без feature flag; откат — git.

## Review Focus

1. Два окна на одной папке с одной текущей фотографией: keep set'ы пересекаются — запись считается в бюджет один раз и защищена, пока её держит хотя бы одна сессия (тест в задаче 1).
2. `keep-share = 0`: keep set'ы пусты, поведение равно сегодняшнему (только текущая активной и видимых защищена) — ничего не ломается (тест в задаче 1).
3. Давление памяти ÷4 при 5 окнах: keep set'ы усекаются до текущих-превью, активная не трогается; после `.normal` соседи возвращаются без повторного чтения с носителя, если байты уцелели (тест в задаче 3).
4. Доведение чтения файла, который исчез с шары на середине: `pread` вернул 0 → чтение завершается коротким буфером, как сегодня, а не зависает в ожидании «доведения» (тест в задаче 5).
5. Restore с окном, чей путь не ответил за 1 с: фронтальное окно открывается сразу, фоновое получает `.home` с тостом, как раньше; закрытие окна во время его отложенного построения не оставляет `pendingWindows` висеть (тест в задаче 7).

---

### Task 1: Keep set'ы в `CacheOwners`

**Files:**
- Modify: `Sources/LoupeCore/CacheOwners.swift`
- Test: `Tests/LoupeCoreTests/CacheOwnersTests.swift`

**Interfaces:**
- Consumes: `CacheOwnerFacts` (есть).
- Produces: в `CacheOwnerFacts` новые поля `previousURL: URL?`, `nextURL: URL?`, `currentGoal: CacheGoal` (`.preview` по умолчанию), `companionURL: URL?`;
  `public typealias KeepSet = [URL: CacheGoal]`;
  `public static func keepSets(_ sessions: [CacheOwnerFacts], share: Int, estimate: (URL, CacheGoal) -> Int) -> [CacheSessionID: KeepSet]`;
  `public static func kept(_ sets: [CacheSessionID: KeepSet]) -> [URL: CacheGoal]` (объединение, по максимуму goal);
  `public static func evictionOrder(_ urls: [URL], sessions: [CacheOwnerFacts], kept: Set<URL>) -> [URL]` (старая сигнатура остаётся обёрткой с `kept: Set(protected(sessions))`).

- [ ] **Step 1: Написать падающие тесты** в `CacheOwnersTests` (помощник `session(...)` расширить параметрами `prev`/`next`/`goal`; `estimate` возвращает 100 за `.preview`, 600 за `.full`):

```swift
@Test func keepSetsHoldCurrentAndNeighbours()   // 5 сессий, share 3500: у каждой {current: goal, prev: .preview, next: .preview}
@Test func keepSetsTruncateOldestFirst()        // share 900: у трёх самых старых только current .preview; активная целиком
@Test func keepSetsZeroShareIsTodaysProtection() // share 0: только current активной и видимых, как protected()
@Test func sharedEntryCountedOnce()              // две сессии с одной current: в сумме она один раз, и в обоих set'ах
@Test func keptNeverInEvictionOrder()            // evictionOrder(kept:) не содержит ни одного URL из kept
```

- [ ] **Step 2: Прогнать** — `swift test --triple "$DEPS_TRIPLE" --filter CacheOwnersTests`; ожидание: ошибки компиляции «no member keepSets».
- [ ] **Step 3: Реализовать** поля фактов, `keepSets` (порядок усечения: сессии по `lastActive` возрастанию, активная последней; шаг 1 снимает `previousURL`/`nextURL`, шаг 2 понижает `currentGoal` до `.preview`; активная сессия не понижается), `kept`, `evictionOrder(kept:)`.
- [ ] **Step 4: Прогнать** тот же фильтр; ожидание: все зелёные, старые тесты `CacheOwnersTests` не изменились.
- [ ] **Step 5: Commit** — `git add Sources/LoupeCore/CacheOwners.swift Tests/LoupeCoreTests/CacheOwnersTests.swift && git commit -m "CacheOwners: keep sets per session, truncated oldest-inactive first"`.

### Task 2: Ключ `keep-share`

**Files:**
- Modify: `Sources/LoupeCore/Config.swift` (список ключей, парсер, `value(for:)`), `Sources/LoupeCore/ConfigText.swift` (описание ключа), `Sources/LoupeCore/CacheLimits.swift`
- Test: `Tests/LoupeCoreTests/ConfigTests.swift` (или где лежат тесты `cache-memory`; найти `cacheMemory` в Tests и добавить рядом), `Tests/LoupeCoreTests/CacheLimitsTests.swift` если есть

**Interfaces:**
- Produces: `Config.keepShare: Int` (50, clamp 0…80, предупреждение вне диапазона как у других процентных ключей); `CacheLimits.keepShare: Int`; `CacheLimits.keepBytes(effectiveMemory: Int) -> Int` = `effectiveMemory * keepShare / 100`.

- [ ] **Step 1: Тесты**: `keepShareDefault50`, `keepShareClampedTo80`, `keepShareParsedFromConf`, `keepBytesIsShareOfEffectiveMemory` (4 ГиБ, 50 → 2 ГиБ; под давлением ÷2 → 1 ГиБ).
- [ ] **Step 2: Прогнать**, ожидание: падение.
- [ ] **Step 3: Реализовать** по образцу ближайшего процентного ключа (`grep -n "percent\|0...100" Config.swift`); текст ключа в `ConfigText` — по-английски, одна строка, как у `cache-memory`.
- [ ] **Step 4: Прогнать**, зелёные; `swift build` без предупреждений о неиспользуемом ключе (шаблон `InputConfTemplate`/settings не трогать — `keep-share` в Settings не выводится).
- [ ] **Step 5: Commit** — `"Config: keep-share, the cache-memory share kept for other windows"`.

### Task 3: Планирование keep set'ов и класс `.keep` в `ImageCache`

**Files:**
- Modify: `Sources/LoupeCore/ImageCache.swift` (`reconcile`, `shortPlan` → `keepPlans`, `evictionCandidates`, `readyCandidates`, `evictToFit`, `stats`), `Sources/LoupeCore/ImageCache+Sessions.swift` (`ownerFacts`), `Sources/LoupeCore/ImageCacheEntry.swift` (`JobPhase.jobClass`, `CacheStats.keptForOtherWindows`), `Sources/LoupeCore/ImageCache+Jobs.swift` (класс задания → приоритет чтения и слот декода), `Sources/LoupeCore/StatsLine.swift` (`activationLog`: `· kept N MB`), `Sources/Loupe/ViewerWindowController.swift:2171-2200` (Diagnostics: `· kept for other windows N MB`)
- Test: `Tests/LoupeCoreTests/ImageCacheSessionsTests.swift`

**Interfaces:**
- Consumes: Task 1 (`keepSets`, `kept`, `evictionOrder(kept:)`), Task 2 (`keepBytes`).
- Produces: `enum JobClass { case foreground, keep }` в `ImageCacheEntry.swift`; `JobPhase.jobClass: JobClass`; `CacheStats.keptForOtherWindows: Int` (байт keep set'ов неактивных сессий, резидентных сейчас); `ImageCache.keepPlans() -> [(url: URL, goal: CacheGoal, session: CacheSessionID)]` (private); `ownerFacts()` заполняет `previousURL/nextURL/currentGoal/companionURL` из `files`/`focus`.

- [ ] **Step 1: Тесты** (на `Rig` из `ImageCacheRig.swift`, две–пять сессий, `setMemory`):

```swift
@Test func inactiveSessionKeepsNeighbours()      // после setActivity(B active) у A резидентны current + 2 соседа превью
@Test func keepSetSurvivesOtherWindowsFill()     // B листает 30 файлов при 4 ГиБ: A.current/prev/next не вытеснены, evictedInactive.count == 0
@Test func keepSetsTruncateUnderPressure()       // setMemoryPressure(.critical) при 5 сессиях: соседи сняты, current активной цела; .normal → соседи вернулись, rereads == 0
@Test func keepJobsRunInKeepClass()              // задание соседа A после активации B имеет jobClass == .keep и не отменено (нет .jobCancelled)
@Test func keptForOtherWindowsCounted()          // stats().keptForOtherWindows == сумма байт keep set'ов неактивных
@Test func visibleInactiveStillGetsItsPhoto()    // существующий visibleInactiveGetsItsPhoto остаётся зелёным (short plan ⊂ keep plan)
```

- [ ] **Step 2: Прогнать** `--filter ImageCacheSessionsTests`; ожидание: падения/компиляция.
- [ ] **Step 3: Реализовать**: `reconcile` строит `wants` из плана активной (`.foreground`) + `keepPlans()` (`.keep`, после плана активной в порядке `lastActive` убыванию); отмена ожидающих заданий — только тех, чьего (url, goal) нет ни в одном из двух; задание, перешедшее из `.foreground` в `.keep`, получает `jobClass = .keep` и `ReadPriority` ниже соседей активной (значение `ReadPriority.keepBase = 500_000`, выше `background`); `evictToFit` целевой лимит не меняется, но `evictionCandidates`/`readyCandidates` идут через `evictionOrder(kept:)` с `kept = Set(CacheOwners.kept(keepSets).keys)`, причём keep set'ы пересчитываются в начале `reconcile` с `share = limits.keepBytes(effectiveMemory:)` и хранятся в `keepSetsNow`; `degrade` не трогает уровень ≥ keep-goal записи. `stats()` считает `keptForOtherWindows`.
- [ ] **Step 4: Прогнать** весь `LoupeCoreTests` (`scripts/test.sh`): зелёные; особо `evictsOldestInactiveFirst`, `twoTabsOneFolder`, `ImageCacheTests` про pressure (937–1012) — при изменении ожиданий править тест с комментарием «keep set».
- [ ] **Step 5: Commit** — `"ImageCache: keep sets planned in the .keep class; other windows no longer evicted first"`.

### Task 4: Классы чтений в `ReadPriority`/`IOPool`

**Files:**
- Modify: `Sources/LoupeCore/FileReader.swift:50-90` (`ReadPriority`), `Sources/LoupeCore/IOJob.swift`, `Sources/LoupeCore/IOPool.swift:129-200`
- Test: `Tests/LoupeCoreTests/FileReaderTests.swift` (там живут тесты пула; если есть `IOPoolTests.swift` — туда)

**Interfaces:**
- Produces: `public enum ReadClass: Sendable { case current, foreground, keep, background }`; `ReadPriority.readClass: ReadClass` (вычисляется: `isCurrent` → `.current`, `isBackground` → `.background`, иначе `keep` если `value >= ReadPriority.keepBase`, иначе `.foreground`); `IOJob.readClass` (под замком пула, читается при выборе).
- Consumes: Task 3 (`ReadPriority.keepBase`).

- [ ] **Step 1: Тесты**: `keepReadIsNotPausedByCurrent` (чтение класса keep продолжает получать чанки, пока current читает; foreground — ждёт), `keepReadQueuesBehindForeground` (порядок старта: current, foreground, keep, background), `keepReadsUseViewerShare` (keep занимает нить viewer-доли, не background-доли).
- [ ] **Step 2: Прогнать**, ожидание: падение.
- [ ] **Step 3: Реализовать**: `yieldToCurrent` — условие паузы дополняется `job.readClass != .keep`; выбор в `pick` (`IOPool.swift:179-195`) — `.keep` считается `neighbourRoom`, значение приоритета уже выше соседей.
- [ ] **Step 4: Прогнать** `FileReaderTests` + `ImageCacheTests`: зелёные.
- [ ] **Step 5: Commit** — `"IOPool: read classes; keep reads go on while the current photo reads"`.

### Task 5: Доведение чтения и счётчик `rereads`

**Files:**
- Modify: `Sources/LoupeCore/FileReader.swift` (`readChunked` около :285-320, `cancel` пути), `Sources/LoupeCore/IOJob.swift` (`progress: Double`), `Sources/LoupeCore/ImageCache.swift` (`reconcile` — отмена чтения; `readTask`; `rereads`), `Sources/LoupeCore/ImageCacheEntry.swift` (`CacheStats.rereads: Int`), `Sources/LoupeCore/StatsLine.swift` (`activationLog`: `· rereads N`)
- Test: `Tests/LoupeCoreTests/FileReaderTests.swift`, `Tests/LoupeCoreTests/ImageCacheSessionsTests.swift`

**Interfaces:**
- Produces: `FileReader.finishReadAbove: Double = 0.5` (static let, комментарий: «замер на NAS — docs/bench/<дата>-window-ownership.md»); `IOJob.finishIfPastThreshold: Bool` — при `markCancelled` чтение с `filled/size >= finishReadAbove` продолжает до конца и возвращает байты; результат доходит до `CacheEntry.data` как `.bytes` (вызывающая сторона `readTask` не отменяет `Task`, а ставит флаг `read.softCancel()`); `ImageCache.rereads: Int` — инкремент в `readTask`, если запись когда-либо имела `data` и потеряла её (`CacheEntry.hadBytes: Bool`).
- Consumes: Task 4.

- [ ] **Step 1: Тесты**: `cancelAfterHalfFinishesRead` (chunkReader по 1 МиБ, файл 10 МиБ, отмена после 6 МиБ → результат полный), `cancelBeforeHalfStops` (отмена после 3 МиБ → `CancellationError`, буфер освобождён), `shrunkFileFinishesShort` (pread вернул 0 на 7-м чанке → короткий результат без ожидания), `rereadCountedWhenBytesWereEvicted` (Rig: байты вытеснены → повторное чтение → `stats().rereads == 1`; возврат в окно с целым keep set'ом → 0).
- [ ] **Step 2: Прогнать**, падение.
- [ ] **Step 3: Реализовать** (`betweenChunks` бросает только если `isCancelled && !finishIfPastThreshold`; `softCancel()` выставляет флаг по текущему `progress`).
- [ ] **Step 4: Прогнать** `FileReaderTests`, `ImageCacheSessionsTests`: зелёные.
- [ ] **Step 5: Commit** — `"FileReader: a read past half the file is finished, not dropped; rereads counted"`.

### Task 6: Stamp-check без паузы при возврате в окно

**Files:**
- Modify: `Sources/LoupeCore/ImageCache.swift:656-674` (`becameCurrent`)
- Test: `Tests/LoupeCoreTests/ImageCacheSessionsTests.swift`

**Interfaces:**
- Consumes: Task 4 (`ReadClass`), `isSatisfied(url, e, goal)` (есть).
- Produces: `becameCurrent` ставит `priority.isCurrent = true` только если `!isSatisfied(url, e, needed)`, где `needed` = `currentGoal` сессии; иначе `ReadPriority(1)` без `isCurrent` (класс `.foreground`).

- [ ] **Step 1: Тест** `returnToSharpWindowDoesNotPauseKeepReads`: A резкая, B активна и читает; `setActivity(A active)` → stamp-check A запущен, чтение keep-класса B не получило `paused` (через `IOPool.priorityMoves`/`paused` в фейке пула Rig'а); существующий `returnWithoutWork` остаётся зелёным.
- [ ] **Step 2: Прогнать**, падение.
- [ ] **Step 3: Реализовать**.
- [ ] **Step 4: Прогнать**, зелёные.
- [ ] **Step 5: Commit** — `"ImageCache: a stamp check of a photo already sharp does not pause other reads"`.

### Task 7: Restore — одно активное окно, остальные по одному

**Files:**
- Modify: `Sources/Loupe/WindowRegistry.swift:306-349` (`open(session:)`, новый `buildNext()`), `Sources/LoupeCore/SessionRestorePlan.swift` (`order(_:) `), `Sources/Loupe/ViewerWindowController.swift:762-793` (`restore(_:activate:)`, `showWithoutKey()`), `Sources/Loupe/ViewerSession.swift:387-412,459-473` (`deferListing`, `releaseDeferredListing()`), `Sources/Loupe/AppDelegate.swift:145-151` (передача «фронтальное первым»)
- Test: `Tests/LoupeCoreTests/SessionRestorePlanTests.swift`; интеграция — бенч (задача 9)

**Interfaces:**
- Produces: `SessionRestorePlan.order(_ steps: [WindowStep], front: Int) -> [WindowStep]` — фронтальное окно первым, остальные в исходном порядке «сзади наперёд» для Z; `WindowStep.isFront: Bool`; `ViewerWindowController.restore(_ step: TabStep, activate: Bool)`; `ViewerWindowController.showBehind(_ other: NSWindow)` (= `showWindow` + `window.order(.below, relativeTo: other.windowNumber)` без `makeKey`); `ViewerSession.deferListing: Bool` (при `true` `open` не вызывает `rereadFolder`/`quickList`, а запоминает файл) и `releaseDeferredListing()`; `WindowRegistry.pendingWindows: [WindowStep]`, `buildNext()` через `DispatchQueue.main.async`; обработчик `folder names` активной сессии (`ViewerSession.onFolderNamed: (() -> Void)?`) → `registry.releaseDeferredListings()`.
- `HomeGrid.availability`: вызывается с путями всех окон, кроме фронтального; фронтальное строится немедленно, до `await`.

- [ ] **Step 1: Тесты** `SessionRestorePlanTests`: `frontWindowComesFirst`, `othersKeepBackToFrontOrder`, `frontIndexOutOfRangeFallsBackToLast`.
- [ ] **Step 2: Прогнать**, падение.
- [ ] **Step 3: Реализовать** порядок и `WindowRegistry`: фронтальное окно — `makeController` + `restore(step, activate: true)` + `bringToFront` синхронно; `pendingWindows` строятся по одному в `buildNext()` (следующий — из `DispatchQueue.main.async` после `showBehind`), с `restore(step, activate: false)` и `session.deferListing = true`; `windowWillClose` во время restore удаляет шаг из `pendingWindows`; `enterFullScreenInTurn` — фронтальное первым; удержание показа фото только у `activate: true`.
- [ ] **Step 4: Проверить вручную по логу**: `LOUPE_DEBUG=1 LOUPE_CONFIG_DIR=<conf с session-restore=last>` с Last Session из 5 окон — ровно одна строка `activate N state=…` до первого `key`, `folder names` фоновых папок появляются после `folder names` активной; `session opened` раньше, чем раньше. Закрыть окно во время restore (⌘W сразу после запуска) — без краша, остальные окна достроены.
- [ ] **Step 5: Прогнать** `scripts/test.sh` целиком; зелёные.
- [ ] **Step 6: Commit** — `"Session restore: the front window first and alone active; the others one per turn, listings deferred"`.

### Task 8: Закрытие окна освобождает сразу

**Files:**
- Modify: `Sources/LoupeCore/ImageCache+Sessions.swift:30-35` (`unregister`), `Sources/Loupe/ViewerView.swift:591-597` (`teardown`), `Sources/Loupe/RenderLoop.swift` (`dropSnapshots()`)
- Test: `Tests/LoupeCoreTests/ImageCacheSessionsTests.swift`, `Tests/LoupeRenderTests` если есть тест `RenderLoop` (иначе проверка по бенчу)

**Interfaces:**
- Produces: `unregister` — после удаления сессии: `cancel` всех `e.jobs` и `e.read` записей, которые листила только она; для каждой записи с `!isListed(url)` → `dropPyramid(e)`, `e.data = nil`, `e.ready = nil`, `entries[url] = nil`; затем `reconcile()` и `malloc_zone_pressure_relief` как в `trimIdle` (`ImageCache+Sessions.swift:190-193`); `ViewerView.teardown()` дополнительно `shownImage = nil` и `renderLoop.dropSnapshots()`; `RenderLoop.dropSnapshots()` обнуляет страницы-снапшоты (`RenderLoop.swift:13-14,79-84`).

- [ ] **Step 1: Тесты**: `unregisterFreesWhatNobodyLists` (две сессии, разные папки; `unregister(A)` → записи A отсутствуют, `stats().usedBytes` = байты B), `unregisterKeepsWhatAnotherLists` (одна папка на двоих → записи остались, принадлежат B), существующий `unregisterActiveKeepsOthersIdle` зелёный.
- [ ] **Step 2: Прогнать**, падение.
- [ ] **Step 3: Реализовать**.
- [ ] **Step 4: Прогнать** `LoupeCoreTests` + `LoupeRenderTests`: зелёные. Вручную: `LOUPE_DEBUG=1`, открыть 3 окна с 147-МП JXL, закрыть два → в Diagnostics `Memory` падает в течение ~1 с; в логе `viewer window freed` для каждого.
- [ ] **Step 5: Commit** — `"ImageCache: a closed window's entries are freed at once; the view drops its image on teardown"`.

### Task 9: Бенчи, replay `close`, документ до/после

**Files:**
- Create: `scripts/session-bench.py`, `scripts/switch-bench.py` (перенос из `spikes/rust/bench/` с правками ниже), `docs/bench/2026-10-xx-window-ownership.md`
- Modify: `Sources/LoupeBench/ReplayScript.swift` (`close`), `Sources/LoupeBench/Replay.swift` (цикл open→pan→close с реальным `register/unregister` сессии и печать footprint на цикл), `README.md` (строка про `keep-share` в разделе настроек кэша, если такой раздел перечисляет `cache-memory`)

**Interfaces:**
- Consumes: строки лога `activate … · other windows −N (M MB) · kept K MB · rereads R` (Task 3, 5), `session opened`, `folder names`.
- Produces: скрипты печатают `other windows`, `kept`, `rereads`, число `activate` до первого `key`, число `folder names` в первые 3 с; `LoupeBench replay --script close <folder>` печатает таблицу «цикл | RAM после | GPU после» и вердикт плато (последние 10 циклов ±5 %).

- [ ] **Step 1: Перенести скрипты** и добавить разбор новых счётчиков; прогнать на текущей ветке «до» (цифры «до» для этой машины уже есть в `spikes/rust/reports/bench-results.md` — можно переиспользовать, указав коммит).
- [ ] **Step 2: Replay `close`**: `ReplayScript.named("close")` → 20 циклов; в `Replay.swift` цикл делает `cache.register`, open первой фотографии, 5 шагов `→` по 0,5 с, `cache.unregister`, ждёт `isIdle`, читает `ProcessMemory.footprint()` и `gpuAllocated()`.
- [ ] **Step 3: Прогнать «после»** на M4 (`session-bench.py` с 5 JXL-папками `~/Pictures/benchmark/session-{1..4}` + `benchmark/images`; `switch-bench.py` с NAS-папкой; `replay --script close`), затем на Intel с NAS-папками. Каждую из четырёх правок измерить отдельно (`git stash`/коммиты по одному) — по строке в таблице.
- [ ] **Step 4: Документ** `docs/bench/<дата>-window-ownership.md` по образцу `2026-10-23-memory-tiers.md`: машина, файлы, сценарии, таблица до/после (`other windows`, `rereads`, активаций при restore, проба main thread p95/max, `session opened` → первый `full on screen`, footprint-плато), вывод по `finishReadAbove` и `keep-share` (подтвердить 0,5 и 50 % или поменять константы с цифрами).
- [ ] **Step 5: Приёмка по спеку §5**: `other windows −N` = 0 при бюджете ≥ keep set'ов; `rereads` = 0 при возврате; одна активация; плато. Если какой-то пункт не выполнен — это баг, а не «уточнение», вернуться к задаче-владельцу.
- [ ] **Step 6: Commit** — `"Bench: window-ownership before/after, replay close script, session/switch benches in scripts/"`.
