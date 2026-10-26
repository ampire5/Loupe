# A folder opened again: its stored listing first, the share's after

Reported: back in a folder whose thumbnails and subfolders the catalog already has, Home waits for the share before it
shows anything, in the grid and in the sidebar's tree.

Now a folder's last listing is kept in `Catalog.db` (`folder_listings`, `StoredListing`: names, kinds, dates, sizes,
counts; up to 2 000 folders): every complete listing, and all of a folder's names as soon as they are in (each keeping
the date, size and count known before; a cold share can take a minute for the dates). Opening a folder not listed in
this run shows it at once as a listing still to be checked (`BrowserListing.isProvisional`: the loading line,
"Checking…" first in the subtitle), its pictures from the catalog by name; the share's complete listing replaces it,
adding and taking away what changed, the cards still there keeping their pictures. A share that does not answer: the
grid stays with a toast; a folder gone: up to the nearest one still there; a photo or folder of an unchecked grid that
is gone: a toast instead of opening it. The sidebar's tree takes a folder's subfolders from the same listing and is
told when the share's names differ.

What: scratchpad `stored-check.py`: a photo opened (`open-in=window`), Return to Folders on its folder, wait, quit;
twice. Times from `home shown` in the `LOUPE_DEBUG` log: `folder from the catalog` (the stored listing to the view),
`folder listing to the view` (the share's parts: names, then complete). M4 Max, release build; NAS = `nas2` over
Wi-Fi.

| Folder | Run | Stored listing on screen | Share: first names | Share: all names | Share: complete |
|---|---|---|---|---|---|
| PC share, 200 JPEG XL | 2 | +88 ms | +131 ms (complete) | | |
| NAS, 792 JPEG (thumbnails in the catalog) | 2 | +85 ms | – | – | +14.9 s |
| NAS, 2 017 JPEG, cold | 1 | – | +12.5–18.1 s | +55 s | not in 70 s |
| NAS, 2 017 JPEG | 2, 3 | +161, +736 ms | – | – | not in 25 s |

Found on the way: on a cold share `ThumbnailLocation.resolve` (`realpath`, `statfs`) waited 5 s and more for the share
(a sample: two threads in `getattrlist`/`lstat` under `resolveFolder` and `storedListing`), and every catalog lookup of
a folder waits for it: its thumbnails, counts and stored listing. On a share the location now comes from the mount
table alone (`ThumbnailLocation.onShare`, `getfsstat` with `MNT_NOWAIT`); local volumes still ask `statfs` (a
firmlinked `/Users/…` is on the Data volume).

`ls -f` of the 2 017-file NAS folder: 16 s cold; `ls -l` 51 s cold, 2.8 s warm; `contentsOfDirectory` with the
listing's keys 17.5 s, then 2.3 s: the client's attributes go cold within a minute.

Not done here: the browser's listing of a folder the viewer has just listed (Return from a photo) is a second listing
of it (the sample: `Playlist.relist` and `BrowserListingSource.names` at once on the same share).
