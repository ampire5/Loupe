# Folder slots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Общие слоты HomeScreenKit, FrameScrub на общем контейнере и вертикальная плёнка соседних папок в Loupe по варианту A.

**Architecture:** Перенести чистые правила в `SlotModel`, AppKit-представления и общий контроллер — в `Slots`, существующую капсулу — в `SlotChrome` внутри HomeScreenKit. Приложения сохраняют собственные конфигурационные кодеки и фабрики вкладок. Loupe разделяет модель выбора папки, асинхронный источник данных и контроллер плёнки; полный переход выполняется после доводки.

**Tech Stack:** Swift 6.2, AppKit, Core Animation, Swift Testing, HomeScreenKit Filmstrip/FilmstripModel, существующие кэши Loupe.

**Spec:** `docs/superpowers/specs/2026-10-29-folder-slots-design.md` (утверждена пользователем 2026-10-29, «go»).

## Execution status (2026-10-29)

Implemented inline at the user's request, without review agents. Shared kit and FrameScrub migration built and tested; Loupe folders and File View boundary implemented. Final suites: HomeScreenKit 659, FrameScrub 1753, Loupe standard pass 2209, all green. Real-window benchmark checks stale replies, File View cancellation, deep branch traversal and bottom-slot fit. See `docs/bench/2026-10-29-folder-slots.md` for measurements and unperformed acceptance checks.

Intel, live Stash/SMB, manual fullscreen/VoiceOver acceptance and kit release/CI remain open; implementation is local, not release-ready. Isolated local clones were used because the harness blocked writes to the native worktree and sibling Git metadata. Completed changes are retained on `codex/folder-slots` in all three repositories.

## Global Constraints

- Рабочие корни: Loupe, соседние FrameScrub и HomeScreenKit. Для реализации создать изолированные worktree на общей ветке `codex/folder-slots`, от актуальных локальных состояний с завершёнными strip-slots; не сбрасывать пользовательские изменения.
- В Loupe и FrameScrub уже изменены Package.resolved и есть пользовательский AGENTS.md. Не включать эти изменения в коммиты задачи и не восстанавливать их через checkout.
- Main никогда не выполняет синхронный I/O; фон ограничен долей физических ядер, уступает открытию фото; число запросов/буферов ограничено.
- В покое нет повторяющейся работы; скрытое окно останавливает анимации и подготовку.
- Бюджеты main-thread CPU: вкладка/экран ≤100 мс, управление ≤50 мс, окно ≤300 мс. Реальный bench, первый визит и возврат отдельно, несколько раундов, Intel Mac; недоступный Intel отмечать непроверенным.
- Zen guide: прочитан `~/.claude/guides/hideable-sidebars-and-glass.md`; проверить наличие пользовательского `~/.Codex/guides/...` перед реализацией. Светлый текст на тёмной вуали, reveal без задержки, hide 150 мс после ухода с оговорками текущего FrameScrub, входная пружина ~0.26 с, Reduce Motion.
- Сохранить уточнения capsule и конфигурационную совместимость FrameScrub; перенос не переопределяет поведение установленного приложения.
- Папки справа по умолчанию: overlay/glass, hidden; рекурсивный All Photos и плагинный мост вне этой реализации.
- Закрытие kits first по `docs/kits.md`; не коммитить зависимости из edit mode, не устанавливать сборку поверх пользовательского приложения автоматически.

## Review Focus

1. Старый конфиг с `plugin:Name + playlist` и именем, содержащим ` + `: прочитать и записать без изменения состава вкладок (Task 3).
2. Меню открыто во вкладке, слот скрывается или вкладка удаляется: фокус возвращается в просмотрщик, нет невидимого first responder (Task 2).
3. Медленная шара возвращает ответ A после выбора B: ни изображение, ни нижняя лента не откатываются к A (Tasks 4, 6).
4. Родитель содержит только пустые папки или цикл ссылок: поиск заканчивается либо отменяется, открытое фото сохраняется (Task 5).
5. Окно свернули во время инерции или превью: незавершённый выбор отменён, нет скрытых display link и фоновых очередей (Tasks 6, 7).

## File map and interfaces

Все пути ниже относительно указанного репозитория. Существующие SlotLayout/SlotTiming переносить с историей там, где возможно; не переписывать их алгоритмы заодно с переносом.

HomeScreenKit:
- `Sources/SlotModel/{SlotGeometry,SlotTiming,SlotTabState}.swift`: общие настройки геометрии/видимости, чистые часы и порядок вкладок.
- `Sources/SlotChrome/SlotCapsuleView.swift`: перенесённая капсула без зависимости от FrameScrubCore.
- `Sources/Slots/{SlotView,SlotsController,SlotTabDescriptor}.swift`: контейнер, события, ленивая фабрика вкладок.
- `Tests/{SlotModelTests,SlotChromeTests,SlotsTests}/`: перенесённые проверки и lifecycle NSView.

FrameScrub:
- `Sources/FrameScrubCore/{SlotSettings,SlotLayout,SlotTiming}.swift`: сохранить app-кодек, удалить дубли общих правил после миграции.
- `Sources/FrameScrub/{SlotsController,SlotView}.swift`: заменить app-контроллер на адаптер, удалить перенесённое представление.
- `Sources/FrameScrub/ViewerWindowController.swift`: интеграция (проверить актуальное имя контроллера окна до изменения через rg).
- `Package.swift`, `Tests/FrameScrubCoreTests/Slot*Tests.swift`, `Sources/FrameScrubBench/SlotsBench.swift`.

Loupe:
- `Sources/LoupeCore/{FolderStripState,FolderStripSource,FolderStripListing}.swift`: выбор, данные и ленивый обход.
- `Sources/Loupe/{FolderStripController,FolderStripCardView,ViewerSlotsController,ViewerSession+FolderStrip}.swift`: UI и адаптеры.
- `Sources/Loupe/{ViewerWindowController,ViewerSession,Settings}.swift`, `Sources/LoupeCore/Config.swift`: подключение и настройки.
- `Tests/LoupeCoreTests/FolderStrip*Tests.swift`, `Sources/LoupeBench/FolderSlotsBench.swift`, `docs/bench/2026-10-29-folder-slots.md`.

Общие новые типы:
```swift
public struct SlotTabID: Hashable, Sendable, Codable { public let rawValue: String }
public struct SlotConfiguration: Equatable, Sendable {
    public var tabs: [SlotTabID] // shown first only in persisted snapshots
    public var mode: SlotMode; public var backdrop: SlotBackdrop
    public var autoHide: SlotAutoHide; public var size: Int
    public var shown: Bool; public var reveal: SlotReveal
}
@MainActor public struct SlotTabDescriptor {
    public let id: SlotTabID
    public let title: String
    public let makeView: () -> NSView
    public let makeTools: () -> NSView?
    public let visibilityChanged: (Bool) -> Void
    public let dropped: () -> Void
}
```
Предоставить явные public init для этих типов. Конфигурационный текст не входит в SlotModel. Передача вкладки в другой слот сохраняет уже созданный view; одинаковая страница в двух слотах имеет два экземпляра, как сейчас во FrameScrub. Идентификатор экземпляра — пара edge/tabID.

## Task 1: Shared slot rules

**Files:** HomeScreenKit `Package.swift`, `Sources/SlotModel/*.swift`, `Tests/SlotModelTests/*.swift`; источники переноса — FrameScrubCore SlotLayout/SlotTiming.

**Consumes:** актуальные чистые SlotLayout, EdgeReveal, AutoHideClock, CapsuleClock FrameScrub.
**Produces:** SlotModel с указанными выше типами; `SlotLayout.compute(_:)` и часы сохраняют существующие публичные сигнатуры. App-специфические имена `video`/`seekBarBottomInset` можно сохранить до следующего отдельного API-рефакторинга.

- [ ] Перенести тесты layout/timing, добавить `SlotTabStateTests`: switch A→B→A сохраняет порядок `[A,B]`, snapshot начинается A; повторный ID удаляется; закрытие активной вкладки выбирает следующую, последней — предыдущую.
- [ ] Запустить `swift test --filter SlotModelTests` в HomeScreenKit; зафиксировать ожидаемый FAIL отсутствующего модуля/API.
- [ ] Перенести правила и добавить `SlotTabState` с `select(_ id: SlotTabID)`, `remove(_ id: SlotTabID)`, `snapshot() -> [SlotTabID]`; перенос настроек не включает app-кодек.
- [ ] Запустить тот же filter: PASS. Проверить прежнюю демоцию newest-first при области меньше 480×270 и размеры крайних случаев из исходных тестов.
- [ ] Закоммитить только файлы Task 1 с сообщением о переносе общих правил без изменения поведения.

## Task 2: Shared AppKit container and capsule

**Files:** HomeScreenKit `Sources/SlotChrome/SlotCapsuleView.swift`, `Sources/Slots/*.swift`, `Tests/SlotChromeTests/*.swift`, `Tests/SlotsTests/*.swift`, `Package.swift`.

**Consumes:** SlotModel Task 1, HomeChrome, перенесённая капсула.
**Produces:** `@MainActor public final class SlotsController` с `init(container: NSView, above: NSView)`, `configure(_ configuration: SlotConfiguration, edge: SlotEdge)`, `register(_ descriptor: SlotTabDescriptor)`, `show(_ edge: SlotEdge)`, `hide(_ edge: SlotEdge)`, `cancelInteraction()`, свойствами `topInset: CGFloat`, `onPersist: ((SlotEdge, SlotConfiguration) -> Void)?`, `onFocusContent: (() -> Void)?`, `onLayout: ((CGRect, CGRect) -> Void)?`. Добавить `refreshLayout()` для resize/layout контейнера. События вкладок идут через descriptor.

- [ ] Написать lifecycle-тесты с настоящим NSWindow: `returnDoesNotRebuild` (фабрика A вызвана один раз после A→B→A), `hiddenCannotReceiveInput`, `closeFocusedTabReturnsFocus`, `menuSuppressesHide`, `dropReleasesView`. Тайминги проверять через управляемые часы, без sleep.
- [ ] Запустить `swift test --filter SlotsTests` и убедиться в FAIL нового API.
- [ ] Перенести SlotView, язычок, capsule и общую часть SlotsController. Фабрика вызывается при первом показе; скрытие сохраняет view, удаление вызывает dropped. Любое app-решение playlist/plugin вывести в callbacks. Перенести tests capsule, добавить публичные продукты и зависимости.
- [ ] Запустить `swift test --filter SlotsTests --filter SlotChromeTests --filter SlotModelTests`: PASS; открыть тестовое окно с яркой подложкой, проверить контраст, pinned/overlay, overshoot и Reduce Motion.
- [ ] Закоммитить Task 2 в ките.

## Task 3: FrameScrub adapter and compatibility

**Files:** FrameScrub файлы из file map; реальный контроллер окна определить поиском `SlotsController(`. HomeScreenKit API менять только при выявленном общем lifecycle-пробеле.

**Consumes:** Slots/SlotModel/SlotChrome Tasks 1–2.
**Produces:** FrameScrub на общем контейнере с прежними `slot-left/right/bottom`, плагинами, фильтром и strip/list; общий код не импортирует FrameScrubCore.

- [ ] Добавить в SlotSettingsTests fixtures для single-tab, `playlist + plugin:Notes`, `plugin:A %2B B`, `%25`, пустого слота и transient URL-вкладки. Проверить read→write с прежними байтами одиночной записи; transient-вкладка не сохраняется.
- [ ] Запустить `scripts/test.sh --filter SlotSettingsTests`: новые adapter assertions FAIL до реализации.
- [ ] В app-кодеке переводить SlotContent ↔ SlotTabID (`playlist`, `plugin:<name>`), сохранив прежний escaping. Существующий SlotsController оставить тонким адаптером для PluginPanel, PlaylistPanelView и callbacks окна. Удалить локальные таргет SlotChrome и общие дубли после перевода импортов.
- [ ] Запустить `scripts/test.sh`, собрать FrameScrub и прогнать текущий SlotsBench. Проверить: фильтр при переносе вкладки, локальное открытие из плагина, скрытые plugin actions, transient page, origin permissions, показ/удаление вкладки под меню. Документировать регрессии/результаты.
- [ ] Закоммитить миграцию без edit-mode Package.resolved. Kit tag/release выполняется только на этапе закрытия ветки.

## Task 4: Folder selection state

**Files:** Loupe `Sources/LoupeCore/FolderStripState.swift`, `Tests/LoupeCoreTests/FolderStripStateTests.swift`.

**Consumes:** URL/BrowserEntry идентификаторы и внешние события жеста.
**Produces:** `FolderStripID: Hashable, Sendable` с cases `folder(URL)`, `gallery(String)`; `FolderStripState` с `opened: FolderStripID?`, `browsed: FolderStripID?`, `generation: UInt64`, методами `browse(_:) -> UInt64`, `settle() -> FolderStripID?`, `cancel()`, `acceptOpened(_:generation:) -> Bool`, `synchronize(_:)`.

- [ ] Добавить тесты `browseDoesNotCommit`, `settleOpensOnlyLatest`, `cancelRestoresOpened`, `externalOpenDoesNotRequestOpen`, `lateAAfterBIsIgnored`, `clickDuringInertiaCancelsOldSettle`. Для A generation 1 и B generation 2 assert `acceptOpened(A,generation:1) == false`, затем B true.
- [ ] Запустить `scripts/test.sh --filter FolderStripStateTests`: FAIL отсутствующего API.
- [ ] Реализовать чистую машину состояний. После cancel/synchronize инвалидировать generation; settle не создаёт повторный запрос для уже открытой папки. Явное нажатие использует browse+settle после отмены инерции.
- [ ] Повторить filter: PASS. Закоммитить Task 4.

## Task 5: Bounded folder source

**Files:** Loupe `Sources/LoupeCore/{FolderStripSource,FolderStripListing}.swift`, `Sources/LoupeCore/FolderSiblings.swift` (переиспользование существующего bounded listing), `Sources/Loupe/StashGalleryNavigator.swift`, `Tests/LoupeCoreTests/FolderStripSourceTests.swift`.

**Consumes:** FolderSiblings, BrowserSort родителя, существующие FolderNavigator/ListFolderNavigator и кэши Home.
**Produces:** `FolderStripEntry: Equatable, Sendable` с `id: FolderStripID`, `parent: FolderStripID?`, `title: String`, `depth: Int`, `photoCount: Int?`; `FolderStripSource: Sendable` с `rows(around: FolderStripID) async throws -> [FolderStripEntry]`, `children(of: FolderStripID) async throws -> [FolderStripEntry]`, `target(for: FolderStripID) async throws -> FolderTarget?`. Disk-реализация `actor FolderStripListing`; Stash adapter сохраняет исходные IDs/порядок и использует существующую пагинацию.

- [ ] Инъецировать async lister в тестах: siblings по BrowserSort, пустые строки сохранены, package/hidden исключены, zip следует archives setting, Stash не сортируется локально, children запрашиваются только для открытой ветки. `photoCount == nil` при неизвестной статистике.
- [ ] Добавить `emptyTreeTerminates`, `symlinkCycleTerminates`, `newChoiceCancelsDeepSearch`, `unreachableKeepsOtherRows`, `pagedGalleryRetainsIdentity`. Обход empty target — depth-first по сортировке Home, канонический visited set; cancellation проверяется между запросами.
- [ ] Запустить `scripts/test.sh --filter FolderStripSourceTests`: FAIL.
- [ ] Реализовать source поверх уже существующего off-main ограниченного листинга, без отдельной unbounded task group. Разделить неполные метаданные строк и получение FolderTarget. Размер кэша ограничить существующей политикой listings; отдельный лимит вводить только после bench, с измерением рядом с константой.
- [ ] Повторить tests: PASS; добавить fixtures timedOut и отмены до/после ответа. Закоммитить Task 5.

## Task 6: Loupe slots and folder filmstrip

**Files:** Loupe `Sources/Loupe/{ViewerSlotsController,FolderStripController,FolderStripCardView,ViewerSession+FolderStrip}.swift`, `ViewerWindowController.swift`, `ViewerSession.swift`, `Settings.swift`, `Sources/LoupeCore/Config.swift`, `Package.swift`; HomeScreenKit FilmstripRowsView при необходимости общего свойства отступа.

**Consumes:** Slots API Task 2, state Task 4, source Task 5, FilmstripRowsView/FilmstripRows, существующие thumbnail/cover/summary/positions stores.
**Produces:** `@MainActor FolderStripController` с `view: NSView`, `synchronize(opened: FolderStripID)`, `setVisible(_ visible: Bool)`, `cancelInteraction()`; `onPreview: ((FolderStripID?, CGImage?) -> Void)?`, `onOpen: ((FolderStripID, UInt64) -> Void)?`. `ViewerSlotsController` регистрирует вкладку `folders` и переводит layout в область фото и полосы нижней ленты.

- [ ] Добавить проверки Config для roundtrip трёх slot settings и default right=`folders, overlay, glass, mouse-leaves, 400, hidden, at-once`; left/bottom empty. Выбранный размер 400 pt — исходный default FrameScrub. Добавить тест расчёта области слотов над нижней лентой: rects не пересекаются, overlay не изменяет viewport фото.
- [ ] Запустить соответствующие filters: FAIL; реализовать codec через SlotConfiguration, ключи `slot-left/right/bottom`, настройки и меню ⌃⌘←/→/↓ без дубликатов shortcut.
- [ ] Подключить FilmstripRowsView: центральная карточка, целая обложка 3:2, до пяти эскизов, доступные facts/даты, дочерние строки с отступом. Если нужен общий indentation, добавить `indent: (Int) -> CGFloat` в rows view с default zero и тестом сохранения исходной геометрии FrameScrub. Не менять горизонтальную ленту.
- [ ] Связать жесты с FolderStripState: превью только из существующего bounded thumbnail/cover request; основной session.current и нижняя лента неизменны до settle/click/Return. Escape, hide, resign/window invisibility вызывают cancelInteraction, отменяют инерцию и запросы превью.
- [ ] Добавить в ViewerSession token-aware путь `openFolderStripTarget(_ target: FolderTarget, isWanted: @escaping @MainActor () -> Bool, completion: @escaping @MainActor (Bool) -> Void)`. Переиспользовать существующий transactional commit открытия папки; проверять isWanted непосредственно перед заменой сессии. Ошибка не меняет прежнюю сессию; внешний open вызывает synchronize без onOpen.
- [ ] Проверить в реальном окне с управляемым source: A медленный→B быстрый, late A не меняет ни фото, ни нижнюю ленту; Escape и скрытие во время инерции отменяют preview; click открывает ровно один раз. Проверить fullscreen, resize, pinned демоцию и вкладки.
- [ ] Запустить `scripts/test.sh`, собрать Loupe с локальным китом. Закоммитить только исходники и тесты Task 6.

## Task 7: Bench, regression and release readiness

**Files:** Loupe `Sources/LoupeBench/FolderSlotsBench.swift`, `Sources/LoupeBench/main.swift`, `docs/bench/2026-10-29-folder-slots.md`; тестовое окно AppKit подключить к отдельному bench-target, если текущий LoupeBench не может импортировать app UI. FrameScrub SlotsBench и отчёт регрессии Task 3.

**Consumes:** реальные SlotsController и FolderStripController, не имитация времени модели.
**Produces:** команда `LoupeBench folder-slots`, или отдельный `FolderSlotsBench` executable при выделенном UI-target; выбранное имя и точный запуск записать в bench doc при создании target.

- [ ] Реализовать bench реального NSWindow: cold show, return, tab switch, click, resize; CLOCK_THREAD_CPUTIME_ID, несколько последовательных раундов. Указать первые и повторные результаты, размеры списка, машину и архитектуру. Размер данных: малый и большой родитель из реальных наборов, плюс управляемая задержка source для stale-result сценария.
- [ ] Измерить запросы/слои/память во время длинной прокрутки; видимый пул не растёт с общим числом строк. Свернуть окно во время инерции: callbacks прекращаются, незавершённый preview сброшен. В покое проверить отсутствие активных display link/таймеров.
- [ ] На Intel проверить бюджеты 100/50/300 мс; если машины нет, отметить невыполненный acceptance criterion. Не заменять main-thread CPU wall-clock временем SMB.
- [ ] Прогнать kit `swift test`, FrameScrub `scripts/test.sh`, Loupe `scripts/test.sh`; визуально проверить стекло на светлом фото, clear text shadow, клавиатуру, VoiceOver и Reduce Motion. Повторять проверки только после относящихся к ним изменений.
- [ ] Закоммитить bench и отчёт. Выполнить whole-branch review с акцентом на пять Review Focus, lifecycle и отсутствие app-зависимостей в ките; исправления проверить адресно.

## Closing the branch

- [ ] Сначала показать пользователю результаты, известные ограничения и дифф; не объявлять Intel-бюджет проверенным без измерения.
- [ ] Когда закрытие ветки разрешено: HomeScreenKit tests → main → новый minor tag; приложения обновляют from/pin на этот тег вне edit mode; `scripts/kits-check.py` и CI зелёные; только затем merge приложений и удаление рабочих веток по docs/kits.md.
- [ ] Перед release-коммитами проверить, что исходные пользовательские Package.resolved/AGENTS.md не попали в дифф задачи. Плагинный мост остаётся следующим самостоятельным дизайном.

## Self-review

Покрытие спецификации: общий контейнер/фокус/совместимость — Tasks 1–3; папки, подпапки, archives/Stash и отмена — Tasks 4–5; UI, превью, доводка, layout и настройки — Task 6; бюджеты и жизненный цикл — Task 7. Все пять Review Focus привязаны к проверкам. Новые signatures совпадают между producer/consumer блоками. Неизвестные статистические поля допускают nil; рекурсивный All Photos не появляется как фиктивная функция.
