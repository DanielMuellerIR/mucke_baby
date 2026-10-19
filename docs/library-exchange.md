# Library exchange format

The JSON exchange file carries stations, named groups and bookmarked tracks between devices. It contains no recordings, listening history, quick slots, startup selection, audio settings or other preferences.

Versions 1, 2 and 3 use the following top-level fields. Version 2 is required when a bookmark includes recognition provenance; version 3 is required when it includes a listening context. Exports without recognition remain version 1. All six fields are required; arrays may be empty.

| Field | Value |
| --- | --- |
| `format` | `"mucke-baby-library"` |
| `formatVersion` | `1`, `2` or `3` |
| `exportedAt` | ISO-8601 timestamp |
| `stations` | Station records in display order |
| `groups` | Group records in display order |
| `bookmarks` | Bookmarked track records in saved order |

Unknown fields are ignored. Unknown format names and versions are rejected without changing local data. The [example file](../Tests/Fixtures/library-exchange-v1.json) uses reserved example domains and fictional metadata.

## Records and limits

Station records contain a required UUID `id`, `name` and HTTP(S) `url`. Optional `enabled` and `favorite` flags default to `true` and `false`. `radioBrowserID` is an optional Radio-Browser UUID. Invalid present values are rejected rather than replaced with defaults. URLs with embedded user information or non-web schemes are not portable and are rejected.

Groups contain a required UUID `id`, `name` and ordered `stationIDs` array. Each referenced station must occur in the same file; a group cannot contain the same station ID twice. A station may belong to several groups.

Bookmarks contain a required UUID `id`, original `raw` track text, `station`, `heardAt` and `savedAt`. Optional `artist` and `title` preserve the parsed metadata. Different mixes remain distinct. Dates use ISO-8601 with seconds or fractional seconds and a timezone. Exports use UTC with millisecond precision.

Version 2 bookmarks may include a `recognition` object with required `source` (`"shazam"`), `recognizedAt`, `stationID` and `originalICY`. Optional `shazamID` and `appleMusicURL` retain the catalog reference. The title is required for recognized bookmarks. Recognition and listening timestamps remain separate. The original ICY string may be empty for a station that supplied no title; in that case `raw` contains the recognized display title and `originalICY` remains empty. Historical station IDs need not occur in the exported station list.

Version 3 adds an optional `recognition.listening` object with required UUID `outputID` and unsigned `revision`. Optional `position` (finite, nonnegative media seconds) and `receivedAt` (ISO-8601 audio-reception timestamp) must occur together for buffered playback; both are absent for direct playback. `heardAt` is the wall-clock time of the explicit recognition request, while `receivedAt` locates the heard audio in its earlier reception session. This is provenance, not a retained audio file. Versions 1/2 cannot carry this object. Older readers reject version 3 rather than silently dropping these fields. Existing version 2 recognition data remains readable and is not assigned invented output provenance.

Catalog links must use HTTPS on `music.apple.com`, without user information or a nonstandard port. Recognition originals have the same 4,096-byte and control-character limits as bookmark originals; catalog IDs are limited to 256 bytes. Invalid recognition data rejects the whole import. A version 1 document cannot carry recognition provenance. Readers that support only version 1 reject version 2 before modifying local data; a compatible recipient is required for exchanging recognized bookmarks.

The file limit is 8 MiB. A file may contain at most 2,000 stations, 200 groups and 20,000 bookmarks. IDs must be unique within each record type. Text limits are UTF-8 byte limits: station/group names and bookmark station names 256, URLs and original track text 4,096, artist/title 1,024. Names cannot contain control characters. Bookmark text may contain tabs and line breaks; other control characters are rejected. Empty station/group names and empty original track text are rejected.

## Compatibility and merge behavior

Legacy station arrays remain readable, including the older export without IDs. The Mac station collection with `formatVersion: 2` is also accepted. Missing legacy station IDs are assigned once when creating the preview. Quick slots in an old collection are not imported.

The Mac preview identifies new, unchanged and conflicting records before saving. New records are included by default; conflicts keep the local record by default. Every new record may be skipped. Each conflict offers **Keep local**, **Use imported** and **Keep both**.

An identical UUID matches a local record. A different station UUID can match by stream URL only when that URL occurs exactly once on both sides. URL matching preserves path/query case and includes all URL components, with HTTP(S) default ports normalized. Station names alone never identify a match. Groups can match by a unique name, ignoring case and character width. Bookmarks can match by a unique normalized artist/title pair, or original track text when parsed metadata is unavailable. Recognized bookmarks additionally match their original radio text, so one catalog title cannot merge different radio mixes or replace an existing station-text bookmark. These secondary matches remain visible as conflicts when the record differs.

Using an imported record retains the matched local ID. Keeping both assigns a fresh ID to the additional record. Group references follow the selected station IDs; skipped new stations are omitted from imported groups. Existing groups remain intact unless their conflict is explicitly resolved with the imported group. Additional groups receive an `Import` suffix when their name is already used. The preview shows the resulting group membership.

No existing record is deleted by import. Local quick slots remain attached to local station IDs. Changing a saved station URL does not replace a running stream; the next manual start uses the saved address.

An existing local legacy list keeps the IDs already assigned in memory throughout preview and confirmation. Confirmation makes those IDs persistent. A local entry that cannot be represented by the portable format blocks exchange with a visible message; the original data remains unchanged and normal local editing is still available.

## Saving and recovery

Preview and cancellation do not write the library. A stale in-memory or on-disk snapshot prevents applying the preview. A failure before the local transaction is committed preserves both existing files and their visible contents.

Stations and bookmarks commit together. If the app stops after committing but before completing the canonical files, the complete saved transaction is recovered on startup. A pending finalization is reported as a saved import, with further changes protected until restart. Damaged or unknown recovery data is preserved and blocks automatic replacement. Neither import nor export modifies recording files or history.

## Bookmark text and CSV exports

Text exports include the catalog title and recognition provenance for recognized tracks. CSV exports retain the six existing columns; when at least one exported entry has recognition provenance, they add `source`, `recognized_at`, `station_id`, `original_icy`, `shazam_id` and `apple_music_url`. Entries without recognition leave these additional fields empty. Formula-like values remain escaped for spreadsheet applications.
