# Тесты: какие прогоны когда

`scripts/test.sh` — три прогона (частые прогоны не должны держать процессор на 100 %).

| Прогон | Что | Цена (M4 Max, 2026-10-16) | Когда |
|---|---|---|---|
| `scripts/test.sh` | все цели, кроме рендер-тестов Metal, параллельно | ~5 с, ~19 с CPU | после каждой правки, перед каждым коммитом |
| `scripts/test.sh render` | + рендер-тесты без матриц сверки с эталоном на CPU, по одному, `nice` | ~78 с, ~88 с CPU (одно ядро) | задача трогает `LoupeRender`, шейдеры, `ViewTransform`, цвет |
| `scripts/test.sh full` | + матрицы сверки (`LOUPE_FULL_TESTS=1`, `TestLevel.fullOnly`), по одному, `nice` | дольше, одно ядро | перед слиянием ветки, после правок рендера |

Loupe собирается со своей libjxl (клон рядом с репозиторием — `../libjxl` или `$LOUPE_LIBJXL`, ветка `loupe`): один раз и после правок ветки — `scripts/build-libjxl.sh`;
`test.sh` и `make-app.sh` подключают её через `scripts/libjxl-env.sh`. Голый `swift build` без этого падает на
`JxlDecoderLoupeVersion` — так и задумано.

Дополнительные аргументы (`--filter X`) уходят в каждый вызов `swift test`. Повторные `--filter` объединяются по ИЛИ, поэтому
если передан свой `--filter`, рендер-прогон берёт его вместо стандартного `--filter LoupeRenderTests` и сужается до него
(`scripts/test.sh render --filter OverscrollRenderTests`).

Почему по одному: параллельно рендер-тесты держат все ядра на 100 % и тратят в ~5 раз больше процессорного времени
(те же тесты: 424 с CPU за 39 с параллельно против 90 с CPU за 94 с по одному) — ожидание GPU и общий Metal-девайс
не делятся между потоками.

Матрицы только для полного прогона (`TestLevel.fullOnly`, `Tests/LoupeRenderTests/TestLevel.swift`): каждая сверяет
каждый пиксель с эталоном Core Graphics или CPU-ресемплером на десятках вариантов —
`orientedFrameMatchesCoreGraphics` (24 варианта, ~250 с CPU параллельно), `matchesReference` (ресемплинг, ~65 с),
`metalfxGeometry`, `extremeZoom`, `orientedPathsMatchTheOrientedPicture`, `orientedEdgesHaveNoFringe`,
`alphaCompositeMatchesReference` (~22 с по одному). Каждый путь отрисовки при этом остаётся в будничном рендер-прогоне
с более дешёвыми проверками.
