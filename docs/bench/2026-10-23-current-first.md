# The current photo first on a share

What: the time from the current photo's read request to its bytes while neighbour reads run on the same share, with
the viewer's two read threads both open to neighbours (before) and with one kept for the current photo and the
neighbours paused while it reads (after, `IOPool`, `ReadPriority.isCurrent`). The numbers are quoted next to
`IOPool.viewerThreads`.

No share could be read from the session that measured this, so the share is simulated on local files:
`LoupeBench sharesim` (ShareSimBench.swift) runs the app's `FileReader` (four threads, the viewer's two among them) on
its chunked share path, and every 1 MiB chunk holds one link shared by all reads for 10 ms: about 100 MiB/s for all
reads together, a 1 GbE share. Each round reads three files as neighbours (unflagged, plan ranks 3, 4, 5), asks for
the next file as the current photo 100 ms later, and times that read.

Command (release build): `LoupeBench sharesim <folder>` (defaults: `--rounds 6 --neighbours 3 --link-mibps 100
--delay-ms 100`).

Before: the same harness built against `Sources/LoupeCore` of ebba891 (the commit before the change), with the line
`priority.isCurrent = !o.flagless` deleted (the flag does not exist there): `git diff --name-only ebba891 6dd4b5f --
Sources/LoupeCore | xargs git checkout ebba891 --`, build, run, `git checkout HEAD --` the same files.

Machine: iMac, Intel i7-10700K (8 cores, 16 threads), 64 GB, macOS 26.

Data: a local folder of baseline JPEGs of 4–25 MP on SSD, 10–19 MiB for the six files timed as the current photo
(the "alone" column: the file at 100 MiB/s with the link to itself).

| round | current MiB | alone ms | before run 1 | before run 2 | after run 1 | after run 2 |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 17.8 | 178 | 731 | 746 | 213 | 252 |
| 2 | 18.6 | 186 | 772 | 818 | 266 | 262 |
| 3 | 13.6 | 136 | 655 | 659 | 192 | 172 |
| 4 | 10.0 | 100 | 518 | 471 | 141 | 128 |
| 5 | 13.5 | 135 | 521 | 523 | 201 | 174 |
| 6 | 12.9 | 129 | 543 | 536 | 169 | 151 |

Before 471–818 ms, after 128–266 ms: the current read then costs the file's own time plus 30–80 ms (the neighbours'
chunks in flight when it starts). `--flagless` on the after build (the current read asked for as one more neighbour,
waiting for the one neighbour thread) gave 187–397 ms, p50 331.

On a local SSD the files are mapped and no read thread is held: `LoupeBench replay --script jumpfar --screen
5120x2880` over 165 such JPEGs (33 hard-linked five times), three runs per side, landings sharp after 209–308 ms
before and 199–314 ms after: no change.
