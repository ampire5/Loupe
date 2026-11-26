# Photo comparison window

The real-window debug workload opens two source tabs, sets different zoom and pan in each,
then opens and closes the comparison five times. It waits for the shared scale, sends a zoom
key, toggles linking, runs Match Visual Scale, switches away and back, and checks both sources'
saved views. With two files in the same directory it also extends the File View selection
with Shift-arrow and opens comparison through its selection action.

Run it with the SwiftPM debug binary and two files of equal proportions. Put only those files
in their directory to exercise File View.

```sh
Loupe --photo-comparison-bench /tmp/photos/original.jpg /tmp/photos/resized.jpg
```

## Measurements

MacBook Pro, Apple M4 Max, with a 6000 × 4000 JPEG and a 3000 × 2000 resize. Times are main-thread
CPU milliseconds measured with `CLOCK_THREAD_CPUTIME_ID` in the real AppKit window. Both originals
were already open for the repeated runs. A fresh comparison tab was built in each round.

| Action | Rounds | Median | Maximum |
| --- | ---: | ---: | ---: |
| Open a comparison tab | 5 | 115.194 | 127.226 |
| Return to an open comparison tab | 5 | 6.535 | 6.738 |
| Linked keyboard zoom | 5 | 0.093 | 0.103 |
| Unlink | 5 | 0.031 | 0.044 |
| Match Visual Scale | 5 | 0.012 | 0.012 |
| Open from File View selection | 1 | 127.610 | 127.610 |

The control timings cover action dispatch and view updates submitted by the action. Decode, Metal
presentation and native click animation run outside these measurements. There is no Intel measurement.
