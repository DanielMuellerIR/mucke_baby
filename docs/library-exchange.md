# Library exchange format

The JSON exchange file carries stations, named groups and bookmarked tracks between devices. It contains no recordings, listening history, quick slots, startup selection, audio settings or other preferences.

Version 1 uses the following top-level fields. All six fields are required; arrays may be empty.

| Field | Value |
| --- | --- |
| `format` | `"mucke-baby-library"` |
| `formatVersion` | `1` |
| `exportedAt` | ISO-8601 timestamp |
| `stations` | Station records in display order |
| `groups` | Group records in display order |
| `bookmarks` | Bookmarked track records in saved order |

Unknown fields are ignored. Unknown format names and versions are rejected without changing local data. The [example file](../Tests/Fixtures/library-exchange-v1.json) uses reserved example domains and fictional metadata.

## Records and limits

Station records contain a required UUID `id`, `name` and HTTP(S) `url`. Optional `enabled` and `favorite` flags default to `true` and `false`. `radioBrowserID` is an optional Radio-Browser UUID. Invalid present values are rejected rather than replaced with defaults. URLs with embedded user information or non-web schemes are not portable and are rejected.

Groups contain a required UUID `id`, `name` and ordered `stationIDs` array. Each referenced station must occur in the same file; a group cannot contain the same station ID twice. A station may belong to several groups.

Bookmarks contain a required UUID `id`, original `raw` track text, `station`, `heardAt` and `savedAt`. Optional `artist` and `title` preserve the parsed metadata. Different mixes remain distinct. Dates use ISO-8601 with seconds or fractional seconds and a timezone. Exports use UTC with millisecond precision.

The file limit is 8 MiB. A file may contain at most 2,000 stations, 200 groups and 20,000 bookmarks. IDs must be unique within each record type. Text limits are UTF-8 byte limits: station/group names and bookmark station names 256, URLs and original track text 4,096, artist/title 1,024. Names cannot contain control characters. Bookmark text may contain tabs and line breaks; other control characters are rejected. Empty station/group names and empty original track text are rejected.

## Compatibility and merge behavior

Legacy station arrays remain readable, including the older export without IDs. The Mac station collection with `formatVersion: 2` is also accepted. Missing legacy station IDs are assigned once when creating the preview. Quick slots in an old collection are not imported.

The Mac preview identifies new, unchanged and conflicting records before saving. New records are included by default; conflicts keep the local record by default. Every new record may be skipped. Each conflict offers **Keep local**, **Use imported** and **Keep both**.

An identical UUID matches a local record. A different station UUID can match by stream URL only when that URL occurs exactly once on both sides. URL matching preserves path/query case and includes all URL components, with HTTP(S) default ports normalized. Station names alone never identify a match. Groups can match by a unique name, ignoring case and character width. Bookmarks can match by a unique normalized artist/title pair, or original track text when parsed metadata is unavailable. These secondary matches remain visible as conflicts when the record differs.

Using an imported record retains the matched local ID. Keeping both assigns a fresh ID to the additional record. Group references follow the selected station IDs; skipped new stations are omitted from imported groups. Existing groups remain intact unless their conflict is explicitly resolved with the imported group. Additional groups receive an `Import` suffix when their name is already used. The preview shows the resulting group membership.

No existing record is deleted by import. Local quick slots remain attached to local station IDs. Changing a saved station URL does not replace a running stream; the next manual start uses the saved address.

## Saving and recovery

Preview and cancellation do not write the library. A stale in-memory or on-disk snapshot prevents applying the preview. A failure before the local transaction is committed preserves both existing files and their visible contents.

Stations and bookmarks commit together. If the app stops after committing but before completing the canonical files, the complete saved transaction is recovered on startup. A pending finalization is reported as a saved import, with further changes protected until restart. Damaged or unknown recovery data is preserved and blocks automatic replacement. Neither import nor export modifies recording files or history.
