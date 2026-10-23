# Folder listing on SMB shares: names only vs any attribute

Why Loupe lists a share's folder by names first (`Playlist.quickList`, `BrowserListingSource.names`) and why folder
cards on a share are counted from names only (`ThumbnailStore.folderCard`, no `fstatat`).

## 2026-10-19 (first measurement, cited in code)

One folder of 1 735 files on an SMB share, cold client cache: one `readdir` pass for names took ~0.05 s; any listing
that asks for attributes — `contentsOfDirectory(atPath:)` included — took ~8 s.

## 2026-10-23 (re-measured)

Machine: Intel iMac, macOS smbfs client, SMB 3.1.1. A small C tool listed each folder one way; "cold" is the first
touch of a folder (folders of 30–300 entries nobody had opened), "warm" the same folder seconds later.

Servers:
- A: a Windows PC share reached over a VPN, ping ~9 ms, no Apple SMB extensions.
- B: a Samba NAS with Apple SMB extensions (`OS_X_SERVER TRUE` in `smbutil statshares`), ping ~95 ms.

| Method | A cold | B cold | warm (both) |
|---|---|---|---|
| `readdir`, names and `d_type` only | ~0.05 s a folder | 0.04–0.14 s a folder | — |
| `getattrlistbulk`, name + type | ~8 ms an entry | — | ~0.3 ms an entry |
| `getattrlistbulk`, + modification date | ~8 ms an entry | — | ~0.3 ms an entry |
| `getattrlistbulk`, + size | 14–19 ms an entry | 23–31 ms an entry | ~0.3 ms an entry |
| `readdir` then `fstatat` each (interleaved or in a second pass) | ~14–15 ms an entry | 22–35 ms an entry | ~0.3 ms an entry |
| Foundation `contentsOfDirectory(at:includingPropertiesForKeys:)` + resource values | 14–18 ms an entry | 21–25 ms an entry | ~0.3 ms an entry |
| `/bin/ls -l` | 20–40 ms an entry | ~40 ms an entry | ~0.7 ms an entry |

## Conclusion

The SMB protocol's directory query carries each entry's size and times, but the macOS client still makes a request
per entry as soon as anything beyond the names is asked — even the object type through `getattrlistbulk` — and the
Apple extensions do not change that. A folder of 300 photos costs seconds cold against a tenth of a second for its
names. So on a share Loupe lists names first and asks for dates and sizes only for the folder the user opened (the
browser's full listing, whose summary is kept in the catalog); unopened folders' cards stay counts only. Getting the
attributes in bulk would take an SMB client of Loupe's own, not the system's.
