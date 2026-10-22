# Карточки папок и архивов: крупная обложка и сведения — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** карточки папок и zip в браузере Home — «Плакат» (обложка + полоса сведений под ней) по умолчанию, «Карточка» и «Список» переключателем, запоминаемым для папки; сведения из сохранённой сводки папки и памяти посещений.

**Architecture:** кит — модель сведений (`CardSummary`, `CardStyle`), раскладки сетки и три вида карточек, `setSummary(_:for:)` по образцу `setImage`; Loupe — чистая сводка папки (`FolderSummary`) из листинга с датами, таблица `folder_summaries` в `Catalog.db`, сводка в той же задаче очереди обложек, посещения в `folder_positions`, связка в `FolderBrowserSource`, ключ `folder-cards`.

**Tech Stack:** Swift 6.2, AppKit, SQLite (свои обёртки), Swift Testing; кит — `swift test`; Loupe — `scripts/test.sh`, `scripts/make-app.sh`.

**Spec:** `docs/superpowers/specs/2026-10-22-folder-cards-design.md`

**Ветки:** кит — `folder-cards` от `capsule-pointer` (корень кита); Loupe — `folder-cards-lts` (чекаут LTS, кит подключён `swift package edit HomeScreenKit`). Перенос в `main` — после ручной проверки L13, отдельно.

## Global Constraints

- Ничего не читается из файлов неоткрытой папки: только листинг каталога (имена + stat листинга) и одно чтение центрального каталога zip.
- Листинг с датами — только на локальных томах (`ThumbnailStore.mountIsNetwork` / `coverVolumeIsNetwork` = false); на шарах — только имена, как сейчас.
- Фото в подпапках — только из сохранённых сводок прямых подпапок; никаких рекурсивных листингов ради счёта.
- Сводка считается в задаче очереди обложек (`.utility`, её пределы, пауза при листании); на главном потоке — только сборка строк.
- `Catalog.db`: новая таблица через `CREATE TABLE IF NOT EXISTS` при открытии, **без** смены `format_version` (её смена стирает каталог).
- `Loupe.db`: `schemaVersion` остаётся 2 (решение R9): `ALTER TABLE folder_positions ADD COLUMN` при каждом открытии вне проверки версии, как `browserTables`; файл версии 3 (предварительная сборка) принимается и снова получает 2.
- Ключ `folder-cards = posters | cards | list`, по умолчанию `posters`: глобально в `loupe.conf`, для папки — в folder settings (наследуется, как `browser-sort`).
- Строки интерфейса — английские. Пороги ширины полосы: < 200 pt — одна строка; ≥ 280 pt — прогресс текстом. Узкая колонка (< 320 pt) — всегда «Плакат». Гистограмма — 12 корзин.
- Клавиши переключателя: ⌃⌘1 Posters, ⌃⌘2 Cards, ⌃⌘3 List (решение пользователя: ⌘1–⌘9 в Loupe всегда выбирают вкладку по номеру, и на Home тоже).
- Числа пределов (строк в `folder_summaries`) — замером, запись рядом с константой. Проекты публичные: никаких личных путей и имён.

## Review Focus

1. Папка на SMB с тысячами файлов: карточка не ждёт листинга с датами, обложка приходит как раньше — тест `shareListsNamesOnly` (Task 6).
2. Файл добавлен в папку после подсчёта: сводка пересчитывается при следующем проходе, не показывает старое — тест `changedFolderIsRecounted` (Task 6).
3. Удалены файлы с прошлого визита: «+N» не отрицательный, прогресс не больше 100 % — тест `deletedFilesNeverNegative` (Task 7).
4. Папку переименовали: визит и сводка не теряются для нового пути (`FolderPositions.movePaths`) — тест `movedFolderKeepsVisit` (Task 7).
5. Все фото одной датой / папка без фото: гистограмма в одну корзину, годы «2021», без деления на ноль — тест `oneDateAndNoPhotos` (Task 4).

---

### Task 1: кит — модель сведений и раскладки сетки

**Files (кит):**
- Create: `Sources/HomeScreenModel/CardSummary.swift`, `Sources/HomeScreenModel/CardSummaryText.swift`
- Modify: `Sources/HomeScreenModel/BrowserEntry.swift` (поле `summary`), `Sources/HomeScreenModel/GridLayout.swift` (стиль коллекций: `posters` с точной высотой полосы, `cards`, `list`)
- Test: `Tests/HomeScreenModelTests/CardSummaryTextTests.swift`, `Tests/HomeScreenModelTests/GridLayoutTests.swift`

**Interfaces:**
- Produces:
  - `public enum CardStyle: String, CaseIterable, Sendable { case posters, cards, list }`
  - `public struct CardSummary: Equatable, Sendable { var photos: Int?; var folders: Int?; var insidePhotos: Int?; var insideIncomplete: Bool; var bytes: Int64?; var first: Date?; var last: Date?; var histogram: [UInt8]; var viewed: Double?; var done: Bool; var new: Int; var twoPages: Bool; var rightToLeft: Bool; var problem: Problem? }`, `enum Problem { case broken, offline }`
  - `public enum CardSummaryText { static func inside(_:) -> String; static func years(_:) -> String?; static func size(_:) -> String?; static func viewed(_:) -> String? }` — «248 · 3 folders», «+1 204 inside» / «+1 204+ inside», «2019–2023» / «2021», «4.2 GB», «137 / 248»
  - `GridLayout(sections:width:target:names:style:metrics:)`, `public static func bandHeight(width: CGFloat) -> CGFloat` (1 строка < 200, 2 строки иначе), строки списка 44 pt, карточки 300 × 92.

- [ ] **Step 1: Тесты** `insideLine` («248 · 3 folders»; без подпапок «248»; «+1 204+ inside» при `insideIncomplete`), `yearsSpan` (2019…2023 → «2019–2023»; одна дата → «2021»; nil → nil), `sizeText` (4 500 000 000 → «4.2 GB»), `posterReservesItsBand` (высота слота = ширина + `bandHeight(width:)`; 180 pt → одна строка, 232 pt → две), `cardsAreThreeHundredWide` (ширина 960 → 3 колонки по 300 + зазоры), `listRowsAre44` (слот 44, одна колонка на всю ширину), `narrowColumnIsPosters` (ширина 300, стиль `list` → раскладка постеров).
- [ ] **Step 2:** `swift test --filter "CardSummaryTextTests|GridLayoutTests"` — FAIL (нет типов).
- [ ] **Step 3:** реализовать; существующие вызовы `GridLayout(...)` получают `style: .posters` по умолчанию; фото-секции не меняются.
- [ ] **Step 4:** `swift test` — все зелёные.
- [ ] **Step 5:** commit `Home model: card facts and styles; the grid reserves a poster's band exactly, compact cards and list rows`.

### Task 2: кит — «Плакат» и «Карточка», сведения позже листинга

**Files (кит):**
- Create: `Sources/HomeScreenKit/PosterCard.swift`, `Sources/HomeScreenKit/CompactCard.swift`
- Modify: `Sources/HomeScreenKit/HomeBrowserView.swift` (`tile()`, `item(for:)`, `setSummary(_:for:)`), `Sources/HomeScreenKit/HomeSource.swift` (`cardStyle(for:)` / `setCardStyle(_:for:)` с реализацией по умолчанию `.posters` / no-op)
- Test: `Tests/HomeScreenKitTests/HomeBrowserViewTests.swift`, `Tests/HomeScreenKitTests/PosterCardTests.swift`, `FakeHomeSource.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces: `HomeBrowserView.setSummary(_ summary: CardSummary?, for id: String)`; `HomeSource.cardStyle(for: BrowserLocation) -> CardStyle`, `setCardStyle(_: CardStyle, for: BrowserLocation)`; `HomeBrowserView.chooseCardStyle(_: CardStyle)` (для меню приложения).

- [ ] **Step 1: Тесты** `posterDrawsBandBelowPicture` (кадр картинки w × w, полоса ниже, ничего поверх картинки; ⧉ и RTL в строке имени; «+12» на обложке; ✓ при `done`), `posterNarrowHasOneLine` (180 pt → только имя и число), `summaryArrivesWithoutRelisting` (`setSummary` меняет одну карточку; `FakeHomeSource.listCount` и порядок не меняются, картинка остаётся), `cardStyleComesFromTheSource` (`FakeHomeSource.cardStyles[location] = .cards` → карточки `CompactCard`; `chooseCardStyle(.list)` → `setCardStyles` получил `(.list, location)`), `collectionsStayCollectionCards` (Recent/места — `CollectionCard`), `brokenAndOffline` (`.offline` → карточка тусклая 0.45, `.broken` — нет, значок есть).
- [ ] **Step 2:** `swift test --filter "HomeBrowserViewTests|PosterCardTests"` — FAIL.
- [ ] **Step 3:** реализовать; папки и zip в браузере → `PosterCard` / `CompactCard` по стилю; строки — `CardSummaryText`; без `summary` — как сегодня: имя и `count`.
- [ ] **Step 4:** `swift test` — все; `swift build --product homescreen-demo` (демо показывает три стиля на фейковых сводках).
- [ ] **Step 5:** commit `Home: folder and archive cards as posters with a band of facts, or compact cards; facts arrive like pictures`.

### Task 3: кит — «Список» и переключатель

**Files (кит):**
- Create: `Sources/HomeScreenKit/ListRow.swift`, `Sources/HomeScreenKit/ListHeader.swift`
- Modify: `Sources/HomeScreenKit/HomeBrowserView.swift` (стиль `list`, ⌃⌘1/⌃⌘2/⌃⌘3 в `handleKey`), `Sources/HomeScreenKit/HomeToolbar.swift` (трёхсегментный переключатель рядом со стилем сетки, скрыт на страницах и местах)
- Test: `Tests/HomeScreenKitTests/HomeBrowserKeysTests.swift`, `HomeBrowserViewTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces: заголовок колонок `Name · Inside · Dates · Viewed · Size`; щелчок по Name/Dates/Size → тот же путь, что капсула (`sortKeyChosen`).

- [ ] **Step 1: Тесты** `commandDigitsSwitchStyle` (⌃⌘1/⌃⌘2/⌃⌘3 → `setCardStyle` `.posters/.cards/.list`; ⌥1 по-прежнему сортировка), `listHeaderSorts` (щелчок Dates → `setSorts.last == date-desc`, повторный → `date`; Inside и Viewed не сортируют), `listShowsFilesInRows` (файлы — строки с форматом, датой, размером), `switchHiddenOnPlaces` (у мест и страниц переключателя нет), `toolbarSwitchFollowsStyle`.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** `swift test` — все.
- [ ] **Step 5:** commit `Home: a list of folders with sortable columns, and a posters / cards / list switch (⌘1–⌘3)`.

### Task 4: Loupe — сводка папки (чистая)

**Files:**
- Create: `Sources/LoupeCore/FolderSummary.swift`
- Test: `Tests/LoupeCoreTests/FolderSummaryTests.swift`

**Interfaces:**
- Produces: `public struct FolderSummary: Equatable, Sendable { photos, folders: Int; bytes: Int64?; first, last: Date?; histogram: [UInt8]; folderModified: Date?; datesKnown: Bool }`; `static func of(entries: [DirectoryEntry]) -> FolderSummary` (фото — `Playlist.imageExtensions`, скрытые и пакеты — нет); `static func of(names: CoverNames, folderModified: Date?) -> FolderSummary` (шара: без дат и байт); `static func ofArchive(photos: Int, bytes: Int64, modified: Date) -> FolderSummary` (без гистограммы); `func inside(_ subfolders: [FolderSummary?]) -> (photos: Int, incomplete: Bool)`; `static let histogramBins = 12`.

- [ ] **Step 1: Тесты** `countsAndSpan` (3 фото 2019/2021/2023, 2 подпапки, txt — не фото → photos 3, folders 2, first/last, bytes сумма), `histogramShares` (12 корзин, сумма долей ≈ 255, пустые — 0), `oneDateAndNoPhotos` (все одной датой → одна корзина 255; без фото → гистограмма пустая, first nil), `namesOnlyHasNoDates` (`datesKnown == false`, bytes nil), `archiveHasNoHistogram`, `insideSumsKnown` (две известные + одна nil → сумма известных, `incomplete`).
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** `scripts/test.sh --filter FolderSummary`, затем `scripts/test.sh` — все.
- [ ] **Step 5:** commit `FolderSummary: counts, span, size and a twelve-bin date histogram from a listing`.

### Task 5: Loupe — таблица сводок в каталоге

**Files:**
- Modify: `Sources/LoupeCore/ThumbnailDatabase.swift` (`folder_summaries(volume, path, folder_mtime, photos, folders, bytes, first, last, histogram BLOB, dates_known, last_used, PRIMARY KEY(volume, path))` через `CREATE TABLE IF NOT EXISTS` при открытии каталога; `summary(at:)`, `putSummaries(_:)` пакетом, вытеснение по `last_used`), `Sources/LoupeCore/ThumbnailStore+Covers.swift` (обёртки на акторе)
- Test: `Tests/LoupeCoreTests/FolderSummaryStoreTests.swift`

**Interfaces:**
- Consumes: Task 4.
- Produces: `ThumbnailDatabase.summary(at: ThumbnailLocation) -> FolderSummary?`, `putSummaries(_: [(ThumbnailLocation, FolderSummary)])`; `ThumbnailStore.folderSummary(at:) async -> FolderSummary?`; `static let summaryCapacity` (замер: время выборки и размер `Catalog.db`, запись у константы).

- [ ] **Step 1: Тесты** `summaryRoundTrips`, `oldCatalogGainsTheTable` (каталог без таблицы открывается, строки `files` целы, `format_version` прежний), `evictsLeastUsed` (capacity 3, четыре записи → самая старая ушла), `batchWritesOnce`.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** `scripts/test.sh` — все.
- [ ] **Step 5:** commit `Catalog: folder summaries beside the folders, kept within a measured cap`.

### Task 6: Loupe — сводка в задаче обложки

**Files:**
- Modify: `Sources/LoupeCore/ThumbnailStore+Covers.swift` (`listCoverNames` → на локальном томе листинг с датами через `FolderSiblings.listEntries`, на шаре — имена; `folderCover` возвращает и сводку; свежая сводка + 4 эскиза — без листинга; ошибка zip → `.broken`, два тайм-аута шары подряд → `.offline`), `Sources/LoupeCore/CoverQueue.swift` при необходимости типа результата, `Sources/Loupe/FolderBrowserSource.swift` (сводка открытой папки из её полного листинга → `putSummaries`)
- Test: `Tests/LoupeCoreTests/ThumbnailCoversTests.swift`

**Interfaces:**
- Consumes: Tasks 4–5.
- Produces: `public struct FolderCard: Sendable { var images: [CGImage]; var summary: FolderSummary?; var problem: CardProblem? }`, `public enum CardProblem: Sendable { case broken, offline }`; `ThumbnailStore.folderCard(_ folder: URL, archive: Bool, in location: ThumbnailLocation?, network: Bool?, maxPixel: Int, lastViewed: String?, modified: Date?) async -> FolderCard?` (nil — «не сейчас», как у `folderCover`); `folderCover` остаётся обёрткой над ним.

- [ ] **Step 1: Тесты** `localListingCarriesDates` (сводка с first/last и bytes), `shareListsNamesOnly` (фейковый `coverVolumes { true }`: листер вызван с «только имена», `datesKnown == false`, обложка как раньше), `freshSummarySkipsListing` (сводка с тем же `folder_mtime` + 4 эскиза → листер не вызван), `changedFolderIsRecounted` (`modified` новее `folder_mtime` → листинг, новая сводка в каталоге), `brokenZip` (листер бросает → `problem == .broken`), `offlineAfterTwoTimeouts`, `openFolderWritesItsSummary` (полный листинг открытой папки → строка в `folder_summaries`).
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** `scripts/test.sh` — все; `ThumbsBench` — время до 12 карточек с обложкой и сводкой на локальной папке с подпапками JPEG на SSD, до и после; запись в `docs/bench/`.
- [ ] **Step 5:** commit `Covers bring the folder's facts: a listing with dates on local volumes, the summary kept in the catalog`.

### Task 7: Loupe — посещения

**Files:**
- Modify: `Sources/LoupeCore/StateDatabase.swift` (версия 3: `folder_positions` + `idx INTEGER`, `count INTEGER`, `visited REAL`), `Sources/LoupeCore/FolderPositions.swift` (`recordVisit(folder:index:count:at:)`, `visit(in:) -> FolderVisit?`, `movePaths` переносит поля), `Sources/Loupe/ViewerSession.swift` (`recordRecent` пишет и визит)
- Create: `Sources/LoupeCore/FolderVisit.swift`
- Test: `Tests/LoupeCoreTests/FolderVisitTests.swift`, `StateDatabaseTests.swift`

**Interfaces:**
- Produces: `public struct FolderVisit: Equatable, Sendable { index, count: Int; visited: Date }`; `func progress() -> Double` ((index+1)/count, ≤ 1); `var done: Bool`; `static func new(since visit: FolderVisit, summary: FolderSummary, dates: [Date]?) -> Int` (по датам — фото позже визита; без дат — `max(0, summary.photos − visit.count)`).

- [ ] **Step 1: Тесты** `version2FileMigrates` (файл версии 2 с позициями → версия 3, строки целы, новые поля nil), `visitRoundTrips`, `progressAndDone`, `newByDatesAndByCount`, `deletedFilesNeverNegative` (count 300, сейчас 250 → 0; index 299 из 250 → прогресс 1), `movedFolderKeepsVisit`.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** `scripts/test.sh` — все.
- [ ] **Step 5:** commit `Folder positions remember the visit: which photo, of how many, and when`.

### Task 8: Loupe — связка, ключ, настройки (сборка L13)

**Files:**
- Modify: `Sources/Loupe/FolderBrowserSource.swift` (`FolderCard` → `CardSummary`: сводка, фото в подпапках из сводок прямых подпапок, визит → `viewed`/`done`/`new`, ⧉/RTL из `FolderSettings.values(for:)` + `Config.applying`, проблема; `setSummary`; `cardStyle(for:)`/`setCardStyle` по образцу `sort(for:)`), `Sources/LoupeCore/Config.swift` (ключ `folder-cards`, по умолчанию `posters`; `homeFolderKeys = ["browser-sort", "folder-cards"]`), `Sources/Loupe/ViewerWindowController.swift` (не сообщать «ignored» для `homeFolderKeys`; меню «Вид»: as Posters ⌃⌘1 / as Cards ⌃⌘2 / as List ⌃⌘3 при показанном Home), `Sources/LoupeSettings/Pages/` (Settings › Home: «Folder cards», описание из спецификации)
- Test: `ConfigTests` (`folderCardsKey`, число ключей `PagesTests` +1), `FolderBrowserSourceTests` (`summaryMapsToCard`, `cardStyleInherits`, `noIgnoredWarningForHomeKeys`)

- [ ] **Step 1:** тесты выше. **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** `scripts/test.sh` — все.
- [ ] **Step 5:** `LOUPE_BUILD_LABEL=L13 scripts/make-app.sh` — сборка; ручные проверки из спецификации («Проверка»).
- [ ] **Step 6:** commit `Home: folder cards show their facts; folder-cards picks posters, cards or list per folder`.
