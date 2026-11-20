# Web Images in Loupe Home

Measured on a Mac16,6 with an Apple M4 Max (14 physical cores), using a debug Loupe bundle in a real
AppKit window. The test bundle used disposable preferences, a loopback SearXNG fixture, and
`LOUPE_DEBUG=1`. The `turn` lines use `CLOCK_THREAD_CPUTIME_ID` and include AppKit layout and the
Core Animation commit in the measured turn. Network waiting and later image decoding are outside these
figures.

The fixture returned two results on page 1, one duplicate and one new result on page 2, then an empty
page. Its two originals and shared thumbnail were 128 × 128 PNGs. One original returned HTTP 404.
A separate request to the configured SearXNG instance returned 377 results for a neutral query.

| Action | Main-thread CPU, ms |
|---|---:|
| Cold window and first Web Images page, two launches | 114.3, 115.5 |
| Submit the restored query | 7.3 |
| First result open, including first construction of the viewer actions | 76.7 |
| Return to the same result grid, three rounds | 8.8, 40.0, 43.0 |
| Reopen a result after those returns | 8.1, 55.8, 53.9 |

The grid stayed in place across all three returns. Saving the selected original twice produced two
byte-identical files, including a numeric suffix on the second. The fixture observed original requests
only when their result was selected. It observed the first two pages in order and a single empty third page.

Intel timings and a longer run with a large live result grid remain unmeasured.
