# Тулбар Home на `NSToolbar` — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Заменить самописный `HomeToolbar` браузера Home системным `NSToolbar` по образцу Photos: заголовок и подзаголовок окна, пилюля пути, текстовый фильтр, кольцо прогресса, `View ▾`, поиск.

**Architecture:** В HomeScreenKit новый `HomeToolbarController` владеет одним `NSToolbar` на `HomeBrowserView`, отдаёт те же `show(...)` и колбэки, что `HomeToolbar`, и ничего не знает об окне, кроме `public var nsToolbar`. Loupe (`ViewerWindowController`) присваивает его окну при показе Home и снимает при показе просмотра; заголовок и подзаголовок Home доходят до окна колбэком `onWindowText`. Сетка идёт под тулбар: верхний отступ берётся из `safeAreaInsets.top`, а без окна (тесты) — из константы.

**Tech Stack:** Swift 6.2 (язык v5), AppKit macOS 26 (`NSToolbar`, `NSToolbarItemGroup`, `NSMenuToolbarItem`, `NSSearchToolbarItem`), swift-testing, SwiftPM; два репозитория — HomeScreenKit (библиотека) и Loupe (приложение).

**Spec:** `docs/superpowers/specs/2026-10-24-home-toolbar-design.md` (Loupe). Прочитать целиком до начала; раскладка согласована в `home-native-ui-brainstorm-2026-10-22`, замеры спайка — в спеке.

## Global Constraints

- Ветки: `home-toolbar` от `main` в репозитории HomeScreenKit и в Loupe (отдельный worktree). Разработка Loupe против локального kit через `swift package edit HomeScreenKit`; релиз (тег kit `0.4.0`, `Package.swift` Loupe `from: "0.4.0"` и `Package.resolved`, push) — только по слову владельца.
- Платформа: `.macOS(.v26)`; в kit `swiftLanguageModes: [.v5]`. Новых зависимостей нет.
- Бюджеты (`CLAUDE.md`): открытие окна ≤ 300 мс, смена экрана ≤ 100 мс, одно нажатие ≤ 50 мс, на Intel Mac, время CPU главного потока (`CLOCK_THREAD_CPUTIME_ID`). Меню наполняются лениво: до первого открытия один пункт (`NSMenuDelegate.menuNeedsUpdate`). Таймеров, анимаций и работы в простое тулбар не добавляет.
- Приоритеты скрытия (`visibilityPriority`, целые): View −300, Posters/Cards/List −250, `− +` −200, фильтр −100, `‹ ›` 0, Start Page 10, путь 50, кольцо 80, поиск 100, Sidebar 1000.
- Раскладка слева направо: Sidebar │ Start Page │ `‹ ›` │ путь │ ⟵ │ `All | Folders | Photos` (текст) │ ⟵ │ кольцо │ `Posters | Cards | List` │ `− +` │ `View ▾` │ поиск. Подписи по-английски, как в приложении.
- `View ▾` содержит только то, что есть в браузере: Sort by… (поля источника, активное со стрелкой направления), Square / Aspect, Posters / Cards / List с галочкой. «Folders First» не добавлять. Кнопки «↑ Enclosing Folder» нет (⌘↑ остаётся).
- Метка вкладки — `window.tab.title` (нынешний `WindowTitle.text`); `window.title` / `window.subtitle` на Home — от контроллера.
- Тексты коммитов и документов — без личных путей, имён папок, томов, людей; **без атрибуции Claude/AI** (никаких `Co-Authored-By`, `Claude-Session`). Сообщения коммитов по-английски, в стиле `Home: …` / `Toolbar: …`. Тесты бенча описывают данные нейтрально («локальная папка из N файлов»).

## Review Focus

- Путь из 15+ предков и очень длинные имена: меню пути не обрезает предков, заголовок окна — последний элемент (Task 4).
- Имя папки с `∕` (U+2215, путь внутри zip), эмодзи и правосторонним текстом попадает в `window.title` без искажений (Task 3).
- Home скрыт на время просмотра и показан снова: тулбар присоединяется заново, выбор фильтра, сортировка и прогресс сохранены (Task 3, Task 7).
- Два окна или вкладки с Home: у каждого свой контроллер, общего состояния нет (Task 3).
- Кольцо прогресса ушло за `»` (узкое окно) или скрыто, а поповер просят из меню View › Thumbnails…: поповер всё равно открывается, не падает и не висит (Task 5).

---

### Task 1: Бенч «до» — `homescreen-demo bench-toolbar`

**Files:**
- Create: `Sources/homescreen-demo/ToolbarBench.swift`
- Modify: `Sources/homescreen-demo/main.swift` (режим `bench-toolbar`)
- Create: `docs/bench/2026-10-24-home-toolbar.md` (HomeScreenKit)

**Interfaces:**
- Produces: `enum ToolbarBench { @MainActor static func run(rounds: Int, settle: Int) -> Never }`; вызов `homescreen-demo bench-toolbar [--rounds N] [--settle MS]`. Печатает по строке на сценарий: `scenario  first  median  max` (мс CPU главного потока).

Сценарии (одни и те же до и после; «после» только добавляет присоединение тулбара к окну одной строкой `if let bar = browser.nsToolbar { window.toolbar = bar }`):
1. `open` — окно как у Loupe (`.titled, .resizable, .closable, .miniaturizable`) с `HomeView(source: DemoBrowserSource())` на `.folder`, от `makeKeyAndOrderFront` до конца первого `settle`.
2. `switch` — `rounds` раз скрыть и показать `HomeView` (как переход Home ↔ просмотр), первый круг отдельно.
3. `narrow` — окно шириной от 1300 до 420 pt шагом 20, время на один шаг.
4. `progress` — 100 вызовов `browser.toolbar.show(progress:)` с растущей долей.
5. `menus` — открытие сортировки и меню пути/сиблингов: на старой версии — `clickSort` и `showSiblings`.

- [ ] **Step 1: Написать `ToolbarBench.swift`** по образцу `LoupeBench/SettingsBench.swift`: окно на экране, `CLOCK_THREAD_CPUTIME_ID`, `RunLoop.run(until:)` на `settle` мс (по умолчанию 800) после каждого действия, `rounds` по умолчанию 12; печатать `first`, `median`, `max`.
- [ ] **Step 2: Подключить режим в `main.swift`** (`CommandLine.arguments.dropFirst().first == "bench-toolbar"`).
- [ ] **Step 3: Запустить на Intel Mac три раза** (`swift run -c release homescreen-demo bench-toolbar`), убедиться, что круги не растут и три запуска согласуются в пределах ~10 %.
- [ ] **Step 4: Записать** в `docs/bench/2026-10-24-home-toolbar.md`: машина, macOS, команда, таблица «до» (колонка «после» пустая). Данные описаны нейтрально.
- [ ] **Step 5: Commit** `Bench: homescreen-demo bench-toolbar measures the browser's toolbar`

---

### Task 2: Таблица item'ов и приоритетов

**Files:**
- Create: `Sources/HomeScreenKit/HomeToolbarItem.swift`
- Test: `Tests/HomeScreenKitTests/HomeToolbarItemTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum HomeToolbarItem: CaseIterable {
      case sidebar, home, history, path, filter, pageFilter, progress, cards, zoom, view, search
      var identifier: NSToolbarItem.Identifier { get }       // rawValue-подобные "home.sidebar" и т. д.
      var priority: Int { get }                              // значения из Global Constraints; pageFilter как filter
      static let browserOrder: [NSToolbarItem.Identifier]    // раскладка слева направо с .space / .flexibleSpace
  }
  ```

- [ ] **Step 1: Тест** `hideOrderFollowsTheSpec`: items, отсортированные по `priority` по возрастанию (без `pageFilter`), дают `view, cards, zoom, filter, history, home, path, progress, search, sidebar`; все приоритеты, кроме пары `filter`/`pageFilter`, различны. `browserOrder` содержит каждый идентификатор по разу (кроме `pageFilter`, который стоит сразу после `filter`) и ровно две `.flexibleSpace`.
- [ ] **Step 2: Запустить** `swift test --filter HomeToolbarItemTests`; ожидание — FAIL (типа нет).
- [ ] **Step 3: Реализовать** `HomeToolbarItem` в `HomeToolbarItem.swift` с таблицей из Global Constraints.
- [ ] **Step 4: Запустить** тот же фильтр; ожидание — PASS.
- [ ] **Step 5: Commit** `Toolbar: the item table and the hide order`

---

### Task 3: `HomeToolbarController` — тулбар, простые item'ы, API `show(...)`

**Files:**
- Create: `Sources/HomeScreenKit/HomeToolbarController.swift`
- Test: `Tests/HomeScreenKitTests/HomeToolbarControllerTests.swift`

**Interfaces:**
- Consumes: `HomeToolbarItem` (Task 2); `BrowserLocation`, `BrowserSort`, `BrowserKindFilter`, `CardStyle`, `GridStyle`, `HomeResize`, `ThumbsProgressState` (уже в kit).
- Produces:
  ```swift
  @MainActor final class HomeToolbarController: NSObject, NSToolbarDelegate, NSMenuDelegate {
      let nsToolbar: NSToolbar                       // identifier "home.browser", без кастомизации и автосохранения
      // колбэки, как у HomeToolbar (без onUp):
      var onSidebar, onHome, onBack, onForward: (() -> Void)?
      var onCrumb: ((BrowserLocation) -> Void)?
      var onSortKey: ((BrowserSort.Key) -> Void)?
      var onKind: ((BrowserKindFilter) -> Void)?;  var onPageFilter: ((Int) -> Void)?
      var onZoom: ((HomeResize) -> Void)?;  var onStyle: (() -> Void)?;  var onCardStyle: ((CardStyle) -> Void)?
      var onFilterText: ((String) -> Void)?;  var onFilterEnd: (() -> Void)?
      var onSiblings: ((Int) -> Void)?;  var onSiblingsClosed: (() -> Void)?
      var onWindowText: ((_ title: String, _ subtitle: String) -> Void)?
      // показ, те же сигнатуры, что у HomeToolbar:
      func show(path:canBack:canForward:canUp:), show(title:), show(subtitle:), show(sort:keys:), show(pageFilters:selected:),
           show(controls:), show(filter:visible:), show(style:), show(cardStyle:visible:), show(progress:), show(progressDetail:)
      func focusFilter()
      // чтение для тестов: windowTitle, subtitleText, kindTitles, kindSelection: Int?, isFilterVisible, isNavVisible,
      //   canBack, canForward, isCardSwitchVisible, cardSwitchSelection: Int?, filterText (get/set), itemLabels: [String]
  }
  ```
  `show(subtitle:)` и `show(path:…)` / `show(title:)` вызывают `onWindowText(windowTitle, subtitleText)`; `windowTitle` — последний элемент пути или заголовок источника.

Item'ы этой задачи: sidebar, home, history (`NSToolbarItemGroup`, momentary, ‹ ›), filter (`NSToolbarItemGroup(titles:)`, `.selectOne`, `All | Folders | Photos` из `BrowserKindFilter.allCases.map(\.title)`) и второй, `pageFilter` (скрыт, пока `pageFilters` пуст), cards (три значка, `.selectOne`; `isHidden` вне папки), zoom (momentary `− +`), search (`NSSearchToolbarItem`: `searchField.delegate = self`, текст → `onFilterText`, Esc/отмена → очистка и `onFilterEnd`). Приоритеты — из `HomeToolbarItem.priority` в `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`. У каждого item'а непустые `label` и `toolTip` с клавишей (как в `HomeToolbar`: «Sidebar (⌃⌘S)», «Start Page (⇧⌘H)», «Smaller (⌘−)», «Larger (⌘=)», «as Posters (⌥⌘1)»…).

- [ ] **Step 1: Тесты** (окно `NSWindow` вне экрана с `window.toolbar = controller.nsToolbar`):
  - `buildsTheBrowserLayout`: `nsToolbar.items.map(\.itemIdentifier)` совпадает с `HomeToolbarItem.browserOrder`.
  - `everyItemHasALabelAndATip`: для каждого item'а `label` и `toolTip` не пусты.
  - `kindSegmentsAreTheFilterTitles`: `kindTitles == ["All", "Folders", "Photos"]`; `show(filter: .photos, visible: true)` → `kindSelection == 2`; клик `clickKind(1)` вызывает `onKind(.folders)`.
  - `pageFiltersReplaceTheKindFilter`: `show(pageFilters: ["Scenes", "Images"], selected: 0)` → `kindTitles == ["Scenes", "Images"]`, `isFilterVisible`; пустой список возвращает `All | Folders | Photos`; `clickKind(1)` вызывает `onPageFilter(1)`, а не `onKind`.
  - `cardSwitchIsOnlyForFolders`: `show(cardStyle: .list, visible: false)` → `!isCardSwitchVisible`; `visible: true` → `isCardSwitchVisible`, `cardSwitchSelection == 2`.
  - `controlsOffOnAPage`: `show(controls: false)` скрывает zoom, search, cards; `true` возвращает (cards — по `show(cardStyle:visible:)`).
  - `windowTextFollowsThePath`: `show(path: [("Photos", a), ("Trips ∕ 2025", b)], …)` и `show(subtitle: "412 photos")` дают `onWindowText("Trips ∕ 2025", "412 photos")` без искажения U+2215; `show(title: "Recent")` — `("Recent", …)`.
  - `stateSurvivesDetach`: `window.toolbar = nil`, затем `window.toolbar = nsToolbar`: выбор фильтра, `cardSwitchSelection`, `filterText` те же.
  - `twoControllersShareNothing`: два контроллера в двух окнах; `show(filter: .photos, …)` в первом не меняет второй.
  - `searchTextAndEscape`: ввод в поле даёт `onFilterText`; Esc очищает поле, вызывает `onFilterText("")` и `onFilterEnd`.
- [ ] **Step 2: Запустить** `swift test --filter HomeToolbarControllerTests`; ожидание — FAIL (типа нет).
- [ ] **Step 3: Реализовать** `HomeToolbarController` (item'ы и `show(...)`); `focusFilter()` ставит фокус в поле поиска (`NSSearchToolbarItem.beginSearchInteraction()`).
- [ ] **Step 4: Запустить** тот же фильтр; ожидание — PASS. Если для окна вне экрана `nsToolbar.items` пуст, держать окно в `orderFront` на экране за границей (`setFrameOrigin` вне видимой области) — результат описать в комментарии теста.
- [ ] **Step 5: Commit** `Toolbar: HomeToolbarController with the plain items and the show(…) API`

---

### Task 4: Меню — пилюля пути и `View ▾`

**Files:**
- Modify: `Sources/HomeScreenKit/HomeToolbarController.swift`
- Test: `Tests/HomeScreenKitTests/HomeToolbarMenusTests.swift`

**Interfaces:**
- Consumes: `HomeToolbarController` (Task 3), `BrowserSort`, `CardStyle`, `GridStyle`.
- Produces: в контроллере — item'ы `path` и `view` (`NSMenuToolbarItem`, `showsIndicator = true`); читаемое для тестов: `pathMenuTitles: [String]`, `pathMenuChecked: [Bool]`, `viewMenuTitles: [String]`, `viewMenuChecked: [Bool]`, `siblingTitles: [String]`, `siblingChecked: [Bool]`; управление: `openPathMenu()`, `openViewMenu()` (вызывают `menuNeedsUpdate` как открытие), `clickPathItem(_ i: Int)`, `clickViewItem(_ i: Int)`, `showSiblings(_ entries: [(title: String, location: BrowserLocation, current: Bool)]?, at i: Int)`, `updateSiblings(_:)`, `chooseSibling(_ i: Int)`, `closeSiblings()`.

Правила: до первого открытия в меню один пункт (лениво); путь — предки текущей папки от неё вверх, текущая с галочкой, `Places` последним; клик по пункту → `onCrumb`; подменю соседей у каждого пункта, при открытии вызывает `onSiblings(i)` и показывает «Loading…» до `updateSiblings`; закрытие → `onSiblingsClosed`. `View ▾`: Sort by <поле источника> (активное со стрелкой ↑/↓ в названии, как `showSort()`), разделитель, Square / Aspect (клик → `onStyle`), разделитель, Posters / Cards / List с галочкой (клик → `onCardStyle`; только когда видим переключатель карточек); без полей сортировки и `controls == false` item `view` скрыт.

- [ ] **Step 1: Тесты:**
  - `menusAreFilledOnFirstOpen`: сразу после `show(path:…)` в `pathMenu` и `viewMenu` по одному пункту; после `openPathMenu()` — предки; после `openViewMenu()` — пункты View.
  - `pathMenuListsAncestorsNearestFirst`: путь `Places › Home › Pictures › Trips` даёт `pathMenuTitles == ["Trips", "Pictures", "Home", "Places"]`, `pathMenuChecked == [true, false, false, false]`; `clickPathItem(2)` вызывает `onCrumb(location Home)`.
  - `longPathKeepsEveryAncestor`: путь из 15 предков даёт 15 пунктов.
  - `siblingsLoadLazily`: `openPathMenu()` + открытие подменю пункта 1 вызывает `onSiblings(1)`; `showSiblings(nil, at: 1)` → `siblingTitles == ["Loading…"]`; `updateSiblings([...])` заменяет, текущая с галочкой; `chooseSibling(0)` вызывает `onCrumb`; `closeSiblings()` — `onSiblingsClosed`.
  - `viewMenuShowsSortWithDirection`: `show(sort: BrowserSort(key: .date, ascending: false), keys: [.name, .date, .size])` → пункты `Name`, `Date ↓`, `Size`; `clickViewItem` на `Size` вызывает `onSortKey(.size)`.
  - `viewMenuHasStyleAndCards`: `Square / Aspect` вызывает `onStyle`; при `show(cardStyle: .cards, visible: true)` три пункта карточек, отмечен второй; `clickViewItem` на `List` вызывает `onCardStyle(.list)`; при `visible: false` пунктов карточек нет.
  - `viewMenuIsHiddenWithoutAnything`: `show(sort: …, keys: [])` и `show(controls: false)` скрывают item `view`.
- [ ] **Step 2: Запустить** `swift test --filter HomeToolbarMenusTests`; ожидание — FAIL.
- [ ] **Step 3: Реализовать** меню и подменю; `NSMenuDelegate` у каждого меню, `menuNeedsUpdate` наполняет, `menuDidClose` сообщает `onSiblingsClosed` для подменю соседей.
- [ ] **Step 4: Запустить**; ожидание — PASS.
- [ ] **Step 5: Commit** `Toolbar: the path pill and the View menu, filled when first opened`

---

### Task 5: Кольцо прогресса

**Files:**
- Modify: `Sources/HomeScreenKit/HomeToolbarController.swift`, `Sources/HomeScreenKit/ThumbsProgressPill.swift` (только если у пилюли есть собственная подложка: флаг `drawsBackdrop`, по умолчанию `true`)
- Test: `Tests/HomeScreenKitTests/HomeToolbarProgressTests.swift`

**Interfaces:**
- Consumes: `ThumbsProgressPill` (`isCompact`, `show(_:)`, `showDetail(_:)`, `openPopover(from:)`, `closePopover()`, `onPause`, `onPrepare`, `onStopSubtree`), `ThumbsProgressState`.
- Produces: item `progress` — `NSToolbarItem` с `view` = `ThumbsProgressPill` в режиме `isCompact = true`, фиксированные констрейнты 28 × 28 pt, `toolTip` = текст состояния; в контроллере `var progress: ThumbsProgressPill` (для проводки `onPause` / `onPrepare` / `onStopSubtree`, как у `HomeToolbar.progress`), `var isProgressVisible: Bool`, `var progressState: ThumbsProgressState?`, `@discardableResult func showProgressPopover() -> Bool`.

Правила: состояния нет → item `isHidden`; есть → виден; текст — только в подсказке; `showProgressPopover()` возвращает `false` вне окна, иначе открывает поповер от кольца, если оно в окне и видно, иначе от ближайшего видимого item'а, иначе от верха `window.contentView`.

- [ ] **Step 1: Тесты:**
  - `ringShowsOnlyWithAState`: `show(progress: nil)` → `!isProgressVisible`; `show(progress: state)` → `isProgressVisible`, `progress.isCompact`.
  - `ringTextIsInTheTip`: `nsToolbar.items` item `progress` имеет `toolTip == state.text`.
  - `popoverOpensFromTheRing`: в окне `showProgressPopover()` → `true`, `progress.isPopoverOnPill`; повторный вызов закрывает/переоткрывает без дублирования (как `togglePopover`).
  - `popoverOpensWhenTheRingIsHidden`: `show(progress: nil)` затем `showProgressPopover()` → `true` (поповер от запасной опоры), `false` без окна.
  - `ringDoesNotDrawItsOwnGlass`: `progress.drawsBackdrop == false` в тулбаре (если у пилюли есть подложка).
- [ ] **Step 2: Запустить** `swift test --filter HomeToolbarProgressTests`; ожидание — FAIL.
- [ ] **Step 3: Реализовать** item и `showProgressPopover()`; убрать из пилюли ступени и расчёт `fullSize` / `compactSize` только в Task 6, когда уйдёт `HomeToolbar`.
- [ ] **Step 4: Запустить**; ожидание — PASS. Посмотреть кольцо в окне `homescreen-demo` глазами (скриншот в `docs/bench`-папку не класть): кольцо одно, без второй подложки, не обрезано.
- [ ] **Step 5: Commit** `Toolbar: the thumbnails' ring as a toolbar item`

---

### Task 6: `HomeBrowserView` на контроллере, удаление `HomeToolbar`

**Files:**
- Modify: `Sources/HomeScreenKit/HomeBrowserView.swift`, `HomeBrowserView+CardStyle.swift`, `ThumbsProgressPill.swift` (убрать ступени `fullSize` / `compactSize`, если больше не нужны), `BrowserLoading.swift` (`LoadingLine` остаётся)
- Delete: `Sources/HomeScreenKit/HomeToolbar.swift`, `Tests/HomeScreenKitTests/HomeToolbarTests.swift`
- Modify (тесты): `HomeBrowserViewTests`, `HomeBrowserSourcesTests`, `HomeBrowserFilterTests`, `HomeBrowserKeysTests`, `HomeBrowserPolishTests`, `HomeBrowserReturnTests`, `HomeBrowserReviewTests`, `HomeViewTests`, `ProgressSnapshots`

**Interfaces:**
- Consumes: `HomeToolbarController` (Tasks 3–5).
- Produces: `let toolbar = HomeToolbarController()` в `HomeBrowserView` (то же имя); `public var nsToolbar: NSToolbar { toolbar.nsToolbar }`; `public var onWindowText: ((String, String) -> Void)?` (проброс `toolbar.onWindowText`); `static let defaultTopInset: CGFloat = 52`; `var topInset: CGFloat` — `safeAreaInsets.top`, когда `window?.toolbar != nil`, иначе `defaultTopInset`; `override func safeAreaInsetsDidChange()` вызывает `tile()`.

Замены: `HomeToolbar.height` → `topInset` (метрики сетки, прокрутка к элементу, заголовок списка, плита списка); `toolbar` больше не subview и не имеет констрейнтов; `skeleton.topAnchor` и `LoadingLine` привязаны к `topInset` (нижняя кромка линии на нём); `toolbar.onUp` не присваивается; `HomeBrowserView.showProgressPopover()` вызывает контроллер. Тесты, читавшие геометрию тулбара (`kindFrame`, `navFrame`, попадание кликов в область тулбара, `pillFrame`), заменяются проверками состояния через контроллер или удаляются вместе с тем, что они проверяли (перехват кликов, `hitTest`, `narrowToolbarHidesThePillFirst`, снимки `ProgressSnapshots` пилюли в трёх ступенях). Вместо `narrowToolbarHidesThePillFirst` — тест таблицы приоритетов из Task 2 (он уже покрывает порядок скрытия).

- [ ] **Step 1: Тест** (новый, в `HomeBrowserViewTests`): `gridStartsBelowTheToolbarInset` — без окна `scroll`-метрики (`metrics.top`) равны `defaultTopInset`; `topInsetFollowsTheSafeArea` — в окне с `fullSizeContentView` и присоединённым `nsToolbar` `topInset == safeAreaInsets.top` и `> 0`; после `window.toolbar = nil` — снова `defaultTopInset`.
- [ ] **Step 2: Запустить** новые тесты; ожидание — FAIL.
- [ ] **Step 3: Перевести `HomeBrowserView`** на контроллер, удалить `HomeToolbar.swift`; поправить остальные тесты и снимки; не оставлять мёртвого кода (`pathRoomFor*`, `ProgressStep`, `GlassGroup`-проводку тулбара, если больше нигде не используется — проверить `grep`).
- [ ] **Step 4: Запустить** весь пакет `swift test` в HomeScreenKit; ожидание — всё зелёное (CI-красные `HomeBrowserAnchorTests` вне этого плана: если они падают из-за гонки, сообщить, не чинить здесь).
- [ ] **Step 5: Запустить** `homescreen-demo` с `window.toolbar = browser.nsToolbar` (правка `Demo.showHomeView`), `fullSizeContentView`, `toolbarStyle = .unified`: посмотреть Home в светлой и тёмной теме, окна 1200 / 900 / 700 / 560 pt (снимки `screencapture -l`); сетка идёт под тулбар, пилюли плавают, текст в заголовке.
- [ ] **Step 6: Commit** `Home: the browser's toolbar is an NSToolbar; HomeToolbar goes`

---

### Task 7: Окно Loupe

**Files:**
- Modify: `Sources/Loupe/ViewerWindowController.swift` (создание окна ≈ строка 145, `showHome` ≈ 766, скрытие Home ≈ 804, `updateTitle` ≈ 714, раскладка контейнера)
- Test: проверка вручную по скриншотам (в `Loupe` нет тестов окна); числовое — в Task 9

**Interfaces:**
- Consumes: `HomeBrowserView.nsToolbar`, `onWindowText` (Task 6), `WindowTitle.text(home:file:companion:)`.
- Produces: окно с `.fullSizeContentView`, `toolbarStyle = .unified`; Home показан → `window.toolbar = homeView.browser.nsToolbar`, `window.title` / `subtitle` от `onWindowText`, `window.tab.title = WindowTitle.text(…)`; Home скрыт → `window.toolbar = nil`, `window.subtitle = ""`, `window.title` из `WindowTitle.text`.

Критично: просмотр не должен сдвинуться. Контейнер просмотра (`viewerView`, лента, статус-бар, плашка «Назад», Info) привязан к `window.contentLayoutGuide.topAnchor`, а не к верху окна, чтобы под заголовком окна без тулбара он стоял там же, где раньше; `HomeView` — на весь контент (сетка идёт под тулбар).

- [ ] **Step 1: Записать «до»**: `frame` `viewerView`, `statsBar`, `backButton`, `window.contentLayoutRect` на окне 1200 × 760 в окне и в полном экране (временная печать, не коммитить).
- [ ] **Step 2: Поменять окно** (`.fullSizeContentView`, `.unified`), проводку `showHome` / скрытия, заголовки (`onWindowText`, `tab.title`), привязку контейнера просмотра к `contentLayoutGuide`.
- [ ] **Step 3: Проверить числами**: те же `frame` `viewerView`, `statsBar`, `backButton` после изменения, в окне и в полном экране; `window.contentLayoutRect` Home ≠ просмотр ожидаемо.
- [ ] **Step 4: Проверить на сборке** (`scripts/make-app.sh --label LNN`, снимки окна): Home в светлой и тёмной теме, переход Home → фото → Home (фильтр, сортировка и прогресс на месте), вкладка (метка вкладки прежняя, под ней тулбар), полный экран (тулбар выезжает со строкой меню, подзаголовок виден), окно 560 pt (`»`, кольцо на месте), папка с `∕` в имени.
- [ ] **Step 5: Прогнать** `scripts/test.sh`; ожидание — зелёное.
- [ ] **Step 6: Commit** `Home: the window carries the browser's NSToolbar; the viewer stays where it was`

---

### Task 8: Подзаголовок с объёмом и свободным местом

**Files:**
- Create: `Sources/HomeScreenModel/VolumeSpace.swift` (HomeScreenKit) — формат строки и ключ кэша
- Modify: `Sources/HomeScreenKit/HomeBrowserView.swift` (`updateSubtitle`, `footerText.line`), `HomeSource` при необходимости (запрос свободного места источником)
- Test: `Tests/HomeScreenModelTests/VolumeSpaceTests.swift`

**Interfaces:**
- Produces: `public enum VolumeSpace { public static func line(free: Int64?) -> String? }` (`1.2 TB free`; `nil` без значения); `HomeSource.freeSpace(for location: BrowserLocation) async -> Int64?` со значением по умолчанию `nil` (расширение протокола), кэш на папку в `HomeBrowserView`, запрос вне главного потока (`.utility`), один запрос на заход в папку и по смене тома; подпись добавляется к сегодняшней строке через « · ».

- [ ] **Step 1: Тесты:** `formatsBinaryDecimalSizes` (`line(free: 1_200_000_000_000) == "1.2 TB free"`, `line(free: 512_000_000) == "512 MB free"`), `nilGivesNoLine`, `subtitleKeepsTheCurrentLine` (в `HomeBrowserViewTests`: без значения подзаголовок прежний; со значением — прежний + ` · 1.2 TB free`; сеть не опрашивается повторно при возврате в ту же папку).
- [ ] **Step 2: Запустить** `swift test --filter VolumeSpaceTests`; ожидание — FAIL.
- [ ] **Step 3: Реализовать**; в Loupe (`FolderBrowserSource`) вернуть `volumeAvailableCapacityForImportantUsage` тома папки (один запрос, `URLResourceValues`), для не-файловых источников — `nil`.
- [ ] **Step 4: Запустить** тесты kit и `scripts/test.sh` Loupe; ожидание — зелёное. Если задача не укладывается в этап, оставить её последней и отложить, спека это допускает.
- [ ] **Step 5: Commit** `Home: the subtitle also tells how much room the volume has`

---

### Task 9: Бенч «после», документ, релиз

**Files:**
- Modify: `docs/bench/2026-10-24-home-toolbar.md` (HomeScreenKit), `Sources/homescreen-demo/ToolbarBench.swift` (строка присоединения тулбара), `README.md` / `ROADMAP.md` Loupe (этап «тулбар Home» закрыт)

- [ ] **Step 1: Дописать в бенч** присоединение `browser.nsToolbar` к окну; запустить `bench-toolbar` три раза на Intel Mac; убедиться: `open` ≤ 300 мс, `switch` ≤ 100 мс (первый круг тоже; если холодный выше — записать причину и вернуться к решениям спеки), `progress` ≤ 50 мс на вызов, круги не растут.
- [ ] **Step 2: Заполнить** колонку «после» и «что сколько стоило»; добавить таблицу ширин (где что прячется, на реальном окне; сравнить с таблицей спайка: все ≥ 1120, `View`+карточки ≤ 1100, `− +` ≤ 980, фильтр ≤ 900, `‹ ›` ≤ 640, Start Page ≤ 560, путь ≤ 480, кольцо ≤ 420) и скриншоты вне репозитория.
- [ ] **Step 3: Проверить дифф** обоих репозиториев на личное: домашний путь, имена папок и томов из этой сессии, адреса почты, имена людей (grep по изменённым файлам; список слов взять у владельца); ничего не найдено.
- [ ] **Step 4: Commit** `Bench: the browser's toolbar before and after`; `ROADMAP`: `Roadmap: the Home toolbar on NSToolbar is done; the viewer's is next`.
- [ ] **Step 5: Остановиться и спросить владельца** про релиз: тег kit `0.4.0`, `Package.swift` Loupe, push. До слова ничего не пушить.

---

## Self-review (выполнено при написании)

- **Покрытие спеки:** раскладка и приоритеты — Tasks 2–4; текст/заголовок/вкладки — Tasks 3, 7; крошки и меню — Task 4; кольцо — Task 5; сетка под тулбаром и удаление `HomeToolbar` — Task 6; окно, полный экран, вкладки — Task 7; свободное место — Task 8; бенч, таблица ширин, документы — Tasks 1, 9. Не входят (по спеке): тулбар просмотра, сайдбар на системных компонентах.
- **Согласованность имён:** `HomeToolbarController`, `HomeToolbarItem`, `nsToolbar`, `onWindowText`, `topInset` / `defaultTopInset`, `showProgressPopover()` одинаковы во всех задачах.
- **Пропорция:** план короче кода, который он описывает; тела функций в плане только там, где их определяют сигнатуры и тесты.
