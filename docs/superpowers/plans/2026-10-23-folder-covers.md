# Обложки папок и архивов — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** видимые карточки папок и zip в Home получают фото без открытия папки (отбор по листингу имён, эскизы в фоне, результат в каталоге); у обложки четыре раскладки, по умолчанию `hero`.

**Architecture:** кит — раскладки мозаики (`HomeMosaic.Layout`) и сигнал «сколько видимых» в `wantImages`; Loupe — чистый отбор образцов (`CoverSampling`), ограниченная очередь обложек (`CoverQueue`) в `ThumbnailStore`, связка в `FolderBrowserSource`, ключ `folder-cover`.

**Tech Stack:** Swift 6.2, AppKit, Swift Testing; кит — `swift test`; Loupe — `scripts/test.sh`, `scripts/make-app.sh`.

**Spec:** `docs/superpowers/specs/2026-10-23-folder-covers-design.md`

## Global Constraints

- Отбор: 4 фото равномерно по списку имён (индексы `round(i·(n−1)/3)`, i = 0…3, без повторов), последний открытый — первым; папка без фото — обложки первых 4 подпапок, глубина ≤ 2; пусто — nil, запоминается на сессию.
- Пределы: листингов одновременно ≤ 2 (локальный том), 1 (сетевой); эскизов на папку ≤ 4; генерация — существующий пул декодирования эскизов (`.utility`); видимые эскизы файлов раньше обложек; при листании в просмотрщике — пауза; таймаут листинга на сетевом томе 2 с; запас (не видимые) — после 150 мс без прокрутки.
- Раскладки `folder-cover = grid | hero | stack | single`, по умолчанию `hero`; ширина карточки < 110 pt → `single`; `stack` — три отпечатка, повороты −4°, 0°, +4°, тень; `hero` — большое ⅔ высоты, три малых внизу; при нехватке фото `hero` деградирует: 2–3 фото — большое + 1–2 малых, 1 — `single`.
- Главный поток не блокируется; числа пределов — замером `ThumbsBench`, запись рядом с константой.
- Проекты публичные: никаких личных путей и имён папок.

## Review Focus

1. Папка с тысячами файлов на сетевом томе: листинг не держит очередь дольше таймаута, остальные карточки продолжают заполняться — тест `slowListingTimesOut` (Task 3).
2. Быстрая прокрутка через сотню папок: задачи ушедших карточек отменяются, очередь не растёт — тест `cancelledWhenLeft` (Task 3).
3. Папка из одних видео / не-фото файлов: «пусто», не крутится бесконечно — тест `noPhotosIsEmpty` (Task 2).
4. Повторный вход в Home: обложки из каталога сразу, без листинга — тест `catalogFirst` (Task 4).
5. zip с вложенными папками внутри: отбор по записям-фото на любом уровне архива — тест `archiveEntriesAnyDepth` (Task 2).

---

### Task 1: кит — раскладки обложки и сигнал видимых

**Files (кит):**
- Modify: `Sources/HomeScreenKit/HomeMosaic.swift` (`public enum Layout: String, CaseIterable, Sendable { case grid, hero, stack, single }`; `make(_ images:, size:, layout:, scale:)`; `cells(count:layout:in:)`; адаптивный `single` при ширине < 110 pt), `Sources/HomeScreenKit/HomeSource.swift` (`func wantImages(_ ids: [String], visible: Int, width: CGFloat)` с реализацией по умолчанию → старый `wantImages(_:width:)`), `Sources/HomeScreenKit/HomeBrowserView.swift` (`askImages` передаёт число видимых; запас — после 150 мс без изменения `bounds`).
- Test: `Tests/HomeScreenKitTests/HomeMosaicTests.swift`, `HomeBrowserViewTests.swift` (через `FakeHomeSource`).

**Interfaces:**
- Produces: `HomeMosaic.Layout`; `HomeMosaic.cells(count: Int, layout: Layout, in: CGRect) -> [CGRect]` (для `stack` — прямоугольники до поворота + `rotations: [CGFloat]` через отдельную функцию `HomeMosaic.stackRotations(count:)`); `HomeSource.wantImages(_:visible:width:)`.

- [ ] **Step 1: Тесты** `heroCells` (4 фото: верхний ⅔ высоты на всю ширину, три равных снизу с зазором 2 pt), `heroDegrades` (3 → большое + 2; 1 → одна ячейка), `stackRotations` (−4, 0, +4 градуса), `gridStaysAsBefore` (старые ожидания), `narrowIsSingle` (ширина 100 → одна ячейка для любой раскладки), `wantImagesTellsVisible` (FakeHomeSource получает `visible` = число видимых id и id в порядке «видимые первыми»), `marginAfterScrollStops` (запас приходит только после 150 мс без прокрутки).
- [ ] **Step 2:** `swift test --filter "HomeMosaicTests|HomeBrowserViewTests"` — FAIL.
- [ ] **Step 3:** реализовать; `stack` рисует тень и поворот в `CGContext`.
- [ ] **Step 4:** `swift test` — зелёный; `swift build --product homescreen-demo`.
- [ ] **Step 5:** commit `Folder covers: hero, stack and single layouts beside the grid; the source learns which cards are visible`.

### Task 2: Loupe — отбор образцов

**Files:**
- Create: `Sources/LoupeCore/CoverSampling.swift`
- Test: `Tests/LoupeCoreTests/CoverSamplingTests.swift`

**Interfaces:**
- Produces: `public enum CoverSampling { public static func pick(_ names: [String], count: Int = 4, lastViewed: String?) -> [String]; public static func isPhoto(_ name: String) -> Bool /* через существующий список расширений Loupe */ }`; `public enum CoverSource: Equatable, Sendable { case photos([String]), subfolders([String]), empty }` и `public static func plan(names: [String], directories: [String], lastViewed: String?) -> CoverSource`.

- [ ] **Step 1: Тесты** `evenlySpread` (10 имён → индексы 0, 3, 6, 9), `fewerThanFour` (2 → оба), `lastViewedFirst` (последний открытый в начале, без дубля), `noPhotosUsesSubfolders` (нет фото, 6 подпапок → первые 4), `noPhotosIsEmpty` (только видео и текст, без подпапок → `.empty`), `archiveEntriesAnyDepth` (имена записей zip с `/` внутри → фото на любом уровне отбираются).
- [ ] **Step 2:** FAIL.
- [ ] **Step 3:** реализовать (используя существующий признак «это фото» Loupe — найти его, не дублировать список расширений).
- [ ] **Step 4:** `scripts/test.sh` — все.
- [ ] **Step 5:** commit `CoverSampling: four photos spread across a folder, subfolders for a folder without its own`.

### Task 3: Loupe — очередь обложек

**Files:**
- Create: `Sources/LoupeCore/CoverQueue.swift` (actor: задачи по id карточки, пределы, приоритет видимых, отмена, пауза)
- Modify: `Sources/LoupeCore/ThumbnailStore+Covers.swift` (`func folderCover(_ folder:, archive: Bool, maxPixel:) async -> [CGImage]` — листинг имён с таймаутом, `CoverSampling`, генерация до 4 эскизов через существующий генератор и `db.put`), `ThumbnailStore.swift` (пауза очереди обложек при активном листании просмотрщика — есть ли сигнал «передний план занят»? найти; иначе — `pauseCovers(_:)`, вызываемый сессией).
- Test: `Tests/LoupeCoreTests/CoverQueueTests.swift`, `ThumbnailCoversTests.swift`.

**Interfaces:**
- Consumes: Task 2.
- Produces: `CoverQueue(listingLimit: Int, networkListingLimit: Int)`; `func want(_ ids: [String], visible: Int, isNetwork: (String) -> Bool, work: @Sendable (String) async -> Void)`; `func pause(_ on: Bool)`; `ThumbnailStore.folderCover(...)`.

- [ ] **Step 1: Тесты** `respectsLimits` (локальные — не больше 2 одновременно, сетевые — 1; проверка через счётчик в фейковой работе), `visibleFirst`, `cancelledWhenLeft` (новый `want` без старого id отменяет его задачу), `pausedWaits`, `slowListingTimesOut` (фейковый листинг дольше таймаута → берутся успевшие имена), `catalogFirst` (`folderCover` при 4 эскизах в каталоге не листает папку).
- [ ] **Step 2:** FAIL.
- [ ] **Step 3:** реализовать; таймаут — через `withTaskGroup` с гонкой против `Task.sleep`; признак сетевого тома — существующий в Loupe (найти: `volumeIsLocal` / `URLResourceKey.volumeIsLocalKey`).
- [ ] **Step 4:** `scripts/test.sh` — все; `ThumbsBench` — замер на локальной папке с подпапками, числа пределов и результат — комментарием у констант.
- [ ] **Step 5:** commit `Cover queue: a few listings at a time, visible cards first, gone cards cancelled; folder covers made in the background`.

### Task 4: Loupe — связка, ключ, настройки (сборка L8)

**Files:**
- Modify: `Sources/Loupe/FolderBrowserSource.swift` (`wantImages(_:visible:width:)` → `CoverQueue`; `mosaic` берёт каталог, при нехватке — `folderCover`; раскладка из конфига), `Sources/LoupeCore/Config.swift` (`folder-cover`), `Sources/LoupeSettings/Pages/` (Home: выбор Grid / Hero / Stack / Single, описание `"How a folder's card shows what is inside. Narrow cards always show one photo."`), меню «Вид» браузера, если там есть стиль сетки — пункт раскладки.
- Test: `ConfigTests` (`folderCoverKey`), `ThumbnailCoversTests` (`catalogFirst` — если не покрыт в Task 3).

- [ ] **Step 1:** реализовать.
- [ ] **Step 2:** `scripts/test.sh` — все.
- [ ] **Step 3:** `scripts/make-app.sh` — **L8**. Ручные проверки — из спецификации («Сборка»).
- [ ] **Step 4:** commit `Home: folder and archive cards fill from the background queue; folder-cover picks the layout`.
